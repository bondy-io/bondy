%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%%
%% @end
%% =============================================================================
-module(juno_config).

-define(APP, juno).
-define(DEFAULT_RESOURCE_SIZE, 16 * erlang:system_info(schedulers)).
-define(DEFAULT_RESOURCE_CAPACITY, 16 * erlang:system_info(schedulers) * 10000). % max messages in process queue
-define(DEFAULT_POOL_TYPE, transient).

-export([automatically_create_realms/0]).
-export([call_timeout/0]).
-export([connection_lifetime/0]).
-export([coordinator_timeout/0]).
-export([http_acceptors_pool_size/0]).
-export([http_max_connections/0]).
-export([http_port/0]).
-export([https_acceptors_pool_size/0]).
-export([https_max_connections/0]).
-export([https_port/0]).
-export([is_router/0]).
-export([load_regulation_enabled/0]).
-export([pool_capacity/1]).
-export([pool_size/1]).
-export([pool_type/1]).
-export([tcp_acceptors_pool_size/0]).
-export([tcp_max_connections/0]).
-export([tcp_port/0]).
-export([tls_acceptors_pool_size/0]).
-export([tls_max_connections/0]).
-export([tls_port/0]).
-export([ws_compress_enabled/0]).





%% =============================================================================
%% API
%% =============================================================================



-spec is_router() -> boolean().
is_router() ->
    application:get_env(?APP, is_router, true).



%% =============================================================================
%% HTTP
%% =============================================================================


http_acceptors_pool_size() ->
    application:get_env(?APP, http_acceptors_pool_size, 200).

http_max_connections() ->
    application:get_env(?APP, http_max_connections, 1000).

http_port() ->
    application:get_env(?APP, http_port, 8080).


%% @doc
%% x-webkit-deflate-frame compression draft which is being used by some
%% browsers to reduce the size of data being transmitted supported by Cowboy.
%% @end
ws_compress_enabled() -> true.

%% =============================================================================
%% HTTPS
%% =============================================================================

https_acceptors_pool_size() ->
    application:get_env(?APP, https_acceptors_pool_size, 200).

https_max_connections() ->
    application:get_env(?APP, https_max_connections, 1000000).

https_port() ->
    application:get_env(?APP, https_port, 8043).


%% =============================================================================
%% TCP
%% =============================================================================


tcp_acceptors_pool_size() ->
    application:get_env(?APP, tcp_acceptors_pool_size, 200).

tcp_max_connections() ->
    application:get_env(?APP, tcp_max_connections, 1000000).

tcp_port() ->
    application:get_env(?APP, tcp_port, 10082).


%% =============================================================================
%% TLS
%% =============================================================================


tls_acceptors_pool_size() ->
    application:get_env(?APP, tls_acceptors_pool_size, 200).

tls_max_connections() ->
    application:get_env(?APP, tls_max_connections, 1000000).

tls_port() ->
    application:get_env(?APP, tls_port, 10083).


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


%% @doc Returns the type of the pool with name PoolName. The type can be one of
%% the following:
%% * permanent - the pool contains a (size) number of permanent workers
%% under a supervision tree. This is the "events as messages" design pattern.
%%  * transient - the pool contains a (size) number of supervisors each one
%% supervision a transient process. This is the "events as messages" design
%% pattern.
%% @end
-spec pool_type(PoolName :: atom()) -> permanent | transient.
pool_type(juno_router_pool) ->
    application:get_env(
        ?APP, juno_router_pool_type, permanent).


-spec pool_size(Resource :: atom()) -> pos_integer().
pool_size(juno_router_pool) ->
    application:get_env(
        ?APP, juno_router_pool_size, ?DEFAULT_RESOURCE_SIZE).


-spec pool_capacity(Resource :: atom()) -> pos_integer().
pool_capacity(juno_router_pool) ->
    application:get_env(
        ?APP, juno_router_pool_capacity, ?DEFAULT_RESOURCE_CAPACITY).


%% CALL

call_timeout() ->
    application:get_env(
        ?APP, call_timeout, infinity).
