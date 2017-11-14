%% =============================================================================
%%  bondy_api_gateway.erl -
%%
%%  Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_api_gateway).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").

-define(PREFIX, {global, api_specs}).
-define(HTTP, api_gateway_http).
-define(HTTPS, api_gateway_https).
-define(ADMIN_HTTP, admin_api_http).
-define(ADMIN_HTTPS, admin_api_https).


-type listener()  ::    api_gateway_http
                        | api_gateway_https
                        | admin_api_http
                        | admin_api_https.


%% API
-export([add/2]).
-export([delete/1]).
-export([dispatch_table/1]).
-export([list/0]).
-export([load/1]).
-export([lookup/1]).
-export([start_admin_listeners/0]).
-export([start_listeners/0]).

% -export([start_http/1]).
% -export([start_https/1]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% Conditionally start the public http and https listeners based on the
%% configuration. This will load any default Bondy api specs.
%% Notice this is not the way to start the admin api listeners see
%% {@link start_admin_listeners()} for that.
%% @end
%% -----------------------------------------------------------------------------
start_listeners() ->
    DTables = case load_dispatch_tables() of
        [] ->
            [
                {<<"http">>, base_routes()},
                {<<"https">>, base_routes()}
            ];
        L ->
            L
    end,
    _ = [start_listener({Scheme, Routes}) || {Scheme, Routes} <- DTables],
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start_admin_listeners() ->
    _ = [
        start_admin_listener({Scheme, Routes})
        || {Scheme, Routes} <- parse_specs([admin_spec()], admin_base_routes())],
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start_listener({Scheme :: binary(), [tuple()]}) -> ok.

start_listener({<<"http">>, Routes}) ->
    {ok, _} = start_http(Routes, ?HTTP),
    ok;

start_listener({<<"https">>, Routes}) ->
    {ok, _} = start_https(Routes, ?HTTPS),
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start_admin_listener({Scheme :: binary(), [tuple()]}) -> ok.

start_admin_listener({<<"http">>, Routes}) ->
    {ok, _} = start_http(Routes, ?ADMIN_HTTP),
    ok;

start_admin_listener({<<"https">>, Routes}) ->
    {ok, _} = start_https(Routes, ?ADMIN_HTTPS),
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start_http(list(), atom()) -> {ok, Pid :: pid()} | {error, any()}.

start_http(Routes, Name) ->
    {ok, Opts} = application:get_env(bondy, Name),
    {_, PoolSize} = lists:keyfind(acceptors_pool_size, 1, Opts),
    {_, Port} = lists:keyfind(port, 1, Opts),

    cowboy:start_clear(
        Name,
        [{port, Port}, {num_acceptors, PoolSize}],
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
            metrics_callback => fun prometheus_cowboy2_instrumenter:observe/1,
            %% cowboy_metrics_h must be first on the list
            stream_handlers => [
                cowboy_metrics_h, cowboy_compress_h, cowboy_stream_h
            ],
            middlewares => [
                cowboy_router,
                cowboy_handler
            ]
        }
    ).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start_https(list(), atom()) -> {ok, Pid :: pid()} | {error, any()}.

start_https(Routes, Name) ->
    {ok, Opts} = application:get_env(bondy, Name),
    {_, PoolSize} = lists:keyfind(acceptors_pool_size, 1, Opts),
    {_, Port} = lists:keyfind(port, 1, Opts),
    {_, PKIFiles} = lists:keyfind(pki_files, 1, Opts),
    cowboy:start_tls(
        Name,
        [{port, Port}, {num_acceptors, PoolSize} | PKIFiles],
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
            stream_handlers => [
                cowboy_compress_h, cowboy_stream_h
            ],
            middlewares => [
                cowboy_router,
                cowboy_handler
            ]
        }
    ).


%% -----------------------------------------------------------------------------
%% @doc
%% Parses the provided Spec, stores it in the metadata store and calls
%% rebuild_dispatch_tables/0.
%% @end
%% -----------------------------------------------------------------------------
-spec load(file:filename() | map()) ->
    ok | {error, invalid_specification_format | any()}.

