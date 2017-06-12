%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2017. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%%
%% @end
%% =============================================================================
-module(bondy_rest_admin_api).
-include("bondy.hrl").

-define(DEFAULT_POOL_SIZE, 100).

-export([start_admin_http/0]).







%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start_admin_http() -> {ok, Pid :: pid()} | {error, any()}.
start_admin_http() ->
    Port = bondy_config:admin_http_port(),
    PoolSize = bondy_config:http_acceptors_pool_size(),
    cowboy:start_clear(
        bondy_admin_http_listener,
        PoolSize,
        [{port, Port}],
        [
            {env,[
                {auth, #{
                    realm_uri => ?BONDY_REALM_URI,
                    schemes => [basic, digest, bearer]
                }},
                {dispatch, admin_dispatch_table()}, 
                {max_connections, infinity}
            ]},
            {middlewares, [
                cowboy_router, 
                % bondy_security_middleware, 
                cowboy_handler
            ]}
        ]
    ).





%% ============================================================================
%% PRIVATE
%% ============================================================================

admin_dispatch_table() ->
    Hosts = [
        %% ADMIN API
        {'_', [
            {"/",
                bondy_rest_admin_handler, #{entity => entry_point}},
            %% Used to establish a websockets connection
            {"/ws",
                bondy_ws_handler, #{}},
            {"/ping",
                bondy_rest_admin_handler, #{entity => ping}},
            %% MULTI-TENANCY CAPABILITY
            {"/realms",
                bondy_realm_rh, #{entity => realm, is_collection => true}},
            {"/realms/:realm", 
                bondy_realm_rh, #{entity => realm}},
            %% SECURITY CAPABILITY    
            {"/users",
                bondy_rest_security_handler, 
                #{entity => user, is_collection => true}},
            {"/users/:id",
                bondy_rest_security_handler, 
                #{entity => user}},
            {"/users/:id/permissions",
                bondy_rest_security_handler, 
                #{entity => permission, is_collection => true}},
            {"/users/:id/source",
                bondy_rest_security_handler, 
                #{entity => source, master => user, is_collection => false}},
            {"/sources/",
                bondy_rest_security_handler, 
                #{entity => source, is_collection => true}},
            {"/groups",
                bondy_rest_security_handler, 
                #{entity => group, is_collection => true}},
            {"/groups/:id",
                bondy_rest_security_handler, 
                #{entity => group}},
            {"/groups/:id/permissions",
                bondy_rest_security_handler, 
                #{entity => permission, is_collection => true}},
            {"/stats",
                bondy_rest_admin_handler, #{entity => stats, is_collection => true}},
            %% CLUSTER MANAGEMENT CAPABILITY
            {"/nodes", 
                bondy_rest_admin_handler, #{entity => node, is_collection => true}},
            {"/nodes/:node", 
                bondy_rest_admin_handler, #{entity => node}},
            %% GATEWAY CAPABILITY
            {"/apis", 
                bondy_rest_api_gateway_handler, 
                #{entity => api, is_collection => true}},
            {"/apis/:id", 
                bondy_rest_api_gateway_handler, #{entity => api}},
            {"/apis/:id/procedures", 
                bondy_rest_api_gateway_handler, 
                #{entity => api, is_collection => true}},
            {"/apis/:id/procedures/:uri", 
                bondy_rest_api_gateway_handler, #{entity => api}}
        ]}
    ],
    cowboy_router:compile(Hosts).


