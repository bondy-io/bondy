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
Records the most recent root hash observed for each `(peer, instance)`
pair, plus the wall-clock timestamps of the last successful sync and
the last time we heard from the peer at all.

## Roles

- Sync sessions write here on successful completion (one root hash per
  `(peer, instance)`).
- Compaction reads here to compute the stability frontier — the
  largest event key reachable from every fresh peer's confirmed root.

## Stale-peer filtering

Reads accept an optional `since` parameter (a wall-clock millisecond
timestamp). Entries older than `since` are excluded. The default is
`now - peer_timeout_ms` where `peer_timeout_ms` is read from app env
(default 30 000ms). This ensures silent peers do not indefinitely block
GC.

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
    root_hash :: binary(),
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
    root_hash := binary(),
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
-export([get_peer_root_hash/2]).
-export([get_known_peers/1]).
-export([get_known_peers/2]).
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
Records the successful completion of an anti-entropy round between the
local replica and `Peer` for `Instance`. `RootHash` is the root hash
shared by both replicas at the end of the round.

Updates `last_sync` and `last_seen` to `os:system_time(millisecond)`.
""").
-spec record_sync_complete(peer_id(), instance_id(), binary()) -> ok.

record_sync_complete(Peer, Instance, RootHash) ->
    record_sync_complete(
        Peer, Instance, RootHash, os:system_time(millisecond)
    ).

-spec record_sync_complete(
    peer_id(), instance_id(), binary(), integer()
) -> ok.

record_sync_complete(Peer, Instance, RootHash, Now) ->
    gen_server:cast(
        ?MODULE,
        {record_sync_complete, Peer, Instance, RootHash, Now}
    ).

?DOC("""
Updates `last_seen` for `Peer` across all instances without recording a
new root hash. Used when the peer was contacted but the sync round
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
Returns the most recently recorded root hash from `Peer` for
`Instance`, or `not_found`.
""").
-spec get_peer_root_hash(peer_id(), instance_id()) ->
    {ok, binary()} | not_found.

get_peer_root_hash(Peer, Instance) ->
    case ets:lookup(?TABLE, {Peer, Instance}) of
        [#peer_instance_state{root_hash = H}] -> {ok, H};
        [] -> not_found
    end.

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
peers. Each entry is a map with `peer`, `instance`, `root_hash`,
`last_sync`, `last_seen`.
""").
-spec get_instance_peer_states(instance_id()) -> [peer_state_entry()].

get_instance_peer_states(Instance) ->
    Cutoff = os:system_time(millisecond) - peer_timeout_ms(),
    get_instance_peer_states(Instance, Cutoff).

-spec get_instance_peer_states(instance_id(), integer()) ->
    [peer_state_entry()].

get_instance_peer_states(Instance, Since) ->
    MatchSpec = [
        {
            #peer_instance_state{
                peer_instance = {'$1', '$2'},
                root_hash = '$3',
                last_sync = '$4',
                last_seen = '$5'
            },
            [
                {'=:=', '$2', {const, Instance}},
                {'>=', '$5', {const, Since}}
            ],
            [{{'$1', '$3', '$4', '$5'}}]
        }
    ],
    [
        #{
            peer => P,
            instance => Instance,
            root_hash => H,
            last_sync => LS,
            last_seen => LSeen
        }
     || {P, H, LS, LSeen} <- ets:select(?TABLE, MatchSpec)
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
30 000ms. Hot path on every stale-filter read.
""").
-spec peer_timeout_ms() -> non_neg_integer().

peer_timeout_ms() ->
    bondy_oplog_config:peer_timeout_ms().

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

handle_cast({record_sync_complete, Peer, Instance, Hash, Now}, State) ->
    Entry = #peer_instance_state{
        peer_instance = {Peer, Instance},
        root_hash = Hash,
        last_sync = Now,
        last_seen = Now
    },
    true = ets:insert(?TABLE, Entry),
    {noreply, State};
handle_cast({touch_peer, Peer, Now}, State) ->
    %% Update last_seen for every (Peer, _) entry.
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
