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

1. **Discard + wipe** every target secondary shard: reset the writer's
   buffered ops (stale, possibly for terms since removed), `clear/2` the
   shard's projection scoped to the index's bucket suffix (so orphaned
   terms do not survive, without touching co-located tables on a shared
   backend), reset the in-flight counter, and reset freshness to stale so
   reads refuse mid rebuild.
2. **Re-derive** every primary shard's index via
   `bondy_oplog_applier:rebuild_indexes_sync/1`. That reads each live
   cell's CURRENT projection value and re-dispatches a `put` for every live
   term of every cell, bypassing the back-pressure cap so the full working
   set lands in one pass. (Reading the converged value, rather than
   replaying the cell's events, is what keeps a context-carrying tier_2
   index from latching superseded multi-value siblings.)
3. **Flush** every secondary writer in the namespace (the target index
   plus any sibling indexes that received idempotent re-puts from the
   shared re-fold), draining buffers and decrementing in-flight counters.
4. **Freshen** the target shards (bump AE, clear `needs_rebuild`) so reads
   pass again — including shards whose working set is empty, which a
   plain write path would leave sentinel-stale forever.

## Triggers

- **Startup backfill** — `bondy_db:open_table` calls `rebuild_sync/2` once
  per index after provisioning, so a table opened over a durable primary
  with pre-existing data (or after a peer bootstrap) materialises its
  indexes before the table is returned.
- **Saturation** — the primary applier drops a batch that would overflow a
  secondary writer's backlog, marks the shard, and `request/2`s a rebuild.
- **Writer crash** — on restart a writer that had previously been
  populated `request/2`s a rebuild to recover the ops its lost buffer held.
- **Operator / tests** — `bondy_db:rebuild_index/2` (sync barrier).

## Serialisation + coalescing

