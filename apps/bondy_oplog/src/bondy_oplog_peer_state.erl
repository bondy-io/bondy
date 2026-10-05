%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_peer_state).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Node-shared peer-state registry.

A single ETS `set` table per node, keyed by `{peer_id, instance_id}`.
Records the most recent durable frontier reported for each `(peer, instance)`
pair, plus the wall-clock timestamps of the last successful sync and the last
time we heard from the peer at all.

## Roles

- Sync sessions write here on successful completion: the initiator records
  the peer's durable frontier, and the peer records the initiator's, which the
  initiator reports to it (`confirm_frontier`).
- Compaction and reclamation read here to compute the stability
  frontier — the largest event key every member has confirmed by its
  recorded durable frontier (folded and checkpointed, and possibly compacted
  since).

## Two readings, for two different safety requirements

**Recency-filtered** (`get_instance_peer_states/1,2`) — entries older than
`now - peer_timeout_ms` (app env, default 30 000ms) are excluded: the peers
heard from recently.

It is **not** sound for anything that must not lose history or reclaims. A
peer partitioned for `peer_timeout_ms + 1` is silently left out, stability
advances without it, and it may return holding writes no other member has.
Truncating the MST on this reading loses them once both sides have truncated
(`proofs/tla/ConfirmedCompaction_RootVV3_Fresh_Partition.cfg` violates
`NoLoss`), which only a fused instance's compaction accepts
(`bondy_oplog_compaction`); reclaiming projection cells on it resurrects
deleted data.

**Strict** (`confirmed_peer_states/2`) — no recency filter, and membership is
supplied by the caller rather than inferred from who happens to be in this
table. Every member must have a recorded durable frontier or the call reports
which do not, so a silent peer holds stability down instead of vanishing from
the computation. Removing a permanently departed node is then an explicit,
replicated membership act — a Partisan `leave`, never a timeout; peer
discovery only joins (see `bondy_oplog_origin_retirement`).

The distinction is deliberate: these are not two ways of asking the same
question. Reclamation, and compaction of any instance that is not fused, MUST
use the strict reading.

## Concurrency

The owning gen_server only handles writes (record/forget) and
diagnostic queries. Reads go directly to the ETS table — it is
created with `read_concurrency` and `protected` access, so any
process can read it without round-tripping the gen_server.
""").

%% Named ETS tables share the namespace with registered process names.
%% The gen_server is registered as `?MODULE`; the table needs a distinct
%% atom so callers can `ets:lookup/2` without ambiguity.
-define(TABLE, bondy_oplog_peer_state_tab).

%% Stored as `set` ETS records keyed by the `peer_instance` 2-tuple.
-record(peer_instance_state, {
    peer_instance :: {peer_id(), instance_id()},
    %% The peer's durable frontier (`bondy_oplog_instance:durable_frontier/1`),
    %% as it last reported it. `undefined` until it reports a non-empty one.
    %% Two consumers in `bondy_oplog_instance`: the stability frontier
    %% (`compute_frontier_for/2`) and the unservable-own-root self-heal (a
    %% rebuild is licensed only when every recency-live peer's recorded
    %% frontier dominates the local one).
    frontier :: #{binary() => non_neg_integer()} | undefined,
    %% ms since UNIX epoch
    last_sync :: integer(),
    %% ms since UNIX epoch
    last_seen :: integer()
}).

-record(state, {
    peer_timeout_ms :: non_neg_integer()
}).

-type peer_state_entry() :: #{
    peer := peer_id(),
    instance := instance_id(),
    frontier := #{binary() => non_neg_integer()} | undefined,
    last_sync := integer(),
    last_seen := integer()
}.

-export_type([peer_state_entry/0]).

%% Lifecycle
-export([start_link/0]).
-export([start_link/1]).
-export([child_spec/1]).

%% Writes
-export([record_sync_complete/3]).
-export([record_sync_complete/4]).
-export([touch_peer/1]).
-export([forget_peer/1]).
-export([forget_instance/1]).

%% Reads (direct ETS, no gen_server roundtrip)
-export([get_known_peers/1]).
-export([get_known_peers/2]).
-export([confirmed_peer_states/2]).
-export([get_instance_peer_states/1]).
-export([get_instance_peer_states/2]).
-export([info/0]).
-export([sync/0]).

%% Tuning
-export([peer_timeout_ms/0]).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

%% =============================================================================
%% LIFECYCLE
%% =============================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.

start_link() ->
    start_link(#{}).

-spec start_link(map()) -> {ok, pid()} | {error, term()}.

start_link(Opts) when is_map(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

-spec child_spec(map()) -> supervisor:child_spec().

child_spec(Opts) ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, [Opts]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

%% =============================================================================
%% WRITES
%% =============================================================================

?DOC("""
Records a completed anti-entropy round between the local replica and `Peer`
for `Instance`, and `Frontier`, the durable frontier `Peer` reported.
`undefined` (none reported) or an empty one refreshes recency and keeps the
frontier recorded before, so the self-heal's domination gate never reads
"claims nothing" as covering an empty local frontier. Keeping it is meant for a
member whose durable frontier only grows; a member that lost its disk, or an
ephemeral one that restarted, keeps confirming its old claims until it reports
a non-empty frontier again.

