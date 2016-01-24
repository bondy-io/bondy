-module(ramp_app).
-behaviour(application).

-export([start/2]).
-export([stop/1]).

start(_Type, _Args) ->
    case ramp_sup:start_link() of
        {ok, Pid} ->
            ok = start_tcp_handlers(),
            {ok, Pid};
        Other  ->
            Other
    end.


stop(_State) ->
    ok.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
-spec start_tcp_handlers() -> ok.
start_tcp_handlers() ->
    ServiceName = ramp_wamp_tcp_listener,
    PoolSize = ramp_config:tcp_acceptors_pool_size(),
    Port = ramp_config:tcp_port(),
    MaxConnections = ramp_config:tcp_max_connections(),
    {ok, _} = ranch:start_listener(
        ServiceName,
        PoolSize,
        ranch_tcp,
        [{port, Port}],
        ramp_wamp_raw_handler, []),
    ranch:set_max_connections(ServiceName, MaxConnections),
    ok.
