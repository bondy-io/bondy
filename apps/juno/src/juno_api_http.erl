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

-export([start_http/0]).
-export([start_https/0]).


-spec start_http() -> {ok, Pid :: pid()} | {error, any()}.
start_http() ->
    Port = juno_config:http_port(),
    PoolSize = juno_config:http_acceptors_pool_size(),
    cowboy:start_http(
        juno_http_listener,
        PoolSize,
        [{port, Port}],
        [{env, [{dispatch, dispatch_table()}]}]
    ).

-spec start_https() -> {ok, Pid :: pid()} | {error, any()}.
start_https() ->
    Port = juno_config:https_port(),
    PoolSize = juno_config:https_acceptors_pool_size(),
    cowboy:start_https(
        juno_https_listener,
        PoolSize,
        [{port, Port}],
        [{env, [{dispatch, dispatch_table()}]}]
    ).


%% ============================================================================
%% PRIVATE
%% ============================================================================



%% @private
dispatch_table() ->
    List = [
        {'_', [
            {"/", juno_entry_point_rh, []},
            {"/ws", juno_ws_handler, []},
            {"/publications", juno_publication_collection_rh, []},
            {"/calls", juno_call_collection_rh, []}
        ]}
    ],
    cowboy_router:compile(List).
