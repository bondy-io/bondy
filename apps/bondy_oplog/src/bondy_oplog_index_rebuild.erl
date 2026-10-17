%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_index_rebuild).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Serialised rebuild orchestrator for the secondary indexes.

A secondary index is a deterministic function of the primary. It is
therefore *rebuildable* at any time from the primary's converged
projection — the authoritative source — whether it is backed by ETS (an
ephemeral table; wiped on node death) or by leveled (a durable table;
persists, but a rebuild still re-derives it). This singleton gen_server is
the one place rebuilds run, so they never race each other (a clear
interleaving another rebuild's flush would lose data).

## What a rebuild does

For one index `(NS, IndexName)`:

1. **Discard + wipe** every target secondary shard: mark it for rebuild,
   remove its durable trust marker (`index_untrust/1`; the mark's own removal
   is best-effort and can be lost, `IndexIntents_UnmarkLost_2Shards.cfg`), and
   sync it, so a crash after the wipe leaves it untrusted on disk
   (`proofs/tla/IndexIntents.tla`, the `IndexIntents_NoSyncBeforeWipe.cfg`
   ablation). A failed removal or sync fails the run before the wipe. Then
   reset the writer's
   buffered ops (stale, possibly for terms since removed), `clear/2` the
   shard's projection scoped to the index's bucket suffix (so orphaned
   terms do not survive, without touching co-located tables on a shared
   backend), reset the in-flight counter, and reset freshness to stale so
   reads refuse mid rebuild.
2. **Re-derive** every primary shard's index via
   `bondy_oplog_applier:rebuild_indexes_sync/2`, naming the shard, so a
   shared instance re-folds this table and not the one that founded it. That
   reads each live
   cell's CURRENT projection value and re-dispatches a `put` for every live
   term of every cell, bypassing the back-pressure cap so the full working
   set lands in one pass. (Reading the converged value, rather than
   replaying the cell's events, is what keeps a context-carrying tier_2
   index from latching superseded multi-value siblings.)
3. **Flush** every secondary writer in the namespace (the target index
   plus any sibling indexes that received idempotent re-puts from the
   shared re-fold), draining buffers and decrementing in-flight counters,
   then sync every target shard, so its trust marker is never written ahead
   of the re-fold it vouches for (the `IndexIntents_NoSyncBeforeMark.cfg`
   ablation).
4. **Freshen** the target shards (bump AE, clear `needs_rebuild`) so reads
   pass again — including shards whose working set is empty, which a
   plain write path would leave sentinel-stale forever. This step runs only
   when every primary was re-folded and every target shard's writer
   flushed and its projection synced, and a shard is cleared only if nothing marked it after its wipe
   (`bondy_oplog_core_registry:index_clear_rebuild/2`). A writer that died
   after the run read the registry fails its flush, so a re-fold it lost
   fails the run. Otherwise the index stays marked and the rebuild runs
   again, its delay doubling up to a minute (`bondy_db_index_lag_test`:
   `rebuild_keeps_mark_when_writer_lost_the_refold`,
   `rebuild_keeps_mark_when_marked_during_run`).
   `proofs/tla/IndexIntents_NoIntents_Writer.cfg` and
   `IndexIntents_DrainRequests.cfg` show an index trusted incomplete
   without these checks; `IndexIntents_NoIntents_Writer_MarkNeedsFlush.cfg`
   holds with them.

## Triggers

- **Untrusted at open** — `bondy_db:open_table` calls `rebuild_sync/2` for
  an index one of whose shards has no trust marker (never built, or a mark
  removed it). An index whose every shard has one is trusted and only
  freshened; the open replays the primaries' leftover index intents instead
  (`bondy_db_index_coldstart_test`).
- **Saturation** — the primary applier drops a batch that would overflow a
  secondary writer's backlog, marks the shard, and `request/2`s a rebuild.
- **Writer crash** — on restart a writer marks its in-memory index shards
  that had been populated and `request/2`s their rebuild. Its durable shards
  replay their primaries' leftover index intents instead.
- **Failed index write** — a writer whose projection write fails, and a
  catalogue install whose group or sync fails
  (`bondy_oplog_cell_apply:settle_install/3`), mark the affected shards.
- **Operator / tests** — `bondy_db:rebuild_index/2` (sync barrier).

## Serialisation + coalescing

`rebuild_sync/2` (a call) and `request/2` (a cast) both run the rebuild
inline in the gen_server, so only one runs at a time across all indexes.
A burst of identical `request/2`s for the same index is coalesced: after a
rebuild the handler drains any further pending requests for that index
from its mailbox. Every trigger marks before it requests: a mark after the
rebuild's wipe fails the run, which then runs again, and a mark before it is
covered by the run.
""").

-export([child_spec/0]).
-export([start_link/0]).
-export([request/2]).
-export([mark/1]).
-export([rebuild_sync/2]).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-define(SERVER, ?MODULE).
%% The substrate's reserved primary-index id (matches `bondy_db`'s
%% `?INDEX`). Registry rows under this index are the primary shards; any
%% other index id is a secondary.
-define(INDEX, primary).
-define(RETRY_MS, 1000).
-define(RETRY_MAX_MS, 60000).
-define(FLUSH_TIMEOUT_MS, 5000).

%% =============================================================================
%% API
%% =============================================================================

child_spec() ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-doc """
Request an asynchronous rebuild of `(NS, IndexName)`. Fire-and-forget and
coalesced; used by the autonomous triggers (saturation drop, writer crash)
where the caller must not block. The shard's `needs_rebuild` flag (set by
the trigger) keeps reads refusing until the rebuild completes, so a lost
cast is self-healing — the next read or operator call re-requests.
""".
-spec request(atom(), atom()) -> ok.

request(NS, IndexName) when is_atom(NS), is_atom(IndexName) ->
    gen_server:cast(?SERVER, {request, NS, IndexName}).

-doc """
Mark the index shard `Entry` for rebuild and request a rebuild of its index.
The mark makes the shard's reads refuse and keeps a close from stamping it
clean until a rebuild completes.
""".
-spec mark(bondy_oplog_core_registry:shard_entry()) -> ok.

mark(Entry) ->
    ok = bondy_oplog_core_registry:index_mark_rebuild(Entry),
    {NS, IndexName, _Shard} = bondy_oplog_core_registry:entry_key(Entry),
    request(NS, IndexName).

-doc """
Synchronously rebuild `(NS, IndexName)` and return once the index has been
re-materialised from the primary and its target shards freshened. The
barrier used by `bondy_db:open_table` for an untrusted index, the operator
API, and tests.
""".
-spec rebuild_sync(atom(), atom()) -> ok | {error, term()}.

rebuild_sync(NS, IndexName) when is_atom(NS), is_atom(IndexName) ->
    gen_server:call(?SERVER, {rebuild, NS, IndexName}, infinity).

%% =============================================================================
%% gen_server callbacks
%% =============================================================================

init([]) ->
    {ok, #{}}.

handle_call({rebuild, NS, IndexName}, _From, State) ->
    Result = run_rebuild(NS, IndexName),
    {reply, Result, schedule(NS, IndexName, Result, State)};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({request, NS, IndexName}, State) ->
    Result = run_rebuild(NS, IndexName),
    ok = drain_requests(NS, IndexName),
    {noreply, schedule(NS, IndexName, Result, State)};
handle_cast(_, State) ->
    {noreply, State}.

handle_info({retry, NS, IndexName}, State) ->
    Retry = maps:get({NS, IndexName}, State, #{}),
    handle_cast(
        {request, NS, IndexName},
        State#{{NS, IndexName} => Retry#{timer => undefined}}
    );
handle_info(_, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% INTERNAL
%% =============================================================================

drain_requests(NS, IndexName) ->
    receive
        {'$gen_cast', {request, NS, IndexName}} ->
            drain_requests(NS, IndexName)
    after 0 ->
        ok
    end.

%% @private
%% The run is a monitored worker so that a raise inside it is a crash report
%% with its stack and a retry, and never the orchestrator's own death: the
%% retry timers live in the orchestrator's state.
run_rebuild(NS, IndexName) ->
    Parent = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        Parent ! {rebuild_result, self(), do_run_rebuild(NS, IndexName)}
    end),
    receive
        {rebuild_result, Pid, Result} ->
            true = erlang:demonitor(Ref, [flush]),
            Result;
        {'DOWN', Ref, process, Pid, Reason} ->
            ?LOG_ERROR(#{
                description =>
                    "bondy_oplog_index_rebuild rebuild worker crashed; the "
                    "index stays marked for rebuild and the rebuild runs "
                    "again.",
                namespace => NS,
                index_name => IndexName,
                reason => Reason
            }),
            {error, {rebuild_crashed, Reason}}
    end.

do_run_rebuild(NS, IndexName) ->
    T0 = erlang:monotonic_time(microsecond),
    Shards = bondy_oplog_core_registry:shards_for(NS),
    Primaries = [E || E <- Shards, index_of(E) =:= ?INDEX],
    Targets = [E || E <- Shards, index_of(E) =:= IndexName],
    AllSec = [E || E <- Shards, is_secondary(E)],
    case Targets of
        [] ->
            ok;
        _ ->
            Result = do_rebuild(Primaries, Targets, AllSec),
            DurUs = erlang:monotonic_time(microsecond) - T0,
            telemetry:execute(
                [bondy_oplog, secondary_index, rebuild],
                #{
                    duration_us => DurUs,
                    target_shards => length(Targets),
                    primary_shards => length(Primaries)
                },
                #{
                    namespace => NS,
                    index_name => IndexName,
                    result => Result
                }
            ),
            settle(NS, IndexName, Result)
    end.

%% @private
do_rebuild(Primaries, Targets, AllSec) ->
    Seen = [{E, reset_target_shard(E)} || E <- Targets],
    Refolded = [refold_primary(E) || E <- Primaries],
    Flushed = [
        {E, bondy_oplog_secondary_writer:flush_entry(E, ?FLUSH_TIMEOUT_MS)}
     || E <- AllSec
    ],
    Complete =
        lists:all(fun(R) -> R =:= ok end, Refolded) andalso
            lists:all(
                fun({E, R}) ->
                    R =:= ok orelse not lists:keymember(E, 1, Seen)
                end,
                Flushed
            ) andalso
            lists:all(fun({E, _Marks}) -> sync_shard(E) =:= ok end, Seen),
    case Complete of
        true -> mark_trusted(Seen);
        false -> incomplete
    end.

%% @private
mark_trusted(Seen) ->
    Now = erlang:monotonic_time(millisecond),
    Cleared = [
        begin
            {NS, Idx, Shard} = bondy_oplog_core_registry:entry_key(E),
            _ = bondy_oplog_core_registry:bump_ae(NS, Idx, Shard, Now),
            bondy_oplog_core_registry:index_clear_rebuild(E, Marks)
        end
     || {E, Marks} <- Seen
    ],
    case lists:all(fun(R) -> R =:= ok end, Cleared) of
        true -> ok;
        false -> incomplete
    end.

%% @private
settle(_NS, _IndexName, ok) ->
    ok;
settle(NS, IndexName, incomplete) ->
    ?LOG_WARNING(#{
        description =>
            "bondy_oplog_index_rebuild did not complete: a primary could "
            "not be re-folded, a writer did not flush, or the index was "
            "marked again while it ran. The index stays marked for rebuild "
            "and the rebuild runs again.",
        namespace => NS,
        index_name => IndexName
    }),
    {error, incomplete}.

%% @private
%% One retry timer per index, its delay doubling up to `?RETRY_MAX_MS`, so
%% the requests and failures of one index never stack full rebuilds.
schedule(NS, IndexName, ok, State) ->
    case maps:take({NS, IndexName}, State) of
        {#{timer := TRef}, State1} when is_reference(TRef) ->
            _ = erlang:cancel_timer(TRef),
            receive
                {retry, NS, IndexName} -> ok
            after 0 -> ok
            end,
            State1;
        {_, State1} ->
            State1;
        error ->
            State
    end;
schedule(NS, IndexName, {error, _}, State) ->
    case maps:get({NS, IndexName}, State, undefined) of
        #{timer := TRef} when is_reference(TRef) ->
            State;
        Retry ->
            Delay =
                case Retry of
                    #{delay := D} -> min(2 * D, ?RETRY_MAX_MS);
                    undefined -> ?RETRY_MS
                end,
            TRef = erlang:send_after(Delay, self(), {retry, NS, IndexName}),
            State#{{NS, IndexName} => #{timer => TRef, delay => Delay}}
    end.

%% @private
reset_target_shard(Entry) ->
    bondy_oplog_core_registry:index_mark_rebuild(Entry),
    ok = bondy_oplog_core_registry:index_untrust(Entry),
    ok = sync_shard(Entry),
    ok = bondy_oplog_secondary_writer:reset(Entry),
    Adapter = bondy_oplog_core_registry:entry_projection_adapter(Entry),
    Handle = bondy_oplog_core_registry:entry_projection_handle(Entry),
    %% Bucket-scoped wipe: pass the `clear_scope()` the owner stamped on the
    %% entry at registration. On a backend that co-locates several tables in
    %% one Bookie (`shared_shards`, `single_bookie`) it is `{entity, ET, Idx}`,
    %% so the wipe drops only THIS table's index cells — never a sibling table
    %% that declared the same `IndexName`. On a single-table handle it is
    %% `{suffix, Idx}`. A registration that predates the field (or a primary
    %% shard) leaves it `undefined`; fall back to the bare-suffix scope, which
    %% is correct on every single-table backend.
    Scope = clear_scope(Entry),
    case erlang:function_exported(Adapter, clear, 2) of
        true ->
            ok = Adapter:clear(Handle, Scope);
        false ->
            %% Without a clear, the re-fold still re-puts every live term;
            %% only orphaned terms (no longer yielded) would survive. Both
            %% shipped projection adapters (ets, leveled) export clear/2, so
            %% this is a defensive branch for a future adapter lacking it.
            ?LOG_WARNING(#{
                description =>
                    "bondy_oplog_index_rebuild: projection adapter has no "
                    "clear/2; orphaned index terms may survive the rebuild.",
                adapter => Adapter
            })
    end,
    bondy_oplog_core_registry:index_inflight_reset(Entry),
    bondy_oplog_core_registry:reset_stale_ae(Entry),
    bondy_oplog_core_registry:index_rebuild_marks(Entry).

%% @private
sync_shard(Entry) ->
    bondy_oplog_projection_adapter:sync(
        bondy_oplog_core_registry:entry_projection_adapter(Entry),
        bondy_oplog_core_registry:entry_projection_handle(Entry)
    ).

%% @private
clear_scope(Entry) ->
    case bondy_oplog_core_registry:entry_index_clear_scope(Entry) of
        undefined ->
            {_NS, IndexName, _Shard} =
                bondy_oplog_core_registry:entry_key(Entry),
            {suffix, IndexName};
        Scope ->
            Scope
    end.

%% @private
refold_primary(Entry) ->
    Key = bondy_oplog_core_registry:entry_key(Entry),
    case bondy_oplog_core_registry:entry_instance_id(Entry) of
        undefined ->
            ok;
        InstanceId ->
            case bondy_oplog_registry:applier_pid(InstanceId) of
                Pid when is_pid(Pid) ->
                    bondy_oplog_applier:rebuild_indexes_sync(Pid, Key);
                _ ->
                    %% A fused instance has no applier and re-folds
                    %% in-process; any other instance without one is
                    %% restarting.
                    case bondy_oplog_registry:fused(InstanceId) of
                        true ->
                            case
                                bondy_oplog_registry:instance_pid(InstanceId)
                            of
                                InstancePid when is_pid(InstancePid) ->
                                    bondy_oplog_instance:rebuild_indexes_sync(
                                        InstancePid, Key
                                    );
                                undefined ->
                                    skipped
                            end;
                        false ->
                            skipped
                    end
            end
    end.

%% @private
index_of(Entry) ->
    {_NS, Index, _Shard} = bondy_oplog_core_registry:entry_key(Entry),
    Index.

%% @private
is_secondary(Entry) ->
    index_of(Entry) =/= ?INDEX.
