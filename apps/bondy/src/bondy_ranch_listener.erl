%% =============================================================================
%%  bondy_ranch_listener.erl -
%%
%%  Copyright (c) 2016-2023 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================
%% -----------------------------------------------------------------------------
%% @doc This module encapsulates several operations on the ranch library and it
%% is used by all other modules to setup and manage TCP and TLS listeners.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_ranch_listener).

-include_lib("kernel/include/logger.hrl").

-export([connections/1]).
-export([resume/1]).
-export([start/3]).
-export([stop/1]).
-export([suspend/1]).
-export([transport_opts/1]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Conditionally starts a listener with reference `Ref'.
%% References for each listener is defined by the bondy.schema file.
%% @end
%% -----------------------------------------------------------------------------
-spec start(
    Ref :: ranch:ranch_ref(), Protocol :: module(), ProtocolOpts :: any()) -> ok.

start(Ref, Protocol, ProtocolOpts) ->
    case bondy_config:get([Ref, enabled], true) of
        true ->
            Transport = ref_to_transport(Ref),
            TransportOpts = transport_opts(Ref),


            {ok, _} = ranch:start_listener(
                Ref,
                Transport,
                TransportOpts,
                Protocol,
                ProtocolOpts
            ),
            ?LOG_NOTICE(#{
                description => "Started TCP listener",
                listener => Ref,
                transport => Transport,
                transport_opts => TransportOpts,
                protocol => Protocol
            }),

            ok;
        false ->
            ok
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec stop(Ref :: ranch:ranch_ref()) -> ok.

stop(Ref) ->
    catch ranch:stop_listener(Ref),
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec suspend(Ref :: ranch:ranch_ref()) -> ok.

suspend(Ref) ->
    catch ranch:suspend_listener(Ref),
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec resume(Ref :: ranch:ranch_ref()) -> ok.

resume(Ref) ->
    catch ranch:resume_listener(Ref),
    ok.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
connections(Ref) ->
    ranch:procs(Ref, connections).




%% -----------------------------------------------------------------------------
%% @doc Returns the transport and transport options to be used with listener
%% `Ref'.
%%
%% The definition of the listeners in bondy.schema MUST match this structure.
%% - Ref
%%     - ip
%%     - port
%%     - acceptors_pool_size
%%     - max_connections
%%     - backlog
%%     - max_connections
%%     - max_connections
%%     - socket_opts
%%            - keepalive
%%            - nodelay
%%            - sndbuf
%%            - recbuf
%%            - buffer
%%            - certfile (TLS)
%%            - keyfile (TLS)
%%            - keyfile (TLS)
%%            - versions (TLS)
%% @end
%% -----------------------------------------------------------------------------

transport_opts(Ref) ->
    Opts = bondy_config:get(Ref),
    Port = key_value:get(port, Opts),
    IPVersion = key_value:get(ip_version, Opts, inet),
    IP = key_value:get(ip, Opts, hostname),
    IPAddress = bondy_utils:get_ipaddr(IP, IPVersion),
    PoolSize = key_value:get(acceptors_pool_size, Opts),
    MaxConnections = key_value:get(max_connections, Opts),

    %% In ranch 2.0 we will need to use socket_opts directly
    SocketOpts = normalise(key_value:get(socket_opts, Opts, [])),

    TLSOpts = key_value:get(tls_opts, Opts, []),

    #{
        num_acceptors => PoolSize,
        max_connections => MaxConnections,
        socket_opts => [
            IPVersion,
            {ip, IPAddress},
            {port, Port} | SocketOpts ++ TLSOpts
        ]
    }.



%% =============================================================================
%% PRIVATE
%% =============================================================================




%% @private
%% These MUST match the listener names defined in bondy.schema
ref_to_transport(bridge_relay_tcp) -> ranch_tcp;
ref_to_transport(bridge_relay_tls) -> ranch_ssl;
ref_to_transport(wamp_tcp) -> ranch_tcp;
ref_to_transport(wamp_tls) -> ranch_ssl.


%% @private
normalise([]) ->
    [];

normalise(Opts) ->
    Sndbuf = lists:keyfind(sndbuf, 1, Opts),
    Recbuf = lists:keyfind(recbuf, 1, Opts),

    case Sndbuf =/= false andalso Recbuf =/= false of
        true ->
            Buffer0 = lists:keyfind(buffer, 1, Opts),
            Buffer1 = max(Buffer0, max(Sndbuf, Recbuf)),
            lists:keystore(buffer, 1, Opts, {buffer, Buffer1});
        false ->
            Opts
    end.
