%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_error_wire_test).
-moduledoc """
Pins the parts of the error payload that clients depend on.

Bondy's error payload is standardised additively: every key a client could read
before keeps its value, and the new keys sit alongside. That promise is only
worth anything if it is checked, so the historical `code` values, the derived
HTTP statuses and the top-level context keys are all asserted here.

Also asserts that the `?WAMP_*` and `?BONDY_ERROR_*` macros agree with the
`bondy_error` catalogue. The catalogue owns the URI strings so that every app
can read them without depending on `bondy_router`; these assertions are what
stop the two from drifting.
""".

-include_lib("eunit/include/eunit.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_uris.hrl").
-include("http_api.hrl").

%% =============================================================================
%% LEGACY PAYLOAD
%% =============================================================================

%% The `code' values Bondy has emitted historically. A client branching on any
%% of these must keep working.
legacy_codes_test() ->
    Expected = [
        {{missing_required_value, ~"k"}, ~"missing_required_value"},
        {{invalid_value, ~"k", 1}, ~"invalid_value"},
        {{invalid_value, ~"k", 1, ~"why"}, ~"invalid_value"},
        {{property_range_limit, ~"k", 3}, ~"property_range_limit"},
        {{inconsistency_error, [~"a", ~"b"]}, ~"invalid_argument"},
        {{no_such_realm, ~"com.a"}, ~"wamp.error.no_such_realm"},
        {{no_such_user, ~"alice"}, ~"wamp.error.no_such_principal"},
        {{badarg, {decoding, json}}, ~"invalid_data"},
        {{badarg, {decoding, msgpack}}, ~"invalid_data"},
        {{badarg, {body_max_bytes_exceeded, 1}}, ~"body_max_bytes_exceeded"},
        {{badarg, ~"nope"}, ~"invalid_argument"},
        {{badheader, ~"x-foo", ~"bad"}, ~"invalid_argument"},
        {unavailable, ~"unavailable"},
        {too_many_results, ~"too_many_results"},
        {temporarily_unavailable, ~"temporarily_unavailable"},
        {unsupported_token_type, ~"unsupported_token_type"},
        {oauth2_invalid_request, ~"invalid_request"},
        {oauth2_invalid_client, ~"invalid_client"},
        {oauth2_invalid_grant, ~"invalid_grant"},
        {oauth2_unauthorized_client, ~"unauthorized_client"},
        {oauth2_unsupported_grant_type, ~"unsupported_grant_type"},
        {oauth2_invalid_scope, ~"invalid_scope"},
        {invalid_scheme, ~"invalid_client"}
    ],
    [
        ?assertEqual(
            {Term, Code},
            {Term, maps:get(~"code", bondy_error:to_map(bondy_error:from_term(Term)))}
        )
     || {Term, Code} <- Expected
    ].

%% The status codes the payload used to carry inline. They now come from the
%% shared table, and must still resolve to the same values.
legacy_status_codes_test() ->
    Expected = [
        {oauth2_invalid_client, ?HTTP_UNAUTHORIZED},
        {invalid_scheme, ?HTTP_UNAUTHORIZED},
        {oauth2_invalid_request, ?HTTP_BAD_REQUEST},
        {oauth2_invalid_grant, ?HTTP_BAD_REQUEST},
        {oauth2_unauthorized_client, ?HTTP_BAD_REQUEST},
        {oauth2_unsupported_grant_type, ?HTTP_BAD_REQUEST},
        {oauth2_invalid_scope, ?HTTP_BAD_REQUEST},
        {unsupported_token_type, ?HTTP_SERVICE_UNAVAILABLE},
        {temporarily_unavailable, ?HTTP_SERVICE_UNAVAILABLE},
        {{badarg, {decoding, json}}, ?HTTP_BAD_REQUEST},
        {{badarg, {body_max_bytes_exceeded, 1}}, ?HTTP_BAD_REQUEST}
    ],
    [
        ?assertEqual(
            {Term, Status},
            {Term, bondy_http_utils:http_status(bondy_error:from_term(Term))}
        )
     || {Term, Status} <- Expected
    ].

%% These used to carry no inline status and fell back to a caller-supplied
%% default. Their derived status is pinned so that removing the inline key did
%% not silently change what a client sees.
derived_status_for_previously_defaulted_errors_test() ->
    Expected = [
        {{no_such_realm, ~"com.a"}, ?HTTP_BAD_GATEWAY},
        {{invalid_value, ~"k", 1}, ?HTTP_BAD_REQUEST},
        {unavailable, ?HTTP_SERVICE_UNAVAILABLE},
        {too_many_results, ?HTTP_BAD_REQUEST}
    ],
    [
        ?assertEqual(
            {Term, Status},
            {Term, bondy_http_utils:http_status(bondy_error:from_term(Term))}
        )
     || {Term, Status} <- Expected
    ].

%% Context has always been readable at the top level of the payload, so it stays
%% there even though it now also appears under `details'.
context_keys_stay_at_the_top_level_test() ->
    Map = bondy_error:to_map(bondy_error:from_term({invalid_value, ~"k", ~"v"})),
    ?assertEqual(~"k", maps:get(~"key", Map)),
    ?assertEqual(~"v", maps:get(~"value", Map)),
    ?assertEqual(~"k", maps:get(~"key", maps:get(~"details", Map))),

    Limit = bondy_error:to_map(bondy_error:from_term({property_range_limit, ~"k", 3})),
    ?assertEqual(3, maps:get(~"limit", Limit)),

    Keys = bondy_error:to_map(bondy_error:from_term({inconsistency_error, [~"a", ~"b"]})),
    ?assertEqual([~"a", ~"b"], maps:get(~"keys", Keys)).

