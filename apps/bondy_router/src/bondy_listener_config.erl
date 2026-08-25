%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_listener_config).

-moduledoc """
Resolves and validates the listener inventory at boot.

This module takes the `bondy_router.listeners` inventory and a function for
reading a listener's option block, and returns either a list of fully resolved
listener maps or the first error. It starts nothing and has no side effects
beyond name resolution — `to_address/2` calls `inet:getaddr/2` for an address
that is not a literal, which is a DNS lookup on the boot path, so an
unresolvable name delays the boot until the resolver gives up. Only an inventory
supplied through application environment can reach that: `listeners.$name.ip` is
parsed by the schema's own translation and takes a literal address only. It reads
application environment in two other places, `external_services/0` and
`external_carriers/0`, for what a plugin registered. Everything else comes from
its two arguments, which is why `bondy_listener_config_test` exercises it
directly.

A static configuration error is *intended* to abort boot: skipping a
misconfigured listener would produce a node that comes up serving nothing an
operator asked for, which is harder to diagnose than a refusal to start. This
module only reports the error — the caller decides what to do with it.

Validation is deliberately strict about required keys. The release renders
`bondy.conf` with `cuttlefish --allow_extra --silent`, so an unrecognised key is
dropped without a warning; requiring `transport`, `protocol`, a bind target and
(for HTTP) `services` turns a mistyped listener name into two named boot errors
rather than a silently bound phantom listener.
""".

-type transport() :: tcp | tls | uds.
-type protocol() :: http | wamp_rawsocket | bridge_relay.
-type bind() :: {port, inet:port_number()} | {path, file:filename()}.

-type driver() :: bondy_listener_ranch.

-type t() :: #{
    name := atom(),
    transport := transport(),
    protocol := protocol(),
    services := [atom()],
    enabled := boolean(),
    start_phase := early | normal,
    bind := bind(),
    driver := driver(),
    carriers := #{atom() => carrier()},
    %% Optional: absent when no address was configured and none is derived —
    %% see `resolve_ip/3`.
    ip => inet:ip_address()
}.

%% One carrier of one listener, fully resolved.
%%
%% `module` is here rather than on each service because it depends on the
%% CARRIER alone — a carrier owns a path and a path is served by one handler.
%% While it rode on the service, two services naming one carrier each carried a
%% value for it and could disagree; there is now nowhere for a disagreement to
%% be written down.
-type carrier() :: #{
    module := module(), protocols := [atom()], config := map()
}.

-type service_spec() :: #{carrier := atom(), protocol := atom() | undefined}.

-type get_fun() :: fun((Key :: [atom()], Default :: term()) -> term()).

-type error_reason() :: {invalid_listener, Name :: atom(), Detail :: term()}.

-export_type([
    t/0,
    transport/0,
    protocol/0,
    driver/0,
    get_fun/0,
    error_reason/0,
    carrier/0,
    service_spec/0
]).

-export([carrier_defaults/1]).
-export([default_inventory/0]).
-export([option_defaults/2]).
-export([reserved_names/0]).
-export([resolve/2]).
-export([resolve_internal/4]).
-export([service_spec/1]).
-export([tls_material/3]).
-export([with_option_defaults/1]).

%% Every transport and protocol that has a driver and a connection handler.
%% A value with neither is not listed here and is refused as
%% `{unknown_transport, _}' / `{unknown_protocol, _}' — a named configuration
%% error at boot — rather than accepted and then crashing at start with `undef'
%% or `function_clause', which names nothing. Adding a value here is what makes
%% it configurable, so a new transport or protocol arrives together with the
%% code that serves it.
-define(TRANSPORTS, [tcp, tls, uds]).
-define(PROTOCOLS, [http, wamp_rawsocket, bridge_relay]).

%% Names an operator may not use freely.
%%
%% `?RESERVED_INTERNAL` names listeners this node injects through
%% `resolve_internal/4`. They may not appear in a configured inventory at all.
%% `?RESERVED_NAMES` adds the names an operator MAY define but may not disable.
%%
%% The second is defined in terms of the first so that an internal name is
%% always also a reserved one. `assert_reserved/2` derives both rules from these
%% lists rather than matching names literally, so adding a name here is what
%% reserves it.
-define(RESERVED_INTERNAL, [admin_local]).
-define(RESERVED_NAMES, [admin | ?RESERVED_INTERNAL]).

-define(TLS_REQUIRED_KEYS, [certfile, keyfile]).
-define(TLS_KEYS, [
    certfile, keyfile, cacertfile, versions, verify, fail_if_no_peer_cert
]).

