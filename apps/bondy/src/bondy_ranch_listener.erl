%% =============================================================================
%%  bondy_ranch_listener.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
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
%% @doc Conditionally starts a listener wirth reference `Ref'.
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
                description => "Starting listener",
                ref => Ref,
                transport => Transport,
                transport_opts => TransportOpts,
                protocol => Protocol,
                protocol_opts => ProtocolOpts
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
%% @doc Returns the transport and transport options to be used wirh listener
%% `Ref'.
%%
%% The definition of the listeners in bondy.schema MUST match this structure.
%% - Ref
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
    {_, Port} = lists:keyfind(port, 1, Opts),
    {_, PoolSize} = lists:keyfind(acceptors_pool_size, 1, Opts),
    {_, MaxConnections} = lists:keyfind(max_connections, 1, Opts),

    %% In ranch 2.0 we will need to use socket_opts directly
    SocketOpts = case lists:keyfind(socket_opts, 1, Opts) of
        {socket_opts, L} -> normalise(L);
        false -> []
    end,

    #{
        num_acceptors => PoolSize,
        max_connections => MaxConnections,
        socket_opts => [{port, Port} | SocketOpts]
    }.

%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
%% These MUST match the listener names defined in bondy.schema
ref_to_transport(edge_tcp) -> ranch_tcp;
ref_to_transport(edge_tls) -> ranch_ssl;
ref_to_transport(wamp_tcp) -> ranch_tcp;
ref_to_transport(wamp_tls) -> ranch_ssl.


%% @private
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
