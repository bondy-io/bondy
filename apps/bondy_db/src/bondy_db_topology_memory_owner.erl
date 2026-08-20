%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_db_topology_memory_owner).
-behaviour(gen_server).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
DB-scoped owner process for the `bondy_db_topology_memory` ETS tables —
the in-RAM analogue of `bondy_db_leveled_sup` for leveled Bookies.

## Why a dedicated owner exists

The per-shard substrate resources of a memory-backed DB are all ETS
tables: the projection tables (`bondy_oplog_projection_ets`) the
per-shard appliers write, and the read caches (`bondy_oplog_cache_ets`)
those same appliers invalidate. The appliers live in the node-global
instance supervision subtree (`bondy_oplog_instance_dyn_sup`) and are
only stopped explicitly via `bondy_oplog:stop_instance/1`. An ETS table
is destroyed the instant its **owning process** dies. If these tables
were owned by the transient process that happens to call
`bondy_db:open_table/3`, that caller dying — while the appliers keep
running under the app tree — would wipe the tables out from under the
appliers, which then crash on a dead tid (the projection) or a dead
cache handle on their next write.

This process breaks that coupling: it owns every ETS table for one
memory-backed DB, and its lifetime is bracketed by the topology's
`init/2` → `shutdown/1`, mirroring the explicit start/stop lifecycle
of the appliers it feeds. Caller death no longer wipes the tables.

The facade additionally points the `bondy_oplog_core_registry` monitor at
this process (not the caller), so the registry row also survives caller
death. With the projection table, the read cache, and the registry row
all anchored here, a write+read driven through the surviving substrate
keeps working after the `open_table/3` caller is gone — see the
`ets_owner_survives_caller_death` regression in `bondy_db_test`.

## Deliberately unlinked

`start/0` uses `gen_server:start/3`, **not** `start_link/3`: linking
would re-introduce exactly the coupling above (the topology's `init/2`
runs in the facade caller's process, so a link would tie this owner's
life to that caller). The owner is instead torn down explicitly by
`bondy_db_topology_memory:shutdown/1` → `stop/1`, and the VM reaps it
(and auto-deletes its tables) on node shutdown — the correct ephemeral
semantics. The trade-off is the same orphan profile the appliers
already have: a caller that dies abnormally without ever calling
`bondy_db:close/1` leaks this process and its tables until the node
stops. That is strictly better than the pre-fix behaviour (tables gone,
appliers crash-looping on a dead tid), and consistent with how leveled
Bookies and oplog instances are managed.

## Ownership of `ets:new` / `ets:delete`

Both table creation and destruction are funnelled through this process
(`open_table/4`, `open_cache/6`, `close_table/2`, `close_cache/2` are
all `gen_server:call`s), so every `ets:new/2` and whole-table
`ets:delete/1` runs *in the owner* — the only process the VM permits to
do either. Readers and the appliers touch the `public` tables from
their own processes for object access, which needs no ownership. Each
owned handle is tracked with the adapter module that closes it
(`#{Handle => Adapter}`), so the owner closes a projection table via
`bondy_oplog_projection_ets:close/1` and a cache via
`bondy_oplog_cache_ets:close/1` — both reduce to `ets:delete/1` here,
but going through the adapter keeps the contract clean.
""").

%% API
-export([start/0]).
-export([stop/1]).
-export([open_table/4]).
-export([close_table/2]).
-export([open_cache/6]).
-export([close_cache/2]).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([terminate/2]).

-define(PROJECTION_ADAPTER, bondy_oplog_projection_ets).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Start an unlinked owner process. Returns the owner pid; the caller
stashes it in the topology state and is responsible for stopping it via
`stop/1` (the memory topology does this in `shutdown/1`).
""".
-spec start() -> {ok, pid()} | {error, term()}.

start() ->
    gen_server:start(?MODULE, [], []).

-doc """
Stop the owner and delete every table it still owns. Idempotent: a
no-op if the owner has already terminated (its tables are gone with it).
""".
-spec stop(Owner :: pid()) -> ok.

stop(Owner) when is_pid(Owner) ->
    try gen_server:stop(Owner) of
        ok -> ok
    catch
        %% Already gone — its tables died with it, which is the goal.
        exit:noproc -> ok;
        exit:{noproc, _} -> ok
    end.

