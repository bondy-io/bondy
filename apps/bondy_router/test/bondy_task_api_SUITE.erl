%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% -----------------------------------------------------------------------------
%% The `bondy.task.*` read API, exercised through `bondy_wamp_api:handle_call/2`
%% rather than by calling `bondy_task_api` directly — a direct call would pass
%% with the dispatch clause unwired, which is the one thing no unit test can
%% check.
%%
%% Four properties:
%%
%%   * DISPATCH — both procedures resolve and answer.
%%   * AUTHORITY — a session in an ordinary realm is refused (D4), for both.
%%   * ENCODABILITY — the reply survives a real `json:encode`, which is the
%%     only thing that proves an agent can actually read it.
%%   * VOCABULARY — `catalogue` publishes the ORDERED `impact` and
%%     `blast_radius` vocabularies, not just the values today's rows use. An
%%     agent policy is a bound on `impact`, so a catalogue with no
%%     `destructive` row must still tell it that `destructive` exists and where
%%     it sits.
%% -----------------------------------------------------------------------------
-module(bondy_task_api_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, <<"com.example.task_api_suite">>).
-define(A_TASK, <<"bondy.router.bridge.stop">>).

all() ->
    [
        catalogue_lists_every_declared_task,
        catalogue_publishes_the_ordered_vocabularies,
        catalogue_publishes_the_out_of_scope_reasons,
        describe_finds_a_task,
        describe_of_an_uncatalogued_procedure_is_empty_not_an_error,
        both_procedures_require_the_master_realm,
        the_reply_encodes
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    R = bondy_realm:create(?REALM),
    ok = bondy_realm:disable_security(R),
    Config.

end_per_suite(Config) ->
    {save_config, Config}.

%% =============================================================================
%% CASES
%% =============================================================================

catalogue_lists_every_declared_task(_) ->
    #{<<"tasks">> := Tasks} = call(?MASTER_REALM_URI, catalogue),
    ?assertEqual(length(bondy_task_catalogue:list()), length(Tasks)),
    [Stop] = [T || T <- Tasks, maps:get(<<"id">>, T) == ?A_TASK],
    ?assertEqual(<<"disruptive">>, maps:get(<<"impact">>, Stop)),
    ?assertEqual(<<"cluster">>, maps:get(<<"blast_radius">>, Stop)),
    ?assertEqual(
        <<"bondy.router.bridge.start">>, maps:get(<<"reverses">>, Stop)
    ),
    %% Atoms render as strings and booleans stay booleans: an agent comparing
    %% `impact` against a policy string must not have to guess which it got.
    ?assertEqual(false, maps:get(<<"idempotent">>, Stop)).

%% The whole vocabulary, in order, independent of which rows exist. Without
%% this an agent bounding itself at "nothing above recoverable" cannot know
%% that `disruptive` and `destructive` are above it — or that they exist.
catalogue_publishes_the_ordered_vocabularies(_) ->
    #{<<"vocabularies">> := V} = call(?MASTER_REALM_URI, catalogue),
    ?assertEqual(
        [<<"benign">>, <<"recoverable">>, <<"disruptive">>, <<"destructive">>],
        maps:get(<<"impact">>, V)
    ),
    ?assertEqual(
        [<<"session">>, <<"realm">>, <<"node">>, <<"cluster">>],
        maps:get(<<"blast_radius">>, V)
    ),
    %% The property: a vocabulary is published in FULL, not derived from the
    %% values today's rows happen to use. `session` is the blast radius no
    %% task carries — every impact grade now has at least one row, so
    %% `destructive` no longer demonstrates it (it did until
    %% `bondy.cluster.leave` was catalogued).
    #{<<"tasks">> := Tasks} = call(?MASTER_REALM_URI, catalogue),
    ?assertEqual(
        [],
        [T || T <- Tasks, maps:get(<<"blast_radius">>, T) == <<"session">>],
        "no task is session-scoped; pick another unused grade for this check"
    ).

%% Coverage is partial on purpose, so the reply says which families were left
%% out and why. An agent that cannot find a task for a condition should be able
%% to tell "not sanctioned" from "nobody has written it down yet".
catalogue_publishes_the_out_of_scope_reasons(_) ->
    #{<<"out_of_scope">> := Out} = call(?MASTER_REALM_URI, catalogue),
    %% `realm` rather than `cluster`: the cluster family left this map when
    %% `bondy.cluster.leave` was catalogued, which is the transition the map
    %% exists to make visible.
    ?assert(maps:is_key(<<"realm">>, Out)),
    ?assert(is_binary(maps:get(<<"realm">>, Out))),
    ?assertNot(
        maps:is_key(<<"cluster">>, Out),
        "cluster carries a task now and must not also be excluded"
    ),
    ?assertEqual(
        map_size(bondy_task_catalogue:out_of_scope()), map_size(Out)
    ).

describe_finds_a_task(_) ->
    #{<<"tasks">> := [T]} = call(?MASTER_REALM_URI, describe, [?A_TASK]),
    ?assertEqual(?A_TASK, maps:get(<<"id">>, T)),
    %% `observe_with` renders as tagged references, the same shape
    %% `bondy.alarm.catalogue` uses, so one consumer parses both.
    ?assertEqual(
        [
            #{
                <<"kind">> => <<"procedure">>,
                <<"ref">> => <<"bondy.router.bridge.status">>
            }
        ],
        maps:get(<<"observe_with">>, T)
    ).

