%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2017. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%%
%% @end
%% =============================================================================
-module(bondy_rest_api_gateway).
-include("bondy.hrl").

-define(DEFAULT_POOL_SIZE, 200).
-define(HTTP, bondy_gateway_http_listener).
-define(HTTPS, bondy_gateway_https_listener).

%% COWBOY MIDDLEWARE CALLBACKS
-export([start_listeners/0]).
-export([start_http/1]).
-export([start_https/1]).
% -export([update_hosts/1]).
-export([add_consumer/4]).




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
    % Parsed = [bondy_rest_api_gateway_spec:parse(S) || S <- Specs],
    % Compiled = bondy_rest_api_gateway_spec:compile(Parsed),
    % SchemeRules = case bondy_rest_api_gateway_spec:load(Compiled) of
    %     [] ->
    %         [{<<"http">>, []}];
    %     Val ->
    %         Val
    % end,
    Parsed = [bondy_rest_api_gateway_spec_parser:parse(S) || S <- Specs],
    SchemeRules = bondy_rest_api_gateway_spec_parser:dispatch_table(
        Parsed, base_rules()),
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
    % io:format("HTTP Listener startin with Rules~p~n", [Rules]),
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
    % io:format("Rules ~p~n", [Rules]),
    % io:format("Table ~p~n", [Table]),
    cowboy:start_clear(
        ?HTTPS,
        bondy_config:http_acceptors_pool_size(),
        [{port, bondy_config:http_port()}],
        #{
            env => #{
                bondy => #{
                    auth => #{
                        schemes => [basic, digest, bearer]
                    }
                },
                dispatch => cowboy_router:compile(Rules), 
                max_connections => infinity
            },
            middlewares => [
                cowboy_router, 
                % bondy_rest_api_gateway,
                % bondy_security_middleware, 
                cowboy_handler
            ]
        }
    ).



-spec start_https(list()) -> {ok, Pid :: pid()} | {error, any()}.
start_https(Rules) ->
    cowboy:start_tls(
        ?HTTPS,
        bondy_config:https_acceptors_pool_size(),
        [{port, bondy_config:https_port()}],
        #{
            env => #{
                bondy => #{
                    auth => #{
                        schemes => [basic, digest, bearer]
                    }
                },
                dispatch => cowboy_router:compile(Rules), 
                max_connections => infinity
            },
            middlewares => [
                cowboy_router, 
                % bondy_rest_api_gateway,
                % bondy_security_middleware, 
                cowboy_handler
            ]
        }
    ).

% update_hosts(Hosts) ->
%     cowboy:set_env(?HTTP, dispatch, cowboy_router:compile(Hosts)).


%% =============================================================================
%% API: CONSUMERS
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
add_consumer(RealmUri, ClientId, Password, Info) ->
    ok = maybe_init_security(RealmUri),
    Opts = [
        {info, Info},
        {"password", binary_to_list(Password)},
        {"groups", "api_consumers"}
    ],
    bondy_security:add_user(RealmUri, ClientId, Opts).
    






%% =============================================================================
%% PRIVATE: REST LISTENERS
%% =============================================================================



%% @private
specs() ->
    case bondy_config:api_gateway() of
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
        {error, _} ->
            {error, {invalid_specification_format, FName}}
    end.



base_rules() ->
    %% The WS entrypoint
    [{'_', [{"/ws", bondy_ws_handler, #{}}]}].


% %% @private
% bridge_dispatch_table() ->
%     Hosts = [
%         {'_', [
%             {"/",
%                 bondy_rest_wamp_bridge_handler, #{entity => entry_point}},
%             %% Used to establish a websockets connection
%             {"/ws",
%                 bondy_ws_handler, #{}},
%             %% BONDY HTTP/REST - WAMP BRIDGE
%             % Used by HTTP publishers to publish an event
%             {"/events",
%                 bondy_rest_wamp_bridge_handler, #{entity => event}},
%             % Used by HTTP callers to make a call
%             {"/calls",
%                 bondy_rest_wamp_bridge_handler, #{entity => call}},
%             % Used by HTTP subscribers to list, add and remove HTTP subscriptions
%             {"/subscriptions",
%                 bondy_rest_wamp_bridge_handler, #{entity => subscription}},
%             {"/subscriptions/:id",
%                 bondy_rest_wamp_bridge_handler, #{entity => subscription}},
%             %% Used by HTTP callees to list, register and unregister HTTP endpoints
%             {"/registrations",
%                 bondy_rest_wamp_bridge_handler, #{entity => registration}},
%             {"/registrations/:id",
%                 bondy_rest_wamp_bridge_handler, #{entity => registration}}
%         ]}
%     ],
%     cowboy_router:compile(Hosts).


%% =============================================================================
%% PRIVATE: SECURITY
%% =============================================================================


%% @private
maybe_init_security(RealmUri) ->
    case bondy_security_group:lookup(RealmUri, <<"api_consumers">>) of
        not_found -> 
            G = #{
                <<"name">> => <<"api_consumers">>,
                <<"description">> => <<"A group of users allowed to consume APIs from the Bondy RESTful API Gateway.">>
            },
            bondy_security_group:add(RealmUri, G);
        _ ->
            ok
    end.
    



