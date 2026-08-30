%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% -----------------------------------------------------------------------------
%% The `bondy.cluster.*` API, exercised through `bondy_wamp_api:handle_call/2`
%% rather than by calling the module directly — a direct call would pass with
%% the dispatch clause unwired, which is the one thing that cannot be checked
%% any other way.
%%
%% `bondy.cluster.leave` is the only `destructive` task in the catalogue, and
%% what makes it destructive is what the removal RELEASES: membership is the
%% reclamation authority, so once a node is out the retirement pass may reap
%% its origins and a node rejoining under the same name is handed a new one.
%% The cases below therefore aim at the two ways that goes wrong — removing
%% something that was never a member, and removing one while a survivor is in
%% no state to be asked what it holds.
%%
%% WHAT THIS SUITE DOES NOT COVER: the real removal on a real cluster. Every
%% case here runs on one node, so `survey/1`'s peer list is empty on the
%% dispatch path and the interesting outcomes are reached by calling the
%% predicate directly with peers that cannot answer. A multi-node case would
%% need `bondy_ct:start_cluster/2` and would be removing a node from the
%% cluster the suite is running in.
%% -----------------------------------------------------------------------------
-module(bondy_cluster_api_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, <<"com.example.cluster_api_suite">>).

all() ->
    [
        members_lists_this_node,
        connections_answers_an_envelope,
        leave_of_a_non_member_is_refused,
        leave_of_an_unknown_atom_creates_no_atom,
        a_silent_peer_makes_a_leave_unsafe,
        a_not_ready_peer_makes_a_leave_unsafe,
        no_peers_is_safe,
        local_readiness_reports_this_node,
        every_procedure_requires_the_master_realm,
        join_is_still_refused
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    R = bondy_realm:create(?REALM),
    ok = bondy_realm:disable_security(R),
    Config.

end_per_suite(Config) ->
    {save_config, Config}.

%% =============================================================================
%% CASES — the read procedures
%% =============================================================================

members_lists_this_node(_) ->
    Members = call(?BONDY_CLUSTER_MEMBERS, []),
    ?assert(lists:member(partisan:node(), Members)).

%% `connections` was a stub refusing with `no_such_procedure` while being
%% documented as reserved. It is a read of Partisan's own connection table and
%% had no reason to be one.
connections_answers_an_envelope(_) ->
    Reply = call(?BONDY_CLUSTER_CONNECTIONS, []),
    ?assertEqual(
        atom_to_binary(partisan:node()), maps:get(<<"node">>, Reply)
    ),
    Conns = maps:get(<<"connections">>, Reply),
    ?assert(is_list(Conns)),
    %% Shape, not count: a single-node suite has no peer connections, and the
    %% envelope must still be well formed rather than absent.
    lists:foreach(
        fun(C) ->
            ?assert(is_binary(maps:get(<<"node">>, C))),
            ?assert(is_binary(maps:get(<<"channel">>, C)))
        end,
        Conns
    ).

%% =============================================================================
%% CASES — leave refusals
%% =============================================================================

%% The first thing `leave` must not do is act on a name that is not a member.
%% Partisan would be handed a spec it never had, and the operator would be told
%% a node was removed that was never there.
leave_of_a_non_member_is_refused(_) ->
    {ok, Before} = partisan_peer_service:members(),
    E = call_error(?BONDY_CLUSTER_LEAVE, [<<"nosuch@nowhere">>]),
    ?assertMatch(#error{}, E),
    {ok, After} = partisan_peer_service:members(),
    ?assertEqual(lists:sort(Before), lists:sort(After)).

%% The node name arrives from a caller, so resolving it must not mint an atom.
%% `binary_to_existing_atom/2` is what makes that true; this case pins it by
%% asking for a name nothing has ever created and asserting it stays uncreated.
leave_of_an_unknown_atom_creates_no_atom(_) ->
    Name = <<"bondy_cluster_api_suite_never_an_atom@nowhere">>,
    _ = call_error(?BONDY_CLUSTER_LEAVE, [Name]),
    ?assertError(
        badarg,
        binary_to_existing_atom(Name, utf8),
        "resolving a node name created an atom"
    ).

%% =============================================================================
%% CASES — the safety predicate
%% =============================================================================

%% The hazard the predicate exists for. After a membership removal the
%% retirement pass reaps every origin no live member claims; it is fail-closed
%% on a member it cannot ask, so a member that is silent NOW is one whose
%% origins cannot be accounted for, and removing another node while that is
%% true is exactly when a live origin gets banned.
a_silent_peer_makes_a_leave_unsafe(_) ->
    Silent = 'bondy_cluster_api_suite_silent@127.0.0.1',
    Survey = bondy_cluster_api:survey([Silent]),
    ?assertEqual(false, maps:get(safe, Survey)),
    ?assertEqual([Silent], maps:get(silent, Survey)),
    ?assertEqual([], maps:get(answered, Survey)).

%% The other side of the same hazard: a member that answers but is NOT READY
%% is up without being fully started, which is the under-advertising case — it
%% can hold origins it is not yet advertising.
%%
%% Driven through the predicate with this node as the peer, because a
%% single-node suite has no second node to put in that state. `is_ready/0`
%% reads the node's own readiness oracle, so making this node not ready makes
%% its own answer `false`.
a_not_ready_peer_makes_a_leave_unsafe(_) ->
    Self = partisan:node(),
    Saved = bondy_config:get(status, undefined),
    ok = bondy_config:set(status, initialising),
    try
        Survey = bondy_cluster_api:survey([Self]),
        ?assertEqual(false, maps:get(safe, Survey)),
        ?assertEqual([Self], maps:get(not_ready, Survey)),
        ?assertEqual([], maps:get(silent, Survey))
    after
        ok = bondy_config:set(status, Saved)
    end.

%% Removing the last peer is not a hazard: with nobody left to under-advertise,
%% there is nothing the reaper can get wrong. Also the vacuity guard for the
%% two cases above — if the predicate answered `false` unconditionally they
%% would both pass for the wrong reason.
no_peers_is_safe(_) ->
    Survey = bondy_cluster_api:survey([]),
    ?assertEqual(true, maps:get(safe, Survey)),
    ?assertEqual([], maps:get(silent, Survey)),
    ?assertEqual([], maps:get(not_ready, Survey)).

local_readiness_reports_this_node(_) ->
    {Node, Ready, Instances} = bondy_cluster_api:local_readiness(),
    ?assertEqual(partisan:node(), Node),
    ?assert(is_boolean(Ready)),
    ?assert(is_integer(Instances) andalso Instances >= 0).

%% =============================================================================
%% CASES — authority
%% =============================================================================

every_procedure_requires_the_master_realm(_) ->
    %% Each with its own arity: the argument count is checked BEFORE the
    %% realm, so passing the wrong number would produce an arity error and
    %% the case would pass for the wrong reason.
    lists:foreach(
        fun({Proc, Args}) ->
            E = call_error(?REALM, Proc, Args),
            ?assertEqual(?WAMP_NOT_AUTHORIZED, E#error.error_uri, Proc)
        end,
        [
            {?BONDY_CLUSTER_LEAVE, [<<"nosuch@nowhere">>]},
            {?BONDY_CLUSTER_CONNECTIONS, []}
        ]
    ).

%% Joining needs a full Partisan node spec — name, listen addresses and
%% channels — which a procedure argument conveys poorly, and peer discovery
%% already forms and grows clusters. It stays refused deliberately.
join_is_still_refused(_) ->
    E = call_error(?BONDY_CLUSTER_JOIN, []),
    ?assertEqual(?WAMP_NO_SUCH_PROCEDURE, E#error.error_uri).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
%% Through the dispatcher, so the `bondy.cluster.` clause in
%% `bondy_wamp_api:do_handle_call/3` is exercised by every call.
handle(RealmUri, Proc, Args) ->
    Ctxt = bondy_context:local_context(RealmUri),
    M = bondy_wamp_message:call(1, #{}, Proc, Args),
    bondy_wamp_api:handle_call(M, Ctxt).

%% @private
call(Proc, Args) ->
    case handle(?MASTER_REALM_URI, Proc, Args) of
        {reply, #result{args = [Reply]}} -> Reply;
        Other -> ct:fail({expected_result, Proc, Other})
    end.

%% @private
call_error(Proc, Args) ->
    call_error(?MASTER_REALM_URI, Proc, Args).

%% @private
%% The unauthorized path THROWS rather than replying, which is how
%% `bondy_wamp_api_utils:validate_admin_call_args/3` reports refusal.
call_error(RealmUri, Proc, Args) ->
    try handle(RealmUri, Proc, Args) of
        {reply, #error{} = E} -> E;
        Other -> ct:fail({expected_error, Proc, Other})
    catch
        error:#error{} = E -> E
    end.
