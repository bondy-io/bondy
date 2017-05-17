%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2017. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%%
%% @end
%% =============================================================================
-module(juno_rest_api_gateway).
-behaviour(cowboy_middleware).

-define(DEFAULT_POOL_SIZE, 200).
-define(HTTP, juno_gateway_http_listener).
-define(HTTPS, juno_gateway_https_listener).

%% COWBOY MIDDLEWARE CALLBACKS
-export([execute/2]).
-export([start_listeners/0]).
-export([start_http/1]).
-export([start_https/1]).
% -export([update_hosts/1]).





%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% Conditionally start http and https listeners based on the configured APIs
%% @end
%% -----------------------------------------------------------------------------
start_listeners() ->
    Specs = specs(),
    Parsed = [juno_rest_api_gateway_spec:parse(S) || S <- Specs],
    Compiled = juno_rest_api_gateway_spec:compile(Parsed),
    SchemeRules = case juno_rest_api_gateway_spec:load(Compiled) of
        [] ->
            [{<<"http">>, []}];
        Val ->
            Val
    end,
    _ = [start_listener({Scheme, Rules}) 
        || {Scheme, Rules} <- SchemeRules],
    ok.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start_listener({Scheme :: binary(), [tuple()]}) -> ok.

start_listener({<<"http">>, Rules}) ->
    {ok, _} = start_http(Rules),
    ok;

start_listener({<<"https">>, Rules}) ->
    {ok, _} = start_https(Rules),
    ok.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start_http(list()) -> {ok, Pid :: pid()} | {error, any()}.
start_http(Rules) ->
    Table = cowboy_router:compile(Rules),
    % io:format("Rules ~p~n", [Rules]),
    % io:format("Table ~p~n", [Table]),
    Port = juno_config:http_port(),
    PoolSize = juno_config:http_acceptors_pool_size(),
    JunoEnv = #{
        auth => #{
            schemes => [basic, digest, bearer]
        }
    },
    cowboy:start_http(
        ?HTTP,
        PoolSize,
        [{port, Port}],
        [
            {env,[
                {juno, JunoEnv},
                {dispatch, Table}, 
                {max_connections, infinity}
            ]},
            {middlewares, [
                cowboy_router, 
                % juno_rest_api_gateway,
                % juno_security_middleware, 
                cowboy_handler
            ]}
        ]
    ).



-spec start_https(list()) -> {ok, Pid :: pid()} | {error, any()}.
start_https(Rules) ->
    Table = cowboy_router:compile(Rules),
    Port = juno_config:https_port(),
    PoolSize = juno_config:https_acceptors_pool_size(),
    JunoEnv = #{
        auth => #{
            schemes => [basic, digest, bearer]
        }
    },
    cowboy:start_https(
        ?HTTPS,
        PoolSize,
        [{port, Port}],
        [
            {env,[
                {juno, JunoEnv},
                {dispatch, Table}, 
                {max_connections, infinity}
            ]},
            {middlewares, [
                cowboy_router, 
                % juno_rest_api_gateway,
                juno_security_middleware, 
                cowboy_handler
            ]}
        ]
    ).

% update_hosts(Hosts) ->
%     cowboy:set_env(?HTTP, dispatch, cowboy_router:compile(Hosts)).


%% =============================================================================
%% API: COWBOY MIDDLEWARE CALLBACKS
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
execute(Req0, Env0) ->
    case get_value(handler, Env0) of
        juno_ws_handler ->
            {ok, Req0, Env0};
        _Other ->
            {ok, Req0, Env0}
    end.





%% =============================================================================
%% PRIVATE: REST LISTENERS
%% =============================================================================



%% @private
specs() ->
    case juno_config:api_gateway() of
        undefined ->
            [];
        L ->
            case lists:keyfind(specs_path, 1, L) of
                false ->
                    [];
                {_, Path} ->
                    Expr = filename:join([Path, "*.jags"]),
                    case filelib:wildcard(Expr) of
                        [] ->
                            [];
                        FNames ->
                            lists:append([read_spec(FName) || FName <- FNames])
                    end
            end
    end.

%% @private
read_spec(FName) ->
    case file:consult(FName) of
        {ok, L} ->
            L;
        {error, _} = E ->
            {error, {invalid_specification_format, FName}}
    end.



add_base_rules(T) ->
    %% The WS entrypoint
    [{'_', [{"/ws", juno_ws_handler, #{}}]} | T].

% %% @private
% bridge_dispatch_table() ->
%     Hosts = [
%         {'_', [
%             {"/",
%                 juno_rest_wamp_bridge_handler, #{entity => entry_point}},
%             %% Used to establish a websockets connection
%             {"/ws",
%                 juno_ws_handler, #{}},
%             %% JUNO HTTP/REST - WAMP BRIDGE
%             % Used by HTTP publishers to publish an event
%             {"/events",
%                 juno_rest_wamp_bridge_handler, #{entity => event}},
%             % Used by HTTP callers to make a call
%             {"/calls",
%                 juno_rest_wamp_bridge_handler, #{entity => call}},
%             % Used by HTTP subscribers to list, add and remove HTTP subscriptions
%             {"/subscriptions",
%                 juno_rest_wamp_bridge_handler, #{entity => subscription}},
%             {"/subscriptions/:id",
%                 juno_rest_wamp_bridge_handler, #{entity => subscription}},
%             %% Used by HTTP callees to list, register and unregister HTTP endpoints
%             {"/registrations",
%                 juno_rest_wamp_bridge_handler, #{entity => registration}},
%             {"/registrations/:id",
%                 juno_rest_wamp_bridge_handler, #{entity => registration}}
%         ]}
%     ],
%     cowboy_router:compile(Hosts).


%% =============================================================================
%% PRIVATE: COWBOY MIDDLEWARE
%% =============================================================================


%% @private
get_value(_, undefined) ->
    undefined;

get_value(Key, Env) when is_list(Env) ->
    case lists:keyfind(Key, 1, Env) of
        {Key, Value} -> Value;
        false -> undefined 
    end;

get_value(Key, Env) when is_map(Env) ->
    maps:get(Key, Env, undefined).


%% private
% get_realm_uri(Env) ->
%     %% We first try in the opts of the handler and revert to the 
%     %% environment default
%     case get_value(realm_uri, get_value(handler_opts, Env)) of
%         undefined ->
%             get_value(realm_uri, get_value(auth, Env));
%         Val ->
%             Val
%     end.