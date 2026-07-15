%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_quarantine).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Node-shared quarantine table for detected equivocations.

When `bondy_oplog_instance:append_remote/2` receives a peer
event whose `{HLC, Origin, Seq}` key already binds to a different
value locally, the validator's `detect_equivocation/2` is invoked and
the proof is recorded here. The MST is *not* mutated — the divergent
incoming event is rejected with `{error, equivocation_detected}`.

Each row is keyed by `{instance_id(), event_key()}` so that the same
Origin equivocating across multiple instances produces one row per
instance — useful for ops triage.

## Use

The library *records* equivocations; it does not act on them. A
typical operator workflow:

1. Inspect `list_for_instance/1` or `list_all/0`.
2. Decide whether the offending Origin should be banned (see
   `bondy_oplog_origin_bans`).
3. Optionally call `forget_instance/1` after clean-up.

## Concurrency

Writes (`record/5`) flow through the gen_server (cast — fire-and-forget).
Reads go directly to ETS.
""").

-define(TABLE, bondy_oplog_quarantine_tab).

-record(quarantined, {
    key :: {instance_id(), bondy_oplog_event:event_key()},
    event_one :: bondy_oplog_event:t(),
    event_two :: bondy_oplog_event:t(),
    proof :: term(),
    first_seen :: integer()
}).

-record(state, {}).

-type entry() :: #{
    instance_id := instance_id(),
    event_key := bondy_oplog_event:event_key(),
    event_one := bondy_oplog_event:t(),
    event_two := bondy_oplog_event:t(),
    proof := term(),
    first_seen := integer()
}.

-export_type([entry/0]).

%% Lifecycle
-export([start_link/0]).
-export([child_spec/0]).

%% Writes
-export([record/5]).
-export([forget_instance/1]).

%% Reads
-export([lookup/2]).
-export([list_for_instance/1]).
-export([list_all/0]).

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
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec child_spec() -> supervisor:child_spec().

child_spec() ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

%% =============================================================================
%% WRITES
%% =============================================================================

?DOC("""
Records a detected equivocation. Idempotent on `(InstanceId, EventKey)` —
re-recording overwrites `event_two` and `proof` while preserving the
original `first_seen`.

Cast; fire-and-forget. The instance gen_server does not block on this.
""").
-spec record(
    InstanceId :: instance_id(),
    EventKey :: bondy_oplog_event:event_key(),
    EventOne :: bondy_oplog_event:t(),
    EventTwo :: bondy_oplog_event:t(),
    Proof :: term()
) -> ok.

record(InstanceId, EventKey, EventOne, EventTwo, Proof) when
    is_binary(InstanceId)
->
    gen_server:cast(
        ?MODULE,
        {record, InstanceId, EventKey, EventOne, EventTwo, Proof,
            os:system_time(millisecond)}
    ).

?DOC("""
Removes all quarantine entries for the given instance. Used when an
instance is destroyed.
""").
-spec forget_instance(InstanceId :: instance_id()) -> ok.

forget_instance(InstanceId) when is_binary(InstanceId) ->
    gen_server:cast(?MODULE, {forget_instance, InstanceId}).

%% =============================================================================
%% READS
%% =============================================================================

?DOC("""
Returns the quarantine entry for `(InstanceId, EventKey)`, or
`not_found`.
""").
-spec lookup(
    instance_id(), bondy_oplog_event:event_key()
) -> {ok, entry()} | not_found.

lookup(InstanceId, EventKey) when is_binary(InstanceId) ->
    case ets:lookup(?TABLE, {InstanceId, EventKey}) of
        [Row] -> {ok, to_entry(Row)};
        [] -> not_found
    end.

?DOC("""
Returns all quarantine rows for `InstanceId`.
""").
-spec list_for_instance(instance_id()) -> [entry()].

list_for_instance(InstanceId) when is_binary(InstanceId) ->
    MatchSpec = [
        {
            #quarantined{key = {'$1', '_'}, _ = '_'},
            [{'=:=', '$1', {const, InstanceId}}],
            ['$_']
        }
    ],
    [to_entry(R) || R <- ets:select(?TABLE, MatchSpec)].

?DOC("""
Returns all quarantine rows across all instances.
""").
-spec list_all() -> [entry()].

list_all() ->
    [to_entry(R) || R <- ets:tab2list(?TABLE)].

%% =============================================================================
%% gen_server CALLBACKS
%% =============================================================================

init([]) ->
    process_flag(trap_exit, true),
    _Tab = ets:new(?TABLE, [
        named_table,
        set,
        protected,
        {keypos, #quarantined.key},
        {read_concurrency, true}
    ]),
    {ok, #state{}}.

handle_call(_Req, _From, State) ->
    {reply, {error, badcall}, State}.

handle_cast({record, InstanceId, EventKey, E1, E2, Proof, Now}, State) ->
    Key = {InstanceId, EventKey},
    Existing =
        case ets:lookup(?TABLE, Key) of
            [#quarantined{first_seen = FS}] -> FS;
            [] -> Now
        end,
    Entry = #quarantined{
        key = Key,
        event_one = E1,
        event_two = E2,
        proof = Proof,
        first_seen = Existing
    },
    true = ets:insert(?TABLE, Entry),
    ?LOG_WARNING(#{
        description => "equivocation quarantined",
        instance_id => InstanceId,
        event_key => EventKey,
        proof => Proof
    }),
    {noreply, State};
handle_cast({forget_instance, InstanceId}, State) ->
    MatchSpec = [
        {
            #quarantined{key = {'$1', '_'}, _ = '_'},
            [{'=:=', '$1', {const, InstanceId}}],
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
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
to_entry(#quarantined{
    key = {Inst, K},
    event_one = E1,
    event_two = E2,
    proof = P,
    first_seen = FS
}) ->
    #{
        instance_id => Inst,
        event_key => K,
        event_one => E1,
        event_two => E2,
        proof => P,
        first_seen => FS
    }.
