%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_jepsen_cluster).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

%% =============================================================================
%% Public API
%% =============================================================================

-export([start_link/0]).
-export([db_name/0]).
-export([tables/0]).
-export([table/1]).
-export([peers/0]).
-export([hlc/0]).
-export([info/0]).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

-define(SERVER, ?MODULE).
-define(PT_KEY(K), {?MODULE, K}).

-record(state, {
    db          :: map(),
    tables      :: #{atom() := map()},
    peers       :: [node()],
    leveled_sup :: pid()
}).

%% =============================================================================
%% API
%% =============================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec db_name() -> atom().
db_name() ->
    persistent_term:get(?PT_KEY(db_name)).

-spec tables() -> [atom()].
tables() ->
    persistent_term:get(?PT_KEY(table_names)).

-spec table(atom()) -> {ok, map()} | error.
table(Name) when is_atom(Name) ->
    case persistent_term:get(?PT_KEY({table, Name}), undefined) of
        undefined -> error;
        T        -> {ok, T}
    end.

-spec peers() -> [node()].
peers() ->
    persistent_term:get(?PT_KEY(peers), []).

-spec hlc() -> bondy_oplog_hlc:hlc().
hlc() ->
    bondy_db:tick(any_table()).

-spec info() -> map().
info() ->
    #{
        db    => db_name(),
        peers => peers(),
        tables => tables(),
        node  => node()
    }.

%% =============================================================================
%% gen_server CALLBACKS
%% =============================================================================

init([]) ->
    process_flag(trap_exit, true),
    DbName = env(db_name, jepsen),
    TableNames = env(tables, [t0, t1, t2, t3, t4, t5, t6, t7, t8, t9]),
    ShardCount = env(shard_count, 16),
    FoldModule = env(fold_module, lww_register),
    %% Optional explicit CRDT module under test. When set (e.g.
    %% `aw_set`, `rw_set`, `two_p_set`, `g_set`, `pn_counter`), every
    %% table is opened with that native operation-based CRDT so the
    %% Jepsen convergence checkers run against a real catalogue type
    %% rather than the default `lww_register`. A short alias is resolved
    %% to its `bondy_oplog_crdt_*` module via the cell kernel; an
    %% already-qualified module name passes through. `undefined` keeps
    %% the legacy behaviour (fold_module drives the kernel).
    CrdtModule = resolve_crdt(env(crdt_module, undefined)),
    Peers = lists:filter(fun(N) -> N =/= node() end, env(peers, [])),
    DataDir = env(data_dir, "/var/lib/bondy_mst_jepsen"),
    ok = filelib:ensure_dir(filename:join(DataDir, ".keep")),
    %% Start the leveled supervisor as a child of *this* gen_server.
    %% A sibling-under-the-umbrella layout would deadlock because
    %% `supervisor:which_children/1` on the still-initializing parent
    %% blocks. Linking it here means the cluster gen_server is the
    %% sole owner of the leveled Bookies' lifetime — when this
    %% gen_server terminates, `terminate/2` calls `bondy_db:close/1`
    %% which calls `bondy_db_leveled_sup:stop/1` (which unlinks
    %% before killing the sup, so no spurious exit signal flows
    %% back here).
    {ok, LeveledSup} = bondy_db_leveled_sup:start_link(),
    %% `shared_shards` topology: the 16 leveled Bookies are shared
    %% across all 10 tables (16 Bookies per node, not 10×16=160). Each
    %% table sees the same set of shards; the bucket per Bookie
    %% disambiguates entity types.
    %% Anchor the WAL + MST + compaction-checkpoint under `DataDir` so
    %% they survive kill -9 + restart. Without this, the per-instance
    %% WAL falls back to `/tmp/bondy_oplog_wal/<os_pid>/<InstanceId>`,
    %% which changes path on every BEAM restart — silently abandoning
    %% all prior fsynced WAL frames. That is the root cause of the
    %% residual Jepsen combined-nemesis flake (PR-J4): an acked event
    %% lands in `/tmp/bondy_oplog_wal/<OLD_PID>/...`, the kill spawns a
    %% new BEAM with a new os_pid, the new writer looks at
    %% `/tmp/bondy_oplog_wal/<NEW_PID>/...` (empty), and the event is
    %% lost despite per_write fsync.
    OplogStoragePath = unicode:characters_to_binary(
        filename:join(DataDir, "oplog")
    ),
    {ok, Db} = bondy_db:open(DbName, maybe_crdt(CrdtModule, #{
        topology            => bondy_db_topology_shared_shards,
        topology_opts       => #{sup => LeveledSup, dir => DataDir},
        shard_count         => ShardCount,
        fold_module         => FoldModule,
        oplog_instance_opts => #{
            storage_path => OplogStoragePath,
            %% Without `seed => true`, an instance with `storage_path`
            %% set boots in `pre_bootstrap` lifecycle and holds appends
            %% until a peer ships a catalogue snapshot. Every Jepsen
            %% node starts as a seed: there is no operator-driven
            %% bootstrap step in this harness.
            seed         => true,
            %% Deterministic per-node origin so kill -9 + restart
            %% recovers its own WAL instead of crashing with
            %% `{orphan_segment, origin_mismatch}`. The default
            %% `bondy_oplog_origin:default/0` mints a fresh random
            %% 16-byte id per BEAM start — designed so that a kill
            %% looks like a new replica to the cluster. That's the
            %% wrong choice under Jepsen's kill-restart nemesis: the
            %% on-disk WAL header carries the *prior* origin, and the
            %% recovery's `bondy_oplog_wal_segment:verify/3` rejects
            %% it as orphan. Pin the origin to `sha256(node())`'s
            %% first 16 bytes so every restart of the same node
            %% recovers cleanly.
            origin       => stable_origin()
        }
    })),
    Tables = lists:foldl(
        fun(Name, Acc) ->
            {ok, T} = bondy_db:open_table(Db, Name, maybe_crdt(CrdtModule, #{
                shard_count => ShardCount,
                fold_module => FoldModule
            })),
            ok = persistent_term:put(?PT_KEY({table, Name}), T),
            Acc#{Name => T}
        end,
        #{},
        TableNames
    ),
    ok = persistent_term:put(?PT_KEY(db_name), DbName),
    ok = persistent_term:put(?PT_KEY(table_names), TableNames),
    ok = persistent_term:put(?PT_KEY(db), Db),
    ok = persistent_term:put(?PT_KEY(peers), Peers),
    %% Wire the sync scheduler: static peer source + a dispatch that
    %% pulls from every connected peer via the disterl transport.
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_mst_jepsen_peer_source, #{}
    ),
    ok = bondy_oplog_sync_scheduler:set_dispatch(
        fun bondy_mst_jepsen_dispatch:dispatch/2
    ),
    ?LOG_NOTICE(#{
        description => "bondy_mst_jepsen cluster ready",
        node => node(),
        peers => Peers,
        db => DbName,
        tables => TableNames,
        shard_count => ShardCount,
        fold_module => FoldModule,
        crdt_module => CrdtModule
    }),
    {ok, #state{
        db          = Db,
        tables      = Tables,
        peers       = Peers,
        leveled_sup = LeveledSup
    }}.

