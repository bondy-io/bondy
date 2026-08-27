%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_listener_ranch).

-moduledoc """
Listener driver for the ranch stream transports: `tcp`, `tls` and `uds`.

An HTTP listener is started through Cowboy (`start_clear/3` for a plaintext
socket, `start_tls/3` for a TLS one — they differ only in the ranch transport
module); a raw-socket or bridge-relay listener is started through
`ranch:start_listener/5` with the protocol's own connection handler.

A Unix-domain listener is a `gen_tcp` stream socket bound to `{local, Path}`
rather than a host and port, so it uses the same driver with a different listen
address. Its socket is a filesystem object, so the bind path is prepared first:
a socket file left by a previous run makes `gen_tcp:listen/2` fail with
`eaddrinuse`, and a missing parent directory makes it fail with `enoent`.
""".

-behaviour(bondy_listener).

-include_lib("kernel/include/logger.hrl").

-export([start/1]).
-export([stop/1]).
-export([suspend/1]).
-export([resume/1]).
-export([connections/1]).
-export([recompile_dispatch/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Compiles `Listener`'s Cowboy dispatch table and publishes it to the
`persistent_term` its protocol options point at.

Called on the start path and again by `bondy_http_gateway` whenever an API
Gateway specification changes: a running listener reads its table through
`{persistent_term, Key}`, so replacing the stored value is what makes new routes
live without restarting it.
""".
-spec recompile_dispatch(bondy_listener_config:t()) -> ok.

recompile_dispatch(#{name := Name} = L) ->
    Routes = bondy_http_services:dispatch(L),
    _ = persistent_term:put(dispatch_key(Name), cowboy_router:compile(Routes)),
    ok.

%% =============================================================================
%% bondy_listener CALLBACKS
%% =============================================================================

start(#{enabled := false, name := Name}) ->
    ?LOG_NOTICE(#{
        description => "Listener disabled by configuration, not starting",
        listener => Name
    }),
    ok;
start(#{protocol := http} = L) ->
    start_http(L);
start(L) ->
    start_stream(L).

stop(#{protocol := http, name := Name} = L) ->
    try
        cowboy:stop_listener(Name)
    catch
        _:_ -> ok
    end,
    ok = bondy_http_security_headers:cleanup(Name),
    %% Symmetric with `start_http/1`: an HTTP listener bound to a Unix domain
    %% socket must not leave its socket file behind.
    ok = maybe_unlink_socket(L),
    ok;
stop(#{name := Name} = L) ->
    try
        ranch:stop_listener(Name)
    catch
        _:_ -> ok
    end,
    ok = maybe_unlink_socket(L),
    ok.

suspend(#{name := Name}) ->
    try
        ranch:suspend_listener(Name)
    catch
        _:_ -> ok
    end,
    ok.

resume(#{name := Name}) ->
    try
        ranch:resume_listener(Name)
    catch
        _:_ -> ok
    end,
    ok.

connections(#{name := Name}) ->
    try
        ranch:procs(Name, connections)
    catch
        _:_ -> []
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
start_http(#{name := Name, transport := Transport} = L) ->
    %% An HTTP listener can bind a Unix domain socket too — the resolver does
    %% not forbid `transport => uds` with `protocol => http`, and Cowboy
    %% reaches `ranch:start_listener/5` on the same `{local, Path}` socket —
    %% so the bind path has to be prepared here as well, not only on the
    %% stream path.
    ok = maybe_prepare_socket(L),
    %% `[Name, http_versions]' is total for an HTTP listener:
    %% `bondy_listener_config:protocol_option_defaults(http)' seats it and
    %% `with_option_defaults/1' runs on every inventory entry, so a bare read
    %% raising `badkey' is the wanted failure if that stops being true.
    Versions = bondy_config:get([Name, http_versions]),
    TransportOpts = with_http_versions(
        Transport, Versions, transport_opts(L)
    ),
    %% Both write a `persistent_term` the running listener reads on every
    %% request, and both must be in place before it can accept one.
    %% `protocol_opts/1` only points Cowboy at the dispatch key, so these are
    %% here — where the ordering against `cowboy:start_*` is visible — rather
    %% than hidden inside an options builder.
    ok = recompile_dispatch(L),
    ok = bondy_http_security_headers:init(Name),
    ProtoOpts = (protocol_opts(L))#{
        %% Gates Cowboy's HTTP/2 prior-knowledge and Upgrade paths on a
        %% plaintext socket (`cowboy_http.erl:531', `:985'); harmless on TLS,
        %% where ALPN decides first.
        protocols => Versions,
        %% `cowboy_tls' routes EVERY non-`h2' ALPN outcome through this —
        %% a negotiated `http/1.1' included, not just an absent ALPN
        %% extension (`cowboy_tls.erl:38-46'). So this must be the HTTP/1.1
        %% codec whenever the listener offers 1.1 at all; `hd(Versions)'
        %% here put h2-first listeners' 1.1 clients into `cowboy_http2'
        %% (caught live by `bondy_connect_conformance_SUITE''s wss group).
        %% An h2-only listener keeps `http2': RFC 7540 §3.3 requires ALPN
        %% for h2 over TLS, so a client landing here is not an h2 client
        %% and refusing it is that configuration's meaning.
        alpn_default_protocol =>
            case lists:member(http, Versions) of
                true -> http;
                false -> http2
            end
    },
    LogMeta = #{
        listener => Name,
        transport => Transport,
        transport_opts => TransportOpts,
        protocol_opts => maps:without([env], ProtoOpts)
    },
    Result =
        case Transport of
            tls -> cowboy:start_tls(Name, TransportOpts, ProtoOpts);
            _ -> cowboy:start_clear(Name, TransportOpts, ProtoOpts)
        end,
    case log_result(Result, LogMeta) of
        ok -> maybe_protect_socket(L);
        {error, _} = Error -> Error
    end.

%% @private
start_stream(#{name := Name, transport := Transport} = L) ->
    ok = maybe_prepare_socket(L),
    Module = ranch_transport(Transport),
    TransportOpts = transport_opts(L),
    Protocol = maps:get(protocol, L),
    Handler = connection_handler(Protocol),
    ProtocolOpts = stream_protocol_opts(Protocol, Name),
    Result = ranch:start_listener(
        Name, Module, TransportOpts, Handler, ProtocolOpts
    ),
    LogMeta = #{
        listener => Name,
        transport => Transport,
        transport_opts => TransportOpts,
        protocol => Handler
    },
    case log_result(Result, LogMeta) of
        ok -> maybe_protect_socket(L);
        {error, _} = Error -> Error
    end.

%% @private
ranch_transport(tls) -> ranch_ssl;
ranch_transport(_) -> ranch_tcp.

%% @private
%% Options handed to the connection handler: the listener's whole resolved option
%% block, read ONCE here at listener start rather than once per connection.
%%
%% One clause for both stream protocols. `bondy_bridge_relay_server:init/1' has
%% always read `auth_timeout', `idle_timeout', `hibernate' and `ping' out of
%% these; `bondy_wamp_tcp_connection_handler:init/1' used to ignore them and read
%% `[Ref, idle_timeout]' and `[Ref, ping]' from application environment itself, on
%% every accepted connection. Both now take the same two things from the same
%% place, which is also where the HTTP carriers get theirs — see
%% `bondy_http_services:carrier_state/2'.
stream_protocol_opts(_Protocol, Name) -> bondy_config:get(Name, []).

%% @private
connection_handler(wamp_rawsocket) -> bondy_wamp_tcp_connection_handler;
connection_handler(bridge_relay) -> bondy_bridge_relay_server.

%% @private
%% Carries over the two behaviours of the now-deleted
%% `bondy_http_gateway:listener_transport_opts/1`: the connection alarms and the
%% reuseport listen-socket fan-out.
%% `num_acceptors`, `max_connections` and `socket_opts` are read here and below
%% WITHOUT a default. `bondy_config:listener_transport_opts/2` merges
%% `?DEFAULT_TRANSPORT_OPTS` and writes `socket_opts` back unconditionally, so
%% all three are present in everything this function is handed, and a default
%% would be both unreachable and a second copy of a value `bondy_config` owns.
%% `key_value:get/2` raises `badkey`, which is the wanted failure if that ever
%% stops being true. `reuseport` is an operator socket option and genuinely may
%% be absent, so that one keeps its default.
transport_opts(#{name := Name, bind := Bind} = L) ->
    %% The listener's resolved address goes in through
    %% `listener_transport_opts/2`, which folds it into `socket_opts` before
    %% normalisation, so that the address and `ip_version` are reconciled in one
    %% place. `with_bind/2` below therefore only ever writes the bind TARGET.
    Opts0 = bondy_config:listener_transport_opts(
        Name, maps:get(ip, L, undefined)
    ),
    Opts1 = with_bind(Bind, Opts0),
    MaxConnections = key_value:get(max_connections, Opts1),
    Opts2 = Opts1#{alarms => alarms(MaxConnections)},
    maybe_reuseport(Opts2).

%% @private
with_bind({path, Path}, Opts) ->
    %% Merge rather than replace: `backlog`, `keepalive`, `nodelay`, `sndbuf`,
    %% `recbuf`, `buffer` and `reuseport` are generic stream-socket options and
    %% are just as meaningful on a Unix domain socket, so an operator who set
    %% them must not have them silently dropped. A UDS listener has no port,
    %% but ranch still requires the key.
    %%
    %% This is the one bind target that DOES replace `ip`: the listen address of
    %% a Unix domain socket is its path, so whatever address the listener
    %% resolved to is not a bind target here. The bare `inet`/`inet6` family
    %% atom that `bondy_config:normalise_socket_opts/1` always prepends is
    %% dropped with it: a Unix domain socket is family-less (`AF_UNIX`), and
    %% combining that atom with `{ip, {local, Path}}` makes `gen_tcp:listen/2`
    %% raise `badarg` (verified directly).
    SocketOpts0 = key_value:get(socket_opts, Opts),
    SocketOpts1 = lists:delete(inet, lists:delete(inet6, SocketOpts0)),
    SocketOpts2 = lists:keystore(ip, 1, SocketOpts1, {ip, {local, Path}}),
    SocketOpts = lists:keystore(port, 1, SocketOpts2, {port, 0}),
    key_value:put(socket_opts, SocketOpts, Opts);
with_bind({port, Port}, Opts) ->
    SocketOpts = key_value:get(socket_opts, Opts),
    key_value:put(
        socket_opts, lists:keystore(port, 1, SocketOpts, {port, Port}), Opts
    ).

%% @private
%% One row per threshold. The alarm names are spelled out rather than built from
%% the percentage: they reach the operator through ranch's alarm callback and the
%% log, so they have to be greppable here.
%%
%% `?LOG/2` rather than `?LOG_WARNING`/`?LOG_ALERT` because the level is a
%% variable; it expands to the same `logger:log/2` call and carries the same
%% location metadata.
-define(CONNECTION_ALARMS, [
    {num_connections_75, 75, warning},
    {num_connections_90, 90, alert}
]).

alarms(infinity) ->
    #{};
alarms(MaxConnections) ->
    maps:from_list([
        {Alarm, #{
            type => num_connections,
            threshold => trunc(MaxConnections * Percent / 100),
            cooldown => timer:seconds(5),
            callback => fun(LName, AlarmName, _SupPid, Pids) ->
                ?LOG(Level, #{
                    description => "Connection threshold exceeded",
                    threshold_percent => Percent,
                    listener => LName,
                    alarm_name => AlarmName,
                    connections => length(Pids)
                })
            end
        }}
     || {Alarm, Percent, Level} <- ?CONNECTION_ALARMS
    ]).

%% @private
%% Server ALPN preference from the listener's `http.versions', in the
%% operator's order. APPENDED to `socket_opts': `cowboy:start_tls/3' PREPENDS
%% its own `{alpn_preferred_protocols, [<<"h2">>, <<"http/1.1">>]}'
%% (`cowboy.erl:161'), and OTP ssl takes the LAST occurrence of a duplicate
%% option (`ssl_config:process_options/3' reverses the list precisely so
%% "we get the last set option if set twice, users depend on it") — so the
%% appended entry is the one that binds. Only a TLS socket negotiates ALPN;
%% a clear listener's HTTP/2 gate is the `protocols' Cowboy option instead.
with_http_versions(tls, Versions, Opts) ->
    SocketOpts = key_value:get(socket_opts, Opts),
    Alpn = {alpn_preferred_protocols, [alpn_name(V) || V <- Versions]},
    key_value:put(socket_opts, SocketOpts ++ [Alpn], Opts);
with_http_versions(_, _, Opts) ->
    Opts.

%% @private
alpn_name(http) -> <<"http/1.1">>;
alpn_name(http2) -> <<"h2">>.

%% @private
maybe_reuseport(Opts) ->
    SocketOpts = key_value:get(socket_opts, Opts),
    case key_value:get(reuseport, SocketOpts, false) of
        true ->
            %% 15 acceptors per listen socket with at least 1 per scheduler
            NumAcceptors = key_value:get(num_acceptors, Opts),
            Schedulers = erlang:system_info(schedulers),
            Opts#{
                num_listen_sockets =>
                    max(Schedulers, trunc(NumAcceptors / 15))
            };
        false ->
            Opts
    end.

%% @private
protocol_opts(#{name := Name}) ->
    Opts = bondy_config:listener_protocol_opts(Name),
    Opts#{
        env => #{
            bondy => #{auth => #{schemes => [basic, bearer]}},
            dispatch => {persistent_term, dispatch_key(Name)}
        },
        metrics_callback => fun bondy_telemetry:http_request/1,
        %% cowboy_metrics_h must be first on the list
        stream_handlers => [
            cowboy_metrics_h, cowboy_compress_h, cowboy_stream_h
        ],
        middlewares => [cowboy_router, cowboy_handler],
        hibernate => true
    }.

%% @private
dispatch_key(Name) -> {bondy_http_gateway, dispatch, Name}.

%% @private
%% Only the start paths call this; `stop/1` unlinks without creating anything.
maybe_prepare_socket(#{bind := {path, Path}} = L) ->
    ok = maybe_create_socket_dir(Path),
    maybe_unlink_socket(L);
maybe_prepare_socket(L) ->
    maybe_unlink_socket(L).

%% @private
%% `gen_tcp:listen/2` returns `{error, enoent}` when a `{local, Path}` bind's
%% parent directory is missing — verified with
%% `gen_tcp:listen(0, [{ip, {local, "./nosuchdir/x.sock"}}])`. Creating the
%% directory removes that failure instead of reporting it, which is what a
%% listener whose path comes from `platform_tmp_dir` needs: the directory is
%% part of the release layout, not something an operator hands over per
%% listener. `filelib:ensure_dir/1` creates the PARENT of the path it is given,
%% hence the socket path itself.
%%
%% The 0700 applies ONLY to a directory this call created, and only to the
%% innermost one (`ensure_dir/1` may create several). A directory that already
%% existed is left alone: `platform_tmp_dir` may legitimately be a shared
%% location such as `/tmp`, and narrowing that would break every other user of
%% it.
%%
%% Neither result is asserted. A directory that cannot be created or tightened
%% makes the bind fail, and `log_result/2` turns that into the `{error, Reason}`
%% the caller acts on — for `admin_local` that is
%% `bondy_app`'s `ok ?= start_early_listeners()`, since it is an `early`
%% listener — whereas a raise here could not be caught there.
maybe_create_socket_dir(Path) ->
    Dir = filename:dirname(Path),
    case filelib:is_dir(Dir) of
        true ->
            ok;
        false ->
            _ = filelib:ensure_dir(Path),
            _ = file:change_mode(Dir, 8#700),
            ok
    end.

%% @private
%% The socket file's mode is the only access control a Unix domain listener has:
%% there is no peer address to filter on and nothing is exchanged before the
%% handler runs. `admin_local` carries this node's Admin API, is injected rather
%% than configured, and has no key an operator could use to widen or narrow it,
%% so its socket is narrowed to its owner here.
%%
%% Scoped to that ONE listener by name, not to every `uds` bind. An operator's
%% own Unix domain listener — `wamp_uds`, or any `listeners.$name.transport =
%% uds` — takes the process umask, which is what a sidecar running under a
%% different uid connects through, and there is no key to opt out of a
%% narrowing applied to it.
%%
%% Applied after the bind because `gen_tcp:listen/2` creates the socket node
%% itself, with the process umask — 0755 was measured here, but a container
%% entrypoint with a umask of 0 yields 0777, which is connectable by any local
%% uid.
%%
%% That the mode is ENFORCED at connect time was verified on this platform
%% rather than assumed: a socket set to 0000 refuses its own owner with
%% `{error, eacces}`, and the same socket at 0600 accepts it.
%%
%% A failure to narrow it fails the listener start. Continuing would leave the
%% Admin API reachable by every local uid, which is the condition this exists to
%% prevent, and a silently unprotected control socket is worse than a node that
%% refuses to start.
maybe_protect_socket(#{name := admin_local, bind := {path, Path}}) ->
    case file:change_mode(Path, 8#600) of
        ok ->
            ok;
        {error, Reason} = Error ->
            ?LOG_ERROR(#{
                description =>
                    "Could not restrict the permissions of the internal admin "
                    "listener's Unix domain socket; refusing to serve on it.",
                listener => admin_local,
                path => Path,
                reason => Reason
            }),
            Error
    end;
maybe_protect_socket(_) ->
    ok.

%% @private
maybe_unlink_socket(#{name := Name, bind := {path, Path}}) ->
    case file:delete(Path) of
        ok ->
            ok;
        {error, enoent} ->
            ok;
        {error, Reason} ->
            ?LOG_WARNING(#{
                description => "Could not remove stale Unix domain socket file",
                listener => Name,
                path => Path,
                reason => Reason
            }),
            ok
    end;
maybe_unlink_socket(_) ->
    ok.

%% @private
log_result({ok, _}, LogMeta) ->
    ?LOG_NOTICE(LogMeta#{description => "Started listener"}),
    ok;
log_result({error, eaddrinuse = Reason} = Error, LogMeta) ->
    ?LOG_ERROR(LogMeta#{
        description => "Failed to start listener, address already in use",
        reason => Reason
    }),
    Error;
log_result({error, Reason} = Error, LogMeta) ->
    ?LOG_ERROR(LogMeta#{
        description => "Failed to start listener", reason => Reason
    }),
    Error.