%% A miss is an empty list, NOT `no_such_procedure`: the procedure asked about
%% may exist perfectly well and simply not be a sanctioned task, and saying "no
%% such procedure" would be a different — and false — statement. It also keeps
%% a routine question off an agent's exception path.
describe_of_an_uncatalogued_procedure_is_empty_not_an_error(_) ->
    #{<<"tasks">> := Tasks} =
        call(?MASTER_REALM_URI, describe, [<<"bondy.registration.list">>]),
    ?assertEqual([], Tasks),
    #{<<"tasks">> := None} =
        call(?MASTER_REALM_URI, describe, [<<"not.a.procedure.at.all">>]),
    ?assertEqual([], None).

%% D4: both procedures refuse a session in an ordinary realm.
%%
%% The asymmetry this comment used to record is gone. Under
%% `do_validate_call_args/6` the first positional argument was read as a realm
%% URI, so `describe` — whose first argument is a TASK URI — was refused by the
%% realm COMPARISON rather than by the admin check, and swapping its validator
%% for the non-admin one failed nothing. Both procedures now use
%% `bondy_wamp_api_utils:admin_call_args/3`, where the master-realm check is
%% written as itself and does not depend on what the first argument happens to
%% be. Swapping either for `call_args/3` fails this case.
both_procedures_require_the_master_realm(_) ->
    _ = [
        ?assertMatch(
            #error{error_uri = ?WAMP_NOT_AUTHORIZED},
            call_error(?REALM, Proc, Args),
            Proc
        )
     || {Proc, Args} <- [{catalogue, []}, {describe, [?A_TASK]}]
    ],
    ok.

%% The end-to-end form of the contract: a reply an agent cannot decode is a
%% reply it cannot act on.
the_reply_encodes(_) ->
    Reply = call(?MASTER_REALM_URI, catalogue),
    ?assert(is_binary(iolist_to_binary(json:encode(Reply)))).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
uri(catalogue) -> ?BONDY_TASK_CATALOGUE;
uri(describe) -> ?BONDY_TASK_DESCRIBE.

%% @private
handle(RealmUri, Proc, Args) ->
    Ctxt = bondy_context:local_context(RealmUri),
    M = bondy_wamp_message:call(1, #{}, uri(Proc), Args),
    bondy_wamp_api:handle_call(M, Ctxt).

%% @private
call(RealmUri, Proc) ->
    call(RealmUri, Proc, []).

%% @private
call(RealmUri, Proc, Args) ->
    case handle(RealmUri, Proc, Args) of
        {reply, #result{args = [Reply]}} -> Reply;
        Other -> ct:fail({expected_result, Proc, Other})
    end.

%% @private
%% The unauthorized path THROWS the error rather than returning it, which is
%% how `bondy_wamp_api_utils:validate_admin_call_args/3` reports refusal.
call_error(RealmUri, Proc, Args) ->
    try handle(RealmUri, Proc, Args) of
        {reply, #error{} = E} -> E;
        Other -> ct:fail({expected_error, Proc, Other})
    catch
        error:#error{} = E -> E
    end.
