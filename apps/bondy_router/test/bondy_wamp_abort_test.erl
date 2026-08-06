%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_abort_test).
-moduledoc """
Pins the session-establishment `ABORT` vocabulary.

Two things matter here and neither is visible from reading a diff:

1. **No user-enumeration oracle.** Every pre-authentication credential or
   identity failure - unknown user, disabled user, missing or bad signature,
   wrong password - must produce a byte-identical `ABORT`. A distinct reason
   URI, message or even detail key would let a client distinguish "no such
   user" from "wrong password" (CWE-204).

2. **The reason URI is part of the wire contract.** Each abort reason has
   always mapped to a particular URI and clients branch on it, so the mapping is
   asserted rather than left to the catalogue.
""".

-include_lib("eunit/include/eunit.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_uris.hrl").

%% =============================================================================
%% FIXTURE
%% =============================================================================

%% abort_message/1 validates the reason URI, which reads the wamp app's
%% uri_strictness setting, so the application has to be started first.
abort_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        ?_test(pre_auth_failures_are_indistinguishable()),
        ?_test(pre_auth_failure_does_not_echo_the_authid()),
        ?_test(abort_reason_uris()),
        ?_test(abort_details_carry_a_message()),
        ?_test(abort_nature_distinguishes_retryable()),
        ?_test(abort_details_carry_the_uri()),
        ?_test(abort_message_is_total()),
        ?_test(unknown_reason_is_not_echoed())
    ]}.

setup() ->
    {ok, Started} = application:ensure_all_started(bondy_wamp),
    Started.

cleanup(Started) ->
    [application:stop(A) || A <- lists:reverse(Started)],
    ok.

%% =============================================================================
%% NO USER-ENUMERATION ORACLE
%% =============================================================================

%% Every one of these must be indistinguishable from the others.
pre_auth_failures_are_indistinguishable() ->
    Reasons = [
        {no_such_user, ~"alice"},
        {authentication_failed, {no_such_user, ~"alice"}},
        {authentication_failed, user_disabled},
        {authentication_failed, missing_signature},
        {authentication_failed, bad_signature},
        {authentication_failed, bad_password},
        {authentication_failed, some_reason_we_have_not_thought_of}
    ],
    [First | Rest] = [bondy_wamp_protocol:abort_message(R) || R <- Reasons],
    [?assertEqual(First, Other) || Other <- Rest].

%% The identity being probed must not survive into the reply, in any field.
pre_auth_failure_does_not_echo_the_authid() ->
    #abort{details = Details} = bondy_wamp_protocol:abort_message(
        {no_such_user, ~"alice"}
    ),
    ?assertEqual(
        nomatch, binary:match(iolist_to_binary(io_lib:format("~p", [Details])), ~"alice")
    ).

%% =============================================================================
%% REASON URI MAPPING
%% =============================================================================

