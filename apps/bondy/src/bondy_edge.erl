%% =============================================================================
%%  bondy_edge_listener.erl -
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

-module(bondy_edge).


-define(TCP, edge_tcp).
-define(TLS, edge_tls).


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
    Protocol = bondy_edge_uplink_server,
    ProtocolOpts = [],
    ok = bondy_ranch_listener:start(?TCP, Protocol, ProtocolOpts),
    bondy_ranch_listener:start(?TLS, Protocol, ProtocolOpts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec stop_listeners() -> ok.

stop_listeners() ->
    ok = bondy_ranch_listener:stop(?TCP),
    bondy_ranch_listener:stop(?TLS).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec suspend_listeners() -> ok.

suspend_listeners() ->
    ok = bondy_ranch_listener:suspend(?TCP),
    bondy_ranch_listener:suspend(?TLS).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec resume_listeners() -> ok.

resume_listeners() ->
    bondy_ranch_listener:resume(?TCP),
    bondy_ranch_listener:resume(?TLS).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
connections() ->
    bondy_ranch_listener:connections(?TCP)
        ++ bondy_ranch_listener:connections(?TLS).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
tls_connections() ->
    bondy_ranch_listener:connections(?TLS).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
tcp_connections() ->
    bondy_ranch_listener:connections(?TCP).