`rebuild_sync/2` (a call) and `request/2` (a cast) both run the rebuild
inline in the gen_server, so only one runs at a time across all indexes.
A burst of identical `request/2`s for the same index is coalesced: after a
rebuild the handler drains any further pending requests for that index
from its mailbox.
""").

-export([child_spec/0]).
-export([start_link/0]).
-export([request/2]).
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
Synchronously rebuild `(NS, IndexName)` and return once the index has been
re-materialised from the primary and its target shards freshened. The
barrier used by the startup backfill, the operator API, and tests.
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
    {reply, Result, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({request, NS, IndexName}, State) ->
    _ = run_rebuild(NS, IndexName),
    %% Coalesce a burst of identical requests (e.g. several shards of the
    %% same index saturating at once) — the single rebuild above already
    %% covered the whole index.
    ok = drain_requests(NS, IndexName),
    {noreply, State};
handle_cast(_, State) ->
    {noreply, State}.

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
run_rebuild(NS, IndexName) ->
    T0 = erlang:monotonic_time(microsecond),
    try
        Shards = bondy_oplog_core_registry:shards_for(NS),
        Primaries = [E || E <- Shards, index_of(E) =:= ?INDEX],
        Targets = [E || E <- Shards, index_of(E) =:= IndexName],
        AllSec = [E || E <- Shards, is_secondary(E)],
        case Targets of
            [] ->
                %% No such index registered under NS — nothing to rebuild.
                ok;
            _ ->
                do_rebuild(NS, IndexName, Primaries, Targets, AllSec),
                DurUs = erlang:monotonic_time(microsecond) - T0,
                telemetry:execute(
                    [bondy_oplog, secondary_index, rebuild],
                    #{
                        duration_us => DurUs,
                        target_shards => length(Targets),
                        primary_shards => length(Primaries)
                    },
                    #{namespace => NS, index_name => IndexName}
                ),
                ok
        end
    catch
        C:R:S ->
            ?LOG_ERROR(#{
                description =>
                    "bondy_oplog_index_rebuild rebuild raised; the index "
                    "stays marked for rebuild and a later trigger retries.",
                namespace => NS,
                index_name => IndexName,
                class => C,
                reason => R,
                stacktrace => S
            }),
            {error, R}
    end.

%% @private
do_rebuild(NS, IndexName, Primaries, Targets, AllSec) ->
    %% 1. Discard stale buffers + wipe the target shards. Keep
    %%    `needs_rebuild` set (reads refuse) until step 4.
    lists:foreach(fun reset_target_shard/1, Targets),
    %% 2. Re-fold every primary MST (re-dispatch every live term, cap
    %%    bypassed). Idempotent re-puts also reach sibling indexes' writers.
    lists:foreach(fun refold_primary/1, Primaries),
    %% 3. Flush every index writer in the namespace so both the target's
    %%    re-puts and the siblings' idempotent re-puts drain (the latter
    %%    keeps sibling in-flight counters from a false saturation).
    lists:foreach(fun flush_writer/1, AllSec),
    %% 4. Freshen the target shards: bump AE (so even an empty shard reads
    %%    fresh) and clear `needs_rebuild`. Now reads pass.
    Now = erlang:monotonic_time(millisecond),
    lists:foreach(
        fun(E) ->
            {NS1, Idx, Shard} = bondy_oplog_core_registry:entry_key(E),
            _ = bondy_oplog_core_registry:bump_ae(NS1, Idx, Shard, Now),
            bondy_oplog_core_registry:index_clear_rebuild(E)
        end,
        Targets
    ),
    ok = clean_namespace_tmp(NS, IndexName).

%% @private
reset_target_shard(Entry) ->
    %% Mark the shard untrusted FIRST (in-memory flag set + durable trust
    %% marker removed) so that, even for an operator-triggered rebuild of an
    %% already-trusted shard, a crash between the wipe below and the
    %% `index_clear_rebuild` in step 4 leaves the shard untrusted on disk —
    %% the next cold-start rebuilds rather than trusting half-wiped cells.
    bondy_oplog_core_registry:index_mark_rebuild(Entry),
    case bondy_oplog_core_registry:entry_writer_pid(Entry) of
        Pid when is_pid(Pid) ->
            %% Reset only THIS index shard's stream on the (possibly shared)
            %% writer — sibling indexes on the same writer keep their buffers.
            {NS, IName, _Shard} = bondy_oplog_core_registry:entry_key(Entry),
            _ = catch bondy_oplog_secondary_writer:reset(Pid, {NS, IName});
        _ ->
            ok
    end,
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
            _ = catch Adapter:clear(Handle, Scope);
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
    ok.

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
    case bondy_oplog_core_registry:entry_instance_id(Entry) of
        undefined ->
            ok;
        InstanceId ->
            case bondy_oplog_registry:applier_pid(InstanceId) of
                Pid when is_pid(Pid) ->
                    bondy_oplog_applier:rebuild_indexes_sync(Pid);
                _ ->
                    %% Applier restarting; its own cold-start replay will
                    %% re-dispatch. The shard stays marked, so a later
                    %% trigger retries.
                    ok
            end
    end.

%% @private
flush_writer(Entry) ->
    case bondy_oplog_core_registry:entry_writer_pid(Entry) of
        Pid when is_pid(Pid) ->
            _ = catch bondy_oplog_secondary_writer:flush_sync(Pid),
            ok;
        _ ->
            ok
    end.

%% @private
clean_namespace_tmp(_NS, _IndexName) ->
    %% No transient filesystem artefacts to clean: a durable (leveled) index
    %% is wiped in place by `clear/2` and re-derived, leaving no temp files.
    %% Hook kept so the rebuild has a single completion point.
    ok.

%% @private
index_of(Entry) ->
    {_NS, Index, _Shard} = bondy_oplog_core_registry:entry_key(Entry),
    Index.

%% @private
is_secondary(Entry) ->
    index_of(Entry) =/= ?INDEX.
