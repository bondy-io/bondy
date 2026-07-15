%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_tls).

-moduledoc """
Shared TLS client-option assembly for the secure transports — the `tls` raw
socket (`bondy_connect_transport_tls`) and the `wss` WebSocket
(`bondy_connect_transport_ws`).

Centralising it gives a **single source of truth** for the security knobs —
verification, CA trust, hostname/SNI, mutual-TLS client certificate, protocol
floor and ciphers — so they cannot drift between the two transports. (Before this
extraction the `wss` path silently lacked client-cert/mTLS and `ciphers` support
because it carried its own, drifted copy — review D1.)

## Secure by default

`verify_peer` is the default:

- CA trust: the user's `cacerts`/`cacertfile`, otherwise the OS trust store
  (`public_key:cacerts_get/0`).
- Hostname check: the connected host is used for SNI and matched against the
  certificate (`public_key:pkix_verify_hostname_match_fun(https)`).
- Protocol floor: TLS 1.2+ (`['tlsv1.3', 'tlsv1.2']`).
- Mutual TLS: supply `certfile`/`keyfile` (or `cert`/`key`).

Verification can be turned off explicitly with `#{verify => verify_none}`, which
is **logged at warning level** — it disables all certificate checks and must only
be used for local testing against a self-signed router.
""".

-include_lib("kernel/include/logger.hrl").

-define(DEFAULT_VERSIONS, ['tlsv1.3', 'tlsv1.2']).
-define(DEFAULT_DEPTH, 10).

-export([options/2]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Build the `ssl` client options from a `tls` config submap, secure by default.
`Host` is the connected host (used for SNI and the HTTPS hostname match); pass
the dialed host (a string enables SNI/hostname verification, otherwise only the
explicit `server_name_indication` applies).
""".
-spec options(Host :: inet:hostname() | inet:ip_address(), TLS :: map()) ->
    [ssl:tls_client_option()].

options(Host, TLS) when is_map(TLS) ->
    Verify = maps:get(verify, TLS, verify_peer),
    Versions = maps:get(versions, TLS, ?DEFAULT_VERSIONS),
    [{versions, Versions}] ++
        verify_opts(Verify, Host, TLS) ++
        cert_opts(TLS).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
verify_opts(verify_none, _Host, _TLS) ->
    ?LOG_WARNING(#{
        description =>
            "TLS peer verification is disabled (verify_none); the server "
            "certificate will not be validated. Use only for local testing."
    }),
    [{verify, verify_none}];
verify_opts(verify_peer, Host, TLS) ->
    [{verify, verify_peer}, {depth, maps:get(depth, TLS, ?DEFAULT_DEPTH)}] ++
        ca_opts(TLS) ++
        hostname_opts(Host, TLS).

%% @private CA trust: user-supplied, otherwise the OS trust store.
ca_opts(#{cacerts := CAs}) ->
    [{cacerts, CAs}];
ca_opts(#{cacertfile := File}) ->
    [{cacertfile, File}];
ca_opts(_) ->
    [{cacerts, public_key:cacerts_get()}].

%% @private SNI + hostname verification. A string host is used for SNI and for
%% the HTTPS-style hostname match; `server_name_indication => disable` turns both
%% off (e.g. when connecting by IP to a cert without an IP SAN).
hostname_opts(Host, TLS) ->
    case maps:get(server_name_indication, TLS, default) of
        disable ->
            [{server_name_indication, disable}];
        default when is_list(Host) ->
            [{server_name_indication, Host} | hostname_check()];
        default ->
            hostname_check();
        Name ->
            [{server_name_indication, Name} | hostname_check()]
    end.

%% @private
hostname_check() ->
    [
        {customize_hostname_check, [
            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
        ]}
    ].

%% @private Optional client certificate (mutual TLS), key material and ciphers.
cert_opts(TLS) ->
    lists:append([
        opt(certfile, TLS),
        opt(keyfile, TLS),
        opt(cert, TLS),
        opt(key, TLS),
        opt(password, TLS),
        opt(ciphers, TLS)
    ]).

%% @private
opt(Key, TLS) ->
    case maps:find(Key, TLS) of
        {ok, Value} -> [{Key, Value}];
        error -> []
    end.
