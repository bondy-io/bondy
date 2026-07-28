%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_session_get_cluster_SUITE).
-moduledoc """
End-to-end cross-node test of `wamp.session.get` routing on a 2-node cluster.

A session is opened on node 1; node 2 CALLs `wamp.session.get(Guid)`. The guid
embeds node 1's hash, so node 2 rewrites the call to
`wamp.session.{Node1Hash}.{Rest}.get`, discovers node 1 from the per-node
wildcard registration stub (converged via AAE), forwards the CALL node-addressed,
node 1's stateless callback resolves the session, and the RESULT rides the
promise reverse path back to node 2's caller — with no per-session registration.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_security.hrl").

-compile([nowarn_export_all, export_all]).

-define(NODE_NAMES, [sessget1, sessget2]).
-define(CONVERGE_MS, 120000).

%% =============================================================================
%% CT CALLBACKS
%% =============================================================================

all() ->
    [
        cross_node_get,
        cross_node_get_unknown
    ].

suite() ->
    [{timetrap, {minutes, 10}}].

init_per_suite(Config) ->
    Nodes = bondy_ct:start_cluster(?NODE_NAMES, Config),
    %% Make this module's helpers callable on every peer.
    _ = [push_module(Node, ?MODULE) || {_, Node, _} <- Nodes],
    [{cluster, Nodes} | Config].

end_per_suite(Config) ->
    ok = bondy_ct:stop_cluster(?config(cluster, Config)),
    Config.

%% =============================================================================
%% TESTS
%% =============================================================================

%% A session opened on node 1 is retrievable via wamp.session.get issued on
%% node 2 — routed by the guid's embedded node hash to node 1's per-node
%% wildcard, with no per-session registration.
cross_node_get(Config) ->
    [N1, N2] = nodes_of(Config),
    Uri = <<"com.bondy.sessget.a">>,

    ok = erpc:call(N1, ?MODULE, do_create_open_realm, [Uri]),
    Guid = erpc:call(N1, ?MODULE, do_open_held_session, [Uri]),

    ok = wait_owner_stub(N1, N2, Uri),

    %% External view is a pure function of the guid — compute it locally.
    ExtId = bondy_session_id:to_external(Guid),

    Result = erpc:call(N2, ?MODULE, do_session_get, [Uri, Guid]),
    ?assertMatch(
        #result{args = [#{session := ExtId, authextra := #{session_guid := Guid}}]},
        Result
    ).

%% A well-formed guid carrying node 1's hash but with no live session routes to
%% node 1 and comes back as a no_such_session ERROR (not a silent success and
%% not a routing failure).
cross_node_get_unknown(Config) ->
    [N1, N2] = nodes_of(Config),
    Uri = <<"com.bondy.sessget.b">>,

    ok = erpc:call(N1, ?MODULE, do_create_open_realm, [Uri]),
    %% One real session so node 1's wildcard exists and converges to node 2.
    _ = erpc:call(N1, ?MODULE, do_open_held_session, [Uri]),
    ok = wait_owner_stub(N1, N2, Uri),

    %% A fresh guid on node 1 (its hash prefix) that was never opened.
    Fake = erpc:call(N1, bondy_session_id, new, []),

    Result = erpc:call(N2, ?MODULE, do_session_get, [Uri, Fake]),
    ?assertMatch(#error{error_uri = ?WAMP_NO_SUCH_SESSION}, Result).

%% =============================================================================
%% CODE RUN ON THE PEERS
%% =============================================================================

%% @private
do_create_open_realm(Uri) ->
    Realm = bondy_realm:create(Uri),
    ok = bondy_realm:disable_security(Realm),
    ok.

%% @private
%% Opens a session from a long-lived holder process (so the session — and its
%% wildcard registration — outlive this short-lived erpc worker) and returns its
%% guid.
do_open_held_session(Uri) ->
    Me = self(),
    _Holder = spawn(fun() ->
        {ok, Session} = bondy_session_manager:open(
            bondy_session_id:new(), Uri, session_opts()
        ),
        Me ! {opened, bondy_session:id(Session)},
        receive
            stop -> ok
        end
    end),
    receive
        {opened, Guid} -> Guid
    after 15000 ->
        error(session_open_timeout)
    end.

%% @private
%% Issues wamp.session.get(Guid) as a local caller and returns the routed
%% RESULT/ERROR (mirrors bondy_aae_cluster_SUITE:do_rib_call/3).
do_session_get(RealmUri, Guid) ->
    Peer = {{127, 0, 0, 1}, 10999},
    Session = bondy_session:new(RealmUri, #{
        peer => Peer,
        authid => <<"sessget">>,
        authmethod => ?WAMP_ANON_AUTH,
        is_anonymous => true,
        security_enabled => false,
        authroles => [<<"anonymous">>],
        roles => #{caller => #{}}
    }),
    Ctxt = bondy_context:new(Peer, {ws, text, json}, #{session => Session}),
    Call = bondy_wamp_message:call(1, #{}, ?WAMP_SESSION_GET, [Guid]),
    ok = bondy_dealer:forward(Call, Ctxt),
    receive
        {'$bondy_request', _, _, M} -> M
    after 30000 ->
        timeout
    end.

%% @private
session_opts() ->
    #{
        peer => {{127, 0, 0, 1}, 10000},
        authid => <<"anonymous">>,
        authmethod => ?WAMP_ANON_AUTH,
        is_anonymous => true,
        security_enabled => true,
        authroles => [<<"anonymous">>],
        roles => #{caller => #{}, subscriber => #{}}
    }.

%% =============================================================================
%% HELPERS (controller side)
%% =============================================================================

%% @private
nodes_of(Config) ->
    [Node || {_, Node, _} <- ?config(cluster, Config)].

%% @private
push_module(Node, Mod) ->
    {Mod, Bin, File} = code:get_object_code(Mod),
    {module, Mod} = erpc:call(Node, code, load_binary, [Mod, File, Bin]),
    ok.

%% @private
%% Wait until node Observer's RIB stub view names Owner for Owner's per-node
%% wamp.session wildcard in RealmUri.
wait_owner_stub(Owner, Observer, RealmUri) ->
    OwnerStr = erpc:call(Owner, bondy_config, nodestring, []),
    NodeHash = erpc:call(Owner, bondy_config, node_hash, []),
    WildUri = <<"wamp.session.", NodeHash/binary, "..get">>,
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    wait_until_eq(
        fun() ->
            Stubs = erpc:call(
                Observer,
                bondy_registry_rib,
                stub_nodes,
                [registration, RealmUri, ?WILDCARD_MATCH, WildUri]
            ),
            lists:member(OwnerStr, [N || {N, _} <- Stubs])
        end,
        true,
        Observer,
        Deadline
    ).

%% @private
wait_until_eq(Fun, Expected, Node, Deadline) ->
    _ = catch erpc:call(Node, bondy_oplog_sync_scheduler, trigger, []),
    case catch Fun() of
        Expected ->
            ok;
        Other ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    error({wait_eq_timeout, Node, Expected, Other});
                false ->
                    timer:sleep(250),
                    wait_until_eq(Fun, Expected, Node, Deadline)
            end
    end.
