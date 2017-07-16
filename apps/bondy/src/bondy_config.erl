%% =============================================================================
%%  bondy_config.erl -
%% 
%%  Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
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


%% =============================================================================
%% @doc
%%
%% @end
%% =============================================================================
-module(bondy_config).

-define(APP, bondy).
-define(DEFAULT_RESOURCE_SIZE, erlang:system_info(schedulers)).
-define(DEFAULT_RESOURCE_CAPACITY, 10000). % max messages in process queue
-define(DEFAULT_POOL_TYPE, transient).

-export([priv_dir/0]).
-export([automatically_create_realms/0]).
-export([connection_lifetime/0]).
-export([coordinator_timeout/0]).
-export([api_gateway/0]).
-export([is_router/0]).
-export([load_regulation_enabled/0]).
-export([router_pool/0]).
-export([request_timeout/0]).
-export([tcp_acceptors_pool_size/0]).
-export([tcp_max_connections/0]).
-export([tcp_port/0]).
-export([tls_acceptors_pool_size/0]).
-export([tls_max_connections/0]).
-export([tls_port/0]).
-export([ws_compress_enabled/0]).
-export([tls_files/0]).





%% =============================================================================
%% API
%% =============================================================================



-spec is_router() -> boolean().
is_router() ->
    application:get_env(?APP, is_router, true).



%% =============================================================================
%% HTTP
%% =============================================================================

api_gateway() ->
    application:get_env(?APP, api_gateway, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the app's priv dir
%% @end
%% -----------------------------------------------------------------------------
priv_dir() ->
    case code:priv_dir(bondy) of
        {error, bad_name} ->
            filename:join(
                [filename:dirname(code:which(?MODULE)), "..", "priv"]);
        Val ->
            Val
    end.



%% @doc
%% x-webkit-deflate-frame compression draft which is being used by some
%% browsers to reduce the size of data being transmitted supported by Cowboy.
%% @end
ws_compress_enabled() -> true.



%% =============================================================================
%% TCP
%% =============================================================================


tcp_acceptors_pool_size() ->
    application:get_env(?APP, tcp_acceptors_pool_size, 200).

tcp_max_connections() ->
    application:get_env(?APP, tcp_max_connections, 1000000).

tcp_port() ->
    Default = 8083,
    try 
        case application:get_env(?APP, tcp_port, Default) of
            Int when is_integer(Int) -> Int;
            Str -> list_to_integer(Str)
        end
    catch
        _:_ -> Default
    end.


%% =============================================================================
%% TLS
%% =============================================================================


tls_acceptors_pool_size() ->
    application:get_env(?APP, tls_acceptors_pool_size, 200).

tls_max_connections() ->
    application:get_env(?APP, tls_max_connections, 1000000).

tls_port() ->
    application:get_env(?APP, tls_port, 10083).


tls_files() ->
    application:get_env(?APP, tls_files, []).


%% =============================================================================
%% REALMS
%% =============================================================================


automatically_create_realms() ->
    application:get_env(?APP, automatically_create_realms, true).


%% =============================================================================
%% SESSION
%% =============================================================================

-spec connection_lifetime() -> session | connection.
connection_lifetime() ->
    application:get_env(?APP, connection_lifetime, session).


%% =============================================================================
%% API : LOAD REGULATION
%% =============================================================================

-spec load_regulation_enabled() -> boolean().
load_regulation_enabled() ->
    application:get_env(?APP, load_regulation_enabled, true).


-spec coordinator_timeout() -> pos_integer().
coordinator_timeout() ->
    application:get_env(?APP, coordinator_timeout, 3000).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns a proplist containing the following keys:
%% 
%% * type - can be one of the following:
%%     * permanent - the pool contains a (size) number of permanent workers
%% under a supervision tree. This is the "events as messages" design pattern.
%%      * transient - the pool contains a (size) number of supervisors each one
%% supervision a transient process. This is the "events as messages" design
%% pattern.
%% * size - The number of workers used by the load regulation system 
%% for the provided pool
%%% * capacity - The usage limit enforced by the load regulation system for the provided pool
%% @end
%% -----------------------------------------------------------------------------
-spec router_pool() -> list().

router_pool() ->
    {ok, Pool} = application:get_env(?APP, router_pool),
    Pool.



%% CALL

request_timeout() ->
    application:get_env(
        ?APP, request_timeout, 5*60*1000). % 5 mins