Updates `last_sync` and `last_seen` to `os:system_time(millisecond)`.
""").
-spec record_sync_complete(
    peer_id(), instance_id(), #{binary() => non_neg_integer()} | undefined
) -> ok.

record_sync_complete(Peer, Instance, Frontier) ->
    record_sync_complete(
        Peer, Instance, Frontier, os:system_time(millisecond)
    ).

-spec record_sync_complete(
    peer_id(),
    instance_id(),
    #{binary() => non_neg_integer()} | undefined,
    integer()
) -> ok.

record_sync_complete(Peer, Instance, Frontier, Now) ->
    gen_server:cast(
        ?MODULE, {record_sync_complete, Peer, Instance, Frontier, Now}
    ).

?DOC("""
Updates `last_seen` for `Peer` across all instances without recording a
new frontier. Used when the peer was contacted but the sync round
itself was a no-op.
""").
-spec touch_peer(peer_id()) -> ok.

touch_peer(Peer) ->
    gen_server:cast(?MODULE, {touch_peer, Peer, os:system_time(millisecond)}).

?DOC("""
Removes all entries for the given peer across every instance.
Idempotent.
""").
-spec forget_peer(peer_id()) -> ok.

forget_peer(Peer) ->
    gen_server:cast(?MODULE, {forget_peer, Peer}).

?DOC("""
Removes all entries for the given instance across every peer.
Called when an instance is stopped (the façade does this).
""").
-spec forget_instance(instance_id()) -> ok.

forget_instance(InstanceId) ->
    gen_server:cast(?MODULE, {forget_instance, InstanceId}).

%% =============================================================================
%% READS
%% =============================================================================

?DOC("""
Returns the list of peers that have any record for `Instance`,
excluding peers whose `last_seen` is older than the configured
`peer_timeout_ms`.
""").
-spec get_known_peers(instance_id()) -> [peer_id()].

get_known_peers(Instance) ->
    Cutoff = os:system_time(millisecond) - peer_timeout_ms(),
    get_known_peers(Instance, Cutoff).

-spec get_known_peers(instance_id(), Since :: integer()) -> [peer_id()].

get_known_peers(Instance, Since) ->
    %% Match-spec: pick peer ids for matching instance with last_seen >= Since.
    MatchSpec = [
        {
            #peer_instance_state{
                peer_instance = {'$1', '$2'},
                last_seen = '$3',
                _ = '_'
            },
            [
                {'=:=', '$2', {const, Instance}},
                {'>=', '$3', {const, Since}}
            ],
            ['$1']
        }
    ],
    ets:select(?TABLE, MatchSpec).

?DOC("""
Returns the full per-peer record set for `Instance`, excluding stale
peers. Each entry is a map with `peer`, `instance`, `frontier`, `last_sync`,
`last_seen`.
""").
-spec get_instance_peer_states(instance_id()) -> [peer_state_entry()].

get_instance_peer_states(Instance) ->
    Cutoff = os:system_time(millisecond) - peer_timeout_ms(),
    %% One unfiltered select, partitioned here, so reporting the exclusions
    %% costs no second select.
    {Fresh, Excluded} = lists:partition(
        fun(#{last_seen := Seen}) -> Seen >= Cutoff end,
        get_instance_peer_states(Instance, 0)
    ),
    ok = report_excluded(Instance, Excluded),
    Fresh.

?DOC("""
Strict reading of the peer states for `Instance`, for callers that drop
history or reclaim irreversibly.

