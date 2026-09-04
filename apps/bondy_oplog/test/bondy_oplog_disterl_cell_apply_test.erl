%% =============================================================================
%% Multi-node convergence test for the cell_apply projection path.
%%
%% Drives a 3-node cluster (test controller + 2 `peer:start_link/1` nodes)
%% through the same wiring as the Jepsen harness, but in-process: append
%% `cell_apply` events on different nodes, drive pairwise
%% `bondy_oplog:sync/3` over the disterl transport, and assert every node's
%% substrate projection converges.
%%
%% Every test ends with at least one `replay_cell_events` cycle, so a
%% regression in the `bondy_mst:diff_to_list/2`-driven watermark path
%% surfaces here rather than in a Docker + Jepsen round-trip.
%% =============================================================================

-module(bondy_oplog_disterl_cell_apply_test).

-include_lib("eunit/include/eunit.hrl").

%% Exported so the peer nodes can invoke shard-registration and read
%% helpers via `erpc:call/4`.
-export([peer_register_shard/3, peer_register_shard/4]).
-export([peer_unregister_shard/3]).
-export([peer_open_instance/3, peer_open_instance/4]).
-export([peer_append_cell/4]).
-export([peer_do_replay/1]).
-export([peer_read/3]).
-export([peer_close_instance/2]).
-export([peer_shard_owner_loop/4]).

%% Default cell bucket — substrate `read/3` aliases land on `<<>>`.
-define(B, <<>>).

setup() ->
    case net_kernel:get_state() of
        #{started := no} ->
            Name = list_to_atom(
                "bondymst_cell_" ++
                    integer_to_list(os:system_time(microsecond))
            ),
            %% OTP-28: the legacy list form `net_kernel:start([Name, shortnames])`
            %% is gone; use start/2 with the options map.
            {ok, _} = net_kernel:start(Name, #{name_domain => shortnames}),
            true = erlang:set_cookie(node(), bondymsttestcookie),
            ok;
        _ ->
            ok
    end,
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)]
    ],
    ok.

disterl_cell_apply_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 90, fun lww_converges_across_three_nodes/0},
        {timeout, 90, fun later_hlc_wins_after_sync/0},
        {timeout, 90, fun new_node_catches_up_via_sync/0}
    ]}.

%% =============================================================================
%% Tests
%% =============================================================================

%% Each node writes one cell_apply event for a distinct key; after
%% pairwise sync, every node's projection holds all three keys with
%% the originator's HLC + value.
lww_converges_across_three_nodes() ->
    {ok, PB, NB} = start_peer_node("nb"),
    {ok, PC, NC} = start_peer_node("nc"),
    try
        ok = setup_peer(NB),
        ok = setup_peer(NC),
        InstId = mk_id(),
        NS = ns_of(InstId),
        %% Register a local shard on the controller and on each peer.
        {Cache, Proj} = register_shard(NS, primary, 0),
        ok = peer_register_shard_at(NB, NS, primary, 0),
        ok = peer_register_shard_at(NC, NS, primary, 0),
        %% Open the same instance on all three with distinct origins.
        OriginA = bondy_oplog_origin:new(),
        OriginB = bondy_oplog_origin:new(),
        OriginC = bondy_oplog_origin:new(),
        {ok, _} = open_instance(InstId, NS, OriginA),
        ok = peer_open_instance_at(NB, InstId, NS, OriginB),
        ok = peer_open_instance_at(NC, InstId, NS, OriginC),
        try
            %% Each node writes one unique cell.
            ok = append_cell(InstId, <<"a">>, 10, <<"v-a">>),
            ok = peer_append_cell_at(NB, InstId, <<"b">>, 20, <<"v-b">>),
            ok = peer_append_cell_at(NC, InstId, <<"c">>, 30, <<"v-c">>),
            %% Pre-sync each node only sees its own write.
            ?assertEqual(
                {<<"v-a">>, 10},
                bondy_oplog_core:read(NS, primary, <<"a">>)
            ),
            ?assertEqual(
                undefined,
                bondy_oplog_core:read(NS, primary, <<"b">>)
            ),
            %% Full mesh sync.
            sync_full_mesh(InstId, [{NB, NB}, {NC, NC}]),
            ok = peer_sync_from(NB, InstId, [node(), NC]),
            ok = peer_sync_from(NC, InstId, [node(), NB]),
            %% A second sync round to let the local replay cast settle
            %% on each node before reading. Each `bondy_oplog:sync/3`
            %% triggers an `integrate_peer_root` which casts
            %% `replay_cell_events` on the applier; the cast queue
            %% drains after the await_apply barrier below.
            _ = bondy_oplog_instance:await_apply(InstId),
            ok = peer_await_apply(NB, InstId),
            ok = peer_await_apply(NC, InstId),
            %% Every node sees every cell.
            assert_all_three_cells(NS, fun bondy_oplog_core:read/3),
            assert_all_three_cells_remote(NB, NS),
            assert_all_three_cells_remote(NC, NS)
        after
            ok = bondy_oplog:stop_instance(InstId),
            _ = erpc:call(NB, bondy_oplog, stop_instance, [InstId]),
            _ = erpc:call(NC, bondy_oplog, stop_instance, [InstId]),
            ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
            _ = peer_unregister_shard_at(NB, NS, primary, 0),
            _ = peer_unregister_shard_at(NC, NS, primary, 0),
            close_shard(Cache, Proj)
        end
    after
        peer:stop(PB),
        peer:stop(PC)
    end.

