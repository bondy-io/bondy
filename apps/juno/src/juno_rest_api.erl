%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%%
%% @end
%% =============================================================================
-module(juno_rest_api).
-include("juno.hrl").

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
        [
            {env,[
                {auth, #{
                    realm_uri => ?JUNO_REALM_URI,
                    schemes => [basic, digest, bearer]
                }},
                {dispatch, admin_dispatch_table()}, 
                {max_connections, infinity}
            ]},
            {middlewares, [
                    cowboy_router, juno_security_middleware, cowboy_handler
            ]}
        ]
    ).

-spec start_http() -> {ok, Pid :: pid()} | {error, any()}.
start_http() ->
    Port = juno_config:http_port(),
    PoolSize = juno_config:http_acceptors_pool_size(),
    cowboy:start_http(
        juno_http_listener,
        PoolSize,
        [{port, Port}],
        [
            {env,[
                {auth, #{
                    schemes => [basic, digest, bearer]
                }},
                {dispatch, admin_dispatch_table()}, 
                {max_connections, infinity}
            ]},
            {middlewares, [
                    cowboy_router, juno_security_middleware, cowboy_handler
            ]}
        ]
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
                juno_rest_admin_handler, #{entity => entry_point}},
            %% Used to establish a websockets connection
            {"/ws",
                juno_ws_handler, #{}},
            {"/ping",
                juno_rest_admin_handler, #{entity => ping}},
            %% MULTI-TENANCY CAPABILITY
            {"/realms",
                juno_realm_rh, #{entity => realm, is_collection => true}},
            {"/realms/:realm", 
                juno_realm_rh, #{entity => realm}},
            %% SECURITY CAPABILITY    
            {"/users",
                juno_rest_security_handler, 
                #{entity => user, is_collection => true}},
            {"/users/:id",
                juno_rest_security_handler, 
                #{entity => user}},
            {"/users/:id/permissions",
                juno_rest_security_handler, 
                #{entity => permission, is_collection => true}},
            {"/users/:id/source",
                juno_rest_security_handler, 
                #{entity => source, master => user, is_collection => false}},
            {"/sources/",
                juno_rest_security_handler, 
                #{entity => source, is_collection => true}},
            {"/groups",
                juno_rest_security_handler, 
                #{entity => group, is_collection => true}},
            {"/groups/:id",
                juno_rest_security_handler, 
                #{entity => group}},
            {"/groups/:id/permissions",
                juno_rest_security_handler, 
                #{entity => permission, is_collection => true}},
            {"/stats",
                juno_rest_admin_handler, #{entity => stats, is_collection => true}},
            %% CLUSTER MANAGEMENT CAPABILITY
            {"/nodes", 
                juno_rest_admin_handler, #{entity => node, is_collection => true}},
            {"/nodes/:node", 
                juno_rest_admin_handler, #{entity => node}},
            %% GATEWAY CAPABILITY
            {"/apis", 
                juno_rest_api_gateway_handler, 
                #{entity => api, is_collection => true}},
            {"/apis/:id", 
                juno_rest_api_gateway_handler, #{entity => api}},
            {"/apis/:id/procedures", 
                juno_rest_api_gateway_handler, 
                #{entity => api, is_collection => true}},
            {"/apis/:id/procedures/:uri", 
                juno_rest_api_gateway_handler, #{entity => api}}
        ]}
    ],
    cowboy_router:compile(List).


%% @private
dispatch_table() ->
    Hosts = [
        {'_', [
            {"/",
                juno_rest_wamp_bridge_handler, #{entity => entry_point}},
            %% JUNO HTTP/REST - WAMP BRIDGE
            % Used by HTTP publishers to publish an event
            {"/events",
                juno_rest_wamp_bridge_handler, #{entity => event}},
            % Used by HTTP callers to make a call
            {"/calls",
                juno_rest_wamp_bridge_handler, #{entity => call}},
            % Used by HTTP subscribers to list, add and remove HTTP subscriptions
            {"/subscriptions",
                juno_rest_wamp_bridge_handler, #{entity => subscription}},
            {"/subscriptions/:id",
                juno_rest_wamp_bridge_handler, #{entity => subscription}},
            %% Used by HTTP callees to list, register and unregister HTTP endpoints
            {"/registrations",
                juno_rest_wamp_bridge_handler, #{entity => registration}},
            {"/registrations/:id",
                juno_rest_wamp_bridge_handler, #{entity => registration}},
            %% Used to establish a websockets connection
            {"/ws",
                juno_ws_handler, #{}},
            %% JUNO API GATEWAY
            {"/api/:version/realms/:realm/[...]",
                juno_rest_api_gateway_handler, #{}}
        ]}
    ],
    cowboy_router:compile(Hosts).