load(Map) when is_map(Map) ->
    case parse_spec(Map) of
        {ok, #{<<"id">> := Id} = Spec} ->
            %% We store the parsed Spec in the MD store
            ok = maybe_init_groups(maps:get(<<"realm_uri">>, Spec)),
            ok = add(
                Id,
                maps:put(<<"ts">>, erlang:monotonic_time(millisecond), Map)
            ),
            %% We rebuild the dispatch table
            rebuild_dispatch_tables();
        {error, _} = Error ->
            Error
    end;

load(FName) ->
    try jsx:consult(FName, [return_maps]) of
        [Spec] ->
            load(Spec)
    catch
        error:badarg ->
            {error, invalid_specification_format}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Loads all configured API specs from the metadata store and rebuilds the
%% Cowboy dispatch table by calling cowboy_router:compile/1 and updating the
%% environment.
%% @end
%% -----------------------------------------------------------------------------
rebuild_dispatch_tables() ->
    %% We get a dispatch table per scheme
    _ = [
        rebuild_dispatch_table(Scheme, Routes) ||
        {Scheme, Routes} <- load_dispatch_tables()
    ],
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec dispatch_table(listener()) -> any().

dispatch_table(Listener) ->
    Map = ranch:get_protocol_options(Listener),
    maps_utils:get_path([env, dispatch], Map).



%% -----------------------------------------------------------------------------
%% @doc
%% We store the API Spec in the metadata store. Notice that we store the JSON
%% and not the parsed spec as the parsed spec might contain mops proxy
%% functions.  In case we upgrade the code of the mops.erl module those funs
%% will no longer be valid and will fail with a badfun exception.
%% @end
%% -----------------------------------------------------------------------------
add(Id, Spec) when is_binary(Id), is_map(Spec) ->
    plumtree_metadata:put(?PREFIX, Id, Spec).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(binary()) -> map() | {error, not_found}.

lookup(Id) ->
    case plumtree_metadata:get(?PREFIX, Id)  of
        Spec when is_map(Spec) ->
            Spec;
        undefined ->
            {error, not_found}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec list() -> [ParsedSpec :: map()].

list() ->
    [V || {_K, [V]} <- plumtree_metadata:to_list(?PREFIX), V =/= '$deleted'].



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec delete(binary()) -> ok.

delete(Id) when is_binary(Id) ->
    plumtree_metadata:delete(?PREFIX, Id),
    ok.



%% =============================================================================
%% PRIVATE
%% =============================================================================



parse_spec(Map) ->
    try bondy_api_gateway_spec_parser:parse(Map) of
        Spec ->
            {ok, Spec}
    catch
        error:Reason ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Loads  API specs from metadata store, parses them and generates a
%% dispatch table per scheme.
%% @end
%% -----------------------------------------------------------------------------
load_dispatch_tables() ->
    %% We sorted by time, this is becuase in case api definitions overlap
    %% we want at least try to process them in FIFO order.
    %% @TODO This does not work in a distributed env, since we are relying
    %% on wall clock, to be solve by using a CRDT?
    Specs = lists:sort([
        begin
            try
                Parsed = bondy_api_gateway_spec_parser:parse(V),
                Ts = maps:get(<<"ts">>, V),
                lager:info(
                    "Loading and parsing API Gateway specification from store"
                    ", name=~s, id=~s, ts=~p",
                    [maps:get(<<"name">>, V), maps:get(<<"id">>, V), Ts]
                ),
                {K, Ts, Parsed}
            catch
                _:_ ->
                    _ = delete(K),
                    lager:info(
                        "Removed invalid API Gateway specification from store"),
                    []
            end

        end ||
        {K, [V]} <- plumtree_metadata:to_list(?PREFIX),
        V =/= '$deleted'
    ]),
    bondy_api_gateway_spec_parser:dispatch_table(
        [element(3, S) || S <- Specs], base_routes()).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec rebuild_dispatch_table(atom() | binary(), list()) -> ok.

rebuild_dispatch_table(http, Routes) ->
    rebuild_dispatch_table(<<"http">>, Routes);

rebuild_dispatch_table(https, Routes) ->
    rebuild_dispatch_table(<<"https">>, Routes);

rebuild_dispatch_table(<<"http">>, Routes) ->
    cowboy:set_env(?HTTP, dispatch, cowboy_router:compile(Routes));

rebuild_dispatch_table(<<"https">>, Routes) ->
    cowboy:set_env(?HTTPS, dispatch, cowboy_router:compile(Routes)).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
base_routes() ->
    %% The WS entrypoint required for WAMP WS subprotocol
    [
        {'_', [
            {"/ws", bondy_ws_handler, #{}}
        ]}
    ].


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
admin_base_routes() ->
    [
        {'_', [
            {"/ws", bondy_ws_handler, #{}},
            {"/metrics/[:registry]", prometheus_cowboy2_handler, []}
        ]}
    ].


admin_spec() ->
    {ok, Base} = application:get_env(bondy, platform_etc_dir),
    File = Base ++ "/bondy_admin_api.json",
    try jsx:consult(File, [return_maps]) of
        [Spec] ->
            Spec
    catch
        error:badarg ->
            _ = lager:error(
                "Error processing API Gateway Specification file. "
                "File not found or invalid specification format, "
                "type=error, reason=badarg, file_name=~p",
                [File]),
            exit(badarg)
    end.


%% @private
parse_specs(Specs, BaseRoutes) ->
    case [bondy_api_gateway_spec_parser:parse(S) || S <- Specs] of
        [] ->
            [
                {<<"http">>, BaseRoutes},
                {<<"https">>, BaseRoutes}
            ];
        L ->
            _ = [
                maybe_init_groups(maps:get(<<"realm_uri">>, Spec))
                || Spec <- L
            ],
            bondy_api_gateway_spec_parser:dispatch_table(L, BaseRoutes)
    end.




%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Reads all Bondy Gateway Specification files in the provided `specs_path`
%% configuration option.
%% @end
%% -----------------------------------------------------------------------------
%% specs() ->
%%     case application:get_env(bondy, api_gateway, undefined) of
%%         undefined ->
%%             % specs("./etc");
%%             [];
%%         Opts ->
%%             case lists:keyfind(specs_path, 1, Opts) of
%%                 false ->
%%                     % specs("./etc");
%%                     [];
%%                 {_, Path} ->
%%                     % lists:append([specs(Path), specs("./etc")])
%%                     specs(Path)
%%             end
%%     end.



%% @private
%% specs(Path) ->
%%     case filelib:wildcard(filename:join([Path, "*.json"])) of
%%         [] ->
%%             [];
%%         FNames ->
%%             Fold = fun(FName, Acc) ->
%%                 try jsx:consult(FName, [return_maps]) of
%%                     [Spec] ->
%%                         [Spec|Acc]
%%                 catch
%%                     error:badarg ->
%%                         _ = lager:error(
%%                             "Error processing API Gateway Specification file, "
%%                             "type=error, reason=~p, file_name=~p", [invalid_specification_format, FName]),
%%                         Acc
%%                 end
%%             end,
%%             lists:foldl(Fold, [], FNames)
%%     end.



%% @private
maybe_init_groups(RealmUri) ->
    Gs = [
        #{
            <<"name">> => <<"resource_owners">>,
            <<"meta">> => #{
                <<"description">> => <<"A group of entities capable of granting access to a protected resource. When the resource owner is a person, it is referred to as an end-user.">>
            }
        },
        #{
            <<"name">> => <<"api_clients">>,
            <<"meta">> => #{
                <<"description">> => <<"A group of applications making protected resource requests through Bondy API Gateway by themselves or on behalf of a Resource Owner.">>
                }
        }
    ],
    _ = [begin
        case bondy_security_group:lookup(RealmUri, maps:get(<<"name">>, G)) of
            {error, not_found} ->
                bondy_security_group:add(RealmUri, G);
            _ ->
                ok
        end
    end || G <- Gs],
    ok.
