%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_address_test).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% ACCEPTED
%% =============================================================================

plain_address_test() ->
    ?assertEqual({ok, ~"user@example.com"}, v(~"user@example.com")).

dotted_local_part_test() ->
    ?assertEqual({ok, ~"first.last@example.com"}, v(~"first.last@example.com")).

atext_specials_are_legal_test() ->
    %% RFC 5322 permits these in an unquoted local part, and real providers
    %% issue addresses using them -- `+` tagging most obviously.
    [
        ?assertMatch({ok, _}, v(A))
     || A <- [
            ~"user+tag@example.com",
            ~"user_name@example.com",
            ~"user-name@example.com",
            ~"user'name@example.com",
            ~"a!#$%&'*+-/=?^_`{|}~@example.com"
        ]
    ].

subdomains_test() ->
    ?assertMatch({ok, _}, v(~"user@mail.corp.example.com")).

single_label_domain_test() ->
    %% Legal, and reachable on an internal network. A relay that does not want
    %% it can say so through allowed_from rather than through syntax.
    ?assertMatch({ok, _}, v(~"root@localhost")).

%% =============================================================================
%% REJECTED
%% =============================================================================

empty_test() ->
    ?assertEqual(error, v(~"")).

no_at_test() ->
    ?assertEqual(error, v(~"userexample.com")).

two_ats_test() ->
    ?assertEqual(error, v(~"user@example@com")).

empty_local_test() ->
    ?assertEqual(error, v(~"@example.com")).

empty_domain_test() ->
    ?assertEqual(error, v(~"user@")).

leading_dot_local_test() ->
    ?assertEqual(error, v(~".user@example.com")).

trailing_dot_local_test() ->
    ?assertEqual(error, v(~"user.@example.com")).

double_dot_test() ->
    ?assertEqual(error, v(~"user..name@example.com")).

domain_edges_test() ->
    [
        ?assertEqual(error, v(A))
     || A <- [
            ~"user@.example.com",
            ~"user@example.com.",
            ~"user@-example.com",
            ~"user@example.com-",
            ~"user@exam..ple.com"
        ]
    ].

space_test() ->
    ?assertEqual(error, v(~"user name@example.com")),
    ?assertEqual(error, v(~"user@exa mple.com")).

%% The whole point of validating before queueing: a newline in an address would
%% otherwise reach a header and let the caller write headers of their own.
control_characters_are_rejected_test() ->
    [
        ?assertEqual(error, v(A))
     || A <- [
            ~"user@example.com\r\nBcc: victim@evil.com",
            ~"user\r@example.com",
            ~"user\n@example.com",
            ~"user\0@example.com",
            ~"user\t@example.com"
        ]
    ].

display_name_form_is_rejected_test() ->
    %% Supported nowhere in v1: it is a second grammar to sanitise, and the
    %% relay's own `from` covers the case that actually wants a display name.
    ?assertEqual(error, v(~"Alice <alice@example.com>")),
    ?assertEqual(error, v(~"<alice@example.com>")).

quoted_local_part_is_rejected_test() ->
    ?assertEqual(error, v(~"\"user name\"@example.com")).

over_long_test() ->
    Local = binary:copy(~"a", 65),
    ?assertEqual(error, v(<<Local/binary, "@example.com">>)),

    Long = binary:copy(~"a", 250),
    ?assertEqual(error, v(<<"u@", Long/binary, ".com">>)).

non_binary_test() ->
    [?assertEqual(error, v(X)) || X <- ["list", undefined, 42, #{}]].

%% =============================================================================
%% LISTS
%% =============================================================================

validate_many_ok_test() ->
    ?assertEqual(
        {ok, [~"a@example.com", ~"b@example.com"]},
        bondy_mail_address:validate_many([~"a@example.com", ~"b@example.com"])
    ).

validate_many_names_the_offender_test() ->
    ?assertEqual(
        {error, {invalid_recipient, ~"nope"}},
        bondy_mail_address:validate_many([~"a@example.com", ~"nope"])
    ).

validate_many_empty_test() ->
    ?assertEqual({ok, []}, bondy_mail_address:validate_many([])).

%% =============================================================================
%% DOMAIN POLICY
%% =============================================================================

domain_test() ->
    ?assertEqual(~"example.com", bondy_mail_address:domain(~"u@example.com")).

any_allows_everything_test() ->
    ?assert(bondy_mail_address:is_domain_allowed(~"u@anywhere.test", any)).

%% The default. A relay whose owner has not said which domains it owns does not
%% let a caller pick one -- so a misconfiguration closes rather than opens.
empty_allows_nothing_test() ->
    ?assertNot(bondy_mail_address:is_domain_allowed(~"u@example.com", [])).

listed_domain_test() ->
    Allowed = [~"example.com", ~"mail.example.com"],
    ?assert(bondy_mail_address:is_domain_allowed(~"u@example.com", Allowed)),
    ?assert(
        bondy_mail_address:is_domain_allowed(~"u@mail.example.com", Allowed)
    ),
    ?assertNot(bondy_mail_address:is_domain_allowed(~"u@evil.com", Allowed)).

domain_match_is_case_insensitive_test() ->
    ?assert(
        bondy_mail_address:is_domain_allowed(~"u@EXAMPLE.com", [~"example.com"])
    ),
    ?assert(
        bondy_mail_address:is_domain_allowed(~"u@example.com", [~"Example.COM"])
    ).

%% A subdomain is not the parent domain. Allowing example.com must not admit
%% evil-example.com, nor sub.example.com unless it is listed too.
subdomain_is_not_the_parent_test() ->
    Allowed = [~"example.com"],
    ?assertNot(
        bondy_mail_address:is_domain_allowed(~"u@sub.example.com", Allowed)
    ),
    ?assertNot(
        bondy_mail_address:is_domain_allowed(~"u@evil-example.com", Allowed)
    ),
    ?assertNot(
        bondy_mail_address:is_domain_allowed(~"u@example.com.evil.com", Allowed)
    ).

%% =============================================================================
%% PRIVATE
%% =============================================================================

v(X) ->
    bondy_mail_address:validate(X).
