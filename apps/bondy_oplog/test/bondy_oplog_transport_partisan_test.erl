%% Partisan transport test — the production sync transport
%% (`bondy_oplog_transport_partisan`) had zero test coverage anywhere in
%% this repo (only `inline` and `disterl` were exercised). Mirrors
%% `bondy_oplog_disterl_test.erl`'s structure and helpers, swapping the
%% transport and adding a real Partisan two-node join, plus a third case
%% closing the second gap: no test combined a real second node with a
%% mid-flight failure.

-module(bondy_oplog_transport_partisan_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

%% Helper invoked from the peer node via erpc:call/4.
-export([do_responder_call/3]).

setup() ->
    case net_kernel:get_state() of
        #{started := no} ->
            Name = list_to_atom(
                "bondyparttest_" ++
                    integer_to_list(os:system_time(microsecond))
            ),
            {ok, _} = net_kernel:start(Name, #{name_domain => shortnames}),
            true = erlang:set_cookie(node(), bondyparttestcookie),
            ok;
        _ ->
            ok
    end,
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup(_) ->
    [
        bondy_oplog:stop_instance(I)
     || I <- bondy_oplog:list_instances()
    ],
    leave_all_peers().

%% `peer:stop/1` kills the peer BEAM but the LOCAL Partisan membership
%% set retains the dead node, leaking it into every later test module in
%% the same run (`bondy_oplog_sync_scheduler_test:
%% partisan_source_excludes_self/0` pins a pristine single-node
%% membership). Sweep every non-self member out on the way down.
leave_all_peers() ->
    Manager = partisan_peer_service:manager(),
    Self = partisan:node(),
    {ok, Members} = Manager:members_for_orchestration(),
    _ = [
        catch partisan_peer_service:leave(Spec)
     || #{name := Name} = Spec <- Members, Name =/= Self
    ],
    ok.

partisan_transport_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 60, fun two_nodes_converge_via_partisan/0},
        {timeout, 60, fun partisan_request_routes_through_responder/0},
        {timeout, 60, fun sync_survives_peer_node_failure/0}
    ]}.

%% Two-node convergence via the Partisan transport -- the direct
%% Partisan analogue of `bondy_oplog_disterl_test:two_nodes_converge_via_disterl/0`.
two_nodes_converge_via_partisan() ->
    {ok, Peer, NodeB} = start_peer_node("partb"),
    try
        ok = setup_peer(NodeB),
        ok = join_partisan(NodeB),
        PeerName = erpc:call(NodeB, partisan, node, []),
        Inst = list_to_binary(
            "px_" ++ integer_to_list(os:system_time(microsecond))
        ),
        {ok, _} = bondy_oplog:start_instance(Inst, #{
            origin => bondy_oplog_origin:new()
        }),
        ok = remote_start_instance(NodeB, Inst, bondy_oplog_origin:new()),
        ok = remote_append_n(NodeB, Inst, 5),
        RootRemote = remote_root(NodeB, Inst),
        {ok, _} = bondy_oplog:sync(Inst, PeerName, #{
            transport => bondy_oplog_transport_partisan,
            transport_opts => #{timeout => 10_000}
        }),
        ?assertEqual(
            [],
            bondy_oplog_instance:missing_set(Inst, RootRemote)
        ),
        ?assertEqual(5, bondy_oplog:size(Inst)),
        ok = bondy_oplog:stop_instance(Inst)
    after
        peer:stop(Peer)
    end.

%% Verify the responder demuxes correctly by instance when reached over
%% the Partisan `partisan_gen_server:call/3` path instead of the plain
%% `gen_server:call/3` the disterl transport uses.
partisan_request_routes_through_responder() ->
    {ok, Peer, NodeB} = start_peer_node("partrouting"),
    try
        ok = setup_peer(NodeB),
        ok = join_partisan(NodeB),
        SelfPeerName = partisan:node(),
        Inst1 = list_to_binary("pr1_" ++ unique()),
        Inst2 = list_to_binary("pr2_" ++ unique()),
        {ok, _} = bondy_oplog:start_instance(Inst1, #{
            origin => bondy_oplog_origin:new()
        }),
        {ok, _} = bondy_oplog:start_instance(Inst2, #{
            origin => bondy_oplog_origin:new()
        }),
        [bondy_oplog:append(Inst1, X) || X <- lists:seq(1, 3)],
        ?assertEqual(undefined, bondy_oplog:root_hash(Inst2)),
        {ok, R1, _Fp1} = remote_call(
            NodeB,
            ?MODULE,
            do_responder_call,
            [SelfPeerName, Inst1, get_root]
        ),
        {ok, R2, _Fp2} = remote_call(
            NodeB,
            ?MODULE,
            do_responder_call,
            [SelfPeerName, Inst2, get_root]
        ),
        ?assert(is_binary(R1)),
        ?assertEqual(undefined, R2),
        ok = bondy_oplog:stop_instance(Inst1),
        ok = bondy_oplog:stop_instance(Inst2)
    after
        peer:stop(Peer)
    end.

