-module(ramp_api_http).

-define(DEFAULT_POOL_SIZE, 200).

-export([start_http/0]).
-export([start_https/0]).


-spec start_http() -> {ok, Pid :: pid()} | {error, any()}.
start_http() ->
    Port = ramp_config:http_port(),
    PoolSize = ramp_config:http_acceptors_pool_size(),
    cowboy:start_http(
        ramp_http_listener,
        PoolSize,
        [{port, Port}],
        [{env, [{dispatch, dispatch_table()}]}]
    ).

-spec start_https() -> {ok, Pid :: pid()} | {error, any()}.
start_https() ->
    Port = ramp_config:https_port(),
    PoolSize = ramp_config:https_acceptors_pool_size(),
    cowboy:start_https(
        ramp_https_listener,
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
            {"/", ramp_entry_point_rh, []},
            {"/ws", ramp_ws_handler, []},
            {"/publications", ramp_publication_collection_rh, []},
            {"/calls", ramp_call_collection_rh, []}
        ]}
    ],
    cowboy_router:compile(List).
