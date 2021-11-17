%% =============================================================================
%%  bondy_http_gateway.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
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
-module(bondy_http_gateway).
-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").



-define(PREFIX, {api_gateway, api_specs}).
-define(HTTP, api_gateway_http).
-define(HTTPS, api_gateway_https).
-define(ADMIN_HTTP, admin_api_http).
-define(ADMIN_HTTPS, admin_api_https).

-record(state, {
    exchange_ref            ::  {pid(), reference()} | undefined,
    updated_specs = []      ::  list(),
    subscriptions = #{}     ::  #{id() => uri()}
}).


-type listener()    ::  api_gateway_http
                        | api_gateway_https
                        | admin_api_http
                        | admin_api_https.


%% API
-export([delete/1]).
-export([dispatch_table/1]).
-export([list/0]).
-export([apply_config/0]).
-export([load/1]).
-export([lookup/1]).
-export([rebuild_dispatch_tables/0]).
-export([resume_admin_listeners/0]).
-export([resume_listeners/0]).
-export([start_admin_listeners/0]).
-export([start_link/0]).
-export([start_listeners/0]).
-export([stop_admin_listeners/0]).
-export([stop_listeners/0]).
-export([suspend_admin_listeners/0]).
-export([suspend_listeners/0]).

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


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
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
-spec start_listeners() -> ok.

