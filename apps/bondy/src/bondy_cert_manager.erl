%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================


-module(bondy_cert_manager).
-moduledoc """
Central TLS certificate manager for Bondy.

Manages three concerns:

1. **CA trust store** for outbound TLS connections — merges CA certificates from
   `certifi:cacerts()`, a user-configured PEM file (`tls.cacertfile`), and the
   OS trust store. Provides `ssl_opts/0,1` consumed by OIDC, RPC Gateway, etc.

2. **Server certificate management** — loads listener TLS certificates
   (cert + key) from PEM files, caches them in `persistent_term`, and provides
   an `sni_fun` callback that returns the current certificate on each TLS
   handshake. This enables live certificate rotation without restarting
   listeners.

3. **mTLS (mutual TLS)** — per-listener client CA pools, `verify` mode, and
   `fail_if_no_peer_cert` settings. Runtime-updatable via
   `ranch:set_transport_options/2`.

## persistent_term keys

- `{bondy_cert_manager, cacerts}` — merged outbound CA certs `[DER]`
- `{bondy_cert_manager, server_cert, ListenerRef}` — server cert data per
  listener
- `{bondy_cert_manager, client_auth, ListenerRef}` — mTLS config per listener

## Warning

`persistent_term:put/2` triggers a global GC of all processes that accessed the
old value. Certificate operations (`reload_cacerts/0`, `rotate_listener/1`,
`set_client_auth/2`) should not be called in rapid succession.

Must be initialised by calling `init/0` before first use (called from
`bondy_config:init/1`).
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("public_key/include/public_key.hrl").


%% Known TLS listener refs
-define(TLS_LISTENERS, [
    api_gateway_https,
    admin_api_https,
    wamp_tls,
    bridge_relay_tls
]).


%% CA Cert API
-export([init/0]).
-export([reload_cacerts/0]).
-export([cacerts/0]).
-export([ssl_opts/0]).
-export([ssl_opts/1]).

%% Server Cert API
-export([set_server_cert/2]).
-export([get_server_cert_info/1]).
-export([server_ssl_opts/1]).
-export([maybe_inject_sni_fun/2]).

%% Live Rotation API
-export([rotate_listener/1]).
-export([rotate_all_listeners/0]).

%% mTLS API
-export([set_client_auth/2]).
-export([get_client_auth/1]).


%% Types
-type listener_ref() :: api_gateway_https | admin_api_https
                      | wamp_tls | bridge_relay_tls | atom().

-type cert_source() :: #{
    certfile => file:filename_all(),
    keyfile => file:filename_all(),
    cert => public_key:der_encoded(),
    key => {atom(), public_key:der_encoded()}
}.

-type mtls_opts() :: #{
    cacerts => [public_key:der_encoded()],
    cacertfile => file:filename_all(),
    verify => verify_peer | verify_none,
    fail_if_no_peer_cert => boolean()
}.

-export_type([listener_ref/0, cert_source/0, mtls_opts/0]).



%% =============================================================================
%% CA CERT API
%% =============================================================================



-doc """
Initialises the certificate manager. Loads CA certs and server certs for all
configured TLS listeners. Called from `bondy_config:init/1`.
""".
-spec init() -> ok.

init() ->
    ok = do_load_cacerts(),
    ok = load_all_server_certs(),
    ok = load_all_client_auth(),
    ok.


-doc """
Re-reads CA certificates from all sources and updates the trust store.
Safe to call at runtime — new outbound connections will use the updated certs.
""".
-spec reload_cacerts() -> ok.

reload_cacerts() ->
    OldCount = try length(cacerts()) catch _:_ -> 0 end,
    ok = do_load_cacerts(),
    NewCount = length(cacerts()),
    ?LOG_NOTICE(#{
        description => "CA certificate store reloaded",
        previous_count => OldCount,
        new_count => NewCount
    }),
    ok.


-doc """
Returns the merged, deduplicated list of DER-encoded CA certificates.
""".
-spec cacerts() -> [public_key:der_encoded()].

cacerts() ->
    persistent_term:get({?MODULE, cacerts}, certifi:cacerts()).


-doc """
Returns SSL client options for outbound TLS connections with certificate
verification enabled using the merged CA store.
""".
-spec ssl_opts() -> [ssl:tls_client_option()].

ssl_opts() ->
    [
        {verify, verify_peer},
        {cacerts, cacerts()},
        {depth, 5},
        {customize_hostname_check, [
            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
        ]}
    ].


-doc """
Returns SSL client options customised by the given options map.

