%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_header_test).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% ACCEPTED
%% =============================================================================

empty_test() ->
    ?assertEqual({ok, []}, v(#{})),
    ?assertEqual({ok, []}, v(undefined)).

custom_header_test() ->
    ?assertEqual(
        {ok, [{~"X-Campaign", ~"spring-2026"}]},
        v(#{~"X-Campaign" => ~"spring-2026"})
    ).

%% Sorted, so a message built twice from one request is byte-identical.
ordering_is_stable_test() ->
    Map = #{~"X-C" => ~"3", ~"X-A" => ~"1", ~"X-B" => ~"2"},
    ?assertEqual(
        {ok, [{~"X-A", ~"1"}, {~"X-B", ~"2"}, {~"X-C", ~"3"}]},
        v(Map)
    ).

empty_value_is_allowed_test() ->
    ?assertEqual({ok, [{~"X-Empty", ~""}]}, v(#{~"X-Empty" => ~""})).

%% =============================================================================
%% RESERVED
%% =============================================================================

reserved_headers_are_refused_test() ->
    [
        ?assertEqual({error, {reserved_header, N}}, v(#{N => ~"x"}))
     || N <- [~"To", ~"From", ~"Subject", ~"Cc", ~"Reply-To"]
    ].

%% Header names are case-insensitive, so the check must be too -- otherwise
%% `bCc` walks straight past a list containing `bcc`.
reserved_check_is_case_insensitive_test() ->
    [
        ?assertMatch({error, {reserved_header, _}}, v(#{N => ~"x"}))
     || N <- [~"to", ~"TO", ~"tO", ~"bCc", ~"FROM"]
    ].

%% Bcc is refused because it is an envelope concern: blind recipients are
%% delivered to without appearing in the message, and the header would publish
%% exactly what it exists to hide.
bcc_header_is_refused_test() ->
    ?assertMatch({error, {reserved_header, _}}, v(#{~"Bcc" => ~"x@y.com"})).

%% A caller asserting an authentication verdict is claiming a check that never
%% ran, and receiving infrastructure may believe it.
authentication_headers_are_refused_test() ->
    [
        ?assertMatch({error, {reserved_header, _}}, v(#{N => ~"pass"}))
     || N <- [
            ~"DKIM-Signature",
            ~"Authentication-Results",
            ~"ARC-Seal",
            ~"Received",
            ~"Return-Path"
        ]
    ].

%% =============================================================================
%% INJECTION
%% =============================================================================

crlf_in_value_test() ->
    ?assertEqual(
        {error, {header_injection, ~"X-Test"}},
        v(#{~"X-Test" => ~"ok\r\nBcc: victim@evil.com"})
    ).

bare_cr_and_lf_test() ->
    ?assertMatch({error, {header_injection, _}}, v(#{~"X" => ~"a\rb"})),
    ?assertMatch({error, {header_injection, _}}, v(#{~"X" => ~"a\nb"})).

crlf_in_name_test() ->
    ?assertMatch({error, {header_injection, _}}, v(#{~"X\r\nBcc" => ~"v"})).

nul_and_other_controls_test() ->
    [
        ?assertMatch({error, {header_injection, _}}, v(#{~"X" => V}))
     || V <- [~"a\0b", ~"a\vb", ~"a\fb", ~"a\bb"]
    ].

%% Injection is reported as injection even when the value is also too long, so
%% the reason a caller is given points at the real problem.
injection_wins_over_length_test() ->
    Long = binary:copy(~"a", 2000),
    ?assertMatch(
        {error, {header_injection, _}},
        v(#{~"X" => <<Long/binary, "\r\nBcc: v@e.com">>})
    ).

%% =============================================================================
%% SHAPE
%% =============================================================================

empty_name_test() ->
    ?assertMatch({error, {invalid_header, _}}, v(#{~"" => ~"v"})).

colon_in_name_test() ->
    %% A colon separates a name from its value; one inside a name would split
    %% the header somewhere the caller did not intend.
    ?assertMatch({error, {invalid_header, _}}, v(#{~"X:Y" => ~"v"})).

space_in_name_test() ->
    ?assertMatch({error, {invalid_header, _}}, v(#{~"X Y" => ~"v"})).

over_long_test() ->
    ?assertMatch(
        {error, {invalid_header, _}},
        v(#{binary:copy(~"a", 100) => ~"v"})
    ),
    ?assertMatch(
        {error, {invalid_header, _}},
        v(#{~"X" => binary:copy(~"a", 1500)})
    ).

non_binary_test() ->
    ?assertMatch({error, {invalid_header, _}}, v(#{x => ~"v"})),
    ?assertMatch({error, {invalid_header, _}}, v(#{~"X" => 42})),
    ?assertMatch({error, {invalid_header, _}}, v(not_a_map)).

%% =============================================================================
%% PRIVATE
%% =============================================================================

v(X) ->
    bondy_mail_header:validate(X).
