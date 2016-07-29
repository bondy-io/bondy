%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%%
%% @end
%% =============================================================================
-module(juno_api_http).

-define(DEFAULT_POOL_SIZE, 200).

-export([start_admin_http/0]).
-export([start_http/0]).
-export([start_https/0]).


-spec start_admin_http() -> {ok, Pid :: pid()} | {error, any()}.
start_admin_http() ->
    Port = juno_config:admin_http_port(),
    PoolSize = juno_config:http_acceptors_pool_size(),
    cowboy:start_http(
        juno_admin_http_listener,
        PoolSize,
        [{port, Port}],
        [{env, [{dispatch, admin_dispatch_table()}, {max_connections, infinity}]}]
    ).

-spec start_http() -> {ok, Pid :: pid()} | {error, any()}.
start_http() ->
    Port = juno_config:http_port(),
    PoolSize = juno_config:http_acceptors_pool_size(),
    cowboy:start_http(
        juno_http_listener,
        PoolSize,
        [{port, Port}],
        [{env, [{dispatch, dispatch_table()}, {max_connections, infinity}]}]
    ).

-spec start_https() -> {ok, Pid :: pid()} | {error, any()}.
start_https() ->
    Port = juno_config:https_port(),
    PoolSize = juno_config:https_acceptors_pool_size(),
    cowboy:start_https(
        juno_https_listener,
        PoolSize,
        [{port, Port}],
        [{env, [{dispatch, dispatch_table()}, {max_connections, infinity}]}]
    ).



%% ============================================================================
%% PRIVATE
%% ============================================================================

admin_dispatch_table() ->
    List = [
        %% ADMIN API
        {'_', [
            {"/",
                juno_admin_rh, #{entity => entry_point}},
            {"/ping",
                juno_admin_rh, #{entity => ping}},
            %% MULTI-TENANCY CAPABILITY
            {"/realms",
                juno_realm_rh, #{entity => realm, is_collection => true}},
            {"/realms/:realm", 
                juno_realm_rh, #{entity => realm}},
            %% SECURITY CAPABILITY    
            {"/users",
                juno_security_admin_rh, 
                #{entity => user, is_collection => true}},
            {"/users/:id",
                juno_security_admin_rh, 
                #{entity => user}},
            {"/users/:id/permissions",
                juno_security_admin_rh, 
                #{entity => permission, is_collection => true}},
            {"/users/:id/source",
                juno_security_admin_rh, 
                #{entity => source, master => user, is_collection => false}},
            {"/sources/",
                juno_security_admin_rh, 
                #{entity => source, is_collection => true}},
            {"/groups",
                juno_security_admin_rh, 
                #{entity => group, is_collection => true}},
            {"/groups/:id",
                juno_security_admin_rh, 
                #{entity => group}},
            {"/groups/:id/permissions",
                juno_security_admin_rh, 
                #{entity => permission, is_collection => true}},
            {"/stats",
                juno_admin_rh, #{entity => stats, is_collection => true}},
            %% CLUSTER MANAGEMENT CAPABILITY
            {"/nodes", 
                juno_admin_rh, #{entity => node, is_collection => true}},
            {"/nodes/:node", 
                juno_admin_rh, #{entity => node}},
            %% GATEWAY CAPABILITY
            {"/apis", 
                juno_admin_collection_rh, 
                #{entity => api, is_collection => true}},
            {"/apis/:id", 
                juno_admin_rh, #{entity => api}}
        ]}
    ],
    cowboy_router:compile(List).


%% @private
dispatch_table() ->
    List = [
        {'_', [
            {"/",
                juno_http_bridge_rh, #{entity => entry_point}},
            %% JUNO HTTP/REST - WAMP BRIDGE
            % Used by HTTP publishers to publish an event
            {"/events",
                juno_http_bridge_rh, #{entity => event}},
            % Used by HTTP callers to make a call
            {"/calls",
                juno_http_bridge_rh, #{entity => call}},
            % Used by HTTP subscribers to list, add and remove HTTP subscriptions
            {"/subscriptions",
                juno_http_bridge_rh, #{entity => subscription}},
            {"/subscriptions/:id",
                juno_http_bridge_rh, #{entity => subscription}},
            %% Used by HTTP callees to list, register and unregister HTTP endpoints
            {"/registrations",
                juno_http_bridge_rh, #{entity => registration}},
            {"/registrations/:id",
                juno_http_bridge_rh, #{entity => registration}},
            %% Used to establish a websockets connection
            {"/ws",
                juno_ws_handler, #{}},
            %% JUNO API GATEWAY
            {"/api/:version/[...]",
                juno_gateway_rh, #{}}
        ]}
    ],
    cowboy_router:compile(List).