%% The second gap: no test combined a real second node with a mid-flight
%% failure. NodeB appends a large-enough batch that the sync round has a
%% comfortably wide in-flight window; the sync call is issued
%% asynchronously and NodeB is killed shortly after, so the in-flight
%% `partisan_gen_server:call` most likely fails. Asserts the failed round
%% neither silently "succeeds" nor corrupts local state, then that a
%% subsequent sync against a fresh peer with the same data still
%% converges normally.
sync_survives_peer_node_failure() ->
    {ok, Peer, NodeB} = start_peer_node("partfail"),
    Inst = list_to_binary(
        "pf_" ++ integer_to_list(os:system_time(microsecond))
    ),
    {ok, _} = bondy_oplog:start_instance(Inst, #{
        origin => bondy_oplog_origin:new()
    }),
    try
        ok = setup_peer(NodeB),
        ok = join_partisan(NodeB),
        PeerNameB = erpc:call(NodeB, partisan, node, []),
        ok = remote_start_instance(NodeB, Inst, bondy_oplog_origin:new()),
        ok = remote_append_n(NodeB, Inst, 2000),
        Self = self(),
        _ = spawn(fun() ->
            Result = bondy_oplog:sync(Inst, PeerNameB, #{
                transport => bondy_oplog_transport_partisan,
                transport_opts => #{timeout => 10_000}
            }),
            Self ! {sync_result, Result}
        end),
        ok = peer:stop(Peer),
        SyncOutcome =
            receive
                {sync_result, R} -> R
            after 15_000 -> {error, test_timeout}
            end,
        %% The call must not silently "succeed" against a dead peer.
        ?assertMatch({error, _}, SyncOutcome),
        %% Local state must be untouched -- no partial/corrupt merge.
        ?assertEqual(0, bondy_oplog:size(Inst)),
        ?assertEqual(undefined, bondy_oplog:root_hash(Inst))
    after
        %% Already dead in the success path; harmless if so.
        catch peer:stop(Peer)
    end,
    %% A fresh peer with the same shape of data: a subsequent sync must
    %% still converge normally -- the failed round left nothing corrupted
    %% to retry against.
    {ok, Peer2, NodeC} = start_peer_node("partfail2"),
    try
        ok = setup_peer(NodeC),
        ok = join_partisan(NodeC),
        PeerNameC = erpc:call(NodeC, partisan, node, []),
        ok = remote_start_instance(NodeC, Inst, bondy_oplog_origin:new()),
        ok = remote_append_n(NodeC, Inst, 500),
        RootC = remote_root(NodeC, Inst),
        {ok, _} = bondy_oplog:sync(Inst, PeerNameC, #{
            transport => bondy_oplog_transport_partisan,
            transport_opts => #{timeout => 10_000}
        }),
        ?assertEqual([], bondy_oplog_instance:missing_set(Inst, RootC)),
        ?assertEqual(500, bondy_oplog:size(Inst))
    after
        peer:stop(Peer2)
    end,
    ok = bondy_oplog:stop_instance(Inst).

%% Helper executed on the REMOTE node — calls back into our local
%% responder over the Partisan channel.
do_responder_call(LocalPeerName, InstanceId, Request) ->
    partisan_gen_server:call(
        {bondy_oplog_responder, LocalPeerName},
        {sync_protocol, InstanceId, Request},
        10_000
    ).

%% =============================================================================
%% Partisan cluster-join helpers
%% =============================================================================

%% Joins NodeB to this (the controller) node's Partisan cluster and waits
%% for both sides to see a 2-member membership.
join_partisan(NodeB) ->
    LocalSpec = partisan:node_spec(),
    ok = erpc:call(NodeB, partisan_peer_service, join, [LocalSpec]),
    wait_for_partisan_members(NodeB, 15_000).

wait_for_partisan_members(NodeB, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_for_partisan_members_loop(NodeB, Deadline).

wait_for_partisan_members_loop(NodeB, Deadline) ->
    LocalOk = members_at_least(fun partisan_peer_service:members/0, 2),
    RemoteOk = members_at_least(
        fun() -> erpc:call(NodeB, partisan_peer_service, members, []) end, 2
    ),
    case LocalOk andalso RemoteOk of
        true ->
            ok;
        false ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    error({partisan_join_timeout, NodeB});
                false ->
                    timer:sleep(250),
                    wait_for_partisan_members_loop(NodeB, Deadline)
            end
    end.

members_at_least(Fun, N) ->
    case Fun() of
        {ok, Members} -> length(Members) >= N;
        _ -> false
    end.

%% =============================================================================
%% Peer-node helpers (mirrors bondy_oplog_disterl_test.erl)
%% =============================================================================

start_peer_node(NameSuffix) ->
    Name = list_to_atom(
        NameSuffix ++ "_" ++ integer_to_list(os:system_time(microsecond))
    ),
    Cookie = atom_to_list(erlang:get_cookie()),
    PeerOpts = #{
        name => Name,
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
    %% Start bondy_db, not bondy_mst: the chain is
    %% bondy_db -> bondy_oplog -> bondy_mst, and bondy_mst alone brings up
    %% no supervision tree -> noproc. `partisan` is a declared bondy_oplog
    %% application dependency, so it comes up too.
    {ok, _} = erpc:call(Node, application, ensure_all_started, [bondy_db]),
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

remote_start_instance(Node, Instance, Origin) ->
    {ok, _Pid} = erpc:call(
        Node,
        bondy_oplog,
        start_instance,
        [Instance, #{origin => Origin}]
    ),
    ok.

remote_append_n(Node, Instance, N) ->
    _ = erpc:call(
        Node,
        lists,
        foreach,
        [
            fun(X) ->
                bondy_oplog:append(Instance, {b, X})
            end,
            lists:seq(1, N)
        ]
    ),
    ok.

remote_root(Node, Instance) ->
    erpc:call(Node, bondy_oplog, root_hash, [Instance]).

remote_call(Node, M, F, A) ->
    erpc:call(Node, M, F, A).

unique() ->
    integer_to_list(os:system_time(microsecond)).