start_listeners() ->
    gen_server:call(?MODULE, {start_listeners, public}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec suspend_listeners() -> ok.

suspend_listeners() ->
    gen_server:call(?MODULE, {suspend_listeners, public}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec resume_listeners() -> ok.

resume_listeners() ->
    gen_server:call(?MODULE, {resume_listeners, public}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec stop_listeners() -> ok.

stop_listeners() ->
    gen_server:call(?MODULE, {stop_listeners, public}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start_admin_listeners() ->
    gen_server:call(?MODULE, {start_listeners, admin}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec stop_admin_listeners() -> ok.

stop_admin_listeners() ->
    gen_server:call(?MODULE, {stop_listeners, admin}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec suspend_admin_listeners() -> ok.

suspend_admin_listeners() ->
    gen_server:call(?MODULE, {suspend_listeners, admin}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec resume_admin_listeners() -> ok.

resume_admin_listeners() ->
    gen_server:call(?MODULE, {resume_listeners, admin}).


%% -----------------------------------------------------------------------------
%% @doc
%% Parses the apis provided by the configuration file
%% ('bondy.api_gateway.config_file'), stores the apis in the metadata store.
%% This call does not load the spec in the HTTP server dispatch tables.
%% @end
%% -----------------------------------------------------------------------------
-spec apply_config() ->
    ok | {error, invalid_specification_format | any()}.

apply_config() ->
    gen_server:call(?MODULE, apply_config).


%% -----------------------------------------------------------------------------
%% @doc
%% Parses the provided Spec, adds it to the store and calls
%% rebuild_dispatch_tables/0.
%% @end
%% -----------------------------------------------------------------------------
-spec load(file:filename() | map()) ->
    ok | {error, invalid_specification_format | any()}.

load(Term) when is_map(Term) orelse is_list(Term) ->
    gen_server:call(?MODULE, {load, Term}).


%% -----------------------------------------------------------------------------
%% @doc Returns the current dispatch configured in Cowboy for the
%% given Listener.
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
    ?LOG_INFO(#{
        description => "Rebuilding HTTP Gateway dispatch tables"
    }),
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
    case plum_db:get(?PREFIX, Id) of
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
%% Notice: Triggers a rebuild of the Cowboy dispatch tables.
%% @end
%% -----------------------------------------------------------------------------
-spec delete(binary()) -> ok.

delete(Id) when is_binary(Id) ->
    plum_db:delete(?PREFIX, Id),
    ok = rebuild_dispatch_tables(),
    ok.



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([]) ->
    State = subscribe(#state{}),
    {ok, State}.


handle_call({start_listeners, Type}, _From, State) ->
    Res = do_start_listeners(Type),
    {reply, Res, State};

handle_call({suspend_listeners, Type}, _From, State) ->
    Res = do_suspend_listeners(Type),
    {reply, Res, State};

handle_call({resume_listeners, Type}, _From, State) ->
    Res = do_resume_listeners(Type),
    {reply, Res, State};

handle_call({stop_listeners, Type}, _From, State) ->
    Res = do_stop_listeners(Type),
    {reply, Res, State};

handle_call(apply_config, _From, State) ->
    Res = do_apply_config(),
    {reply, Res, State};

handle_call({load, Map}, _From, State) ->
    try
        Res = load_spec(Map),
        ok = rebuild_dispatch_tables(),
        {reply, Res, State}
    catch
       _:Reason ->
            {reply, {error, Reason}, State}
    end;

handle_call(Event, From, State) ->
    ?LOG_ERROR(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State}.


handle_cast(#event{} = Event, State) ->
    %% We informally implement bondy_subscriber
    Id = Event#event.subscription_id,
    Topic = maps:get(Id, State#state.subscriptions, undefined),
    NewState = case {Topic, Event#event.args} of
        {undefined, _} ->
            State;
        {?BONDY_REALM_DELETED, [Uri]} ->
            on_realm_deleted(Uri, State)
    end,
    {noreply, NewState};

handle_cast(Event, State) ->
    ?LOG_ERROR(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.

handle_info({plum_db_event, exchange_started, {Pid, _Node}}, State) ->
    Ref = erlang:monitor(process, Pid),
    {noreply, State#state{exchange_ref = {Pid, Ref}}};

handle_info(
    {plum_db_event, exchange_finished, {Pid, _Reason}},
    #state{exchange_ref = {Pid, Ref}} = State0) ->

    true = erlang:demonitor(Ref),
    ok = handle_spec_updates(State0),
    State1 = State0#state{updated_specs = [], exchange_ref = undefined},
    {noreply, State1};

handle_info({plum_db_event, exchange_finished, {_, _}}, State) ->
    %% We are receiving the notification after we recevied a DOWN message
    %% we do nothing
    {noreply, State};


handle_info({plum_db_event, object_update, {{?PREFIX, Key}, _, _}}, State0) ->
    %% We've got a notification that an API Spec object has been updated
    %% in the database via cluster replication, so we need to rebuild the
    %% Cowboy dispatch tables.
    ?LOG_INFO(#{
        description => "API Specification remote update received",
        key => Key
    }),
    Specs = [Key|State0#state.updated_specs],
    State1 = State0#state{updated_specs = Specs},
    Status = {bondy_config:get(status), plum_db_config:get(aae_enabled)},

    case Status of
        {ready, false} ->
            %% We finished initialising and AAE is disabled so
            %% we try to rebuild immediately
            ok = handle_spec_updates(State1),
            {noreply, State1#state{updated_specs = []}};
        {ready, true} ->
            %% We finished initialising and AAE is enabled so
            %% we try to rebuild immediately even though we do not have causal
            %% ordering not consistency guarantees.

            %% TODO if/when we have casual ordering and reliable delivery of
            %% Security and API Gateway config we can trigger the rebuild
            %% immediately, provided an exchange has not been.

            %% TODO if rebuild disaptch tables fails, we should retry later on
            ok = handle_spec_updates(State1),
            {noreply, State1#state{updated_specs = []}};

        {_, false} ->
            %% We are either initialising or shutting down
            {noreply, State1};
        {_, true} ->
            %% We might be initialising (and have not yet performed an AAE).
            %% Since Specs depend on other objects being present and we
            %% also want to avoid rebuilding the dispatch table multiple times
            %% during initialisation, we just set a flag on the state to
            %% rebuild the dispatch tables once we received an
            %% exchange_finished event, that is we rebuild dispatch tables only
            %% after an AAE exchange
            {noreply, State1}
    end;

handle_info(
    {'DOWN', Ref, process, Pid, _Reason},
    #state{exchange_ref = {Pid, Ref}} = State0) ->

    ok = handle_spec_updates(State0),
    State1 = State0#state{updated_specs = [], exchange_ref = undefined},
    {noreply, State1};

handle_info(Info, State) ->
    ?LOG_ERROR(#{
        reason => unsupported_event,
        event => Info
    }),
    {noreply, State}.


terminate(normal, State) ->
    _ = unsubscribe(State),
    ok;

terminate(shutdown, State) ->
    _ = unsubscribe(State),
    ok;

terminate({shutdown, _}, State) ->
    _ = unsubscribe(State),
    ok;

terminate(_Reason, State) ->
    _ = unsubscribe(State),
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
subscribe(State) ->
    %% We subscribe to change notifications in plum_db_events, we are
    %% interested in updates to API Specs coming from another node so that we
    %% recompile them and generate this node's Cowboy dispatch tables
    ok = plum_db_events:subscribe(exchange_started),
    ok = plum_db_events:subscribe(exchange_finished),
    MS = [{
        %% {{{_, _} = FullPrefix, Key}, NewObj, ExistingObj}
        {{?PREFIX, '_'}, '_', '_'}, [], [true]
    }],
    ok = plum_db_events:subscribe(object_update, MS),

    %% We subscribe to WAMP events
    %% We will handle then in handle_cast/2
    {ok, Id} = bondy:subscribe(
        ?MASTER_REALM_URI,
        #{
            subscription_id => bondy_utils:get_id(global),
            match => <<"exact">>
        },
        ?BONDY_REALM_DELETED
    ),
    Subs = maps:put(Id, ?BONDY_REALM_DELETED, State#state.subscriptions),

    State#state{subscriptions = Subs}.


%% @private
unsubscribe(State) ->
    _ = plum_db_events:unsubscribe(exchange_started),
    _ = plum_db_events:unsubscribe(exchange_finished),
    _ = plum_db_events:unsubscribe(object_update),

    _ = [
        bondy_broker:unsubscribe(Id, ?MASTER_REALM_URI)
        ||  Id <- maps:keys(State#state.subscriptions)
    ],

    State#state{subscriptions = #{}}.


%% @private
do_start_listeners(public) ->
    ?LOG_NOTICE(#{
        description => "Starting public HTTP/S listeners"
    }),
    DTables = load_dispatch_tables(),
    _ = [start_listener({Scheme, Routes}) || {Scheme, Routes} <- DTables],
    ok;

do_start_listeners(admin) ->
    ?LOG_NOTICE(#{
        description => "Starting admin HTTP/S listeners"
    }),
    DTables = parse_specs([admin_spec()], admin_base_routes()),
    _ = [start_admin_listener({Scheme, Routes}) || {Scheme, Routes} <- DTables],
    ok.


%% @private
do_suspend_listeners(public) ->
    ?LOG_NOTICE(#{
        description => "Suspending public HTTP/S listeners"
    }),
    catch ranch:suspend_listener(?HTTP),
    catch ranch:suspend_listener(?HTTPS),
    ok;

do_suspend_listeners(admin) ->
    ?LOG_NOTICE(#{
        description => "Suspending admin HTTP/S listeners"
    }),
    catch ranch:suspend_listener(?ADMIN_HTTP),
    catch ranch:suspend_listener(?ADMIN_HTTPS),
    ok.


%% @private
do_resume_listeners(public) ->
    ?LOG_NOTICE(#{
        description => "Resuming public HTTP/S listeners"
    }),
    catch ranch:resume_listener(?HTTP),
    catch ranch:resume_listener(?HTTPS),
    ok;

do_resume_listeners(admin) ->
    ?LOG_NOTICE(#{
        description => "Resuming admin HTTP/S listeners"
    }),
    catch ranch:resume_listener(?ADMIN_HTTP),
    catch ranch:resume_listener(?ADMIN_HTTPS),
    ok.


%% @private
do_stop_listeners(public) ->
    ?LOG_NOTICE(#{
        description => "Stopping public HTTP/S listeners"
    }),
    catch cowboy:stop_listener(?HTTP),
    catch cowboy:stop_listener(?HTTPS),
    ok;

do_stop_listeners(admin) ->
    ?LOG_NOTICE(#{
        description => "Stopping admin HTTP/S listeners"
    }),
    catch cowboy:stop_listener(?ADMIN_HTTP),
    catch cowboy:stop_listener(?ADMIN_HTTPS),
    ok.


%% @private
-spec do_apply_config() -> ok | no_return().

do_apply_config() ->
    case bondy_config:get([api_gateway, config_file], undefined) of
        undefined -> ok;
        FName -> do_apply_config(FName)
    end.


%% @private
do_apply_config(FName) ->
    try
        case bondy_utils:json_consult(FName) of
            {ok, Spec} when is_map(Spec) ->
                load_spec(Spec);
            {ok, []} ->
                ok;
            {ok, Specs} when is_list(Specs) ->
                ?LOG_INFO(#{
                    description => "Loading configuration file found",
                    filename => FName
                }),
                _ = [load_spec(Spec) || Spec <- Specs],
                ok;
            {error, enoent} ->
                ?LOG_WARNING(#{
                    description => "No configuration file found",
                    reason => enoent,
                    filename => FName
                }),
                ok;
            {error, Reason} ->
                ?LOG_ERROR(#{
                    description => "Error while loading API specification",
                    reason => invalid_json_format,
                    filename => FName
                }),
                error({invalid_json_format, Reason})
        end
    catch
        Class:EReason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while loading API specification",
                class => Class,
                reason => EReason,
                stacktrace => Stacktrace,
                filename => FName
            }),
            ok
    end.


%% @private
load_spec(Map) when is_map(Map) ->
    case validate_spec(Map) of
        {ok, #{<<"id">> := Id} = Spec} ->
            %% We store the source specification, see add/2 for an explanation
            ok = maybe_init_groups(maps:get(<<"realm_uri">>, Spec)),
            add(
                Id,
                maps:put(<<"ts">>, erlang:monotonic_time(millisecond), Map)
            );
        {error, Reason} ->
            ?LOG_ERROR(#{
                description => "Error while loading API specification",
                reason => Reason,
                api_id => maps:get(<<"id">>, Map, undefined)
            }),
            throw(Reason)
    end;

load_spec(FName) ->
    case bondy_utils:json_consult(FName) of
        {ok, Spec} when is_map(Spec) ->
            ok = load_spec(Spec),
            rebuild_dispatch_tables();
        {ok, []} ->
            ok;
        {error, Reason} ->
            ?LOG_ERROR(#{
                description => "Error while parsing API specification",
                filename => FName,
                reason => Reason
            }),
            throw(invalid_json_format)
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
    ok = maybe_start_http(Routes, ?HTTP),
    ok;

start_listener({<<"https">>, Routes}) ->
    ok = maybe_start_https(Routes, ?HTTPS),
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start_admin_listener({Scheme :: binary(), [tuple()]}) -> ok.

start_admin_listener({<<"http">>, Routes}) ->
    ok = maybe_start_http(Routes, ?ADMIN_HTTP),
    ok;

start_admin_listener({<<"https">>, Routes}) ->
    ok = maybe_start_https(Routes, ?ADMIN_HTTPS),
    ok.


maybe_start_http(Routes, Name) ->
    case bondy_config:get([Name, enabled], true) of
        true ->
            start_http(Routes, Name);
        false ->
            ok
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start_http(list(), atom()) -> ok | {error, any()}.

start_http(Routes, Name) ->
    {TransportOpts, ProtoOpts} = cowboy_opts(Routes, Name),

    case cowboy:start_clear(Name, TransportOpts, ProtoOpts) of
        {ok, _} ->
            ok;
        {error, eaddrinuse} ->
            ?LOG_ERROR(#{
                description => "Cannot start HTTP listener, address is in use", name => Name,
                reason => eaddrinuse,
                transport_opts => TransportOpts
            }),
            {error, eaddrinuse};
        {error, _} = Error ->
            Error
    end.

maybe_start_https(Routes, Name) ->
    case bondy_config:get([Name, enabled], true) of
        true ->
            start_https(Routes, Name);
        false ->
            ok
    end.


cowboy_opts(Routes, Name) ->
    {TransportOpts, _OtherTransportOpts}  = transport_opts(Name),
    ProtocolOpts = #{
        env => #{
            bondy => #{
                auth => #{
                    %% REVIEW this in light of recent changes to auth methods
                    schemes => [basic, bearer]
                }
            },
            dispatch => cowboy_router:compile(Routes)
        },
        metrics_callback => fun bondy_prometheus_cowboy_collector:observe/1,
        %% cowboy_metrics_h must be first on the list
        stream_handlers => [
            cowboy_metrics_h,
            cowboy_compress_h,
            cowboy_stream_h
        ],
        middlewares => [
            cowboy_router,
            cowboy_handler
        ]
    },
    {TransportOpts, ProtocolOpts}.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start_https(list(), atom()) -> ok | {error, any()}.