%% LWW semantics survive cross-node merges: an earlier-HLC write to
%% the same key is absorbed and the later-HLC value wins on every
%% node after sync.
later_hlc_wins_after_sync() ->
    {ok, PB, NB} = start_peer_node("nb2"),
    {ok, PC, NC} = start_peer_node("nc2"),
    try
        ok = setup_peer(NB),
        ok = setup_peer(NC),
        InstId = mk_id(),
        NS = ns_of(InstId),
        {Cache, Proj} = register_shard(NS, primary, 0),
        ok = peer_register_shard_at(NB, NS, primary, 0),
        ok = peer_register_shard_at(NC, NS, primary, 0),
        OriginA = bondy_oplog_origin:new(),
        OriginB = bondy_oplog_origin:new(),
        OriginC = bondy_oplog_origin:new(),
        {ok, _} = open_instance(InstId, NS, OriginA),
        ok = peer_open_instance_at(NB, InstId, NS, OriginB),
        ok = peer_open_instance_at(NC, InstId, NS, OriginC),
        try
            %% Three writes to the SAME key from three nodes, all with
            %% different HLCs.
            ok = append_cell(InstId, <<"k">>, 1, <<"first">>),
            ok = peer_append_cell_at(NB, InstId, <<"k">>, 5, <<"latest">>),
            ok = peer_append_cell_at(NC, InstId, <<"k">>, 3, <<"middle">>),
            sync_full_mesh(InstId, [{NB, NB}, {NC, NC}]),
            ok = peer_sync_from(NB, InstId, [node(), NC]),
            ok = peer_sync_from(NC, InstId, [node(), NB]),
            _ = bondy_oplog_instance:await_apply(InstId),
            ok = peer_await_apply(NB, InstId),
            ok = peer_await_apply(NC, InstId),
            ?assertEqual(
                {<<"latest">>, 5},
                bondy_oplog_core:read(NS, primary, <<"k">>)
            ),
            ?assertEqual(
                {<<"latest">>, 5},
                remote_read(NB, NS, <<"k">>)
            ),
            ?assertEqual(
                {<<"latest">>, 5},
                remote_read(NC, NS, <<"k">>)
            )
        after
            ok = bondy_oplog:stop_instance(InstId),
            _ = erpc:call(NB, bondy_oplog, stop_instance, [InstId]),
            _ = erpc:call(NC, bondy_oplog, stop_instance, [InstId]),
            ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
            _ = peer_unregister_shard_at(NB, NS, primary, 0),
            _ = peer_unregister_shard_at(NC, NS, primary, 0),
            close_shard(Cache, Proj)
        end
    after
        peer:stop(PB),
        peer:stop(PC)
    end.