legacy_map_carries_the_documented_prose_test() ->
    Map = bondy_error:to_map(bondy_error:from_term({missing_required_value, ~"match"})),
    ?assertEqual(
        ~"The operation failed due to a missing required value.",
        maps:get(~"message", Map)
    ),
    ?assertEqual(~"A value for 'match' is required.", maps:get(~"description", Map)).

%% A `code' used to be an atom for some reasons and a binary for others. It is
%% always a binary now, which is invisible in JSON but stops a header being
%% built by binary concatenation from crashing.
code_is_always_a_binary_test() ->
    [
        ?assert(is_binary(maps:get(~"code", bondy_error:to_map(bondy_error:from_term(Term)))))
     || Term <- [
            {missing_required_value, ~"k"},
            {invalid_value, ~"k", 1},
            unavailable,
            too_many_results,
            {badmatch, self()},
            oauth2_invalid_client
        ]
    ].

%% =============================================================================
%% URI RESOLUTION
%% =============================================================================

%% Reproduces what the old code_to_uri/1 returned for each shape of input.
code_to_uri_test() ->
    ?assertEqual(?WAMP_INVALID_ARGUMENT, uri_of(invalid_argument)),
    ?assertEqual(
        ~"wamp.error.no_such_realm",
        uri_of(~"wamp.error.no_such_realm")
    ),
    ?assertEqual(
        ~"bondy.error.already_exists",
        uri_of(~"bondy.error.already_exists")
    ),
    ?assertEqual(
        ~"com.example.error.custom",
        uri_of(~"com.example.error.custom")
    ),
    ?assertEqual(
        ~"bondy.error.something_new",
        uri_of(~"something_new")
    ).

%% URI resolution used to have no clause for tuples, pids or integers, yet was
%% called with whatever a catch handler produced.
code_to_uri_is_total_test() ->
    [
        ?assert(is_binary(uri_of(Term)))
     || Term <- [{a, b}, self(), make_ref(), 42, [1, 2 | 3], #{}, <<255>>]
    ].

%% =============================================================================
%% CATALOGUE AND MACROS AGREE
%% =============================================================================

wamp_uri_macros_are_catalogued_test() ->
    Expected = [
        {?WAMP_UNAVAILABLE, service_unavailable},
        {?WAMP_AUTHENTICATION_FAILED, authentication_failed},
        {?WAMP_AUTHORIZATION_FAILED, authorization_failed},
        {?WAMP_CANCELLED, canceled},
        {?WAMP_INVALID_ARGUMENT, invalid_argument},
        {?WAMP_INVALID_PAYLOAD, invalid_payload},
        {?WAMP_INVALID_URI, invalid_uri},
        {?WAMP_NOT_AUTHORIZED, not_authorized},
        {?WAMP_NOT_AUTH_METHOD, not_auth_method},
        {?WAMP_NO_ELIGIBLE_CALLE, no_eligible_callee},
        {?WAMP_NO_AVAILABLE_CALLEE, no_available_callee},
        {?WAMP_NO_SUCH_PRINCIPAL, no_such_principal},
        {?WAMP_NO_SUCH_PROCEDURE, no_such_procedure},
        {?WAMP_NO_SUCH_REALM, no_such_realm},
        {?WAMP_NO_SUCH_REGISTRATION, no_such_registration},
        {?WAMP_NO_SUCH_ROLE, no_such_role},
        {?WAMP_NO_SUCH_SESSION, no_such_session},
        {?WAMP_NO_SUCH_SUBSCRIPTION, no_such_subscription},
        {?WAMP_OPTION_NOT_ALLOWED, option_not_allowed},
        {?WAMP_PAYLOAD_SIZE_EXCEEDED, payload_size_exceeded},
        {?WAMP_PROCEDURE_ALREADY_EXISTS, procedure_already_exists},
        {?WAMP_PROTOCOL_VIOLATION, protocol_violation},
        {?WAMP_SYSTEM_SHUTDOWN, system_shutdown},
        {?WAMP_ERROR_TIMEOUT, timeout},
        {?WAMP_FEATURE_NOT_SUPPORTED, feature_not_supported},
        {?WAMP_DISCLOSE_ME_NOT_ALLOWED, disclose_me_not_allowed}
    ],
    [?assertEqual({Uri, Uri}, {Uri, bondy_error:uri(Type)}) || {Uri, Type} <- Expected].

bondy_uri_macros_are_catalogued_test() ->
    Expected = [
        {?BONDY_ERROR_ALREADY_EXISTS, already_exists},
        {?BONDY_ERROR_BAD_GATEWAY, bad_gateway},
        {?BONDY_ERROR_TOO_MANY_REQUESTS, too_many_requests},
        {?BONDY_ERROR_INTERNAL, internal_error},
        {?BONDY_ERROR_NOT_FOUND, not_found},
        {?BONDY_ERROR_NOT_IN_SESSION, not_in_session},
        {?BONDY_ERROR_INCONSISTENCY_ERROR, inconsistency_error},
        {?BONDY_ERROR_HTTP_API_GATEWAY_INVALID_EXPR, invalid_expression}
    ],
    [?assertEqual({Uri, Uri}, {Uri, bondy_error:uri(Type)}) || {Uri, Type} <- Expected].

%% ?BONDY_ERROR_TIMEOUT is bondy.error.timeout, whereas the catalogued `timeout'
%% type carries the WAMP URI. Both are reachable, so both must have a status.
bondy_error_timeout_macro_has_a_status_test() ->
    ?assertEqual(
        ?HTTP_GATEWAY_TIMEOUT, bondy_http_utils:http_status(?BONDY_ERROR_TIMEOUT)
    ),
    ?assertEqual(
        ?HTTP_GATEWAY_TIMEOUT, bondy_http_utils:http_status(?WAMP_ERROR_TIMEOUT)
    ).

