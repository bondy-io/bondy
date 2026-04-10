%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oidc_cookie_SUITE).
-moduledoc """
Unit tests for bondy_oidc_handler cookie options.

Tests the cookie_opts/6 and same_site_atom/1 helpers to ensure that
cookie_same_site and cookie_domain config values are correctly translated
into Cowboy cookie options. Uses the test profile's export_all to call
private functions directly — no Bondy runtime needed.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([nowarn_export_all, export_all]).


all() ->
    [
        %% same_site_atom/1
        same_site_atom_binary_lax,
        same_site_atom_binary_strict,
        same_site_atom_binary_none,
        same_site_atom_atom_lax,
        same_site_atom_atom_strict,
        same_site_atom_atom_none,

        %% cookie_opts/6
        cookie_opts_default_lax,
        cookie_opts_none,
        cookie_opts_strict,
        cookie_opts_with_domain,
        cookie_opts_without_domain,
        cookie_opts_http_only_true,
        cookie_opts_http_only_false,

        %% set_resp_cookie integration (via meck)
        set_ticket_cookie_same_site_none,
        set_ticket_cookie_same_site_lax,
        set_csrf_cookie_same_site_none,
        clear_ticket_cookie_same_site_none,
        clear_csrf_cookie_same_site_none
    ].


init_per_suite(Config) ->
    Config.


end_per_suite(_Config) ->
    ok.



%% =============================================================================
%% same_site_atom/1
%% =============================================================================



same_site_atom_binary_lax(_Config) ->
    ?assertEqual(lax, bondy_oidc_handler:same_site_atom(<<"lax">>)).


same_site_atom_binary_strict(_Config) ->
    ?assertEqual(strict, bondy_oidc_handler:same_site_atom(<<"strict">>)).


same_site_atom_binary_none(_Config) ->
    ?assertEqual(none, bondy_oidc_handler:same_site_atom(<<"none">>)).


same_site_atom_atom_lax(_Config) ->
    ?assertEqual(lax, bondy_oidc_handler:same_site_atom(lax)).


same_site_atom_atom_strict(_Config) ->
    ?assertEqual(strict, bondy_oidc_handler:same_site_atom(strict)).


same_site_atom_atom_none(_Config) ->
    ?assertEqual(none, bondy_oidc_handler:same_site_atom(none)).



%% =============================================================================
%% cookie_opts/6
%% =============================================================================



cookie_opts_default_lax(_Config) ->
    Opts = bondy_oidc_handler:cookie_opts(
        <<>>, 3600, true, true, undefined, lax
    ),
    ?assertEqual(lax, maps:get(same_site, Opts)),
    ?assertNot(maps:is_key(domain, Opts)).


cookie_opts_none(_Config) ->
    Opts = bondy_oidc_handler:cookie_opts(
        <<>>, 3600, true, true, undefined, none
    ),
    ?assertEqual(none, maps:get(same_site, Opts)).


cookie_opts_strict(_Config) ->
    Opts = bondy_oidc_handler:cookie_opts(
        <<>>, 3600, true, true, undefined, strict
    ),
    ?assertEqual(strict, maps:get(same_site, Opts)).


cookie_opts_with_domain(_Config) ->
    Opts = bondy_oidc_handler:cookie_opts(
        <<>>, 3600, true, true, <<"example.com">>, lax
    ),
    ?assertEqual(<<"example.com">>, maps:get(domain, Opts)),
    ?assertEqual(lax, maps:get(same_site, Opts)).


cookie_opts_without_domain(_Config) ->
    Opts = bondy_oidc_handler:cookie_opts(
        <<>>, 3600, true, true, undefined, none
    ),
    ?assertNot(maps:is_key(domain, Opts)).


cookie_opts_http_only_true(_Config) ->
    Opts = bondy_oidc_handler:cookie_opts(
        <<>>, 3600, true, true, undefined, lax
    ),
    ?assert(maps:get(http_only, Opts)).


cookie_opts_http_only_false(_Config) ->
    Opts = bondy_oidc_handler:cookie_opts(
        <<>>, 3600, true, false, undefined, lax
    ),
    ?assertNot(maps:get(http_only, Opts)).



%% =============================================================================
%% set/clear cookie integration via meck
%%
%% Mock cowboy_req:set_resp_cookie/4 and verify the SameSite option is passed
%% through correctly by the set_*/clear_* wrappers.
%% =============================================================================



set_ticket_cookie_same_site_none(_Config) ->
    Opts = capture_set_resp_cookie(fun() ->
        bondy_oidc_handler:set_ticket_cookie(
            fake_req(), <<"com.example">>, <<"jwt">>,
            <<>>, 3600, true, <<"example.com">>, none
        )
    end),
    ?assertEqual(none, maps:get(same_site, Opts)),
    ?assertEqual(<<"example.com">>, maps:get(domain, Opts)),
    ?assert(maps:get(http_only, Opts)).


set_ticket_cookie_same_site_lax(_Config) ->
    Opts = capture_set_resp_cookie(fun() ->
        bondy_oidc_handler:set_ticket_cookie(
            fake_req(), <<"com.example">>, <<"jwt">>,
            <<>>, 3600, true, undefined, lax
        )
    end),
    ?assertEqual(lax, maps:get(same_site, Opts)),
    ?assertNot(maps:is_key(domain, Opts)).


set_csrf_cookie_same_site_none(_Config) ->
    Opts = capture_set_resp_cookie(fun() ->
        bondy_oidc_handler:set_csrf_cookie(
            fake_req(), <<"com.example">>, <<"csrf-tok">>,
            <<>>, 3600, true, <<"example.com">>, none
        )
    end),
    ?assertEqual(none, maps:get(same_site, Opts)),
    ?assertNot(maps:get(http_only, Opts)).


clear_ticket_cookie_same_site_none(_Config) ->
    Opts = capture_set_resp_cookie(fun() ->
        bondy_oidc_handler:clear_ticket_cookie(
            fake_req(), <<"com.example">>,
            <<>>, true, <<"example.com">>, none
        )
    end),
    ?assertEqual(none, maps:get(same_site, Opts)),
    ?assertEqual(0, maps:get(max_age, Opts)).


clear_csrf_cookie_same_site_none(_Config) ->
    Opts = capture_set_resp_cookie(fun() ->
        bondy_oidc_handler:clear_csrf_cookie(
            fake_req(), <<"com.example">>,
            <<>>, true, <<"example.com">>, none
        )
    end),
    ?assertEqual(none, maps:get(same_site, Opts)),
    ?assertEqual(0, maps:get(max_age, Opts)).



%% =============================================================================
%% HELPERS
%% =============================================================================



fake_req() ->
    #{}.


%% @doc Mocks cowboy_req:set_resp_cookie/4, runs Fun, and returns the cookie
%% options map that was passed to the mock.
capture_set_resp_cookie(Fun) ->
    Self = self(),
    ok = meck:new(cowboy_req, [passthrough, no_link]),
    meck:expect(cowboy_req, set_resp_cookie,
        fun(_Name, _Value, Req, Opts) ->
            Self ! {captured_opts, Opts},
            Req
        end
    ),
    try
        _ = Fun(),
        receive
            {captured_opts, Opts} -> Opts
        after 1000 ->
            ct:fail("cowboy_req:set_resp_cookie was not called")
        end
    after
        meck:unload(cowboy_req)
    end.
