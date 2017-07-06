%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2017. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%%
%% @end
%% =============================================================================
-module(bondy_api_gateway).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").


-define(DEFAULT_POOL_SIZE, 200).
-define(HTTP, bondy_gateway_http_listener).
-define(HTTPS, bondy_gateway_https_listener).

%% API
-export([add_client/2]).
-export([add_resource_owner/4]).
-export([dispatch_table/1]).
-export([load/1]).

%% COWBOY MIDDLEWARE CALLBACKS
-export([start_listeners/0]).
-export([start_http/1]).
-export([start_https/1]).




%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec load(file:filename()) -> 
    ok | {error, {invalid_specification_format, any()}}.

load(FName) ->
    try jsx:consult(FName, [return_maps]) of
        [Spec] ->
            %% We append the new spec to the base ones
            Specs = [Spec | specs()],
            _ = [
                update_dispatch_table(Scheme, Routes) 
                || {Scheme, Routes} <- parse_specs(Specs)
            ],
            ok
    catch
        error:badarg ->
            {error, invalid_specification_format}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Adds an API client to realm RealmUri.
%% Creates a new user adding it to the `api_clients` group.
%% @end
%% -----------------------------------------------------------------------------
-spec add_client(uri(), map()) -> ok | {error, term()}.

add_client(RealmUri, Info0) ->
    try 
        ok = maybe_init_security(RealmUri),
        Info1 = maps_utils:validate(Info0, #{
            <<"client_id">> => #{
                required => true,
                allow_null => false,
                datatype => binary,
                default => fun() -> bondy_oauth2:generate_fragment(48) end
            },
            <<"client_secret">> => #{
                required => true,
                allow_null => false,
                datatype => binary,
                default => fun() -> bondy_oauth2:generate_fragment(64) end
            },
            <<"description">> => #{
                datatype => binary
            }
        }),
        {Props, Info2} = maps_utils:split(
            [<<"client_id">>, <<"client_secret">>], Info1),
        Opts = [
            {info, Info2},
            {"password", maps:get(<<"client_secret">>, Props)},
            {"groups", "api_clients"}
        ],
        bondy_security:add_user(
            RealmUri, maps:get(<<"client_id">>, Props), Opts)
    catch
        error:Error when is_map(Error) ->
            {error, Error}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Adds a resource owner (end-user or system) to realm RealmUri.
%% Creates a new user adding it to the `resource_owners` group.
%% @end
%% -----------------------------------------------------------------------------
-spec add_resource_owner(uri(), binary(), binary(), map()) -> 
    ok | {error, term()} | no_return().

add_resource_owner(RealmUri, Username, Password, Info) ->
    ok = maybe_init_security(RealmUri),
    Opts = [
        {info, Info},
        {"password", binary_to_list(Password)},
        {"groups", "resource_owners"}
    ],
    bondy_security:add_user(RealmUri, Username, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% Conditionally start http and https listeners based on the configured APIs
%% @end
%% -----------------------------------------------------------------------------
start_listeners() ->
    % Parsed = [bondy_api_gateway_spec:parse(S) || S <- Specs],
    % Compiled = bondy_api_gateway_spec:compile(Parsed),
    % SchemeRoutes = case bondy_api_gateway_spec:load(Compiled) of
    %     [] ->
    %         [{<<"http">>, []}];
    %     Val ->
    %         Val
    % end,
    _ = [
        start_listener({Scheme, Routes}) 
        || {Scheme, Routes} <- parse_specs(specs())],
    ok.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start_listener({Scheme :: binary(), [tuple()]}) -> ok.

start_listener({<<"http">>, Routes}) ->
    {ok, _} = start_http(Routes),
    % io:format("HTTP Listener startin with Routes~p~n", [Routes]),
    ok;

start_listener({<<"https">>, Routes}) ->
    {ok, _} = start_https(Routes),
    ok.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start_http(list()) -> {ok, Pid :: pid()} | {error, any()}.
start_http(Routes) ->
    %% io:format("HTTP Routes ~p~n", [Routes]),
    % io:format("Table ~p~n", [Table]),
    cowboy:start_clear(
        ?HTTP,
        bondy_config:http_acceptors_pool_size(),
        [{port, bondy_config:http_port()}],
        #{
            env => #{
                bondy => #{
                    auth => #{
                        schemes => [basic, digest, bearer]
                    }
                },
                dispatch => cowboy_router:compile(Routes), 
                max_connections => infinity
            },
            middlewares => [
                cowboy_router, 
                % bondy_api_gateway,
                % bondy_security_middleware, 
                cowboy_handler
            ]
        }
    ).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start_https(list()) -> {ok, Pid :: pid()} | {error, any()}.