Supported options:
- `#{verify => verify_none}` — disables certificate verification
""".
-spec ssl_opts(Opts :: map()) -> [ssl:tls_client_option()].

ssl_opts(#{verify := verify_none}) ->
    [{verify, verify_none}];

ssl_opts(#{}) ->
    ssl_opts().



%% =============================================================================
%% SERVER CERT API
%% =============================================================================



-doc """
Loads a server certificate and key for a listener from PEM files or DER
binaries. Stores the parsed cert data in `persistent_term`.

If the listener is already running, new TLS handshakes will automatically use
the updated certificate via `sni_fun`.
""".
-spec set_server_cert(listener_ref(), cert_source()) -> ok | {error, term()}.

set_server_cert(ListenerRef, #{certfile := CertPath, keyfile := KeyPath}) ->
    case parse_pem_cert_and_key(CertPath, KeyPath) of
        {ok, CertData} ->
            ok = persistent_term:put(
                {?MODULE, server_cert, ListenerRef}, CertData
            ),
            log_cert_info(ListenerRef, CertData),
            ok;
        {error, _} = Error ->
            Error
    end;

set_server_cert(ListenerRef, #{cert := Cert, key := Key}) ->
    CertData = #{cert => Cert, key => Key, chain => []},
    ok = persistent_term:put({?MODULE, server_cert, ListenerRef}, CertData),
    log_cert_info(ListenerRef, CertData),
    ok.


-doc """
Returns metadata about the currently loaded server certificate for a listener.
Never exposes the private key.
""".
-spec get_server_cert_info(listener_ref()) ->
    {ok, map()} | {error, not_found}.

get_server_cert_info(ListenerRef) ->
    case persistent_term:get({?MODULE, server_cert, ListenerRef}, undefined) of
        undefined ->
            {error, not_found};
        #{cert := DerCert} ->
            {ok, extract_cert_metadata(DerCert)}
    end.


-doc """
Returns SSL server options containing an `sni_fun` that reads the current
certificate from `persistent_term` on each TLS handshake.
""".
-spec server_ssl_opts(listener_ref()) -> [ssl:tls_server_option()].

server_ssl_opts(ListenerRef) ->
    [{sni_fun, make_sni_fun(ListenerRef)}].


-doc """
Conditionally injects `sni_fun` into socket options for TLS listeners.
Called from `bondy_config:listener_transport_opts/1`.

If `certfile` is present in the socket opts (indicating a TLS listener), adds
an `sni_fun` that enables live certificate rotation.
""".
-spec maybe_inject_sni_fun(atom(), list()) -> list().

maybe_inject_sni_fun(ListenerRef, SocketOpts) ->
    case lists:keymember(certfile, 1, SocketOpts) of
        true ->
            [{sni_fun, make_sni_fun(ListenerRef)} | SocketOpts];
        false ->
            SocketOpts
    end.



%% =============================================================================
%% LIVE ROTATION API
%% =============================================================================



-doc """
Re-reads the certificate files from disk for a listener and updates the cached
cert data. New TLS handshakes will use the updated certificate.

Also calls `ranch:set_transport_options/2` to update the static cert for
clients that don't send SNI.
""".
-spec rotate_listener(listener_ref()) -> ok | {error, term()}.

rotate_listener(ListenerRef) ->
    case load_server_cert_from_config(ListenerRef) of
        ok ->
            update_ranch_opts(ListenerRef);
        {error, _} = Error ->
            Error
    end.


-doc """
Rotates certificates for all known TLS listeners.
""".
-spec rotate_all_listeners() -> ok.

rotate_all_listeners() ->
    lists:foreach(fun(Ref) ->
        case rotate_listener(Ref) of
            ok ->
                ok;
            {error, Reason} ->
                ?LOG_WARNING(#{
                    description => "Failed to rotate listener certificate",
                    listener => Ref,
                    reason => Reason
                })
        end
    end, ?TLS_LISTENERS).



%% =============================================================================
%% mTLS API
%% =============================================================================



-doc """
Sets the client certificate verification configuration for a listener.

