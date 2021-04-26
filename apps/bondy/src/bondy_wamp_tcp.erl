%% =============================================================================
%%  bondy_wamp_tcp.erl -
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

-module(bondy_wamp_tcp).

-define(WAMP_TCP, wamp_tcp).
-define(WAMP_TLS, wamp_tls).

-export([connections/0]).
-export([resume_listeners/0]).
-export([start_listeners/0]).
-export([stop_listeners/0]).
-export([suspend_listeners/0]).
-export([tcp_connections/0]).
-export([tls_connections/0]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% Starts the tcp and tls raw socket listeners
%% @end
%% -----------------------------------------------------------------------------
-spec start_listeners() -> ok.

start_listeners() ->
    ok = maybe_start_listener(?WAMP_TCP),
    maybe_start_listener(?WAMP_TLS).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec stop_listeners() -> ok.

stop_listeners() ->
    catch ranch:stop_listener(?WAMP_TCP),
    catch ranch:stop_listener(?WAMP_TLS),
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec suspend_listeners() -> ok.

suspend_listeners() ->
    catch ranch:suspend_listener(?WAMP_TCP),
    catch ranch:suspend_listener(?WAMP_TLS),
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec resume_listeners() -> ok.

resume_listeners() ->
    catch ranch:resume_listener(?WAMP_TCP),
    catch ranch:resume_listener(?WAMP_TLS),
    ok.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
connections() ->
    tls_connections() ++ tcp_connections().


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
tls_connections() ->
    ranch:procs(?WAMP_TLS, connections).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
tcp_connections() ->
    ranch:procs(?WAMP_TCP, connections).




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
maybe_start_listener(Name) ->
    case bondy_config:get([Name, enabled], true) of
        true ->
            {ok, _} = ranch:start_listener(
                Name,
                listener_to_transport(Name),
                transport_opts(Name),
                bondy_wamp_tcp_connection_handler,
                []
            ),
            %% _ = ranch:set_max_connections(H, MaxConns),
            ok;
        false ->
            ok
    end.


%% @private
listener_to_transport(?WAMP_TCP) -> ranch_tcp;
listener_to_transport(?WAMP_TLS) -> ranch_ssl.


%% @private
transport_opts(Name) ->
    Opts = bondy_config:get(Name),
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
