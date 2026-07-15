%% Stage 8: distributed-Erlang transport test.
%%
%% Spawns two peer nodes (using `peer:start_link/1`), starts an
%% instance on each with a distinct origin, exchanges events via
%% `bondy_oplog_transport_disterl`, and verifies
%% convergence.

-module(bondy_oplog_disterl_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

%% Helper invoked from the peer node via erpc:call/4.
-export([do_responder_call/3]).

setup() ->
    %% Start the local node in distributed mode if not already.
    case net_kernel:get_state() of
        #{started := no} ->
            %% Use a unique name per run so tests don't collide.
            Name = list_to_atom(
                "bondymsttest_" ++
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
    %% Make sure the local app is up so we can sync from the other end.
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup(_) ->
    [
        bondy_oplog:stop_instance(I)
     || I <- bondy_oplog:list_instances()
    ],
    ok.

disterl_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 60, fun two_nodes_converge_via_disterl/0},
        {timeout, 60, fun disterl_request_routes_through_responder/0}
    ]}.

%% Two-node convergence via Distributed Erlang.
%%
%% NodeA appends events; NodeB pulls from NodeA via the disterl
%% transport. After the pull, NodeB's local missing_set against
%% NodeA's root must be empty.
two_nodes_converge_via_disterl() ->
    {ok, Peer, NodeB} = start_peer_node("nodeb"),
    try
        ok = setup_peer(NodeB),
        %% Local instance "I" on this node, distinct on the peer node:
        Inst = list_to_binary(
            "dx_" ++ integer_to_list(os:system_time(microsecond))
        ),
        %% Local (initiator) node: holds B in our diagram. We'll PULL
        %% from the remote node (call it A).
        {ok, _} = bondy_oplog:start_instance(Inst, #{
            origin => bondy_oplog_origin:new()
        }),
        %% Remote node: start the same instance with a different origin
        %% and append 5 events.
        ok = remote_start_instance(
            NodeB,
            Inst,
            bondy_oplog_origin:new()
        ),
        ok = remote_append_n(NodeB, Inst, 5),
        RootRemote = remote_root(NodeB, Inst),
        %% Sync local from remote via disterl transport.
        {ok, _} = bondy_oplog:sync(Inst, NodeB, #{
            transport => bondy_oplog_transport_disterl,
            transport_opts => #{timeout => 10_000}
        }),
        %% Convergence invariant: local's missing_set against remote's
        %% root is empty.
        ?assertEqual(
            [],
            bondy_oplog_instance:missing_set(Inst, RootRemote)
        ),
        %% Local now has the 5 events from remote.
        ?assertEqual(5, bondy_oplog:size(Inst)),
        ok = bondy_oplog:stop_instance(Inst)
    after
        peer:stop(Peer)
    end.

%% Verify the responder routes a sync_protocol request from a remote
%% caller to the correct local instance, even with multiple instances
%% running.
disterl_request_routes_through_responder() ->
    {ok, Peer, NodeB} = start_peer_node("nodebrouting"),
    try
        ok = setup_peer(NodeB),
        Inst1 = list_to_binary("r1_" ++ unique()),
        Inst2 = list_to_binary("r2_" ++ unique()),
        {ok, _} = bondy_oplog:start_instance(Inst1, #{
            origin => bondy_oplog_origin:new()
        }),
        {ok, _} = bondy_oplog:start_instance(Inst2, #{
            origin => bondy_oplog_origin:new()
        }),
        %% Append events ONLY to Inst1 locally so its root is non-undef.
        [bondy_oplog:append(Inst1, X) || X <- lists:seq(1, 3)],
        %% Inst2 locally is empty (root = undefined).
        ?assertEqual(undefined, bondy_oplog:root_hash(Inst2)),
        %% From the remote node, ask the responder for our local Inst1
        %% root and our local Inst2 root. Different instances, same
        %% wire shape; the responder must demux.
        Self = node(),
        %% `get_root` replies `{ok, Root, Fingerprint}`; Fingerprint is
        %% `undefined` for these bare oplog instances (no bondy_db manifest).
        {ok, R1, _Fp1} = remote_call(
            NodeB,
            ?MODULE,
            do_responder_call,
            [Self, Inst1, get_root]
        ),
        {ok, R2, _Fp2} = remote_call(
            NodeB,
            ?MODULE,
            do_responder_call,
            [Self, Inst2, get_root]
        ),
        ?assert(is_binary(R1)),
        ?assertEqual(undefined, R2),
        %% The local responder did the demux correctly.
        ok = bondy_oplog:stop_instance(Inst1),
        ok = bondy_oplog:stop_instance(Inst2)
    after
        peer:stop(Peer)
    end.

%% Helper executed on the REMOTE node — calls back into our local
%% responder.
do_responder_call(LocalNode, InstanceId, Request) ->
    gen_server:call(
        {bondy_oplog_responder, LocalNode},
        {sync_protocol, InstanceId, Request},
        10_000
    ).

%% =============================================================================
%% Peer-node helpers
%% =============================================================================

start_peer_node(NameSuffix) ->
    Name = list_to_atom(
        NameSuffix ++ "_" ++ integer_to_list(os:system_time(microsecond))
    ),
    Cookie = atom_to_list(erlang:get_cookie()),
    %% Start the peer attached so it dies with us if we crash.
    %% `connection => standard_io` keeps the peer chained to our shell;
    %% the cookie must match the parent's so disterl handshakes succeed
    %% on the very first connection.
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
    %% Bring the storage substrate up on the peer (its code path was
    %% inherited at startup). Start bondy_db, not bondy_mst: the chain is
    %% bondy_db -> bondy_oplog -> bondy_mst, and bondy_mst alone brings up
    %% no supervision tree -> noproc.
    {ok, _} = erpc:call(Node, application, ensure_all_started, [bondy_db]),
    %% Push the test module to the peer so it can run callbacks the
    %% test expects to see there. `-pa` only puts the paths on the
    %% peer; modules still need a `code:ensure_loaded` to be available
    %% via apply.
    {Mod, Bin, File} = code:get_object_code(?MODULE),
    {module, Mod} = erpc:call(Node, code, load_binary, [Mod, File, Bin]),
    %% Disable the peer's default schedulers so it doesn't auto-sync
    %% during the test.
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
