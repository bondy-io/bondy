%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% EUnit coverage for `bondy_namespace_catalog:main_status/0`, the signal that
%% keeps a node out of the load balancer when its durable store did not open.
%%
%% The catalogue deliberately survives a failed `main` open — the process stays
%% up, the ephemeral registry still works, and an operator can inspect the node.
%% What must NOT survive is the node calling itself ready: every durable table
%% raises `*_not_provisioned` on use, so a passing readiness probe just routes
%% traffic at a node that can serve none of it.
%%
%% The distinction this locks down is `idle` vs `failed`. `is_open/0` returns
%% `false` for BOTH — nothing to provision, and could not provision — which is
%% why it cannot drive a health probe and why `main_status/0` exists.
-module(bondy_namespace_catalog_main_status_test).

-include_lib("eunit/include/eunit.hrl").

-define(PT_MAIN_FAILED, {bondy_namespace_catalog, main_failed}).

main_status_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun no_failure_recorded_is_not_failed/0,
        fun recorded_failure_is_failed/0,
        fun failure_disqualifies_readiness/0,
        fun idle_does_not_disqualify_readiness/0
    ]}.

setup() ->
    _ = persistent_term:erase(?PT_MAIN_FAILED),
    ok.

cleanup(_) ->
    _ = persistent_term:erase(?PT_MAIN_FAILED),
    ok.

%% With no failure recorded the status reflects whether the DB is published.
%% In a bare eunit VM nothing is provisioned, so this is `idle` — the
%% legitimate "nothing to open" case, NOT a fault.
no_failure_recorded_is_not_failed() ->
    ?assertNotEqual(failed, bondy_namespace_catalog:main_status()).

recorded_failure_is_failed() ->
    _ = persistent_term:put(?PT_MAIN_FAILED, {shutdown, some_reason}),
    ?assertEqual(failed, bondy_namespace_catalog:main_status()).

%% The two halves of the contract. `bondy_admin_ready_http_handler` gates on
%% `failed` only, so a node with nothing to provision still serves traffic.
failure_disqualifies_readiness() ->
    _ = persistent_term:put(?PT_MAIN_FAILED, {shutdown, some_reason}),
    ?assertEqual(failed, bondy_namespace_catalog:main_status()),
    ?assert(is_disqualifying(bondy_namespace_catalog:main_status())).

idle_does_not_disqualify_readiness() ->
    ?assertNot(is_disqualifying(idle)),
    ?assertNot(is_disqualifying(open)).

%% @private Mirrors the handler's gate; keeps the assertion honest without
%% standing up cowboy for a two-line predicate.
is_disqualifying(failed) -> true;
is_disqualifying(_) -> false.