start_https(Routes, Name) ->
    {TransportOpts, ProtoOpts} = cowboy_opts(Routes, Name),

    case cowboy:start_tls(Name, TransportOpts, ProtoOpts) of
        {ok, _} ->
            ok;
        {error, eaddrinuse} ->
            ?LOG_ERROR(#{
                description => "Cannot start HTTPS listener, address is in use",
                name => Name,
                reason => eaddrinuse,
                transport_opts => TransportOpts
            }),
            {error, eaddrinuse};
        {error, _} = Error ->
            Error
    end.


validate_spec(Map) ->
    try
        Spec = bondy_http_gateway_api_spec_parser:parse(Map),
        %% We compile it to validate the spec, if it is not valid it fill
        %% fail with badarg
        SchemeTables = bondy_http_gateway_api_spec_parser:dispatch_table(Spec),
        [_ = cowboy_router:compile(Table) || {_Scheme, Table} <- SchemeTables],
        {ok, Spec}
    catch
        _:Reason:_ ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc Loads all the existing API specs from store, parses them and generates a
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
                Parsed = bondy_http_gateway_api_spec_parser:parse(V),
                Ts = maps:get(<<"ts">>, V),
                ?LOG_INFO(#{
                    description => "Loading and parsing API Gateway specification from store",
                    name => maps:get(<<"name">>, V),
                    id => maps:get(<<"id">>, V),
                    timestamp => Ts
                }),
                {K, Ts, Parsed}
            catch
                _:_:_ ->
                    _ = delete(K),
                    ?LOG_WARNING(#{
                        description => "Removed invalid API Gateway specification from store",
                        key => K
                    }),
                    []
            end

        end ||
        {K, [V]} <- plum_db:to_list(?PREFIX),
        V =/= '$deleted'
    ]),

    Result = bondy_http_gateway_api_spec_parser:dispatch_table(
        [element(3, S) || S <- Specs], base_routes()),

    case Result of
        [] ->
            [
                {<<"http">>, base_routes()},
                {<<"https">>, base_routes()}
            ];
        _ ->
            Result
    end.



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


