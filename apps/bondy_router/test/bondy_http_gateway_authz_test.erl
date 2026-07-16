%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_gateway_authz_test).
-moduledoc """
WP-L / G-1 — the API gateway `is_authorized/3` per-scheme fail-closed logic.

Only an endpoint declaring an EMPTY security map is served anonymously; every
declared-but-unenforced scheme (`basic`, `oidc`, `api_key`) and any unknown
scheme must fail closed instead of falling through to anonymous access.
""".

-include_lib("eunit/include/eunit.hrl").

-define(H, bondy_http_gateway_rest_handler).

%% The clauses under test only pattern-match on `St.security`; the Req is passed
%% through / logged, never inspected — a stub suffices.
ia(Security) ->
    ?H:is_authorized(<<"GET">>, #{stub_req => true}, #{security => Security}).

basic_fails_closed_test() ->
    ?assertMatch({false, _, _}, ia(#{<<"type">> => <<"basic">>})).

oidc_fails_closed_test() ->
    ?assertMatch({false, _, _}, ia(#{<<"type">> => <<"oidc">>})).

api_key_fails_closed_test() ->
    ?assertMatch({false, _, _}, ia(#{<<"type">> => <<"api_key">>})).

unknown_scheme_fails_closed_test() ->
    ?assertMatch({false, _, _}, ia(#{<<"type">> => <<"totally_new_scheme">>})).

empty_security_is_anonymous_test() ->
    %% The only served-without-auth case: an explicitly empty security map.
    ?assertMatch({true, _, #{is_anonymous := true}}, ia(#{})).
