%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_peer_state).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
-moduledoc """
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

## Confirmation is by membership, never by recency

`confirmed_peer_states/2` takes the membership from the caller rather than
inferring it from who happens to be in this table. Every member must have a
recorded durable frontier or the call reports which do not, so a silent peer
holds stability down instead of vanishing from the computation. Removing a
permanently departed node is an explicit, replicated membership act — a
Partisan `leave`, never a timeout; peer discovery only joins (see
`bondy_oplog_origin_retirement`). A reading that dropped silent peers would
let stability advance without a peer that may return holding writes no other
member has: truncating on it loses them once both sides have truncated
(`proofs/tla/ConfirmedCompaction_3R_Fresh_Partition.cfg` violates
`NoLoss`), and reclaiming projection cells on it resurrects deleted data.

## Concurrency

The owning gen_server only handles writes (record/forget) and
diagnostic queries. Reads go directly to the ETS table — it is
created with `read_concurrency` and `protected` access, so any
process can read it without round-tripping the gen_server.
""".

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
    %% (`compute_frontier_for/2`) and the rebuild of a tree whose own root
    %% lost pages (licensed only when every member's recorded frontier
    %% covers the local applied one).
    frontier :: #{binary() => non_neg_integer()} | undefined,
    %% ms since UNIX epoch
    last_sync :: integer(),
    %% ms since UNIX epoch
    last_seen :: integer()
}).

-record(state, {}).

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
-export([get_known_peers/2]).
-export([confirmed_peer_states/2]).
-export([get_instance_peer_states/2]).
-export([info/0]).
-export([sync/0]).

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

-doc """
Records a completed anti-entropy round between the local replica and `Peer`
for `Instance`, and `Frontier`, the durable frontier `Peer` reported.
`undefined` (none reported) or an empty one refreshes recency and keeps the
frontier recorded before, so the rebuild's cover check never reads
"claims nothing" as covering an empty local frontier. Keeping it is meant for a
member whose durable frontier only grows; a member that lost its disk, or an
ephemeral one that restarted, keeps confirming its old claims until it reports
a non-empty frontier again.

Updates `last_sync` and `last_seen` to `os:system_time(millisecond)`.
""".
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

-doc """
Updates `last_seen` for `Peer` across all instances without recording a
new frontier. Used when the peer was contacted but the sync round
itself was a no-op.
""".
-spec touch_peer(peer_id()) -> ok.

touch_peer(Peer) ->
    gen_server:cast(?MODULE, {touch_peer, Peer, os:system_time(millisecond)}).

-doc """
Removes all entries for the given peer across every instance.
Idempotent.
""".
-spec forget_peer(peer_id()) -> ok.

forget_peer(Peer) ->
    gen_server:cast(?MODULE, {forget_peer, Peer}).

-doc """
Removes all entries for the given instance across every peer.
Called when an instance is stopped (the façade does this).
""".
-spec forget_instance(instance_id()) -> ok.

forget_instance(InstanceId) ->
    gen_server:cast(?MODULE, {forget_instance, InstanceId}).

%% =============================================================================
%% READS
%% =============================================================================

-doc """
Returns the peers that have a record for `Instance` whose `last_seen` is at or
after `Since` (ms since UNIX epoch).
""".
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

-doc """
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
""".
-spec confirmed_peer_states(instance_id(), Members :: [peer_id()]) ->
    {ok, [peer_state_entry()]} | {unconfirmed, [peer_id()]}.

confirmed_peer_states(_Instance, []) ->
    %% No members to confirm. `reclamation_members/0` lists none only with
    %% clustering disabled, where no other replica exists.
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

-doc """
Returns the per-peer records for `Instance` whose `last_seen` is at or after
`Since` (ms since UNIX epoch). Each entry is a map with `peer`, `instance`,
`frontier`, `last_sync`, `last_seen`.
""".
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

-doc """
Returns operational diagnostics. Cheap.
""".
-spec info() -> map().

info() ->
    #{
        table_size => ets:info(?TABLE, size),
        memory_words => ets:info(?TABLE, memory)
    }.

-doc """
Synchronous round-trip through the gen_server. Returns when every
cast queued before this call has been processed. Useful in tests and
in code that needs read-after-write consistency for casts.
""".
-spec sync() -> ok.

sync() ->
    gen_server:call(?MODULE, sync).

%% =============================================================================
%% gen_server CALLBACKS
%% =============================================================================

init(_Opts) ->
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
    {ok, #state{}}.

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