start_https(Routes) ->
    %% io:format("HTTPS Routes ~p~n", [Routes]),
    cowboy:start_tls(
        ?HTTPS,
        bondy_config:https_acceptors_pool_size(),
        [{port, bondy_config:https_port()} | bondy_config:ssl_files()],
        #{
            env => #{
                bondy => #{
                    auth => #{
                        schemes => [basic, digest, bearer]
                    }
                },
                dispatch => cowboy_router:compile(Routes), 
                max_connections => infinity
            },
            middlewares => [
                cowboy_router, 
                % bondy_api_gateway,
                % bondy_security_middleware, 
                cowboy_handler
            ]
        }
    ).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec dispatch_table(binary() | atom()) -> any().

dispatch_table(<<"http">>) ->
    dispatch_table(http);

dispatch_table(<<"https">>) ->
    dispatch_table(https);

dispatch_table(http) ->
    Map = ranch:get_protocol_options(?HTTP),
    maps_utils:get_path([env, dispatch], Map);

dispatch_table(https) ->
    Map = ranch:get_protocol_options(?HTTPS),
    maps_utils:get_path([env, dispatch], Map).






%% =============================================================================
%% PRIVATE: REST LISTENERS
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update_dispatch_table(atom() | binary(), list()) -> ok.

update_dispatch_table(http, Routes) ->
    update_dispatch_table(<<"http">>, Routes);

update_dispatch_table(https, Routes) ->
    update_dispatch_table(<<"https">>, Routes);

update_dispatch_table(<<"http">>, Routes) ->
    cowboy:set_env(?HTTP, dispatch, cowboy_router:compile(Routes));

update_dispatch_table(<<"https">>, Routes) ->
    cowboy:set_env(?HTTPS, dispatch, cowboy_router:compile(Routes)).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
base_routes() ->
    %% The WS entrypoint required for WAMP WS subprotocol
    [ {'_', [{"/ws", bondy_ws_handler, #{}}]} ].


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Reads all Bondy Gateway Specification files in the provided `specs_path`
%% configuration option.
%% @end
%% -----------------------------------------------------------------------------
specs() ->
    case bondy_config:api_gateway() of
        undefined ->
            specs("./etc");
        Opts ->
            case lists:keyfind(specs_path, 1, Opts) of
                false ->
                    specs("./etc");
                {_, Path} ->
                    lists:append([specs(Path), specs("./etc")])
            end
    end.


%% @private
specs(Path) ->
    %% @TODO this is loading erlang terms, we need to settle on JSON see load/1
    %% maybe *.bgs.json and *.bgs
    case filelib:wildcard(filename:join([Path, "*.json"])) of
        [] ->
            [];
        FNames ->
            Fold = fun(FName, Acc) ->
                try jsx:consult(FName, [return_maps]) of
                    [Spec] ->
                        [Spec|Acc]
                catch
                    error:badarg ->
                        lager:error("Error processing API Gateway Specification file, reason=~p, file_name=~p", [invalid_specification_format, FName]),
                        Acc
                end
            end,
            lists:foldl(Fold, [], FNames)
    end.


%% @private
parse_specs(Specs) ->
    case [bondy_api_gateway_spec_parser:parse(S) || S <- Specs] of
        [] ->
            [{<<"http">>, []}, {<<"https">>, []}];
        Parsed ->
            bondy_api_gateway_spec_parser:dispatch_table(
                Parsed, base_routes())
    end.



%% =============================================================================
%% PRIVATE: SECURITY
%% =============================================================================



%% @private
maybe_init_security(RealmUri) ->
    Gs = [
        #{
            <<"name">> => <<"api_clients">>,
            <<"description">> => <<"A group of applications making protected resource requests through Bondy API Gateway on behalf of the resource owner and with its authorisation.">>
        },
        #{
            <<"name">> => <<"resource_owners">>,
            <<"description">> => <<"A group of entities capable of granting access to a protected resource. When the resource owner is a person, it is referred to as an end-user.">>
        }
    ],
    [maybe_init_group(RealmUri, G) || G <- Gs],
    ok.


%% @private
maybe_init_group(RealmUri, #{<<"name">> := Name} = G) ->
    case bondy_security_group:lookup(RealmUri, Name) of
        not_found -> 
            bondy_security_group:add(RealmUri, G);
        _ ->
            ok
    end.