%% Boot a third node *after* the first two have already exchanged
%% events. The newcomer's projection must catch up via a single sync
%% — exercises the cold-fold path in `do_replay_cell_events/1`
%% (`last_replayed_root = undefined`).
new_node_catches_up_via_sync() ->
    {ok, PB, NB} = start_peer_node("nb3"),
    try
        ok = setup_peer(NB),
        InstId = mk_id(),
        NS = ns_of(InstId),
        {Cache, Proj} = register_shard(NS, primary, 0),
        ok = peer_register_shard_at(NB, NS, primary, 0),
        OriginA = bondy_oplog_origin:new(),
        OriginB = bondy_oplog_origin:new(),
        {ok, _} = open_instance(InstId, NS, OriginA),
        ok = peer_open_instance_at(NB, InstId, NS, OriginB),
        try
            %% A + B exchange events first.
            ok = append_cell(InstId, <<"x">>, 1, <<"vx">>),
            ok = peer_append_cell_at(NB, InstId, <<"y">>, 2, <<"vy">>),
            {ok, _} = bondy_oplog:sync(InstId, NB, sync_opts()),
            ok = peer_sync_from(NB, InstId, [node()]),
            _ = bondy_oplog_instance:await_apply(InstId),
            ok = peer_await_apply(NB, InstId),
            ?assertEqual(
                {<<"vx">>, 1},
                bondy_oplog_core:read(NS, primary, <<"x">>)
            ),
            ?assertEqual(
                {<<"vy">>, 2},
                remote_read(NB, NS, <<"y">>)
            ),
            %% Now C joins the cluster.
            {ok, PC, NC} = start_peer_node("nc3"),
            try
                ok = setup_peer(NC),
                ok = peer_register_shard_at(NC, NS, primary, 0),
                OriginC = bondy_oplog_origin:new(),
                ok = peer_open_instance_at(NC, InstId, NS, OriginC),
                %% C is empty; one sync from A must populate C's
                %% projection with both x and y.
                ok = peer_sync_from(NC, InstId, [node()]),
                ok = peer_await_apply(NC, InstId),
                ok = peer_replay(NC, InstId),
                ?assertEqual(
                    {<<"vx">>, 1},
                    remote_read(NC, NS, <<"x">>)
                ),
                ?assertEqual(
                    {<<"vy">>, 2},
                    remote_read(NC, NS, <<"y">>)
                ),
                _ = erpc:call(NC, bondy_oplog, stop_instance, [InstId]),
                _ = peer_unregister_shard_at(NC, NS, primary, 0)
            after
                peer:stop(PC)
            end
        after
            ok = bondy_oplog:stop_instance(InstId),
            _ = erpc:call(NB, bondy_oplog, stop_instance, [InstId]),
            ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
            _ = peer_unregister_shard_at(NB, NS, primary, 0),
            close_shard(Cache, Proj)
        end
    after
        peer:stop(PB)
    end.

%% =============================================================================
%% Assertions
%% =============================================================================

assert_all_three_cells(NS, ReadFun) ->
    ?assertEqual({<<"v-a">>, 10}, ReadFun(NS, primary, <<"a">>)),
    ?assertEqual({<<"v-b">>, 20}, ReadFun(NS, primary, <<"b">>)),
    ?assertEqual({<<"v-c">>, 30}, ReadFun(NS, primary, <<"c">>)).

assert_all_three_cells_remote(Node, NS) ->
    ?assertEqual({<<"v-a">>, 10}, remote_read(Node, NS, <<"a">>)),
    ?assertEqual({<<"v-b">>, 20}, remote_read(Node, NS, <<"b">>)),
    ?assertEqual({<<"v-c">>, 30}, remote_read(Node, NS, <<"c">>)).

%% =============================================================================
%% Local helpers
%% =============================================================================

mk_id() ->
    list_to_binary(
        "distca_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

ns_of(Id) when is_binary(Id) ->
    binary_to_atom(<<"ns_", Id/binary>>, utf8).

register_shard(NS, Index, Shard) ->
    register_shard(NS, Index, Shard, lww_register).

register_shard(NS, Index, Shard, FoldModule) ->
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, Index, Shard, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, Index, Shard, #{}),
    ok = bondy_oplog_core_registry:register(NS, Index, Shard, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        fold_module => FoldModule,
        overlay => disabled
    }),
    {Cache, Proj}.

close_shard(Cache, Proj) ->
    ok = bondy_oplog_projection_ets:close(Proj),
    ok = bondy_oplog_cache_ets:close(Cache),
    ok.

open_instance(InstanceId, NS, Origin) ->
    open_instance(InstanceId, NS, Origin, lww_register).

open_instance(InstanceId, NS, Origin, FoldModule) ->
    bondy_oplog:start_instance(InstanceId, #{
        origin => Origin,
        fold_module => FoldModule,
        applier => #{
            cell_apply_target => {NS, primary, 0}
        }
    }).

append_cell(InstanceId, Key, Hlc, Value) ->
    _ = bondy_oplog:append(
        InstanceId,
        {cell_apply, ?B, Key, {set, Hlc, Value}}
    ),
    _ = bondy_oplog:projection(InstanceId),
    ok.