%% The carrier settings an operator may override per listener, with the value
%% each takes when the operator names it nowhere.
%%
%% Keys are the paths a `listeners.$name.<carrier>.*' mapping renders into the
%% listener's option block, which is NOT always the conf key's own name:
%% `websocket.compression_enabled' lands on `compress' and
%% `websocket.deflate.level' on `deflate_opts.level'. The rendered path is what
%% a consumer reads, so the rendered path is what belongs here.
%%
%% Values are the ones the deleted `wamp.{websocket,sse,longpoll}.*' mappings
%% carried, in the form cuttlefish converted them to (`20s' as 20000, `4MB' as
%% 4194304). They were read out of the generated
%% `bondy_router.wamp_{websocket,sse,longpoll}' blocks rather than transcribed
%% from the `{default, ...}' terms, so no duration or bytesize is off by a unit,
%% and while both existed a suite case asserted the two agreed key for key.
%%
%% This is now the ONLY statement of what a carrier setting defaults to. It is
%% not rendered into a release's `etc/bondy.conf' the way a non-fuzzy schema
%% default is, so an operator reading a generated conf sees no carrier default
%% at all; `doc/guides/configuration/listeners.md' carries the table for them.
%%
%% ONE table rather than a path list beside a value map: the paths
%% `resolve_carrier_config/3' reads are DERIVED from this map by `leaf_paths/1',
%% so a carrier key with no default cannot be expressed and the two cannot
%% drift. What it cannot express is a setting whose value is itself a map —
%% `leaf_paths/1' descends into a map and would treat its members as separate
%% keys. No carrier setting has one; a LIST-valued setting is fine, since only
%% maps are descended.
%%
%% Only the carriers that HAVE settings appear. `carrier_defaults/1'
%% answers `#{}' for any other, so a row of `api_gateway => #{}' would state
%% what its own absence already states, and would read as a carrier whose
%% settings had been forgotten. Which carriers those are is not a list to keep
%% in step with `service_spec/1' either: across that table, the carriers with
%% settings are exactly the ones whose services name a `protocol', because a
%% protocol is what has framing, timeouts and a keepalive to configure.
%% `api_gateway', `admin_api', `admin' and `metrics' all carry
%% `protocol => undefined' — they are route sets on a listener's HTTP, not
%% connection styles — and have nothing to default. An EXTENSION's carrier
%% (`external_services/0') is outside that correspondence: it can name a
%% protocol and still answer `#{}' here, which is correct, since the schema
%% declares no `listeners.$name.<carrier>.*' mapping for it either.
%%
%% `wamp.websocket.buffer.{min,max}' are deliberately ABSENT. Since Cowboy
%% 2.13 a WebSocket connection inherits the listener's `dynamic_buffer' and
%% `cowboy_websocket' overrides any handler-supplied value, so a WS-specific
%% setting cannot take effect (see the comment at bondy_config:setup_wamp/0).
%% Exposing them per listener would ship two knobs that do nothing.
-define(CARRIER_DEFAULTS, #{
    websocket => #{
        compress => false,
        hibernate => idle,
        idle_timeout => 28800000,
        max_frame_size => 4194304,
        ping => #{
            enabled => true,
            idle_timeout => 20000,
            max_attempts => 3,
            timeout => 10000
        },
        deflate_opts => #{
            level => 5,
            mem_level => 8,
            strategy => default,
            server_context_takeover => takeover,
            client_context_takeover => takeover,
            server_max_window_bits => 11,
            client_max_window_bits => 11
        }
    },
    sse => #{
        idle_timeout => 600000,
        ping => #{enabled => true, interval => 20000}
    },
    longpoll => #{
        idle_timeout => 600000,
        poll_timeout => 30000
    },
    %% `public_base_uri' is a PRESENT key with a sentinel, not an absent key:
    %% it has no meaningful default (it exists for deployments behind a
    %% TLS-terminating proxy, where the public origin is not one this node
    %% ever sees), and a key without a leaf here could not be expressed per
    %% listener at all — the paths `resolve_carrier_config/3' reads are the
    %% leaves of this row.
    mcp => #{
        protocol_versions => [
            <<"2026-07-28">>, <<"2025-11-25">>, <<"2025-06-18">>
        ],
        public_base_uri => undefined,
        max_body_size => 4194304,
        max_inflight => 64,
        idle_timeout => 600000,
        list => #{default_page_size => 200},
        schema => #{max_depth => 32, max_validation_ms => 50}
    }
}).

%% =============================================================================
%% API
%% =============================================================================

-doc """
The listeners a node starts when `bondy.conf` declares no `listeners.*` key.

This is the ONLY default. It is not a compatibility shim: the legacy
`admin_api.*`, `api_gateway.*`, `wamp.{tcp,tls}.*` and `bridge.listener.*`
mappings are gone, so there is no second place a listener's identity can come
from.

It has to exist rather than defaulting to no listeners at all, because the
`prod`, `prod_named` and `docker` releases overlay no `bondy.conf` whatsoever —
only `sys.config` and `vm.args`. Those three listeners ran on the legacy
mappings' own `{default, on}` values, so a node with no conf file must keep
getting them from somewhere, and code is the one place left.

**Three entries, all plaintext.** The six the historical set carried with
`enabled => false` are gone: on the configured path an undeclared listener does
not exist, which is how an operator drops one, so a permanently-disabled default
buys nothing.

A disabled TLS entry would now *resolve* — `assert_tls_keys/4` skips a listener
that will not start — so this is a choice rather than a constraint. It was a
constraint until that guard existed: the certificate paths a TLS entry needed came
from the legacy mappings' own `{default, "{{platform_etc_dir}}/keycert.pem"}`, and
with those deleted such an entry failed resolution on every node that has no
certificates, taking the whole inventory down with it.

`wamp_uds` is gone for the same reason and never had a mapping anyway: it was
reachable only through application environment and defaulted to disabled.

**The admin listener is named `admin`, not `admin_api_http`.** That is the
reserved name, and it must be the one used here: `with_reserved/1` in the manager
adds `admin` only when it is absent, so a default inventory naming
`admin_api_http` would put two listeners on 18081 and `assert_bind_free/2` would
refuse the boot. Using the reserved name also means a listener's options are read
under the name it actually carries — the mistake that left 26 `admin_api.http.*`
options unread in the shipped templates.

The ports are the ones these listeners have always bound. The `services` of each
HTTP listener are the route sets `bondy_http_services` exposes, equal to the
deleted `base_routes/0` and `admin_base_routes/0`, which
`bondy_http_services_test` asserts path by path. `admin` declares `admin_api`
rather than `api_gateway`: the admin listener mounts the built-in Admin API
specification from `priv/`, the public one mounts the specifications in storage,
and neither mounts both. `bondy_admin_listener_SUITE` drives `/realms` over real
HTTP.
""".
-spec default_inventory() -> [{atom(), map()}].

default_inventory() ->
    [
        {admin, #{
            transport => tcp,
            protocol => http,
            port => 18081,
            start_phase => early,
            services => [admin_api, wamp_ws, admin, metrics]
        }},
        {api_gateway_http, #{
            transport => tcp,
            protocol => http,
            port => 18080,
            services => [api_gateway, wamp_ws, wamp_sse, wamp_longpoll]
        }},
        {wamp_tcp, #{
            transport => tcp, protocol => wamp_rawsocket, port => 18082
        }}
    ].

-doc """
Listener names an operator may not use freely: `admin` may be overridden but
not removed or disabled, `admin_local` is internal.
""".
-spec reserved_names() -> [atom()].

reserved_names() -> ?RESERVED_NAMES.

-doc """
The value each of `Carrier`'s settings takes when the operator names it nowhere.

The map is nested exactly as a resolved carrier config is, so a caller can
compare the two directly.

Only `websocket`, `sse` and `longpoll` have settings — they are the carriers
that name a `protocol` in `service_spec/1`, and a protocol is what has framing,
timeouts and a keepalive. Every other carrier (`api_gateway`, `admin_api`,
`admin`, `metrics`) is a route set rather than a connection style, and answers
`#{}`, as does a carrier this module does not know.

These are the values the global `wamp.<carrier>.*` mappings used to render.
Those mappings are gone, so this is the only place a carrier default comes from
and every listener that does not state a key gets its value from here.
""".
-spec carrier_defaults(Carrier :: atom()) -> map().

carrier_defaults(Carrier) ->
    maps:get(Carrier, ?CARRIER_DEFAULTS, #{}).

-doc """
The option defaults a listener's transport and protocol imply.

The legacy `wamp.{tcp,tls}.*`, `api_gateway.*`, `admin_api.*` and
`bridge.listener.*` mappings each carried a `{default, ...}`, and
`rebar3_scuttler` renders every non-fuzzy schema default into a release's
generated `etc/bondy.conf` as an active line, so those values were in force on
every node — including `prod`, `prod_named` and `docker`, which overlay no
`bondy.conf` template of their own. Their `listeners.$name.*` replacements
cannot carry a default: `cuttlefish_generator:add_fuzzy_default/4` materialises a
fuzzy mapping's default for every name mentioned anywhere under the `listeners`
prefix (see the note above those mappings in `schema/bondy.schema`). The values
whose consumer has no equivalent fallback of its own therefore live here.

These are the listener's OWN settings, not a carrier's:
`resolve_carrier_config/3` has its own defaults in `carrier_defaults/1`, and the
two blocks do not overlap. What both have in common is the reason they are in
code at all — a `listeners.$name.*` mapping cannot carry a `{default, ...}`.

Keyed on the transport as well as the protocol because one of them belongs to
neither alone — see `transport_option_defaults/2`.

Total in both arguments. `with_option_defaults/1` runs before `resolve/2` has
validated anything, so an unknown transport or protocol answers `#{}` here and is
reported by `resolve/2` as the named configuration error it is.
""".
-spec option_defaults(Transport :: atom(), Protocol :: atom()) -> map().

option_defaults(Transport, Protocol) ->
    deep_merge(
        protocol_option_defaults(Protocol),
        transport_option_defaults(Transport, Protocol)
    ).

-doc """
`Spec` with the defaults its transport and protocol imply filled in.

The operator's value wins at every LEAF rather than at the block: a listener
stating one `ping` key keeps the defaults for the siblings it did not state.
That is what makes an enabled `ping` block complete by construction — every key
`bondy_wamp_tcp_connection_handler:maybe_enable_ping/2` and
`bondy_bridge_relay_server:maybe_enable_ping/2` read with `maps:get/2` is there
whether the operator wrote it or not.

A `Spec` carrying no `transport`/`protocol` pair comes back unchanged, so
`resolve/2` reports the missing key instead of this raising first.

One limit. A block an embedded caller supplied as a PROPLIST replaces its
default block whole instead of merging into it, because only a map is descended
into. Every block the `bondy_router.listeners` translation renders is a nested
map — its `Put` fun builds one with `maps:put/3` — so a proplist reaches here
only from `sys.config` or a direct call.
""".
-spec with_option_defaults(Spec :: map()) -> map().

with_option_defaults(#{transport := Transport, protocol := Protocol} = Spec) ->
    Defaults = deep_merge(
        option_defaults(Transport, Protocol), held_stream_defaults(Spec)
    ),
    deep_merge(Defaults, Spec);
with_option_defaults(Spec) ->
    Spec.

%% @private
%% Connection-level defaults for a listener whose services hold streams open
%% (SSE, long-poll, MCP). A held response sends for minutes on a connection that
%% may receive nothing, and Cowboy's connection idle timer is the ONLY timer
%% that governs it over HTTP/2 — `cowboy_http2:commands/3' discards the whole
%% per-stream `set_options' cast (`cowboy_http2.erl:988'), so the per-stream
%% override the handlers once cast worked over HTTP/1.1 alone. Seating the
%% carriers' `idle_timeout' as the CONNECTION default instead gives both
%% versions the same behaviour from the same timer. `reset_idle_timeout_on_send'
%% rides along because both protocol modules honour it at connection level
%% (`cowboy_http.erl:356', `cowboy_http2.erl:383') and a held stream's
%% traffic is nearly all sends: without it, an SSE stream that only pings
%% would die at the floor even mid-conversation. Both are DEFAULTS: an
%% operator's explicit `http.idle_timeout' or `http.reset_idle_timeout_on_send'
%% wins in `with_option_defaults/1''s final merge.
held_stream_defaults(#{protocol := http} = Spec) ->
    Services = maps:get(services, Spec, []),
    Floors = [
        held_stream_floor(Carrier, Spec)
     || Service <- Services,
        Carrier <- [held_stream_carrier(Service)],
        Carrier =/= undefined
    ],
    case Floors of
        [] ->
            #{};
        _ ->
            #{
                protocol_opts => #{
                    idle_timeout => lists:max(Floors),
                    reset_idle_timeout_on_send => true
                }
            }
    end;
held_stream_defaults(_) ->
    #{}.

%% @private
held_stream_carrier(Service) ->
    case service_spec(Service) of
        #{carrier := sse} -> sse;
        #{carrier := longpoll} -> longpoll;
        %% MCP holds SSE response streams open the same way, and its carrier
        %% row carries the same `idle_timeout' key.
        #{carrier := mcp} -> mcp;
        _ -> undefined
    end.

%% @private
%% The operator's per-carrier `idle_timeout' if the spec states one, else the
%% carrier's own default: the same value the handlers used to cast per
%% stream, so at defaults the connection behaves as the HTTP/1.1 path
%% always had.
held_stream_floor(Carrier, Spec) ->
    Block = maps:get(Carrier, Spec, #{}),
    maps:get(
        idle_timeout, Block, maps:get(idle_timeout, carrier_defaults(Carrier))
    ).

-doc """
Resolves `Inventory` into validated listener maps.

`GetFun` reads a per-listener option path, e.g.
`GetFun([pub, transport_opts, socket_opts, backlog], undefined)`. Production
callers pass `fun bondy_config:get/2`.

Returns the FIRST error encountered, so boot failure names one listener and one
problem rather than a list the operator has to unpick.
""".
-spec resolve(Inventory :: [{atom(), map()}], GetFun :: get_fun()) ->
    {ok, [t()]} | {error, error_reason()}.

resolve(Inventory, GetFun) ->
    catching(fun() ->
        {Resolved, _} = lists:foldl(
            fun({Name, Spec}, {Acc, Seen}) ->
                ok = assert_reserved(Name, Spec),
                ok = assert_unique_name(Name, Seen),
                Listener = resolve_one(Name, Spec, GetFun),
                ok = assert_bind_free(Listener, Seen),
                {[Listener | Acc], [{Name, Listener} | Seen]}
            end,
            {[], []},
            Inventory
        ),
        lists:reverse(Resolved)
    end).

-doc """
Resolves one listener this node injects rather than an operator configuring it.

A second entry point, not a flag on `resolve/2`, because the two differ in
PROVENANCE and nothing about a `{Name, Spec}` pair carries that. `resolve/2`
rejects every `?RESERVED_INTERNAL` name outright — see `assert_reserved/2` — and
that rejection is only unconditional, and therefore only a guarantee that
exactly one such listener exists, if the injected entry never travels through
the same door.

`Resolved` is the already-resolved operator inventory. The injected listener is
checked against it for name and bind clashes exactly as an inventory entry is
checked against its predecessors, so it is a participant in uniqueness rather
than an exception to it — without that, an operator could point a `uds` listener
at this one's path and take it over silently.

Raises for a name that is not in `?RESERVED_INTERNAL`. That is a caller error,
not a configuration error: the argument above holds only for names `resolve/2`
refuses, so a general "resolve one listener out of band" door would let a caller
inject a second listener under a name an operator may legitimately have used.
""".
-spec resolve_internal(
    Name :: atom(), Spec :: map(), Resolved :: [t()], GetFun :: get_fun()
) ->
    {ok, t()} | {error, error_reason()}.

resolve_internal(Name, Spec, Resolved, GetFun) ->
    lists:member(Name, ?RESERVED_INTERNAL) orelse
        error({not_a_reserved_internal_listener, Name}),
    catching(fun() ->
        Seen = [{maps:get(name, L), L} || L <- Resolved],
        ok = assert_unique_name(Name, Seen),
        Listener = resolve_one(Name, Spec, GetFun),
        ok = assert_bind_free(Listener, Seen),
        Listener
    end).

-doc """
Maps a `services` entry to the carrier it is reachable on and the protocol it
carries there.

Carrier and carried protocol are INTRINSIC to a service name, so this is data,
not a compatibility matrix to keep in step with anything. A service whose
carrier already appears on the listener contributes its protocol to that
carrier's set rather than a second route on the same path.

It does NOT say which module serves the carrier: that depends on the carrier
alone, so it lives in `carrier_module/1`. Two services naming one carrier
therefore cannot disagree about who serves it — `api_gateway` and `admin_api`
used to be the case in point, both naming a shared `rest` carrier.

Returns the atom `error` for a service name this application does not know,
including one that no registered extension claims either.
""".
-spec service_spec(atom()) -> service_spec() | error.

service_spec(api_gateway) ->
    #{carrier => api_gateway, protocol => undefined};
service_spec(admin_api) ->
    #{carrier => admin_api, protocol => undefined};
service_spec(wamp_ws) ->
    #{carrier => websocket, protocol => wamp};
service_spec(bamp_ws) ->
    #{carrier => websocket, protocol => bamp};
service_spec(wamp_sse) ->
    #{carrier => sse, protocol => wamp};
service_spec(wamp_longpoll) ->
    #{carrier => longpoll, protocol => wamp};
%% `protocol => mcp' rather than `undefined' because MCP genuinely frames a
%% wire protocol, unlike `api_gateway' or `admin'. Nothing dispatches on the
%% value today — the carrier has one service, so the union is always
%% `[mcp]' — but it keeps this table's rule intact: the carriers with
%% settings in `?CARRIER_DEFAULTS' are exactly the ones whose services name
%% a protocol.
service_spec(mcp) ->
    #{carrier => mcp, protocol => mcp};
service_spec(admin) ->
    #{carrier => admin, protocol => undefined};
service_spec(metrics) ->
    #{carrier => metrics, protocol => undefined};
service_spec(Other) ->
    %% Extension point for an application shipped OUTSIDE the Bondy release.
    %% A service that ships inside the release belongs in the literal clauses
    %% above: this env is readable only before the inventory resolves (a
    %% dependent app's start/2 is too late), and an external carrier gets no
    %% ?CARRIER_DEFAULTS row and no schema mappings, so its per-listener
    %% config always resolves to `#{}'.
    case lists:keyfind(Other, 1, external_services()) of
        {Other, Spec} -> Spec;
        false -> error
    end.

-doc """
Resolves one key of a TLS listener's certificate material.

The single definition of where a listener's certificate and key come from:
`[Name, tls, Key]`, which is where `listeners.$name.tls.*` lands once
`bondy_config:splat_listener_blocks/1` has copied the inventory entry out.
`assert_tls_keys/3` validates through this function, and `bondy_cert_manager`
reads a listener's certificate and key through it too
(`server_cert_from_config/1`, for both boot-time preload and live rotation), so
a certificate a validated listener carries is guaranteed visible to rotation as
well — the two can no longer disagree because they are the same call.
""".
-spec tls_material(Name :: atom(), Key :: atom(), GetFun :: get_fun()) ->
    term().

tls_material(Name, Key, GetFun) ->
    GetFun([Name, tls, Key], undefined).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Turns the `throw` every validation helper raises into the `{error, _}` both
%% entry points return, so a static configuration error reaches the caller as a
%% value rather than an exception.
catching(Fun) ->
    try
        {ok, Fun()}
    catch
        throw:{invalid_listener, _, _} = Reason ->
            {error, Reason}
    end.

%% @private
%% Defaults the PROTOCOL alone implies.
%%
%% One clause for both stream protocols because their whole restored set is the
%% shared keepalive contract below, `wamp.{tcp,tls}.linger.timeout' (`1s')
%% included. That one was withheld while the key's datatype still declared
%% milliseconds; it goes back on top of the corrected `{duration, s}', and the
%% evidence for the unit sits beside the value in `stream_keepalive_defaults/0'
%% rather than being restated here.
protocol_option_defaults(Stream) when
    Stream =:= wamp_rawsocket; Stream =:= bridge_relay
->
    stream_keepalive_defaults();
protocol_option_defaults(http) ->
    #{
        %% `api_gateway.http*.active_n' defaulted to 100 where Cowboy's own is 1
        %% (`cowboy_http.erl:214'), and `api_gateway.http*.idle_timeout' to 15s
        %% where Cowboy's is 60000 (`:337'). The shipped templates restate both
        %% for `listeners.admin' only, so every other HTTP listener took
        %% Cowboy's.
        protocol_opts => #{active_n => 100, idle_timeout => 15000},
        %% Priority-ordered HTTP versions the listener offers
        %% (`listeners.$name.http.versions'). On a TLS listener the order is
        %% the server's ALPN preference; on a clear listener membership gates
        %% the HTTP/2 prior-knowledge and Upgrade paths. HTTP/2 first — the
        %% same preference `cowboy:start_tls/3' ships — is safe for held
        %% streams because their lifetime is connection-level on BOTH
        %% versions: `held_stream_defaults/1' seats the connection timer, and
        %% nothing per-stream remains for the versions to disagree on
        %% (`bondy_http_sse_SUITE:held_stream_outlives_http_default_on_both_versions'
        %% holds a quiet stream past the plain HTTP default on each).
        http_versions => [http2, http]
    };
protocol_option_defaults(_Unknown) ->
    #{}.

%% @private
%% The keepalive contract both stream protocols implement: probe a connection
%% that has been idle for `ping.idle_timeout', give up on the peer after
%% `max_attempts' probes each unanswered for `timeout', and reap a connection
%% idle for `idle_timeout' whether or not it is being probed. The two handlers
%% read the same key names and mean the same thing by them, so this is one rule
%% expressed once, not two that happen to agree.
%%
%% `wamp.{tcp,tls}.ping.enabled' defaulted to `on', `ping.timeout' to `10s' and
%% `wamp.tcp.ping.max_attempts' to `2'; `bridge.listener.{tcp,tls}.ping.*'
%% carried the same four, `idle_timeout' included. The one value that differed by
%% transport was `max_attempts': `wamp.tls' defaulted to `3' where `wamp.tcp' and
%% both bridge listeners defaulted to `2', and nothing explained the split. It is
%% 3 for every listener here — the transport does not change how many unanswered
%% probes mean a dead peer, and the same 3 is the default for a WebSocket
%% connection (`wamp.websocket.ping.max_attempts', the block a listener's
%% `websocket.ping.*' falls back to), so one number covers every protocol.
%%
%% The 20s probe interval is `wamp.tcp.ping.idle_timeout''s own default and the
%% interval every WebSocket connection is already probed at. It must be shorter
%% than the 8h reap deadline: taken from `idle_timeout' instead, as
%% `bondy_wamp_tcp_connection_handler:maybe_enable_ping/2' used to, both timers
%% come due together and the connection is closed at the moment it would have
%% been probed — a keepalive that can neither hold a NAT binding open nor notice
%% a dead peer any sooner than the reap already does.
stream_keepalive_defaults() ->
    #{
        idle_timeout => 28800000,
        ping => #{
            enabled => true,
            idle_timeout => 20000,
            timeout => 10000,
            max_attempts => 3
        },
        %% `wamp.{tcp,tls}.linger.timeout' and
        %% `bridge.listener.{tcp,tls}.linger.timeout' all defaulted to `1s', so
        %% this belongs to the raw-socket shape rather than to one protocol.
        %%
        %% ONE, not 1000. `bondy_config:normalise_socket_opts/1' hands the value
        %% to `{linger, {true, N}}', whose second component `inet' documents in
        %% SECONDS (`kernel/src/inet.erl:1124', OTP 28.5). While the key's
        %% datatype was `{duration, ms}' the shipped default rendered 1000 and
        %% asked for a 1000-second blocking close, which is why this was withheld
        %% until the datatype was corrected to `{duration, s}'.
        %%
        %% An HTTP listener gets none: Cowboy's own `linger_timeout' protocol
        %% option covers it, reached through `listeners.$name.http.linger.timeout'
        %% and genuinely in milliseconds.
        transport_opts => #{socket_opts => #{linger_timeout => 1}}
    }.

%% @private
%% The one default that belongs to the transport and the protocol TOGETHER.
%%
%% `admin_api.https.security_headers.hsts' carried this value and no plaintext
%% mapping did. HSTS tells a browser to reach this host over TLS for the next
%% year, so a plaintext listener sending it directs clients at a port that does
%% not speak TLS; and it is an HTTP response header, so a raw socket has nothing
%% to send it on. `bondy_http_security_headers:default_config/0' has
%% `hsts => undefined' and merges the listener's block over it, so this is what
%% decides whether the header is emitted at all.
transport_option_defaults(tls, http) ->
    #{
        security_headers => #{
            hsts => <<"max-age=31536000; includeSubDomains">>
        }
    };
transport_option_defaults(_Transport, _Protocol) ->
    #{}.

%% @private
%% `Over' wins at the LEAF: where both sides hold a map the two are merged
%% rather than the block replaced. Only a map is descended into — a list-valued
%% leaf (`tls.versions', `cors.allowed_origins') is a value, not a nested block.
deep_merge(Under, Over) ->
    maps:fold(fun deep_merge_key/3, Under, Over).

%% @private
deep_merge_key(Key, Value, Acc) when is_map(Value) ->
    case maps:find(Key, Acc) of
        {ok, Existing} when is_map(Existing) ->
            maps:put(Key, deep_merge(Existing, Value), Acc);
        _ ->
            maps:put(Key, Value, Acc)
    end;
deep_merge_key(Key, Value, Acc) ->
    maps:put(Key, Value, Acc).

%% @private
resolve_one(Name, Spec, GetFun) ->
    Transport = required(Name, transport, Spec),
    lists:member(Transport, ?TRANSPORTS) orelse
        invalid(Name, {unknown_transport, Transport}),

    Protocol = required(Name, protocol, Spec),
    lists:member(Protocol, ?PROTOCOLS) orelse
        invalid(Name, {unknown_protocol, Protocol}),

    ok = assert_transport_protocol(Name, Transport, Protocol),

    Services = resolve_services(Name, Protocol, Spec),
    ok = assert_services_compatible(Name, Services),

    Enabled = maps:get(enabled, Spec, true),

    Driver = driver(Transport),
    ok = assert_tls_keys(Name, Transport, Enabled, GetFun),

    Carriers = resolve_carriers(Name, Services, GetFun),

    ok = assert_listener_ping(Name, Protocol, GetFun),

    maps:merge(
        #{
            name => Name,
            transport => Transport,
            protocol => Protocol,
            services => Services,
            enabled => Enabled,
            start_phase => maps:get(start_phase, Spec, normal),
            bind => resolve_bind(Name, Transport, Spec),
            driver => Driver,
            carriers => Carriers
        },
        resolve_ip(Name, Services, Spec)
    ).

%% @private
%% Both rules are derived from `?RESERVED_INTERNAL' and `?RESERVED_NAMES', so a
%% name added to either list is actually reserved. Internal is tested first, and
%% `?RESERVED_NAMES' contains `?RESERVED_INTERNAL' by construction, so the two
%% branches are ordered rather than overlapping.
%%
%% `admin_local' is injected by `bondy_listener_manager' through
%% `resolve_internal/4' and has no per-listener mappings of its own.
%% Every `listeners.$name.*' mapping in `schema/bondy.schema' is a cuttlefish
%% FUZZY mapping, so `listeners.admin_local.transport' is accepted and
%% reaches the inventory. Without this rejection an operator's `admin_local'
%% block would still be caught, just less clearly: `resolve_internal/4' calls
%% `assert_unique_name/2' against the inventory it is injected into, which
%% would report `duplicate_name' — true, but it does not tell the operator the
%% name is reserved rather than merely already used twice. Rejecting it here
%% produces that diagnosis directly.
%%
%% Called before `resolve_one/3' and before `assert_bind_free/2' so a
%% reserved-name violation is reported as such:
%% `admin_listener_cannot_be_disabled_test' fails with
%% `{unknown_service, admin_api}' when this runs after `resolve_services/3'.
assert_reserved(Name, Spec) ->
    Internal = lists:member(Name, ?RESERVED_INTERNAL),
    Reserved = lists:member(Name, ?RESERVED_NAMES),
    Disabled = maps:get(enabled, Spec, true) =:= false,
    if
        Internal -> invalid(Name, reserved_name);
        Reserved andalso Disabled -> invalid(Name, reserved_cannot_be_disabled);
        true -> ok
    end.

%% @private
%% `transport` selects a listener DRIVER, not merely a ranch transport module.
%% Every transport `?TRANSPORTS` admits is a ranch stream listener, so there is
%% one driver today; the indirection is what lets a transport with a different
%% lifecycle (its own listen process, its own option set) arrive without the
%% manager branching on transport itself.
driver(_) -> bondy_listener_ranch.

%% @private
%% `transport` and `protocol` validate independently above, against
%% `?TRANSPORTS` and `?PROTOCOLS`, so a value valid on each axis alone can
%% still name a combination nothing serves: `bridge_relay` is a connection
%% between two Bondy nodes, `schema/bondy_bridge_relay.schema` exposes only a
%% `tcp` and a `tls` listener block for it, and no suite binds one over a
%% Unix domain socket. Left unchecked, that pair resolves, binds, and only
%% fails on its first connection, inside `inet_utils:peername_to_binary/1`,
%% which has no clause for the raw `{local, <<>>}` peername
%% `bondy_bridge_relay_server:peername/2` stores unconverted. Refusing it here
%% instead names the listener and the reason at boot.
assert_transport_protocol(Name, uds, bridge_relay) ->
    invalid(Name, {unsupported_combination, uds, bridge_relay});
assert_transport_protocol(_Name, _Transport, _Protocol) ->
    ok.

%% @private
%% A listener that will not start is not checked at all. `enabled = off` has to
%% mean the listener does not participate: a disabled `tls` entry would otherwise
%% have to carry a certificate for a socket that never binds, and because
%% `resolve/2` fails the WHOLE inventory on the first bad entry, one such entry
%% takes the node down rather than itself. That is not a hypothetical — it is what
%% deleting the legacy mappings did to nine listeners across three shipped
%% templates, whose certificate paths had been coming from a schema default.
%%
%% Nothing is lost, only deferred: `enabled = on` is the same boot-time check, run
%% at the boot that enables the listener.
%% `disabling_a_listener_defers_the_tls_check_it_does_not_lose_it` pins exactly
%% that — the same spec passes disabled and is rejected enabled.
assert_tls_keys(_Name, _Transport, false, _GetFun) ->
    ok;
%% TLS material is only meaningful where the driver terminates TLS. Setting it
%% elsewhere is an error, not a no-op: an operator who wrote a certfile on a
%% plaintext listener believes that port is encrypted.
assert_tls_keys(Name, tls, true, GetFun) ->
    Missing = [
        K
     || K <- ?TLS_REQUIRED_KEYS, tls_material(Name, K, GetFun) =:= undefined
    ],
    case Missing of
        [] -> ok;
        [K | _] -> invalid(Name, {missing, [tls, K]})
    end;
assert_tls_keys(Name, Transport, true, GetFun) ->
    %% Every key of the `tls` block is scanned, not just the two a TLS listener
    %% requires: an operator who set `verify` or `versions` on a plaintext
    %% listener is as wrong as one who set a certificate. The error names the
    %% listener and its transport rather than the offending key --
    %% `tls_keys_on_plain_tcp_are_rejected_test` covers all three spellings.
    Set = [
        K
     || K <- ?TLS_KEYS, tls_material(Name, K, GetFun) =/= undefined
    ],
    case Set of
        [] -> ok;
        _ -> invalid(Name, {tls_not_supported, Transport})
    end.

%% @private
%% A listener declaring both `mcp' and `admin_api' is refused: mounting an
%% agent-driven surface on the socket that administers realms, users and
%% grants puts it one misconfiguration away from the wrong audience — the
%% same reasoning that keeps `admin_api' and `api_gateway' apart in Bondy's
%% own defaults, and MCP is its strongest case, since its whole purpose is to
%% let an autonomous agent choose which of the exposed operations to invoke.
%% Refusing the boot eliminates the failure mode rather than warning about
%% it; this is not a configuration an operator arrives at deliberately.
%% `mcp' alongside `api_gateway' is allowed: both are tenant-facing, and a
%% small deployment sharing one port is a legitimate choice.
%%
%% Runs on the service list, so it reports before `assert_tls_keys/4': a case
%% that declares both services in order to pin some LATER error will report
%% `{incompatible_services, mcp, admin_api}' instead.
assert_services_compatible(Name, Services) ->
    case
        lists:member(mcp, Services) andalso lists:member(admin_api, Services)
    of
        true -> invalid(Name, {incompatible_services, mcp, admin_api});
        false -> ok
    end.

%% @private
%% `services` is meaningful only for HTTP: it is HTTP's path multiplexing that
%% makes a LIST of reachable things possible. A raw socket carries exactly one
%% protocol, named by the `protocol` key, so a service list there is an error
%% rather than a silently ignored value.
%% An EMPTY list is the same error as an absent key, not a listener that serves
%% nothing: it bound a socket and answered 404 to every request, with no
%% diagnostic anywhere. `listeners.pub.services =` renders as `[]` — the
%% translation's `Split` fun drops empty tokens — so the two spellings of "this
%% listener names nothing to serve" report the same thing.
resolve_services(Name, http, Spec) ->
    case maps:find(services, Spec) of
        {ok, [_ | _] = Services} -> Services;
        _ -> invalid(Name, {missing, services})
    end;
resolve_services(Name, Protocol, Spec) ->
    case maps:is_key(services, Spec) of
        true -> invalid(Name, {services_not_supported, Protocol});
        false -> []
    end.

%% @private
%% Which module serves a carrier. One row per carrier, because a carrier owns a
%% path and a path is served by one handler — the functional dependency that
%% makes this a table of its own rather than a field on `service_spec/1`.
%%
%% Returns `undefined` rather than raising, so the caller can name the listener
%% and the service that asked for the carrier. The dispatch assembler used to
%% discover the same condition, as `{no_module_for_carrier, Carrier}`, at
%% listener start or during a dispatch rebuild — where no listener name is at
%% hand.
carrier_module(websocket) ->
    bondy_http_services;
carrier_module(sse) ->
    bondy_http_services;
carrier_module(longpoll) ->
    bondy_http_services;
%% Served by an application other than `bondy_router'. Only the atom is held
%% here: the call is resolved when a listener's dispatch table is assembled,
%% so no compile-time dependency on `bondy_mcp' exists.
carrier_module(mcp) ->
    bondy_mcp_http_service;
carrier_module(admin) ->
    bondy_http_services;
carrier_module(metrics) ->
    bondy_http_services;
carrier_module(api_gateway) ->
    bondy_http_services;
carrier_module(admin_api) ->
    bondy_http_services;
carrier_module(Other) ->
    case lists:keyfind(Other, 1, external_carriers()) of
        {Other, Module} -> Module;
        false -> undefined
    end.

%% @private
external_services() ->
    application:get_env(bondy_router, http_services, []).

%% @private
%% The carrier half of an extension's registration. Separate from
%% `http_services` because the two tables answer different questions: a service
%% says which carrier it rides, a carrier says which module serves it.
external_carriers() ->
    application:get_env(bondy_router, http_carriers, []).

%% @private
%% Groups `Services` by carrier, UNIONING the protocols of every service that
%% shares one: HTTP multiplexes on path, so `wamp_ws` and `bamp_ws` both mount
%% `/ws` and must resolve to a single `websocket` carrier entry carrying both
%% protocols rather than a second, unreachable route on the same path.
resolve_carriers(Name, Services, GetFun) ->
    lists:foldl(
        fun(Service, Acc) ->
            case service_spec(Service) of
                error ->
                    invalid(Name, {unknown_service, Service});
                #{carrier := Carrier, protocol := Protocol} ->
                    add_service(Name, Service, Carrier, Protocol, Acc, GetFun)
            end
        end,
        #{},
        Services
    ).

%% @private
%% `maps:find/2` rather than `maps:get/3` with a default: a `maps:get/3` default
%% is evaluated EAGERLY, so building the entry inline resolved the carrier's
%% whole configuration once per SERVICE and discarded it for every service but
%% the first. `carrier_config_is_resolved_once_per_carrier_test` counts the
%% reads through the `GetFun` and measured 2 for a two-service carrier.
add_service(Name, Service, Carrier, Protocol, Acc, GetFun) ->
    case maps:find(Carrier, Acc) of
        {ok, #{protocols := Protos} = Entry} ->
            Acc#{
                Carrier := Entry#{protocols := add_protocol(Protocol, Protos)}
            };
        error ->
            Acc#{
                Carrier => #{
                    module => module_for(Name, Service, Carrier),
                    protocols => add_protocol(Protocol, []),
                    config => resolve_carrier_config(Name, Carrier, GetFun)
                }
            }
    end.

%% @private
module_for(Name, Service, Carrier) ->
    case carrier_module(Carrier) of
        undefined -> invalid(Name, {unknown_carrier, Carrier, Service});
        Module -> Module
    end.

%% @private
add_protocol(undefined, Protos) ->
    Protos;
add_protocol(Protocol, Protos) ->
    case lists:member(Protocol, Protos) of
        true -> Protos;
        false -> [Protocol | Protos]
    end.

%% @private
%% Precedence has exactly two levels: the value the operator set on THIS
%% listener, otherwise `?CARRIER_DEFAULTS'. There is no global tier — the
%% `wamp.{websocket,sse,longpoll}.*' block that used to sit between them is
%% gone, and `?CARRIER_DEFAULTS' holds the values it rendered.
%%
%% The result is TOTAL over the carrier's keys — every one of them is present,
%% whether or not the operator named it — because the paths read are the leaves
%% of the default map itself.
%%
%% Resolved ONCE per listener rather than per connection, so the connection
%% handler performs no configuration lookup on the accept path.
resolve_carrier_config(Name, Carrier, GetFun) ->
    Defaults = carrier_defaults(Carrier),
    Config = lists:foldl(
        fun(Path, Acc) ->
            case GetFun([Name, Carrier | Path], undefined) of
                undefined -> Acc;
                Value -> put_path(Path, Value, Acc)
            end
        end,
        #{},
        leaf_paths(Defaults)
    ),
    Resolved = deep_merge(Defaults, Config),
    ok = assert_carrier_ping(Name, Carrier, Resolved),
    Resolved.

%% @private
%% A carrier's `ping' block cannot be INCOMPLETE: `resolve_carrier_config/3'
%% merges `?CARRIER_DEFAULTS' under the resolved values at the leaf, so every
%% sibling `maybe_enable_ping/2' reads is there whatever the operator wrote.
%% Only the type of `enabled' is still worth checking — `bondy.conf' cannot
%% render a non-boolean, but `sys.config' and an embedded caller can.
assert_carrier_ping(Name, Carrier, Config) ->
    case maps:find(ping, Config) of
        {ok, Ping} ->
            _ = assert_ping_enabled(Name, Carrier, Ping),
            ok;
        error ->
            ok
    end.

%% @private
%% The listener's OWN `ping' block, at `[Name, ping]' — a different thing from
%% a carrier's, and invisible to `resolve_carrier_config/3': it belongs to the
%% connection handler of a raw-socket or bridge-relay listener, so
%% `?CARRIER_DEFAULTS' does not describe it.
%%
%% Both handlers have the same shape as the carrier ones —
%% `bondy_wamp_tcp_connection_handler:maybe_enable_ping/2' and
%% `bondy_bridge_relay_server:maybe_enable_ping/2' each have a clause for
%% `enabled' true and fall through to "ping off" otherwise, and read their
%% siblings with `maps:get/2' once enabled — so the same gap has the same
%% consequence: an ENABLED block missing a sibling kills the first connection
%% rather than failing the boot.
%%
%% ONE list for both protocols: since the raw-socket handler stopped taking its
%% probe interval from the listener's own `idle_timeout', the two read the same
%% three keys and mean the same thing by them.
%%
%% `option_defaults/2' supplies all four keys, so an inventory that reached here
%% through `bondy_listener_manager:init/0' cannot fail this check. It stays
%% because that is not the only door: `resolve/2' is a public entry point, and a
%% caller passing a spec straight to it — every case in
%% `bondy_listener_config_test' does — bypasses `with_option_defaults/1' and can
%% still enable ping with the block half-written.
%%
%% Checked only for the two protocols whose handler reads the block. Nothing
%% reads `[Name, ping]' for an HTTP listener — a WebSocket's ping comes from
%% the `websocket' carrier config — so there is no crash to prevent there.
assert_listener_ping(Name, Protocol, GetFun) when
    Protocol =:= wamp_rawsocket; Protocol =:= bridge_relay
->
    case GetFun([Name, ping], undefined) of
        undefined ->
            ok;
        Block ->
            assert_ping_keys(
                Name,
                listener,
                [idle_timeout, timeout, max_attempts],
                key_value:to_map(Block)
            )
    end;
assert_listener_ping(_Name, _Protocol, _GetFun) ->
    ok.

%% @private
%% `enabled' itself is NOT required: every `maybe_enable_ping/2' treats its
%% absence as `false' (ping off), so an unstated `enabled' is a working
%% configuration and rejecting it would refuse a node that runs. Only the
%% siblings an ENABLED handler reads with `maps:get/2' are required — that read
%% is the one with no default left to fall back on.
%%
%% A PRESENT but non-boolean `enabled' is rejected here rather than left to the
%% handler, which also refuses it (`{invalid_ping_enabled, _}'): the handler runs
%% after the socket is accepted, so there the operator sees a listener that binds
%% and then kills every connection, while here they get the same boot-time error
%% as any other bad listener key. `bondy.conf' cannot produce one — the schema
%% datatype is `{flag, on, off}' — but `sys.config' and an embedded caller can.
assert_ping_keys(Name, Label, Siblings, Ping) ->
    Required =
        case assert_ping_enabled(Name, Label, Ping) of
            true -> Siblings;
            false -> []
        end,
    Missing = [K || K <- Required, not maps:is_key(K, Ping)],
    case Missing of
        [] -> ok;
        _ -> invalid(Name, {incomplete_ping, Label, Missing})
    end.

%% @private
%% Split out because a CARRIER needs this half and not the other: its block is
%% complete by construction, so `assert_carrier_ping/3' asks only whether
%% `enabled' is a boolean.
assert_ping_enabled(Name, Label, Ping) ->
    case maps:get(enabled, Ping, false) of
        true -> true;
        false -> false;
        Invalid -> invalid(Name, {invalid_ping_enabled, Label, Invalid})
    end.

%% @private
%% Every root-to-leaf path through a nested option map, in the form `put_path/3'
%% and a `get_fun()' take. Only a map is descended into, so a list-valued
%% setting is a leaf and not a block.
leaf_paths(Map) ->
    maps:fold(
        fun
            (Key, Value, Acc) when is_map(Value) ->
                Acc ++ [[Key | Path] || Path <- leaf_paths(Value)];
            (Key, _, Acc) ->
                Acc ++ [[Key]]
        end,
        [],
        Map
    ).

%% @private
%% Carrier keys are nested (`ping.enabled', `deflate_opts.level'), so the
%% resolved config is a nested map mirroring the key path.
put_path([Key], Value, Map) ->
    maps:put(Key, Value, Map);
put_path([Key | Rest], Value, Map) ->
    Inner = maps:get(Key, Map, #{}),
    maps:put(Key, put_path(Rest, Value, Inner), Map).

%% @private
%% A listener exposing `admin` or `metrics` defaults to loopback, matching the
%% present admin listeners. An explicit `ip` always wins.
%%
%% Returns a MAP to be merged into the resolved listener, so a listener that
%% configured no address and needs no narrowing carries no `ip` key at all
%% rather than a wildcard. That difference is load-bearing:
%% `bondy_config:normalise_socket_opts/1` is the only place an address and an
%% `ip_version` are reconciled, and it treats an absent address as `any`, which
%% it resolves to the wildcard OF THE CONFIGURED FAMILY. A `{0,0,0,0}` invented
%% here instead would reach the socket options after that reconciliation and
%% contradict it — `gen_tcp:listen(0, [inet6, {ip, {0,0,0,0}}])` raises
%% `badarg`, verified directly, and both
%% `ipv6_listener_binds_without_an_explicit_ip` and
%% `explicit_ipv6_binds_without_an_ip_version` in `bondy_listener_SUITE` bind a
%% real socket over this.
resolve_ip(Name, Services, Spec) ->
    case maps:find(ip, Spec) of
        {ok, Ip} ->
            #{ip => to_address(Name, Ip)};
        error ->
            Privileged = [S || S <- Services, S =:= admin orelse S =:= metrics],
            case Privileged of
                [] -> #{};
                _ -> #{ip => {127, 0, 0, 1}}
            end
    end.

%% @private
%% Both sources of an inventory converge here. From `bondy.conf` an `ip` arrives
%% already parsed, as an address tuple, because the schema's translation calls
%% `inet:parse_address/1` — a name is refused while the file is read. From
%% application environment (`sys.config`, or a caller building the inventory
%% itself) it may be a STRING, and a string may be a name, which is why the
%% resolving clause below exists.
%%
%% A literal is parsed before anything is resolved. `inet:getaddr/2` on a
%% resolver holding a wildcard record can answer a lookup for a literal with a
%% different address, so trying DNS first would silently move a listener.
%%
%% A tuple is checked with `inet:ntoa/1` rather than accepted on `is_tuple/1`
%% alone: verified directly, `inet:ntoa/1` answers `{error, einval}` for
%% `{1,2,3}` (wrong arity), `{256,0,0,0}` and `{-1,0,0,0}` (out-of-range
%% elements), and a string for every valid v4/v6 tuple. `gen_tcp:listen/2`
%% would not accept those tuples either, so this rejects them as a
%% configuration error instead of handing them to the driver.
%%
%% The final clause exists because `unicode:characters_to_list/1` raises
%% `badarg` on anything that is neither a tuple nor a string/binary — an atom
%% such as `any`, say — and `catching/1` only catches
%% `throw:{invalid_listener, _, _}`, so an unconverted value would otherwise
%% surface as an opaque boot crash rather than a named configuration error.
to_address(Name, Ip) when is_tuple(Ip) ->
    case inet:ntoa(Ip) of
        {error, einval} -> invalid(Name, {invalid_ip, Ip});
        _ -> Ip
    end;
to_address(Name, Ip0) when is_list(Ip0); is_binary(Ip0) ->
    Ip = unicode:characters_to_list(Ip0),
    case inet:parse_address(Ip) of
        {ok, Address} ->
            Address;
        {error, einval} ->
            %% `inet` before `inet6`, so a name holding both records resolves to
            %% its v4 address.
            case inet:getaddr(Ip, inet) of
                {ok, Address} ->
                    Address;
                {error, _} ->
                    case inet:getaddr(Ip, inet6) of
                        {ok, Address} ->
                            Address;
                        {error, Reason} ->
                            invalid(Name, {unresolvable_ip, Ip0, Reason})
                    end
            end
    end;
to_address(Name, Ip) ->
    invalid(Name, {invalid_ip, Ip}).

%% @private
resolve_bind(Name, uds, Spec) ->
    case maps:find(path, Spec) of
        {ok, Path} -> {path, Path};
        error -> invalid(Name, {missing, path})
    end;
resolve_bind(Name, _Transport, Spec) ->
    case maps:find(port, Spec) of
        {ok, Port} -> {port, Port};
        error -> invalid(Name, {missing, port})
    end.

%% @private
assert_unique_name(Name, Seen) ->
    lists:keymember(Name, 1, Seen) andalso invalid(Name, duplicate_name),
    ok.

%% @private
%% Checked on the RESOLVED listener rather than on the spec, so what is compared
%% is what it will actually bind: `resolve_bind/3` reads `path` for a uds
%% listener and `port` for every other transport, and a spec carrying both would
%% otherwise be checked on the key that is ignored.
%%
%% Paths are compared as well as ports. Two listeners on one path do not race
%% like two on one port: `bondy_listener_ranch:maybe_unlink_socket/1` deletes
%% the socket node before binding, so the second listener SUCCEEDS, silently
%% taking over the path while the first keeps an unreachable listen socket. No
%% error is reported by anything at runtime, which is why it is refused here.
assert_bind_free(#{bind := {port, 0}}, _Seen) ->
    %% Port 0 delegates the choice to the OS, so any number of listeners may ask
    %% for it without colliding. Exempting the newcomer alone is enough: an
    %% incumbent on port 0 is only reachable by `clashes/2` from a newcomer that
    %% also asked for 0, and that one never gets there.
    ok;
assert_bind_free(#{name := Name, bind := Bind} = Listener, Seen) ->
    case [Other || {Other, L} <- Seen, clashes(Listener, L)] of
        [] -> ok;
        [Other | _] -> invalid(Name, bind_clash(Bind, Other))
    end.

%% @private
%% A `path` bind is compared on the path ALONE, because a uds socket node has no
%% address and an `ip` on either listener says nothing about whether the two
%% collide. Two clauses rather than one address-aware comparison so that stays
%% true by construction; `a_path_clash_ignores_the_address_test` is what fails if
%% they are folded together.
clashes(#{bind := {path, Path}}, #{bind := {path, Path}}) ->
    true;
clashes(#{bind := {port, Port}} = A, #{bind := {port, Port}} = B) ->
    %% `resolve_ip/3` leaves `ip` ABSENT when none was configured and none
    %% derived, and `bondy_config:normalise_socket_opts/1` binds that to the
    %% wildcard of the configured family — hence `any`.
    overlaps(maps:get(ip, A, any), maps:get(ip, B, any));
clashes(_, _) ->
    false.

%% @private
%% The OS's uniqueness domain for a stream socket is (address, port) and not
%% port: two listens on distinct literal addresses of one port both succeed,
%% while a wildcard listen excludes every address on that port. Measured on
%% darwin 25.5 / OTP 28.5 — `127.0.0.1` and `::1` share a port in either order,
%% and repeating either address answers `eaddrinuse`;
%% `bondy_listener_SUITE:one_port_two_addresses` binds the accepted pair.
%%
%% Families are NOT distinguished, so this is conservative rather than exact:
%% `{127,0,0,1}` against a `::` wildcard is reported as a clash though
%% `bindv6only` decides whether it really is one, and so is a pair with no
%% address that differs only in `ip_version`. Both would otherwise reach the
%% driver, so the trade is a named configuration error for a possible
%% `eaddrinuse` at bind time.
overlaps(A, B) ->
    wildcard(A) orelse wildcard(B) orelse A =:= B.

%% @private
%% Every spelling of "any address of this family", including the one an operator
%% writes out rather than omitting.
wildcard(any) -> true;
wildcard({0, 0, 0, 0}) -> true;
wildcard({0, 0, 0, 0, 0, 0, 0, 0}) -> true;
wildcard(_) -> false.

%% @private
bind_clash({port, _}, Other) -> {port_in_use_by, Other};
bind_clash({path, _}, Other) -> {path_in_use_by, Other}.

%% @private
required(Name, Key, Spec) ->
    case maps:find(Key, Spec) of
        {ok, Value} -> Value;
        error -> invalid(Name, {missing, Key})
    end.

%% @private
-spec invalid(atom(), term()) -> no_return().

invalid(Name, Detail) ->
    throw({invalid_listener, Name, Detail}).
