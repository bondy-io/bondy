%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_tls_SUITE).

-moduledoc """
Pure unit tests for `bondy_connect_tls:options/2` — the shared, secure-by-default
TLS client-option builder used by both the `tls` raw-socket and `wss` WebSocket
transports (review D1). The `mutual_tls_and_ciphers_present` case is the D1
regression guard: these options were absent from the `wss` path before the
extraction.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([nowarn_export_all, export_all]).

all() ->
    [
        defaults_are_secure,
        verify_none_disables_checks,
        cacertfile_is_honoured,
        cacerts_is_honoured,
        mutual_tls_and_ciphers_present,
        sni_default_uses_host,
        sni_can_be_disabled,
        sni_explicit_name
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(ssl),
    Config.

end_per_suite(_) ->
    ok.

defaults_are_secure(_) ->
    Opts = bondy_connect_tls:options("127.0.0.1", #{}),
    ?assertEqual(['tlsv1.3', 'tlsv1.2'], proplists:get_value(versions, Opts)),
    ?assertEqual(verify_peer, proplists:get_value(verify, Opts)),
    ?assertEqual(10, proplists:get_value(depth, Opts)),
    %% OS trust store when no CA is supplied.
    ?assert(is_list(proplists:get_value(cacerts, Opts))),
    %% Hostname verification enabled, SNI derived from the dialed host.
    ?assert(lists:keymember(customize_hostname_check, 1, Opts)),
    ?assertEqual(
        "127.0.0.1", proplists:get_value(server_name_indication, Opts)
    ).

verify_none_disables_checks(_) ->
    Opts = bondy_connect_tls:options("127.0.0.1", #{verify => verify_none}),
    ?assertEqual(verify_none, proplists:get_value(verify, Opts)),
    ?assertEqual(undefined, proplists:get_value(cacerts, Opts)),
    ?assertEqual(undefined, proplists:get_value(depth, Opts)),
    ?assertNot(lists:keymember(customize_hostname_check, 1, Opts)).

cacertfile_is_honoured(_) ->
    Opts = bondy_connect_tls:options("h", #{cacertfile => "/tmp/ca.pem"}),
    ?assertEqual("/tmp/ca.pem", proplists:get_value(cacertfile, Opts)),
    ?assertEqual(undefined, proplists:get_value(cacerts, Opts)).

cacerts_is_honoured(_) ->
    CAs = [<<"der1">>, <<"der2">>],
    Opts = bondy_connect_tls:options("h", #{cacerts => CAs}),
    ?assertEqual(CAs, proplists:get_value(cacerts, Opts)).

%% D1 regression guard: the wss transport previously lacked client-cert/mTLS and
%% ciphers. Both transports now build options via this module, so these knobs are
%% available to both.
mutual_tls_and_ciphers_present(_) ->
    TLS = #{
        certfile => "/tmp/client.pem",
        keyfile => "/tmp/client.key",
        password => "secret",
        ciphers => ["TLS_AES_256_GCM_SHA384"]
    },
    Opts = bondy_connect_tls:options("h", TLS),
    ?assertEqual("/tmp/client.pem", proplists:get_value(certfile, Opts)),
    ?assertEqual("/tmp/client.key", proplists:get_value(keyfile, Opts)),
    ?assertEqual("secret", proplists:get_value(password, Opts)),
    ?assertEqual(
        ["TLS_AES_256_GCM_SHA384"], proplists:get_value(ciphers, Opts)
    ).

sni_default_uses_host(_) ->
    Opts = bondy_connect_tls:options("example.com", #{}),
    ?assertEqual(
        "example.com", proplists:get_value(server_name_indication, Opts)
    ),
    ?assert(lists:keymember(customize_hostname_check, 1, Opts)).

sni_can_be_disabled(_) ->
    Opts = bondy_connect_tls:options(
        "example.com", #{server_name_indication => disable}
    ),
    ?assertEqual(disable, proplists:get_value(server_name_indication, Opts)),
    ?assertNot(lists:keymember(customize_hostname_check, 1, Opts)).

sni_explicit_name(_) ->
    Opts = bondy_connect_tls:options(
        {127, 0, 0, 1}, #{server_name_indication => "router.internal"}
    ),
    ?assertEqual(
        "router.internal", proplists:get_value(server_name_indication, Opts)
    ),
    ?assert(lists:keymember(customize_hostname_check, 1, Opts)).