sync_opts() ->
    #{
        transport => bondy_oplog_transport_disterl,
        transport_opts => #{timeout => 10_000}
    }.

%% Pull from each listed peer in sequence. Each pull merges the peer's
%% events into the local MST and triggers a `replay_cell_events` cast.
sync_full_mesh(InstId, NodesPeers) ->
    lists:foreach(
        fun({_PeerTag, Node}) ->
            {ok, _} = bondy_oplog:sync(InstId, Node, sync_opts())
        end,
        NodesPeers
    ).

%% =============================================================================
%% Peer-node helpers
%% =============================================================================

start_peer_node(NameSuffix) ->
    Name = list_to_atom(
        NameSuffix ++ "_" ++
            integer_to_list(os:system_time(microsecond))
    ),
    Cookie = atom_to_list(erlang:get_cookie()),
    PeerOpts = #{
        name => Name,
        %% Match the controller's short hostname (from `node()`); a literal
        %% "127.0.0.1" forces a longname under our shortnames controller and the
        %% peer would exit with `nodistribution` (OTP-28).
        host => controller_host(),
        connection => standard_io,
        args => ["-setcookie", Cookie, "-pa" | code:get_path()]
    },
    {ok, Peer, Node} = peer:start_link(PeerOpts),
    {ok, Peer, Node}.

controller_host() ->
    case string:split(atom_to_list(node()), "@") of
        [_, Host] -> Host;
        _ -> "localhost"
    end.

setup_peer(Node) ->
    %% Start bondy_db on the peer (chain: bondy_db -> bondy_oplog -> bondy_mst);
    %% starting bondy_mst alone brings up no supervision tree -> noproc.
    {ok, _} = erpc:call(Node, application, ensure_all_started, [bondy_db]),
    %% Push this test module to the peer so the registration helpers
    %% can run via apply.
    {Mod, Bin, File} = code:get_object_code(?MODULE),
    {module, Mod} = erpc:call(Node, code, load_binary, [Mod, File, Bin]),
    ok = erpc:call(
        Node,
        bondy_oplog_sync_scheduler,
        set_dispatch,
        [undefined]
    ),
    ok = erpc:call(
        Node,
        bondy_oplog_gc_scheduler,
        set_trigger,
        [undefined]
    ),
    ok.

peer_register_shard_at(Node, NS, Index, Shard) ->
    erpc:call(Node, ?MODULE, peer_register_shard, [NS, Index, Shard]).

peer_unregister_shard_at(Node, NS, Index, Shard) ->
    erpc:call(Node, ?MODULE, peer_unregister_shard, [NS, Index, Shard]).

peer_open_instance_at(Node, InstId, NS, Origin) ->
    erpc:call(Node, ?MODULE, peer_open_instance, [InstId, NS, Origin]).

peer_append_cell_at(Node, InstId, Key, Hlc, Value) ->
    erpc:call(
        Node,
        ?MODULE,
        peer_append_cell,
        [InstId, Key, Hlc, Value]
    ).

peer_sync_from(Node, InstId, From) when is_list(From) ->
    lists:foreach(
        fun(Origin) ->
            {ok, _} = erpc:call(
                Node,
                bondy_oplog,
                sync,
                [InstId, Origin, sync_opts()]
            )
        end,
        From
    ).

peer_await_apply(Node, InstId) ->
    _ = erpc:call(Node, bondy_oplog_instance, await_apply, [InstId]),
    ok.

%% Force the synchronous peer-event replay barrier on `Node`: project the
%% events a sync session installed into the MST onto the per-cell
%% projection. `await_apply` drains the WAL applier but NOT the async
%% `replay_cell_events` cast `integrate_peer_root` fires, so a read issued
%% straight after a single pull can miss the just-synced cells. The
%% production read-after-sync path is eventually-consistent via that cast;
%% tests force the barrier for determinism (same gotcha as the
%% mv_register / aw_map e2e tests).
peer_replay(Node, InstId) ->
    _ = erpc:call(Node, ?MODULE, peer_do_replay, [InstId]),
    ok.

remote_read(Node, NS, Key) ->
    erpc:call(Node, ?MODULE, peer_read, [NS, primary, Key]).

%% =============================================================================
%% Helpers invoked on the peer node
%% =============================================================================

peer_do_replay(InstId) ->
    Pid = bondy_oplog_registry:applier_pid(InstId),
    bondy_oplog_applier:replay_cell_events_sync(Pid).