%% =============================================================================
%% HTTP STATUS
%% =============================================================================

%% The two tables this replaced disagreed on exactly these rows, and both
%% carried a %% REVIEW comment. Resolved on WAMP semantics: not_authorized is
%% the peer being refused, authorization_failed is the router being unable to
%% decide.
reconciled_status_rows_test() ->
    ?assertEqual(?HTTP_FORBIDDEN, bondy_http_utils:http_status(?WAMP_NOT_AUTHORIZED)),
    ?assertEqual(
        ?HTTP_INTERNAL_SERVER_ERROR,
        bondy_http_utils:http_status(?WAMP_AUTHORIZATION_FAILED)
    ).

http_status_accepts_uri_type_and_error_test() ->
    ?assertEqual(?HTTP_NOT_FOUND, bondy_http_utils:http_status(?BONDY_ERROR_NOT_FOUND)),
    ?assertEqual(?HTTP_NOT_FOUND, bondy_http_utils:http_status(not_found)),
    ?assertEqual(
        ?HTTP_NOT_FOUND,
        bondy_http_utils:http_status(bondy_error:new(not_found))
    ).

http_status_defaults_to_server_error_test() ->
    ?assertEqual(
        ?HTTP_INTERNAL_SERVER_ERROR,
        bondy_http_utils:http_status(~"com.example.error.unheard_of")
    ).

%% Every status must be a plausible HTTP error code; a typo here would send a
%% success status on an error path.
every_catalogued_status_is_an_error_test() ->
    Bad = [
        {T, bondy_http_utils:http_status(T)}
     || T <- bondy_error:types(),
        bondy_http_utils:http_status(T) < 400 orelse
            bondy_http_utils:http_status(T) > 599
    ],
    ?assertEqual([], Bad).

default_status_codes_is_keyed_by_uri_test() ->
    Map = bondy_http_utils:default_status_codes(),
    ?assert(map_size(Map) > 0),
    ?assert(lists:all(fun is_binary/1, maps:keys(Map))),
    ?assert(lists:all(fun is_integer/1, maps:values(Map))),
    ?assertEqual(?HTTP_NOT_FOUND, maps:get(?BONDY_ERROR_NOT_FOUND, Map)).

%% =============================================================================
%% HELPERS
%% =============================================================================

uri_of(Term) ->
    maps:get(uri, bondy_error:from_term(Term)).
