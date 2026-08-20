%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Cross-node coverage of `bondy_registry_meta`: registrations are added on BOTH
%% cluster nodes, then a coordinator node pages the whole realm. The distributed
%% keyset walk must return every entry from every node — no skips, no
%% duplicates — across page boundaries. Unlike RIB convergence, this needs no
%% wait: `list` reads each node's local entries directly via the per-node
%% `partisan_gen_server` responder, so the union is immediate.
-module(bondy_registry_meta_cluster_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_security.hrl").

-compile([export_all, nowarn_export_all]).

-define(NODE_NAMES, [bondy_meta1, bondy_meta2]).
-define(REALM, <<"com.meta.cluster">>).
-define(PER_NODE, 15).
%% list/match target only RIB-known nodes, so cross-node completeness tracks RIB
%% stub convergence; budget matches the other cluster suites.
-define(CONVERGE_MS, 120000).

suite() ->
    [{timetrap, {minutes, 5}}].

all() ->
    [
        cluster_list_paginates_all_nodes,
        cluster_get_by_id_across_nodes,
        cluster_member_pages_span_nodes,
        cluster_member_pages_by_uri,
        cluster_member_cursor_is_not_interchangeable
    ].

init_per_suite(Config) ->
    Nodes = bondy_ct:start_cluster(?NODE_NAMES, Config),
    _ = [push_module(N) || {_, N, _} <- Nodes],
    [N1, N2] = [Node || {_, Node, _} <- Nodes],

    ok = erpc:call(N1, ?MODULE, do_create_open_realm, [?REALM]),
    ok = wait_realm(N2, ?REALM),

    %% Distinct exact registrations on each node; ids are node-local.
    Ids1 = erpc:call(N1, ?MODULE, do_add_regs, [?REALM, uris(<<"n1">>)]),
    Ids2 = erpc:call(N2, ?MODULE, do_add_regs, [?REALM, uris(<<"n2">>)]),

    [
        {nodes, Nodes},
        {coordinator, N1},
        {ids_on_peer, Ids2},
        {all_ids, lists:sort(Ids1 ++ Ids2)}
        | Config
    ].

end_per_suite(Config) ->
    Nodes = proplists:get_value(nodes, Config, []),
    try
        bondy_ct:stop_cluster(Nodes)
    catch
        _:_ -> ok
    end,
    ok.

%% =============================================================================
%% CASES
%% =============================================================================

cluster_list_paginates_all_nodes(Config) ->
    Coordinator = ?config(coordinator, Config),
    ExpectedIds = ?config(all_ids, Config),

    %% The coordinator's own entries are visible at once; the peer's appear once
    %% its RIB stubs converge, so poll the full paginated drain until complete.
    %% Page size does not divide the 2-node total, so pages straddle the node
    %% boundary as well as page boundaries.
    Collected = wait_until_complete(Coordinator, length(ExpectedIds)),

    ?assertEqual(ExpectedIds, lists:usort(Collected)),
    ?assertEqual(length(ExpectedIds), length(Collected)),
    ?assert(all_unique(Collected)).

%% A point-get from the coordinator for an id owned by the PEER node resolves
%% via the broadcast; a non-existent id resolves to not_found.
cluster_get_by_id_across_nodes(Config) ->
    Coordinator = ?config(coordinator, Config),
    [IdOnPeer | _] = ?config(ids_on_peer, Config),

    {ok, External} = erpc:call(Coordinator, ?MODULE, do_get, [?REALM, IdOnPeer]),
    ?assertEqual(IdOnPeer, maps:get(id, External)),

    ?assertEqual(
        {error, not_found},
        erpc:call(Coordinator, ?MODULE, do_get, [?REALM, 999999999999999])
    ).

%% `page_members/4` pairs each member session with the node holding it, and that
%% node is the whole point — it is what `bondy.registration.callee.list`
%% reports. The realm-wide form must span the cluster: reading
%% `bondy_registry:match/3` instead would answer with the coordinator's OWN
%% entries only under write-only RIB, silently omitting the peer's callees and
%% shrinking the answer as the cluster grows.
%%
%% The page size is deliberately smaller than one node's share, so the walk
%% must cross a page boundary AND a node boundary to see both.
cluster_member_pages_span_nodes(Config) ->
    Coordinator = ?config(coordinator, Config),
    Peer = peer_node(Config),

    Nodestrings = wait_until_member_nodes(Coordinator, all, 2),

    ?assertEqual(
        lists:usort([nodestring(Coordinator), nodestring(Peer)]),
        Nodestrings
    ).

%% The by-URI form must also reach the peer AND stay scoped to the URI asked
%% for: this procedure is registered on the peer only, so exactly one member
%% comes back and it names the peer.
cluster_member_pages_by_uri(Config) ->
    Coordinator = ?config(coordinator, Config),
    PeerNS = nodestring(peer_node(Config)),
    [Uri | _] = uris(<<"n2">>),

    _ = wait_until_member_nodes(Coordinator, Uri, 1),

    Members = drain_members(Coordinator, Uri, 7, undefined, []),

    ?assertMatch([#{node := PeerNS, session_id := _}], Members).

%% A cursor minted by the callee walk must not be resumable by the entry walk
%% over the same realm: the two agree on the walk but not on the projection, so
%% a shared cursor would hand back the other procedure's values. The
%% fingerprint binds the projection, so this is rejected as stale.
cluster_member_cursor_is_not_interchangeable(Config) ->
    Coordinator = ?config(coordinator, Config),
    _ = wait_until_member_nodes(Coordinator, all, 2),

    {ok, #{next := Next, has_more := true}} = erpc:call(
        Coordinator, ?MODULE, do_page_members, [?REALM, all, #{limit => 1}]
    ),

    Cursor = bondy_pagination:encode_cursor(Next),

    ?assertEqual(
        {error, stale},
        erpc:call(Coordinator, ?MODULE, do_list, [
            ?REALM, #{limit => 1, cursor => Cursor}
        ])
    ).

%% =============================================================================
%% PEER-SIDE HELPERS (run on the cluster nodes via erpc)
%% =============================================================================

do_create_open_realm(Uri) ->
    Realm = bondy_realm:create(Uri),
    ok = bondy_realm:disable_security(Realm),
    ok.

do_has_realm(Uri) ->
    bondy_realm:exists(Uri).

%% Add exact registrations for `Uris` on THIS node and return their ids.
do_add_regs(RealmUri, Uris) ->
    Peer = {{127, 0, 0, 1}, 10000},
    Session = bondy_session:new(RealmUri, #{
        peer => Peer,
        authid => <<"meta">>,
        authmethod => ?WAMP_ANON_AUTH,
        is_anonymous => true,
        security_enabled => true,
        authroles => [<<"anonymous">>],
        roles => #{caller => #{}, callee => #{}}
    }),
    Ctxt = bondy_context:new(Peer, {ws, text, json}, #{session => Session}),
    Ref = bondy_context:ref(Ctxt),
    [
        begin
            {ok, {Entry, true}} = bondy_registry:add(
                registration, RealmUri, Uri, #{match => ?EXACT_MATCH}, Ref
            ),
            bondy_registry_entry:id(Entry)
        end
     || Uri <- Uris
    ].

%% Run the paginated list on THIS (coordinator) node — a cluster member, so its
%% node set spans the peers.
do_list(RealmUri, Opts) ->
    bondy_registry_meta:list(registration, RealmUri, Opts).

%% Resolve a get-by-id from THIS (coordinator) node across the cluster.
do_get(RealmUri, Id) ->
    bondy_registry_meta:get(registration, RealmUri, Id).

%% Page {node, session_id} members from THIS (coordinator) node cluster-wide.
do_page_members(RealmUri, Query, Opts) ->
    bondy_registry_meta:page_members(registration, RealmUri, Query, Opts).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% Poll the full paginated drain until it yields at least `Expected` ids (peer
%% RIB stubs have converged) or the budget elapses (returning what we have, so
%% the caller's assertion fails with detail).
wait_until_complete(Coordinator, Expected) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    wait_until_complete(Coordinator, Expected, Deadline).

wait_until_complete(Coordinator, Expected, Deadline) ->
    Collected = drain(Coordinator, 7, undefined, []),
    case length(Collected) >= Expected of
        true ->
            Collected;
        false ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    Collected;
                false ->
                    timer:sleep(200),
                    wait_until_complete(Coordinator, Expected, Deadline)
            end
    end.

%% Drive the paginated list from the coordinator node, threading the wire cursor.
drain(Coordinator, Limit, Cursor, Acc) ->
    Opts =
        case Cursor of
            undefined -> #{limit => Limit};
            _ -> #{limit => Limit, cursor => Cursor}
        end,
    {ok, #{values := Values, next := Next, has_more := HasMore}} =
        erpc:call(Coordinator, ?MODULE, do_list, [?REALM, Opts]),
    Ids = [maps:get(id, V) || V <- Values],
    Acc1 = Acc ++ Ids,
    case HasMore of
        false ->
            ?assertEqual(undefined, Next),
            Acc1;
        true ->
            drain(
                Coordinator,
                Limit,
                bondy_pagination:encode_cursor(Next),
                Acc1
            )
    end.

%% @private
peer_node(Config) ->
    Coordinator = ?config(coordinator, Config),
    [Peer] = [
        Node
     || {_, Node, _} <- ?config(nodes, Config), Node =/= Coordinator
    ],
    Peer.

%% @private
nodestring(Node) ->
    atom_to_binary(Node, utf8).

%% @private
%% Drains the FULL member walk, threading the wire cursor exactly as a client
%% would. Page size is deliberately smaller than one node's share so the drain
%% crosses page boundaries as well as the node boundary.
drain_members(Coordinator, Query, Limit, Cursor, Acc) ->
    Opts =
        case Cursor of
            undefined -> #{limit => Limit};
            _ -> #{limit => Limit, cursor => Cursor}
        end,
    {ok, #{values := Values, next := Next, has_more := HasMore}} =
        erpc:call(Coordinator, ?MODULE, do_page_members, [?REALM, Query, Opts]),
    Acc1 = Acc ++ Values,

    case HasMore of
        false ->
            ?assertEqual(undefined, Next),
            Acc1;
        true ->
            drain_members(
                Coordinator,
                Query,
                Limit,
                bondy_pagination:encode_cursor(Next),
                Acc1
            )
    end.

%% @private
%% Polls the full member drain until it reports at least `N' distinct nodes,
%% then returns them sorted. The realm-wide node set is derived from RIB stubs,
%% so the peer's contribution appears only once its stubs converge — the same
%% reason `cluster_list_paginates_all_nodes' polls rather than asserting once.
wait_until_member_nodes(Coordinator, Query, N) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    wait_until_member_nodes(Coordinator, Query, N, Deadline).

wait_until_member_nodes(Coordinator, Query, N, Deadline) ->
    Members = drain_members(Coordinator, Query, 7, undefined, []),
    Nodestrings = lists:usort([maps:get(node, M) || M <- Members]),

    case length(Nodestrings) >= N of
        true ->
            Nodestrings;
        false ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    %% Return what we have; the caller's assertion reports it.
                    Nodestrings;
                false ->
                    timer:sleep(200),
                    wait_until_member_nodes(Coordinator, Query, N, Deadline)
            end
    end.

%% @private
push_module(Node) ->
    {?MODULE, Bin, File} = code:get_object_code(?MODULE),
    {module, ?MODULE} = erpc:call(Node, code, load_binary, [?MODULE, File, Bin]),
    ok.

%% @private
wait_realm(Node, Uri) ->
    wait_until(
        fun() -> erpc:call(Node, ?MODULE, do_has_realm, [Uri]) end,
        {realm, Node, Uri}
    ).

%% @private
wait_until(Fun, Tag) ->
    wait_until(Fun, Tag, erlang:monotonic_time(millisecond) + 30000).

wait_until(Fun, Tag, Deadline) ->
    case Fun() of
        true ->
            ok;
        _ ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    error({wait_timeout, Tag});
                false ->
                    timer:sleep(100),
                    wait_until(Fun, Tag, Deadline)
            end
    end.

uris(NodeTag) ->
    [
        <<"com.meta.c.", NodeTag/binary, ".",
            (list_to_binary(io_lib:format("~4..0b", [I])))/binary>>
     || I <- lists:seq(1, ?PER_NODE)
    ].

%% No id appears twice across the whole cluster walk. (Ordering is node-then-id,
%% not globally ascending, so we assert dup-freedom rather than monotonicity;
%% completeness is asserted separately by the caller.)
all_unique(Ids) ->
    length(Ids) =:= length(lists:usort(Ids)).