handle_call(_Req, _From, State) ->
    {reply, {error, badcall}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{db = Db, tables = Tables}) ->
    %% Best-effort orderly shutdown: close every table, then the DB.
    maps:foreach(
        fun(_Name, T) ->
            _ = catch bondy_db:close_table(T)
        end,
        Tables
    ),
    _ = catch bondy_db:close(Db),
    lists:foreach(
        fun(Key) ->
            _ = persistent_term:erase(?PT_KEY(Key))
        end,
        [db, db_name, table_names, peers]
    ),
    lists:foreach(
        fun(Name) ->
            _ = persistent_term:erase(?PT_KEY({table, Name}))
        end,
        maps:keys(Tables)
    ),
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

env(Key, Default) ->
    application:get_env(bondy_mst_jepsen, Key, Default).

%% Resolve a configured `crdt_module` to a concrete `bondy_oplog_crdt_*`
%% module. Accepts a short catalogue alias (`aw_set`, `pn_counter`, ...)
%% or an already-qualified module name; `undefined` passes through. An
%% unknown atom raises so a typo in the run config fails loudly at boot
%% rather than silently falling back to the default register.
resolve_crdt(undefined) ->
    undefined;
resolve_crdt(Alias) when is_atom(Alias) ->
    case bondy_oplog_cell_kernel:default_crdt_for_fold(Alias) of
        undefined -> error({unknown_crdt_module, Alias});
        Module -> Module
    end.

%% Inject `crdt_module` into a `bondy_db` open/open_table opts map when
%% one is configured. When `undefined`, the opts are returned unchanged
%% so the `fold_module` continues to drive kernel selection.
maybe_crdt(undefined, Opts) ->
    Opts;
maybe_crdt(Module, Opts) when is_atom(Module) ->
    Opts#{crdt_module => Module}.

%% First 16 bytes of `sha256(node())`. Deterministic per node name —
%% kill -9 + restart on the same node yields the same origin, which
%% lets the WAL recovery accept its own segments after restart.
stable_origin() ->
    Hash = crypto:hash(sha256, atom_to_binary(node(), utf8)),
    <<Origin:16/binary, _/binary>> = Hash,
    Origin.

any_table() ->
    case tables() of
        [Name | _] ->
            {ok, T} = table(Name),
            T;
        [] ->
            error(no_tables_open)
    end.