%% @private
handle_spec_updates(#state{updated_specs = []}) ->
    ok;

handle_spec_updates(#state{updated_specs = [Key]}) ->
    ?LOG_INFO(#{
        description => "API Spec object_update received",
        key => Key
    }),
    rebuild_dispatch_tables();

handle_spec_updates(#state{updated_specs = L}) ->
    ?LOG_INFO(#{
        description => "Multiple API Spec object_update(s) received",
        count => length(L)
    }),
    rebuild_dispatch_tables().


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
base_routes() ->
    %% The WS entrypoint required for WAMP WS subprotocol
    [
        {'_', [
            {"/ws", bondy_wamp_ws_connection_handler, #{}}
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
            {"/ws", bondy_wamp_ws_connection_handler, #{}},
            {"/ping", bondy_admin_ping_http_handler, #{}},
            {"/ready", bondy_admin_ready_http_handler, #{}},
            {"/metrics/[:registry]", prometheus_cowboy2_handler, []}
        ]}
    ].


admin_spec() ->
    Base = bondy_config:get(priv_dir),
    File = filename:join(Base, "specs/bondy_admin_api.json"),
    case bondy_utils:json_consult(File) of
        {ok, Spec} ->
            Spec;
        {error, enoent} ->
            ?LOG_ERROR(#{
                description => "Error processing API Gateway Specification file.",
                filename => File,
                reason => file:format_error(enoent)
            }),
            exit(enoent);
        {error, Reason} ->
            ?LOG_ERROR(#{
                description => "Error while parsing API Gateway Specification file",
                filename => File,
                reason => Reason
            }),
            exit(invalid_json_format)
    end.


%% @private
parse_specs(Specs, BaseRoutes) ->
    case [bondy_http_gateway_api_spec_parser:parse(S) || S <- Specs] of
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
            bondy_http_gateway_api_spec_parser:dispatch_table(L, BaseRoutes)
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
        case bondy_rbac_group:lookup(RealmUri, maps:get(<<"name">>, G)) of
            {error, not_found} ->
                bondy_rbac_group:add(RealmUri, bondy_rbac_group:new(G));
            _ ->
                ok
        end
    end || G <- Gs],
    ok.


transport_opts(Name) ->
    Opts = bondy_config:get(Name),
    {_, Port} = lists:keyfind(port, 1, Opts),
    {_, PoolSize} = lists:keyfind(acceptors_pool_size, 1, Opts),
    {_, MaxConnections} = lists:keyfind(max_connections, 1, Opts),

    %% In ranch 2.0 we will need to use socket_opts directly
    {SocketOpts, OtherSocketOpts} = case lists:keyfind(socket_opts, 1, Opts) of
        {socket_opts, L} -> normalise(L);
        false -> {[], []}
    end,

    TransportOpts = #{
        num_acceptors => PoolSize,
        max_connections =>  MaxConnections,
        socket_opts => [{port, Port} | SocketOpts]
    },
    {TransportOpts, OtherSocketOpts}.


    %% #{
    %%     port => Port,
    %%     num_acceptors => PoolSize,
    %%     max_connections => MaxConnections,
    %%     %% handshake_timeout => timeout(),
    %%     %% logger => module(),
    %%     %% num_conns_sups => pos_integer(),
    %%     %% num_listen_sockets => pos_integer(),
    %%     %% shutdown => timeout() | brutal_kill,
    %%     socket_opts => SocketOpts
    %% }.


normalise(Opts0) ->
    Sndbuf = lists:keyfind(sndbuf, 1, Opts0),
    Recbuf = lists:keyfind(recbuf, 1, Opts0),

    Opts1 = case Sndbuf =/= false andalso Recbuf =/= false of
        true ->
            Buffer0 = lists:keyfind(buffer, 1, Opts0),
            Buffer1 = max(Buffer0, max(Sndbuf, Recbuf)),
            lists:keystore(buffer, 1, Opts0, {buffer, Buffer1});
        false ->
            Opts0
    end,

    lists:splitwith(
        fun
            ({nodelay, _}) -> false;
            ({keepalive, _}) -> false;
            ({_, _}) -> true
        end,
        Opts1
    ).



%% -----------------------------------------------------------------------------
%% @private
%% @doc Tear down all APIs for that realm when event occurs
%% @end
%% -----------------------------------------------------------------------------
on_realm_deleted(_RealmUri, State) ->
    %% TODO
    State.