Updates `persistent_term` and propagates changes to the running listener via
`ranch:set_transport_options/2`.
""".
-spec set_client_auth(listener_ref(), mtls_opts()) -> ok | {error, term()}.

set_client_auth(ListenerRef, Opts0) when is_map(Opts0) ->
    Opts = normalise_mtls_opts(Opts0),
    ok = persistent_term:put({?MODULE, client_auth, ListenerRef}, Opts),
    ?LOG_NOTICE(#{
        description => "Updated client auth configuration",
        listener => ListenerRef,
        verify => maps:get(verify, Opts, verify_none),
        fail_if_no_peer_cert => maps:get(fail_if_no_peer_cert, Opts, false)
    }),
    update_ranch_opts(ListenerRef).


-doc """
Returns the current mTLS configuration for a listener.
""".
-spec get_client_auth(listener_ref()) -> {ok, mtls_opts()} | {error, not_found}.

get_client_auth(ListenerRef) ->
    case persistent_term:get({?MODULE, client_auth, ListenerRef}, undefined) of
        undefined ->
            {error, not_found};
        Opts ->
            {ok, Opts}
    end.



%% =============================================================================
%% PRIVATE — CA Certs
%% =============================================================================



%% @private
do_load_cacerts() ->
    CertifiCerts = certifi:cacerts(),
    UserCerts = load_user_cacerts(),
    OsCerts = load_os_cacerts(),

    All = CertifiCerts ++ UserCerts ++ OsCerts,
    Unique = deduplicate(All),

    ok = persistent_term:put({?MODULE, cacerts}, Unique),

    ?LOG_NOTICE(#{
        description => "CA certificate store initialised",
        total => length(Unique),
        certifi => length(CertifiCerts),
        user => length(UserCerts),
        os => length(OsCerts)
    }),
    ok.


%% @private
load_user_cacerts() ->
    Path = case bondy_config:get([cert_manager, cacertfile], undefined) of
        undefined ->
            try
                Opts = bondy_config:get(
                    [api_gateway_https, transport_opts]
                ),
                SocketOpts = key_value:get(socket_opts, Opts, []),
                key_value:get(cacertfile, SocketOpts, undefined)
            catch
                _:_ -> undefined
            end;
        Configured ->
            Configured
    end,
    load_pem_certs(Path).


%% @private
load_os_cacerts() ->
    try
        ok = public_key:cacerts_load(),
        Certs = public_key:cacerts_get(),
        ?LOG_INFO(#{
            description => "Loaded OS trust store CA certificates",
            count => length(Certs)
        }),
        Certs
    catch
        _:_ ->
            ?LOG_DEBUG(#{
                description => "OS trust store not available, skipping"
            }),
            []
    end.


%% @private
deduplicate(Certs) ->
    Map = lists:foldl(
        fun(DER, Acc) -> Acc#{DER => true} end,
        #{},
        Certs
    ),
    maps:keys(Map).



%% =============================================================================
%% PRIVATE — Server Certs
%% =============================================================================



%% @private
load_all_server_certs() ->
    lists:foreach(fun(Ref) ->
        case load_server_cert_from_config(Ref) of
            ok -> ok;
            {error, not_configured} -> ok;
            {error, Reason} ->
                ?LOG_WARNING(#{
                    description =>
                        "Failed to load server certificate from config",
                    listener => Ref,
                    reason => Reason
                })
        end
    end, ?TLS_LISTENERS).


%% @private
load_server_cert_from_config(ListenerRef) ->
    try
        Opts = bondy_config:get([ListenerRef, transport_opts]),
        SocketOpts = key_value:get(socket_opts, Opts, []),
        CertFile = key_value:get(certfile, SocketOpts, undefined),
        KeyFile = key_value:get(keyfile, SocketOpts, undefined),
        case CertFile of
            undefined ->
                {error, not_configured};
            _ when KeyFile =:= undefined ->
                {error, not_configured};
            _ ->
                set_server_cert(ListenerRef, #{
                    certfile => CertFile,
                    keyfile => KeyFile
                })
        end
    catch
        _:_ ->
            {error, not_configured}
    end.


%% @private
parse_pem_cert_and_key(CertPath, KeyPath) ->
    case {file:read_file(CertPath), file:read_file(KeyPath)} of
        {{ok, CertPem}, {ok, KeyPem}} ->
            CertEntries = public_key:pem_decode(CertPem),
            KeyEntries = public_key:pem_decode(KeyPem),

            %% First Certificate entry is the server cert; rest are chain
            DerCerts = [
                DER
                || {'Certificate', DER, not_encrypted} <- CertEntries
            ],
            DerKey = parse_key_entry(KeyEntries),

            case {DerCerts, DerKey} of
                {[Cert | Chain], {ok, Key}} ->
                    {ok, #{cert => Cert, key => Key, chain => Chain}};
                {[], _} ->
                    {error, {no_certificate_found, CertPath}};
                {_, {error, Reason}} ->
                    {error, {invalid_key, KeyPath, Reason}}
            end;
        {{error, Reason}, _} ->
            {error, {cert_read_failed, CertPath, Reason}};
        {_, {error, Reason}} ->
            {error, {key_read_failed, KeyPath, Reason}}
    end.


%% @private
parse_key_entry(PemEntries) ->
    case find_key_entry(PemEntries) of
        {Type, DER, not_encrypted} ->
            KeyType = pem_type_to_key_type(Type),
            {ok, {KeyType, DER}};
        not_found ->
            {error, no_key_found}
    end.


%% @private
find_key_entry([]) ->
    not_found;
find_key_entry([{Type, _DER, not_encrypted} = Entry | _])
when Type =:= 'RSAPrivateKey';
     Type =:= 'ECPrivateKey';
     Type =:= 'PrivateKeyInfo' ->
    Entry;
find_key_entry([_ | Rest]) ->
    find_key_entry(Rest).


%% @private
pem_type_to_key_type('RSAPrivateKey') -> 'RSAPrivateKey';
pem_type_to_key_type('ECPrivateKey') -> 'ECPrivateKey';
pem_type_to_key_type('PrivateKeyInfo') -> 'PrivateKeyInfo'.


%% @private
make_sni_fun(ListenerRef) ->
    fun(_Hostname) ->
        case persistent_term:get(
            {?MODULE, server_cert, ListenerRef}, undefined
        ) of
            undefined ->
                %% No cert managed by us; let SSL use static socket_opts
                [];
            #{cert := Cert, key := Key} = CertData ->
                Chain = maps:get(chain, CertData, []),
                [{cert, Cert}, {key, Key}] ++
                    case Chain of
                        [] -> [];
                        _ -> [{cacerts, Chain}]
                    end
        end
    end.


%% @private
log_cert_info(ListenerRef, #{cert := DerCert}) ->
    try
        Meta = extract_cert_metadata(DerCert),
        ?LOG_INFO(#{
            description => "Loaded server certificate",
            listener => ListenerRef,
            subject => maps:get(subject, Meta, undefined),
            not_after => maps:get(not_after, Meta, undefined)
        })
    catch
        _:_ ->
            ?LOG_INFO(#{
                description => "Loaded server certificate",
                listener => ListenerRef
            })
    end.


%% @private
extract_cert_metadata(DerCert) ->
    OtpCert = public_key:pkix_decode_cert(DerCert, otp),
    TbsCert = OtpCert#'OTPCertificate'.tbsCertificate,

    Subject = format_rdn(
        TbsCert#'OTPTBSCertificate'.subject
    ),
    Issuer = format_rdn(
        TbsCert#'OTPTBSCertificate'.issuer
    ),

    #'Validity'{notBefore = NotBefore, notAfter = NotAfter} =
        TbsCert#'OTPTBSCertificate'.validity,

    Serial = TbsCert#'OTPTBSCertificate'.serialNumber,

    #{
        subject => Subject,
        issuer => Issuer,
        not_before => format_asn1_time(NotBefore),
        not_after => format_asn1_time(NotAfter),
        serial => integer_to_binary(Serial)
    }.


%% @private
format_rdn({rdnSequence, RdnSeq}) ->
    Parts = lists:filtermap(
        fun([#'AttributeTypeAndValue'{type = Oid, value = Val}]) ->
            case Oid of
                ?'id-at-commonName' ->
                    {true, iolist_to_binary(format_rdn_value(Val))};
                _ ->
                    false
            end;
        (_) ->
            false
        end,
        RdnSeq
    ),
    case Parts of
        [CN | _] -> CN;
        [] -> <<"unknown">>
    end.


%% @private
format_rdn_value({utf8String, V}) when is_binary(V) -> V;
format_rdn_value({printableString, V}) when is_list(V) -> list_to_binary(V);
format_rdn_value({printableString, V}) when is_binary(V) -> V;
format_rdn_value(V) when is_list(V) -> list_to_binary(V);
format_rdn_value(V) when is_binary(V) -> V;
format_rdn_value(_) -> <<"?">>.


%% @private
format_asn1_time({utcTime, Time}) ->
    list_to_binary(Time);
format_asn1_time({generalTime, Time}) ->
    list_to_binary(Time).



%% =============================================================================
%% PRIVATE — mTLS
%% =============================================================================



%% @private
load_all_client_auth() ->
    lists:foreach(fun(Ref) ->
        case load_client_auth_from_config(Ref) of
            ok -> ok;
            {error, not_configured} -> ok;
            {error, Reason} ->
                ?LOG_WARNING(#{
                    description =>
                        "Failed to load client auth config",
                    listener => Ref,
                    reason => Reason
                })
        end
    end, ?TLS_LISTENERS).


%% @private
load_client_auth_from_config(ListenerRef) ->
    try
        Opts = bondy_config:get([ListenerRef, transport_opts]),
        SocketOpts = key_value:get(socket_opts, Opts, []),
        Verify = key_value:get(verify, SocketOpts, undefined),
        case Verify of
            undefined ->
                {error, not_configured};
            _ ->
                CACertFile = key_value:get(
                    cacertfile, SocketOpts, undefined
                ),
                FailIfNoPeerCert = key_value:get(
                    fail_if_no_peer_cert, SocketOpts, false
                ),
                CACerts = case CACertFile of
                    undefined -> [];
                    _ -> load_pem_certs(CACertFile)
                end,
                MtlsOpts = #{
                    verify => Verify,
                    fail_if_no_peer_cert => FailIfNoPeerCert,
                    cacerts => CACerts
                },
                ok = persistent_term:put(
                    {?MODULE, client_auth, ListenerRef}, MtlsOpts
                ),
                ok
        end
    catch
        _:_ ->
            {error, not_configured}
    end.


%% @private
normalise_mtls_opts(#{cacertfile := Path} = Opts) ->
    CACerts = load_pem_certs(Path),
    Opts1 = maps:remove(cacertfile, Opts),
    Opts1#{cacerts => CACerts};

normalise_mtls_opts(Opts) ->
    Opts.



%% =============================================================================
%% PRIVATE — Ranch Integration
%% =============================================================================



%% @private
update_ranch_opts(ListenerRef) ->
    try
        CurrentOpts = ranch:get_transport_options(ListenerRef),
        SocketOpts0 = maps:get(socket_opts, CurrentOpts, []),
        SocketOpts = merge_managed_socket_opts(ListenerRef, SocketOpts0),
        ok = ranch:set_transport_options(
            ListenerRef, CurrentOpts#{socket_opts => SocketOpts}
        ),
        ?LOG_INFO(#{
            description => "Updated Ranch transport options",
            listener => ListenerRef
        }),
        ok
    catch
        exit:{noproc, _} ->
            %% Listener not running yet (startup)
            ok;
        error:badarg ->
            %% Listener not registered
            ok
    end.


%% @private
%% Merges cert manager state into socket opts for ranch:set_transport_options.
merge_managed_socket_opts(ListenerRef, SocketOpts0) ->
    %% Merge server cert (for non-SNI fallback)
    SocketOpts1 = case persistent_term:get(
        {?MODULE, server_cert, ListenerRef}, undefined
    ) of
        undefined ->
            SocketOpts0;
        #{cert := Cert, key := Key} = CertData ->
            Chain = maps:get(chain, CertData, []),
            Opts1 = lists:keystore(cert, 1, SocketOpts0, {cert, Cert}),
            Opts2 = lists:keystore(key, 1, Opts1, {key, Key}),
            case Chain of
                [] -> Opts2;
                _ -> lists:keystore(cacerts, 1, Opts2, {cacerts, Chain})
            end
    end,

    %% Merge mTLS opts
    case persistent_term:get(
        {?MODULE, client_auth, ListenerRef}, undefined
    ) of
        undefined ->
            SocketOpts1;
        MtlsOpts ->
            Verify = maps:get(verify, MtlsOpts, verify_none),
            FailIfNoPeer = maps:get(
                fail_if_no_peer_cert, MtlsOpts, false
            ),
            ClientCAs = maps:get(cacerts, MtlsOpts, []),
            Opts3 = lists:keystore(
                verify, 1, SocketOpts1, {verify, Verify}
            ),
            Opts4 = lists:keystore(
                fail_if_no_peer_cert, 1, Opts3,
                {fail_if_no_peer_cert, FailIfNoPeer}
            ),
            case ClientCAs of
                [] -> Opts4;
                _ -> lists:keystore(cacerts, 1, Opts4, {cacerts, ClientCAs})
            end
    end.



%% =============================================================================
%% PRIVATE — PEM Helpers
%% =============================================================================



%% @private
-spec load_pem_certs(file:filename_all() | undefined) ->
    [public_key:der_encoded()].

load_pem_certs(undefined) ->
    [];

load_pem_certs(Path) ->
    case file:read_file(Path) of
        {ok, PemBin} ->
            Entries = public_key:pem_decode(PemBin),
            DerCerts = [
                DER
                || {'Certificate', DER, not_encrypted} <- Entries
            ],
            ?LOG_INFO(#{
                description => "Loaded CA certificates from PEM file",
                path => Path,
                count => length(DerCerts)
            }),
            DerCerts;
        {error, Reason} ->
            ?LOG_WARNING(#{
                description => "Failed to read certificate file",
                path => Path,
                reason => Reason
            }),
            []
    end.