-doc """
Create the per-shard projection ETS tables for one table (`EntityType`)
of the DB, owned by this process. Returns `#{Shard => Tid}`. On any
per-shard failure the already-created shards are deleted and the error
is returned, so the caller never inherits a partial table.
""".
-spec open_table(
    Owner :: pid(),
    DbName :: atom(),
    EntityType :: atom(),
    ShardCount :: pos_integer()
) -> {ok, #{non_neg_integer() => ets:tid()}} | {error, term()}.

open_table(Owner, DbName, EntityType, ShardCount) when
    is_pid(Owner),
    is_atom(DbName),
    is_atom(EntityType),
    is_integer(ShardCount),
    ShardCount > 0
->
    gen_server:call(Owner, {open_table, DbName, EntityType, ShardCount}).

-doc """
Delete a table's per-shard projection tables. `Shards` is the
`#{Shard => Tid}` map (or a plain list of handles). Handles not owned by
this process are ignored.
""".
-spec close_table(
    Owner :: pid(),
    Shards :: #{non_neg_integer() => ets:tid()} | [ets:tid()]
) -> ok.

close_table(Owner, Shards) when is_pid(Owner), is_map(Shards) ->
    close_table(Owner, maps:values(Shards));
close_table(Owner, Handles) when is_pid(Owner), is_list(Handles) ->
    safe_call(Owner, {close_handles, Handles}).

-doc """
Create a per-shard read cache via `CacheAdapter`, owned by this process,
and return its handle. The adapter's `init/4` runs *in the owner* so the
VM attributes the table to this long-lived process rather than the
transient `open_table/3` caller.
""".
-spec open_cache(
    Owner :: pid(),
    CacheAdapter :: module(),
    NS :: atom(),
    Index :: atom(),
    Shard :: non_neg_integer(),
    Opts :: map()
) -> {ok, term()} | {error, term()}.

open_cache(Owner, CacheAdapter, NS, Index, Shard, Opts) when
    is_pid(Owner),
    is_atom(CacheAdapter),
    is_atom(NS),
    is_atom(Index),
    is_integer(Shard),
    is_map(Opts)
->
    gen_server:call(Owner, {open_cache, CacheAdapter, NS, Index, Shard, Opts}).

-doc """
Delete a single cache (or projection) handle previously created here.
Idempotent and owner-safe: a handle this process does not own, or an
already-stopped owner, is a no-op.
""".
-spec close_cache(Owner :: pid(), Handle :: term()) -> ok.

close_cache(Owner, Handle) when is_pid(Owner) ->
    safe_call(Owner, {close_handles, [Handle]}).

%% =============================================================================
%% gen_server CALLBACKS
%% =============================================================================

init([]) ->
    %% `#{Handle => Adapter}` — Adapter is the module whose `close/1`
    %% deletes Handle (projection vs cache). Lets the owner close each
    %% table through its own adapter without a second registry.
    {ok, #{handles => #{}}}.

handle_call({open_table, DbName, EntityType, ShardCount}, _From, State) ->
    #{handles := Handles} = State,
    case open_shards(DbName, EntityType, ShardCount) of
        {ok, Shards} ->
            Handles1 = lists:foldl(
                fun(Tid, Acc) -> Acc#{Tid => ?PROJECTION_ADAPTER} end,
                Handles,
                maps:values(Shards)
            ),
            {reply, {ok, Shards}, State#{handles := Handles1}};
        {error, _} = Err ->
            {reply, Err, State}
    end;
handle_call({open_cache, CacheAdapter, NS, Index, Shard, Opts}, _From, State) ->
    #{handles := Handles} = State,
    case CacheAdapter:init(NS, Index, Shard, Opts) of
        {ok, Handle} ->
            {reply, {ok, Handle}, State#{
                handles := Handles#{Handle => CacheAdapter}
            }};
        {error, _} = Err ->
            {reply, Err, State}
    end;
handle_call({close_handles, ToClose}, _From, State) ->
    #{handles := Handles} = State,
    Handles1 = lists:foldl(fun close_owned/2, Handles, ToClose),
    {reply, ok, State#{handles := Handles1}};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, #{handles := Handles}) ->
    %% Tables would be auto-deleted on process exit anyway; deleting
    %% explicitly here keeps the teardown unambiguous and runs in the
    %% owner (the process the VM permits to do it).
    _ = [
        try
            Adapter:close(Handle)
        catch
            _:_ -> ok
        end
     || {Handle, Adapter} <- maps:to_list(Handles)
    ],
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% A `gen_server:call` that tolerates an already-stopped owner — the
%% tables it owned died with it, so "delete them" is already satisfied.
safe_call(Owner, Request) ->
    try gen_server:call(Owner, Request) of
        ok -> ok
    catch
        exit:{noproc, _} -> ok;
        exit:{normal, _} -> ok;
        exit:{shutdown, _} -> ok
    end.

%% @private
%% Runs inside the owner, so every `ets:new/2` it triggers is owned by
%% the owner. On partial failure the already-created shards are deleted
%% (also in the owner) before the error propagates.
open_shards(DbName, EntityType, ShardCount) ->
    open_shards(DbName, EntityType, 0, ShardCount, #{}).

open_shards(_DbName, _EntityType, N, N, Acc) ->
    {ok, Acc};
open_shards(DbName, EntityType, I, N, Acc) ->
    case ?PROJECTION_ADAPTER:open(DbName, EntityType, I, #{}) of
        {ok, Tid} ->
            open_shards(DbName, EntityType, I + 1, N, Acc#{I => Tid});
        {error, _} = Err ->
            _ = [?PROJECTION_ADAPTER:close(T) || T <- maps:values(Acc)],
            Err
    end.

%% @private
close_owned(Handle, Handles) ->
    case maps:take(Handle, Handles) of
        {Adapter, Handles1} ->
            _ = Adapter:close(Handle),
            Handles1;
        error ->
            Handles
    end.