abort_reason_uris() ->
    Expected = [
        {internal_error, ?BONDY_ERROR_INTERNAL},
        {decoding_error, ?WAMP_PROTOCOL_VIOLATION},
        {{invalid_message, x}, ?WAMP_PROTOCOL_VIOLATION},
        {{protocol_violation, ~"nope"}, ?WAMP_PROTOCOL_VIOLATION},
        {{unsupported_encoding, json}, ?WAMP_PROTOCOL_VIOLATION},
        {{invalid_options, missing_client_role}, ?WAMP_PROTOCOL_VIOLATION},
        {{missing_param, ~"authid"}, ?WAMP_PROTOCOL_VIOLATION},
        {{no_authmethod, []}, ?WAMP_NOT_AUTH_METHOD},
        {{no_authmethod, [~"ticket"]}, ?WAMP_NOT_AUTH_METHOD},
        {{unsupported_authmethod, ~"ticket"}, ?WAMP_NOT_AUTH_METHOD},
        {{invalid_authmethod, ~"ticket"}, ?WAMP_NOT_AUTH_METHOD},
        {connections_not_allowed, ?WAMP_AUTHENTICATION_FAILED},
        {{authentication_failed, invalid_authmethod}, ?WAMP_AUTHENTICATION_FAILED},
        {{authentication_failed, invalid_scheme}, ?WAMP_AUTHENTICATION_FAILED},
        {{authentication_failed, oauth2_invalid_grant}, ?WAMP_AUTHENTICATION_FAILED},
        {overload, ?WAMP_UNAVAILABLE},
        {{rate_limited, hello}, ?WAMP_UNAVAILABLE},
        {{authentication_failed, temporarily_unavailable}, ?WAMP_UNAVAILABLE},
        {no_such_realm, ?WAMP_NO_SUCH_REALM},
        {{no_such_realm, ~"com.a"}, ?WAMP_NO_SUCH_REALM},
        {{authentication_failed, {no_such_realm, ~"com.a"}}, ?WAMP_NO_SUCH_REALM},
        {{no_such_groups, [~"g1"]}, ?WAMP_NO_SUCH_ROLE},
        {{authentication_failed, {no_such_groups, [~"g1"]}}, ?WAMP_NO_SUCH_ROLE}
    ],
    [
        ?assertEqual(
            {Reason, Uri},
            {Reason, (bondy_wamp_protocol:abort_message(Reason))#abort.reason_uri}
        )
     || {Reason, Uri} <- Expected
    ].

%% =============================================================================
%% PAYLOAD
%% =============================================================================

%% `message' has always been readable from the abort details and is what most
%% clients surface to a human.
abort_details_carry_a_message() ->
    #abort{details = Details} = bondy_wamp_protocol:abort_message(overload),
    Message = maps:get(~"message", Details),
    ?assert(is_binary(Message)),
    ?assertNotEqual(~"", Message).

%% The point of routing aborts through the error model: a client can tell a
%% refusal it should retry from one it should not, without parsing prose.
abort_nature_distinguishes_retryable() ->
    Transient = [overload, {rate_limited, hello}, {authentication_failed, temporarily_unavailable}],
    Permanent = [{authentication_failed, invalid_scheme}, {no_such_realm, ~"com.a"}],

    [
        ?assertEqual({R, ~"transient"}, {R, nature(R)})
     || R <- Transient
    ],
    [
        ?assertEqual({R, ~"permanent"}, {R, nature(R)})
     || R <- Permanent
    ].

abort_details_carry_the_uri() ->
    #abort{details = Details, reason_uri = Uri} =
        bondy_wamp_protocol:abort_message(overload),
    ?assertEqual(Uri, maps:get(~"uri", Details)).

%% =============================================================================
%% TOTALITY
%% =============================================================================

%% abort_message/1 is reached from every protocol path. An unmatched reason used
%% to raise function_clause, which would crash the connection handler instead of
%% closing the connection with a valid ABORT.
abort_message_is_total() ->
    Reasons = [
        {some_tag, some_atom},
        {some_tag, ~"a binary"},
        totally_unknown,
        {a, b, c},
        42,
        self(),
        [1, 2 | 3],
        #{}
    ],
    [
        begin
            M = bondy_wamp_protocol:abort_message(R),
            ?assertMatch(#abort{}, M),
            ?assert(is_binary(M#abort.reason_uri))
        end
     || R <- Reasons
    ].

%% An unknown reason must not put its term on the wire.
unknown_reason_is_not_echoed() ->
    #abort{details = Details} = bondy_wamp_protocol:abort_message(
        {unhandled, ~"a secret value"}
    ),
    ?assertEqual(
        nomatch,
        binary:match(
            iolist_to_binary(io_lib:format("~p", [Details])), ~"a secret value"
        )
    ).

%% =============================================================================
%% HELPERS
%% =============================================================================

nature(Reason) ->
    #abort{details = Details} = bondy_wamp_protocol:abort_message(Reason),
    maps:get(~"nature", Details).
