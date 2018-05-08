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
-behaviour(gen_server).
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
-export([delete/1]).
-export([dispatch_table/1]).
-export([rebuild_dispatch_tables/0]).
-export([list/0]).
-export([load/1]).
-export([lookup/1]).
-export([start_admin_listeners/0]).
-export([start_listeners/0]).
-export([start_link/0]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).



%% =============================================================================
%% API
%% =============================================================================



start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%% -----------------------------------------------------------------------------
%% @doc
%% Conditionally start the public http and https listeners based on the
%% configuration. This will load any default Bondy api specs.
%% Notice this is not the way to start the admin api listeners see
%% {@link start_admin_listeners()} for that.
%% @end
%% -----------------------------------------------------------------------------
start_listeners() ->
    gen_server:call(?MODULE, start_listeners).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start_admin_listeners() ->
    gen_server:call(?MODULE, start_admin_listeners).


%% -----------------------------------------------------------------------------
%% @doc
%% Parses the provided Spec, stores it in the metadata store and calls
%% rebuild_dispatch_tables/0.
%% @end
%% -----------------------------------------------------------------------------
-spec load(file:filename() | map()) ->
    ok | {error, invalid_specification_format | any()}.

load(Map) when is_map(Map) ->
    gen_server:call(?MODULE, {load, Map}).


%% -----------------------------------------------------------------------------
%% @doc Returns the current dispatch configured in the HTTP server.
%% @end
%% -----------------------------------------------------------------------------
-spec dispatch_table(listener()) -> any().

dispatch_table(Listener) ->
    Map = ranch:get_protocol_options(Listener),
    maps_utils:get_path([env, dispatch], Map).


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
%% @doc Returns the API Specification object identified by `Id'.
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(binary()) -> map() | {error, not_found}.

lookup(Id) ->
    case plum_db:get(?PREFIX, Id)  of
        Spec when is_map(Spec) ->
            Spec;
        undefined ->
            {error, not_found}
    end.


%% -----------------------------------------------------------------------------
%% @doc Returns the list of all stored API Specification objects.
%% @end
%% -----------------------------------------------------------------------------
-spec list() -> [ParsedSpec :: map()].

list() ->
    [V || {_K, [V]} <- plum_db:to_list(?PREFIX), V =/= '$deleted'].



%% -----------------------------------------------------------------------------
%% @doc Deletes the API Specification object identified by `Id'.
%% @end
%% -----------------------------------------------------------------------------
-spec delete(binary()) -> ok.

delete(Id) when is_binary(Id) ->
    plum_db:delete(?PREFIX, Id),
    ok.




%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([]) ->
    %% We subscribe to change notifications in plum_db_events, so we get updates
    %% to API Specs coming from another node so that we recompile the Cowboy
    %% dispatch tables
    MS = [{{{?PREFIX, '_'}, '_'}, [], [true]}],
    ok = plum_db_events:subscribe(object_update, MS),
    {ok, undefined}.


handle_call(start_listeners, _From, State) ->
    Res = do_start_listeners(),
    {reply, Res, State};

handle_call(start_admin_listeners, _From, State) ->
    Res = do_start_admin_listeners(),
    {reply, Res, State};

handle_call({load, Map}, _From, State) ->
    Res = load_spec(Map),
    {reply, Res, State};

handle_call(Event, From, State) ->
    _ = lager:error(
        "Error handling call, reason=unsupported_event, event=~p, from=~p", [Event, From]),
    {noreply, State}.


handle_cast(Event, State) ->
    _ = lager:error(
        "Error handling call, reason=unsupported_event, event=~p", [Event]),
    {noreply, State}.


handle_info({plum_db_event, object_update, {{?PREFIX, Key}, _}}, State) ->
    %% We've got a notification that an API Spec object has been updated
    %% in the database via cluster replication, so we need to rebuild the
    %% Cowboy dispatch tables
    _ = lager:info(
        "API Spec object_update received,"
        " rebuilding HTTP server dispatch tables; key=~p",
        [Key]
    ),
    ok = rebuild_dispatch_tables(),
    {noreply, State};

handle_info(Info, State) ->
    _ = lager:debug("Unexpected message, message=~p", [Info]),
    {noreply, State}.


terminate(normal, _State) ->
    ok;
terminate(shutdown, _State) ->
    ok;
terminate({shutdown, _}, _State) ->
    ok;
terminate(_Reason, _State) ->
    %% TODO publish metaevent
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
do_start_listeners() ->
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


%% @private
do_start_admin_listeners() ->
    _ = [
        start_admin_listener({Scheme, Routes})
        || {Scheme, Routes} <- parse_specs([admin_spec()], admin_base_routes())],
    ok.



load_spec(Map) when is_map(Map) ->
    case validate_spec(Map) of
        {ok, #{<<"id">> := Id} = Spec} ->
            %% We store the source specification, see add/2 for an explanation
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

load_spec(FName) ->
    try jsx:consult(FName, [return_maps]) of
        [Spec] ->
            load(Spec)
    catch
        error:badarg ->
            {error, invalid_specification_format}
    end.

%% -----------------------------------------------------------------------------
%% @doc
%% We store the API Spec in the metadata store. Notice that we store the JSON
%% and not the parsed spec as the parsed spec might contain mops proxy
%% functions.  In case we upgrade the code of the mops.erl module those funs
%% will no longer be valid and will fail with a badfun exception.
%% @end
%% -----------------------------------------------------------------------------
add(Id, Spec) when is_binary(Id), is_map(Spec) ->
    plum_db:put(?PREFIX, Id, Spec).



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
            metrics_callback => fun bondy_cowboy_prometheus:observe/1,
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


validate_spec(Map) ->
    try
        Spec = bondy_api_gateway_spec_parser:parse(Map),
        %% We compile it to validate the spec, if it is not valid it fill
        %% fail with badarg
        SchemeTables = bondy_api_gateway_spec_parser:dispatch_table(Spec),
        [_ = cowboy_router:compile(Table) || {_Scheme, Table} <- SchemeTables],
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
    %% We sorted by time, this is because in case api definitions overlap
    %% we want at least try to process them in FIFO order.
    %% @TODO This does not work in a distributed env, since we are relying
    %% on wall clock, to be solve by using a CRDT?
    Specs = lists:sort([
        begin
            try
                Parsed = bondy_api_gateway_spec_parser:parse(V),
                Ts = maps:get(<<"ts">>, V),
                _ = lager:info(
                    "Loading and parsing API Gateway specification from store"
                    ", name=~s, id=~s, ts=~p",
                    [maps:get(<<"name">>, V), maps:get(<<"id">>, V), Ts]
                ),
                {K, Ts, Parsed}
            catch
                _:_ ->
                    _ = delete(K),
                    _ = lager:warning(
                        "Removed invalid API Gateway specification from store"),
                    []
            end

        end ||
        {K, [V]} <- plum_db:to_list(?PREFIX),
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
            {"/ws", bondy_wamp_ws_handler, #{}}
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
            {"/ws", bondy_wamp_ws_handler, #{}},
            {"/ping", bondy_http_ping_handler, #{}},
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
