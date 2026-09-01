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
        info_answers_this_node_spec,
        leave_of_a_non_member_is_refused,
        leave_of_an_unknown_atom_creates_no_atom,
        a_silent_peer_makes_a_leave_unsafe,
        a_not_ready_peer_makes_a_leave_unsafe,
        no_peers_is_safe,
        a_spent_budget_makes_a_leave_unsafe,
        local_readiness_reports_this_node,
        every_procedure_requires_the_master_realm,
        the_declared_procedures_are_the_ones_the_module_dispatches,
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

%% The caller's `_deadline` bounds the survey, and running out of it is
%% FAIL-CLOSED. A survey that ran out of time and answered `safe` would be
%% asserting exactly the thing it failed to check: the retirement pass that
%% follows a removal reaps origins no live member claims and is itself
%% fail-closed on a member it could not ask, so "I did not get to ask" and
%% "everyone answered" must not produce the same verdict.
%%
%% Driven at the predicate with a spent budget, which is what a caller whose
%% deadline has already passed produces. No peer is contacted at all — with no
%% time to receive an answer there is nothing to be gained by asking.
a_spent_budget_makes_a_leave_unsafe(_) ->
    Peer = 'bondy_cluster_api_suite_spent@127.0.0.1',
    Survey = bondy_cluster_api:survey([Peer], 0),
    ?assertEqual(false, maps:get(safe, Survey)),
    ?assertEqual([Peer], maps:get(silent, Survey)),
    ?assertEqual([], maps:get(answered, Survey)),

    %% An empty membership is still safe with no budget: there was nothing to
    %% ask, so nothing went unasked. Without this the case above would pass
    %% against a `survey/2` that answered `unsafe` unconditionally.
    ?assertEqual(
        #{safe => true, answered => [], silent => [], not_ready => []},
        bondy_cluster_api:survey([], 0)
    ).

%% `info` had no case at all until it was put behind the master realm on
%% 2026-09-02. Gating a procedure nothing exercises would have been a change
%% whose happy path stayed unobserved either side of it.
info_answers_this_node_spec(_) ->
    Info = call(?BONDY_CLUSTER_INFO, []),
    ?assertEqual(
        bondy_wamp_api_utils:node_spec(), maps:get(<<"node_spec">>, Info)
    ),
    ?assert(is_list(maps:get(<<"nodes">>, Info))).

%% =============================================================================
%% CASES — authority
%% =============================================================================

%% Every `bondy.cluster.*` procedure the module answers, the arity a call must
%% carry, and the authority it requires.
%%
%% DECLARED, never derived from the module: a set read out of the code it is
%% meant to constrain can only ever agree with itself. `members` and `info`
%% answered in ANY realm until 2026-09-02, for exactly as long as this case
%% listed the two procedures somebody remembered to list.
procedures() ->
    [
        {?BONDY_CLUSTER_LEAVE, [<<"nosuch@nowhere">>], master_realm},
        {?BONDY_CLUSTER_CONNECTIONS, [], master_realm},
        {?BONDY_CLUSTER_MEMBERS, [], master_realm},
        {?BONDY_CLUSTER_INFO, [], master_realm},
        {?BONDY_CLUSTER_JOIN, [], refused}
    ].

every_procedure_requires_the_master_realm(_) ->
    %% Each with its own arity: the argument count is checked BEFORE the
    %% realm, so passing the wrong number would produce an arity error and
    %% the case would pass for the wrong reason.
    lists:foreach(
        fun({Proc, Args, _}) ->
            E = call_error(?REALM, Proc, Args),
            ?assertEqual(?WAMP_NOT_AUTHORIZED, E#error.error_uri, Proc)
        end,
        [P || {_, _, master_realm} = P <- procedures()]
    ).

%% The ratchet on `procedures/0`. That table is worth something only if it is
%% COMPLETE, and nothing about writing a new `handle_call/3` clause makes an
%% author come here. So the declared URIs are compared against the ones the
%% module actually dispatches, read from its compiled abstract code: a new
%% clause fails this case until its authority is declared above.
the_declared_procedures_are_the_ones_the_module_dispatches(_) ->
    Declared = lists:sort([Uri || {Uri, _, _} <- procedures()]),
    Dispatched = dispatched_uris(),
    %% Reach first. An unreadable or stripped beam yields an empty list, which
    %% would otherwise let any declaration pass.
    ?assert(length(Dispatched) >= 4, {too_few_clauses_read, Dispatched}),
    ?assertEqual(Declared, Dispatched).

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
%% The `bondy.cluster.*` URIs `handle_call/3` matches on. The catch-all clause
%% binds a variable rather than a literal and contributes nothing.
dispatched_uris() ->
    lists:sort([
        Uri
     || {function, _, handle_call, 3, Clauses} <- forms(bondy_cluster_api),
        {clause, _, [Head | _], _, _} <- Clauses,
        Uri <- literal(Head)
    ]).

%% @private
%% A clause head's binary literal, as a ONE-ELEMENT list so that a head which
%% is not one contributes nothing to the comprehension above.
literal({bin, _, _} = Abstract) ->
    [erl_parse:normalise(Abstract)];
literal(_) ->
    [].

%% @private
forms(Mod) ->
    {ok, {Mod, [{abstract_code, {_, Forms}}]}} =
        beam_lib:chunks(beam(Mod), [abstract_code]),
    Forms.

%% @private
%% Found on the code path rather than through `code:which/1`, which answers
%% `cover_compiled` when the suite runs under cover — and it is the beam ON
%% DISK that still carries the `debug_info` this read needs.
beam(Mod) ->
    File = atom_to_list(Mod) ++ ".beam",
    Paths = [
        Path
     || Dir <- code:get_path(),
        Path <- [filename:join(Dir, File)],
        filelib:is_regular(Path)
    ],
    case Paths of
        [Path | _] -> Path;
        [] -> ct:fail({beam_not_found, Mod})
    end.

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