`Members` is the set of peers that must have confirmed — supplied by the
caller, because this table only knows peers it has synced with at least once
and "never synced" is indistinguishable from "absent" here.

Returns `{ok, States}` only when every member has a recorded durable frontier.
There is **no recency filter**: a silent member holds stability down rather
than being dropped, which is what makes reclamation safe.
`{unconfirmed, Peers}` names the members still missing, so a caller can log or
expose why stability is not advancing.

Contrast `get_instance_peer_states/1`, which drops peers unheard-from within
`peer_timeout_ms`, and is unsound for any caller that must not lose history.
""").
-spec confirmed_peer_states(instance_id(), Members :: [peer_id()]) ->
    {ok, [peer_state_entry()]} | {unconfirmed, [peer_id()]}.

confirmed_peer_states(_Instance, []) ->
    %% No members: nothing can contradict us, so everything is trivially
    %% stable. A genuinely solo instance is the one case where reclamation
    %% needs no confirmation at all.
    {ok, []};
confirmed_peer_states(Instance, Members) when is_list(Members) ->
    %% `0` ⇒ no recency filter, deliberately. A row with no recorded
    %% frontier proves recency, NOT confirmation — it must never satisfy the
    %% stability requirement.
    States = get_instance_peer_states(Instance, 0),
    Confirmed =
        #{
            maps:get(peer, S) => S
         || S <- States, is_map(maps:get(frontier, S))
        },

    case [P || P <- Members, not is_map_key(P, Confirmed)] of
        [] ->
            {ok, [maps:get(P, Confirmed) || P <- Members]};
        Missing ->
            {unconfirmed, Missing}
    end.

-spec get_instance_peer_states(instance_id(), integer()) ->
    [peer_state_entry()].

get_instance_peer_states(Instance, Since) ->
    MatchSpec = [
        {
            #peer_instance_state{
                peer_instance = {'$1', '$2'},
                frontier = '$6',
                last_sync = '$4',
                last_seen = '$5'
            },
            [
                {'=:=', '$2', {const, Instance}},
                {'>=', '$5', {const, Since}}
            ],
            [{{'$1', '$6', '$4', '$5'}}]
        }
    ],
    [
        #{
            peer => P,
            instance => Instance,
            frontier => F,
            last_sync => LS,
            last_seen => LSeen
        }
     || {P, F, LS, LSeen} <- ets:select(?TABLE, MatchSpec)
    ].

?DOC("""
Returns operational diagnostics. Cheap.
""").
-spec info() -> map().

info() ->
    #{
        table_size => ets:info(?TABLE, size),
        memory_words => ets:info(?TABLE, memory),
        peer_timeout_ms => peer_timeout_ms()
    }.

?DOC("""
Returns the configured `peer_timeout_ms` from app env, defaulting to
30 000ms. Read on every recency-filtered read.
""").
-spec peer_timeout_ms() -> non_neg_integer().

peer_timeout_ms() ->
    bondy_oplog_config:peer_timeout_ms().

%% @private
%% A peer left out of a recency-filtered read must not be invisible: an
%% operator needs to connect the decision taken without it to a peer that keeps
%% ageing out. Telemetry only, deliberately no log: a level-triggered log line
%% would storm for as long as the peer stays silent, and telemetry handlers can
%% aggregate or rate-limit where a log statement here cannot.
report_excluded(_Instance, []) ->
    ok;
report_excluded(Instance, Excluded) ->
    telemetry:execute(
        [bondy_oplog, peer_state, excluded],
        #{count => length(Excluded)},
        #{
            instance_id => Instance,
            peers => [maps:get(peer, S) || S <- Excluded],
            peer_timeout_ms => peer_timeout_ms()
        }
    ),
    ok.

?DOC("""
Synchronous round-trip through the gen_server. Returns when every
cast queued before this call has been processed. Useful in tests and
in code that needs read-after-write consistency for casts.
""").
-spec sync() -> ok.

sync() ->
    gen_server:call(?MODULE, sync).

%% =============================================================================
%% gen_server CALLBACKS
%% =============================================================================

init(Opts) ->
    process_flag(trap_exit, true),
    %% Absorbs remote-event / anti-entropy bursts during sync; off_heap
    %% mailbox so a sync burst backlog isn't re-scanned by the GC.
    process_flag(message_queue_data, off_heap),
    _Tab = ets:new(?TABLE, [
        named_table,
        set,
        protected,
        {keypos, #peer_instance_state.peer_instance},
        {read_concurrency, true}
    ]),
    {ok, #state{
        peer_timeout_ms = maps:get(peer_timeout_ms, Opts, peer_timeout_ms())
    }}.

handle_call(sync, _From, State) ->
    {reply, ok, State};
handle_call(_Req, _From, State) ->
    {reply, {error, badcall}, State}.

handle_cast(
    {record_sync_complete, Peer, Instance, Frontier0, Now}, State
) ->
    Key = {Peer, Instance},
    Prev =
        case ets:lookup(?TABLE, Key) of
            [#peer_instance_state{} = P] -> P;
            [] -> undefined
        end,
    Frontier =
        case {Frontier0, Prev} of
            {F, _} when is_map(F), map_size(F) > 0 -> F;
            {_, #peer_instance_state{frontier = PF}} -> PF;
            {_, undefined} -> undefined
        end,
    Entry = #peer_instance_state{
        peer_instance = Key,
        frontier = Frontier,
        last_sync = Now,
        last_seen = Now
    },
    true = ets:insert(?TABLE, Entry),
    {noreply, State};
handle_cast({touch_peer, Peer, Now}, State) ->
    MatchSpec = [
        {
            #peer_instance_state{
                peer_instance = {'$1', '_'},
                _ = '_'
            },
            [{'=:=', '$1', {const, Peer}}],
            ['$_']
        }
    ],
    Entries = ets:select(?TABLE, MatchSpec),
    [
        ets:insert(?TABLE, E#peer_instance_state{last_seen = Now})
     || E <- Entries
    ],
    {noreply, State};
handle_cast({forget_peer, Peer}, State) ->
    %% select_delete with match-spec; never tab2list+filter.
    MatchSpec = [
        {
            #peer_instance_state{
                peer_instance = {'$1', '_'},
                _ = '_'
            },
            [{'=:=', '$1', {const, Peer}}],
            [true]
        }
    ],
    _ = ets:select_delete(?TABLE, MatchSpec),
    {noreply, State};
handle_cast({forget_instance, Instance}, State) ->
    MatchSpec = [
        {
            #peer_instance_state{
                peer_instance = {'_', '$1'},
                _ = '_'
            },
            [{'=:=', '$1', {const, Instance}}],
            [true]
        }
    ],
    _ = ets:select_delete(?TABLE, MatchSpec),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    %% The named ETS is automatically cleaned up when the owner exits.
    ok.
