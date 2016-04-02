%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%%
%% @end
%% =============================================================================
-module(juno_app).
-behaviour(application).

-export([start/2]).
-export([stop/1]).

start(_Type, _Args) ->
    case juno_sup:start_link() of
        {ok, Pid} ->
            ok = juno_router:start_pool(),
            ok = maybe_start_router_services(),
            {ok, Pid};
        Other  ->
            Other
    end.


stop(_State) ->
    ok.



%% =============================================================================
%% PRIVATE
%% =============================================================================

maybe_start_router_services() ->
    case juno_config:is_router() of
        true ->
            ok = start_tcp_handlers(),
            %% {ok, _} = juno_api_http:start_https(),
            {ok, _} = juno_api_http:start_http(),
            ok;
        false ->
            ok
    end.


%% @private
-spec start_tcp_handlers() -> ok.
start_tcp_handlers() ->
    ServiceName = juno_wamp_tcp_listener,
    PoolSize = juno_config:tcp_acceptors_pool_size(),
    Port = juno_config:tcp_port(),
    MaxConnections = juno_config:tcp_max_connections(),
    {ok, _} = ranch:start_listener(
        ServiceName,
        PoolSize,
        ranch_tcp,
        [{port, Port}],
        juno_wamp_raw_handler, []),
    ranch:set_max_connections(ServiceName, MaxConnections),
    ok.
