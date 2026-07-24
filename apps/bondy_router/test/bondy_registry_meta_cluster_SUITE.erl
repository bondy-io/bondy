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
        cluster_get_by_id_across_nodes
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
    catch bondy_ct:stop_cluster(Nodes),
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