peer_register_shard(NS, Index, Shard) ->
    peer_register_shard(NS, Index, Shard, lww_register).

peer_register_shard(NS, Index, Shard, FoldModule) ->
    %% ETS tables die with the calling process, and `erpc:call/4`
    %% workers exit as soon as the call returns. Spawn a long-lived
    %% owner process on the peer to hold the cache + projection
    %% handles for the test's duration; the owner is registered under
    %% a deterministic name so `peer_unregister_shard/3` can find and
    %% stop it at teardown.
    Owner = spawn(
        ?MODULE,
        peer_shard_owner_loop,
        [NS, Index, Shard, FoldModule]
    ),
    Name = owner_name(NS, Index, Shard),
    %% Best-effort register; bail loudly on collision so two tests
    %% sharing a triple don't silently corrupt each other.
    true = register(Name, Owner),
    %% Wait for the owner to publish its handles and complete the
    %% registry insert before returning.
    Owner ! {register, self()},
    receive
        {Owner, registered} -> ok
    after 5_000 ->
        exit({peer_register_shard_timeout, NS, Index, Shard})
    end.

peer_unregister_shard(NS, Index, Shard) ->
    Name = owner_name(NS, Index, Shard),
    case whereis(Name) of
        undefined ->
            ok;
        Pid ->
            Pid ! {unregister, self()},
            receive
                {Pid, unregistered} -> ok
            after 5_000 ->
                exit({peer_unregister_shard_timeout, NS, Index, Shard})
            end
    end.

%% @private
%% Long-lived ETS owner on the peer node. Owns the cache + projection
%% tables for one `(NS, Index, Shard)` triple. Registers them in the
%% local `bondy_oplog_core_registry` once the controller sends `register`,
%% and tears them down on `unregister`. Linked to no one — the test
%% explicitly stops it.
peer_shard_owner_loop(NS, Index, Shard, FoldModule) ->
    receive
        {register, From} ->
            {ok, Cache} = bondy_oplog_cache_ets:init(NS, Index, Shard, #{}),
            {ok, Proj} = bondy_oplog_projection_ets:open(NS, Index, Shard, #{}),
            ok = bondy_oplog_core_registry:register(NS, Index, Shard, #{
                shard_count => 1,
                cache_adapter => bondy_oplog_cache_ets,
                cache_handle => Cache,
                projection_adapter => bondy_oplog_projection_ets,
                projection_handle => Proj,
                fold_module => FoldModule,
                overlay => disabled
            }),
            From ! {self(), registered},
            peer_shard_owner_loop_serve(NS, Index, Shard, Cache, Proj)
    end.

peer_shard_owner_loop_serve(NS, Index, Shard, Cache, Proj) ->
    receive
        {unregister, From} ->
            _ =
                try
                    bondy_oplog_core_registry:unregister(NS, Index, Shard)
                catch
                    _:_ -> ok
                end,
            _ =
                try
                    bondy_oplog_projection_ets:close(Proj)
                catch
                    _:_ -> ok
                end,
            _ =
                try
                    bondy_oplog_cache_ets:close(Cache)
                catch
                    _:_ -> ok
                end,
            From ! {self(), unregistered},
            ok
    end.

owner_name(NS, Index, Shard) ->
    list_to_atom(
        "owner_" ++ atom_to_list(NS) ++ "_" ++
            atom_to_list(Index) ++ "_" ++ integer_to_list(Shard)
    ).

peer_open_instance(InstId, NS, Origin) ->
    peer_open_instance(InstId, NS, Origin, lww_register).

peer_open_instance(InstId, NS, Origin, FoldModule) ->
    {ok, _} = bondy_oplog:start_instance(InstId, #{
        origin => Origin,
        fold_module => FoldModule,
        applier => #{
            cell_apply_target => {NS, primary, 0}
        }
    }),
    ok.

peer_append_cell(InstId, Key, Hlc, Value) ->
    _ = bondy_oplog:append(
        InstId,
        {cell_apply, <<>>, Key, {set, Hlc, Value}}
    ),
    _ = bondy_oplog:projection(InstId),
    ok.

peer_read(NS, Index, Key) ->
    bondy_oplog_core:read(NS, Index, Key).

peer_close_instance(InstId, NS) ->
    _ = bondy_oplog:stop_instance(InstId),
    _ = bondy_oplog_core_registry:unregister(NS, primary, 0),
    ok.
