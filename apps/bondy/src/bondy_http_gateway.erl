%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_gateway).

-moduledoc """
Manages Cowboy HTTP/HTTPS listeners and the API Gateway dispatch tables.

This gen_server is responsible for the full lifecycle of the Bondy HTTP
API Gateway: loading API specification documents, storing them in plum_db,
compiling them into Cowboy dispatch tables, and starting/stopping/suspending
the underlying Ranch/Cowboy listeners.

## Listeners

Four listener names are supported:

| Name | Description |
|---|---|
| `api_gateway_http` | Public HTTP listener |
| `api_gateway_https` | Public HTTPS listener |
| `admin_api_http` | Admin HTTP listener |
| `admin_api_https` | Admin HTTPS listener |

Each listener can be independently started, stopped, suspended and resumed
via the corresponding public API functions.

## API specifications

API specs are JSON documents parsed by `bondy_http_gateway_api_spec_parser`.
They are stored in plum_db under the `{api_gateway, api_specs}` prefix so
they are replicated across cluster nodes. When a spec is loaded:

1. The JSON document is validated and parsed
2. The parsed spec is compiled into a Cowboy dispatch table
   (`cowboy_router:compile/1`) to verify correctness
3. The **source JSON** (not the parsed form) is persisted in plum_db —
   parsed specs can contain `mops` proxy funs that become invalid after a
   code upgrade, so we always re-parse from source
4. The dispatch tables are rebuilt for all active listeners

## Cluster replication

The server subscribes to three plum_db event classes:

- `exchange_started` — a new AAE exchange has begun with a peer node
- `exchange_finished` — the exchange completed; the server rebuilds
  dispatch tables from any specs updated during the exchange
- `object_update` — an individual API spec was replicated from another
  node; if the system is in `ready` state the dispatch tables are
  rebuilt immediately, otherwise the update is buffered until the next
  exchange completes

This batching avoids redundant rebuilds during initial startup when many
specs may arrive in quick succession.

## WAMP subscriptions

The server subscribes to `bondy.realm.deleted` on the master realm. When
a realm is deleted the server can tear down all API specs associated with
that realm (currently a placeholder).

## Base routes

Every listener includes a base set of routes that are always present
regardless of loaded API specs:

- Public listeners: `/ws` (WAMP WebSocket endpoint)
- Admin listeners: `/ws`, `/ping`, `/ready`, `/metrics/[:registry]`

## Configuration

- `bondy.api_gateway.config_file` — optional path to a JSON file
  containing one or more API spec documents, loaded at startup via
  `apply_config/0`

## Connection alarms

Listeners are configured with two connection-count alarms:

- **75% threshold** — logs a warning when 75% of `max_connections` is
  reached
- **90% threshold** — logs an alert when 90% of `max_connections` is
  reached
""".

-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").


-define(DISPATCH_KEY(Name), {?MODULE, dispatch, Name}).
-define(PREFIX, {api_gateway, api_specs}).
-define(HTTP, api_gateway_http).
-define(HTTPS, api_gateway_https).
-define(ADMIN_HTTP, admin_api_http).
-define(ADMIN_HTTPS, admin_api_https).

-record(state, {
    %% Use for WAMP subscriptions
    bondy_ref               ::  bondy_ref:t(),
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



-doc "Starts the gen_server and registers it as `bondy_http_gateway`.".
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


-doc """
Starts the public HTTP and HTTPS listeners based on the configuration.

Loads all API specs from the metadata store, compiles them into Cowboy
dispatch tables, and starts the `api_gateway_http` and `api_gateway_https`
Ranch listeners (when enabled). This does not start the admin listeners;
use `start_admin_listeners/0` for that.
""".
-spec start_listeners() -> ok | {error, any()}.

start_listeners() ->
    gen_server:call(?MODULE, {start_listeners, public}).


-doc """
Suspends the public HTTP and HTTPS listeners.

Suspended listeners stop accepting new connections but keep existing
connections alive.
""".
-spec suspend_listeners() -> ok.

suspend_listeners() ->
    gen_server:call(?MODULE, {suspend_listeners, public}).


-doc "Resumes the public HTTP and HTTPS listeners after a suspension.".
-spec resume_listeners() -> ok.

resume_listeners() ->
    gen_server:call(?MODULE, {resume_listeners, public}).


-doc "Stops the public HTTP and HTTPS listeners and closes all connections.".
-spec stop_listeners() -> ok.

stop_listeners() ->
    gen_server:call(?MODULE, {stop_listeners, public}).


-doc """
Starts the admin HTTP and HTTPS listeners.

Loads the built-in admin API spec from `priv/specs/bondy_admin_api.json`,
compiles the dispatch table, and starts the `admin_api_http` and
`admin_api_https` Ranch listeners (when enabled). The admin listeners
include the `/ping`, `/ready` and `/metrics` endpoints in addition to
the WAMP WebSocket endpoint.
""".
-spec start_admin_listeners() -> ok | {error, any()}.

start_admin_listeners() ->
    gen_server:call(?MODULE, {start_listeners, admin}).


-doc "Stops the admin HTTP and HTTPS listeners and closes all connections.".
-spec stop_admin_listeners() -> ok.

stop_admin_listeners() ->
    gen_server:call(?MODULE, {stop_listeners, admin}).


-doc """
Suspends the admin HTTP and HTTPS listeners.

Suspended listeners stop accepting new connections but keep existing
connections alive.
""".
-spec suspend_admin_listeners() -> ok.

suspend_admin_listeners() ->
    gen_server:call(?MODULE, {suspend_listeners, admin}).


-doc "Resumes the admin HTTP and HTTPS listeners after a suspension.".
-spec resume_admin_listeners() -> ok.

resume_admin_listeners() ->
    gen_server:call(?MODULE, {resume_listeners, admin}).


-doc """
Loads API specs from the configuration file into the metadata store.

Reads the JSON file at `bondy.api_gateway.config_file`, parses each
spec, validates it, and stores it in plum_db. Does **not** rebuild the
Cowboy dispatch tables — call `rebuild_dispatch_tables/0` or `load/1`
for that.
""".
-spec apply_config() ->
    ok | {error, invalid_specification_format | any()}.

apply_config() ->
    gen_server:call(?MODULE, apply_config).


-doc """
Parses an API spec, stores it in plum_db, and rebuilds dispatch tables.

Accepts either a map (a single parsed JSON spec) or a list of maps.
The spec is validated by compiling it through
`bondy_http_gateway_api_spec_parser` and `cowboy_router:compile/1`
before being persisted. On success the Cowboy dispatch tables for all
active listeners are rebuilt immediately.
""".
-spec load(file:filename() | map()) ->
    ok | {error, invalid_specification_format | any()}.

load(Term) when is_map(Term) orelse is_list(Term) ->
    gen_server:call(?MODULE, {load, Term}).


-doc """
Returns the current Cowboy dispatch table for the given listener.

Retrieves the compiled dispatch rules from Ranch's protocol options
for `Listener`.
""".
-spec dispatch_table(listener()) -> any().

dispatch_table(Listener) ->
    Map = ranch:get_protocol_options(Listener),
    maps_utils:get_path([env, dispatch], Map).


-doc """
Rebuilds the Cowboy dispatch tables for all active public listeners.

Loads every API spec from plum_db, re-parses them, compiles the
dispatch table via `cowboy_router:compile/1`, and stores the result
in `persistent_term` for each enabled listener (`api_gateway_http`,
`api_gateway_https`).
""".
rebuild_dispatch_tables() ->
    ?LOG_NOTICE(#{
        description => "Rebuilding HTTP Gateway dispatch tables"
    }),
    _ = [
        rebuild_dispatch_table(Scheme, Routes) ||
        {Scheme, Routes} <- load_dispatch_tables()
    ],
    ok.


-doc """
Returns the API specification stored under `Id`, or `{error, not_found}`.

The returned map is the **source JSON** as originally loaded, not the
parsed form.
""".
-spec lookup(binary()) -> map() | {error, not_found}.

lookup(Id) ->
    case plum_db:get(?PREFIX, Id) of
        Spec when is_map(Spec) ->
            Spec;
        undefined ->
            {error, not_found}
    end.


-doc "Returns the list of all stored API specification objects.".
-spec list() -> [ParsedSpec :: map()].

list() ->
    [V || {_K, [V]} <- plum_db:to_list(?PREFIX), V =/= '$deleted'].



-doc """
Deletes the API specification identified by `Id` and rebuilds dispatch tables.

The spec is removed from plum_db and the Cowboy dispatch tables are
recompiled to reflect the removal.
""".
-spec delete(binary()) -> ok.

delete(Id) when is_binary(Id) ->
    plum_db:delete(?PREFIX, Id),
    ok = rebuild_dispatch_tables(),
    ok.



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([]) ->
    SessionId = bondy_session_id:new(),
    Ref = bondy_ref:new(internal, self(), SessionId),
    State = subscribe(#state{bondy_ref = Ref}),
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
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State}.




handle_cast(Event, State) ->
    ?LOG_WARNING(#{
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

    true = erlang:demonitor(Ref, [flush]),
    ok = handle_spec_updates(State0),
    State1 = State0#state{updated_specs = [], exchange_ref = undefined},
    {noreply, State1};

handle_info({plum_db_event, exchange_finished, {_, _}}, State) ->
    %% We are receiving the notification after we received a DOWN message
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

handle_info({?BONDY_REQ, _, ?MASTER_REALM_URI, #event{} = Event}, State) ->
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

handle_info(
    {'DOWN', Ref, process, Pid, _Reason},
    #state{exchange_ref = {Pid, Ref}} = State0) ->

    ok = handle_spec_updates(State0),
    State1 = State0#state{updated_specs = [], exchange_ref = undefined},
    {noreply, State1};

handle_info(Info, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Info,
        state_exchange_ref => State#state.exchange_ref
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
    {ok, Id} = bondy_broker:subscribe(
        ?MASTER_REALM_URI,
        #{
            subscription_id => bondy_message_id:global(),
            match => <<"exact">>
        },
        ?BONDY_REALM_DELETED,
        State#state.bondy_ref
    ),
    Subs = maps:put(Id, ?BONDY_REALM_DELETED, State#state.subscriptions),

    State#state{
        subscriptions = Subs
    }.


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
        description => "Starting public HTTP(S) listeners"
    }),

    DTables = load_dispatch_tables(),

    try
        _ = [
            resulto:throw_or(start_listener({Scheme, Routes}))
            || {Scheme, Routes} <- DTables
        ],
        ok
    catch
        throw:Reason ->
            {error, Reason}
    end;

do_start_listeners(admin) ->
    ?LOG_NOTICE(#{
        description => "Starting admin HTTP(S) listeners"
    }),

    DTables = parse_specs([admin_spec()], admin_base_routes()),

    try
        _ = [
            resulto:throw_or(start_admin_listener({Scheme, Routes}))
            || {Scheme, Routes} <- DTables
        ],
        ok
    catch
        throw:Reason ->
            {error, Reason}
    end.


%% @private
do_suspend_listeners(public) ->
    ?LOG_NOTICE(#{
        description => "Suspending public HTTP(S) listeners"
    }),
    catch ranch:suspend_listener(?HTTP),
    catch ranch:suspend_listener(?HTTPS),
    ok;

do_suspend_listeners(admin) ->
    ?LOG_NOTICE(#{
        description => "Suspending admin HTTP(S) listeners"
    }),
    catch ranch:suspend_listener(?ADMIN_HTTP),
    catch ranch:suspend_listener(?ADMIN_HTTPS),
    ok.


%% @private
do_resume_listeners(public) ->
    ?LOG_NOTICE(#{
        description => "Resuming public HTTP(S) listeners"
    }),
    catch ranch:resume_listener(?HTTP),
    catch ranch:resume_listener(?HTTPS),
    ok;

do_resume_listeners(admin) ->
    ?LOG_NOTICE(#{
        description => "Resuming admin HTTP(S) listeners"
    }),
    catch ranch:resume_listener(?ADMIN_HTTP),
    catch ranch:resume_listener(?ADMIN_HTTPS),
    ok.


%% @private
do_stop_listeners(public) ->
    ?LOG_NOTICE(#{
        description => "Stopping public HTTP(S) listeners"
    }),
    catch cowboy:stop_listener(?HTTP),
    catch cowboy:stop_listener(?HTTPS),
    bondy_http_security_headers:cleanup(?HTTP),
    bondy_http_security_headers:cleanup(?HTTPS),
    ok;

do_stop_listeners(admin) ->
    ?LOG_NOTICE(#{
        description => "Stopping admin HTTP(S) listeners"
    }),
    catch cowboy:stop_listener(?ADMIN_HTTP),
    catch cowboy:stop_listener(?ADMIN_HTTPS),
    bondy_http_security_headers:cleanup(?ADMIN_HTTP),
    bondy_http_security_headers:cleanup(?ADMIN_HTTPS),
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
        {ok, #{~"id" := Id} = Spec} ->
            %% We store the source specification, see add/2 for an explanation
            ok = maybe_init_groups(maps:get(~"realm_uri", Spec)),
            add(
                Id,
                maps:put(<<"ts">>, erlang:monotonic_time(millisecond), Map)
            );
        {error, Reason} ->
            ?LOG_ERROR(#{
                description => "Error while loading API specification",
                reason => Reason,
                api_id => maps:get(~"id", Map, undefined)
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



-spec start_listener({Scheme :: binary(), [tuple()]}) -> ok.

start_listener({~"http", Routes}) ->
    ok = maybe_start_http(Routes, ?HTTP),
    ok;

start_listener({~"https", Routes}) ->
    ok = maybe_start_https(Routes, ?HTTPS),
    ok.



-spec start_admin_listener({Scheme :: binary(), [tuple()]}) ->
    ok | {error, any()}.

start_admin_listener({~"http", Routes}) ->
    maybe_start_http(Routes, ?ADMIN_HTTP);

start_admin_listener({~"https", Routes}) ->
    maybe_start_https(Routes, ?ADMIN_HTTPS).


maybe_start_http(Routes, Name) ->
    case bondy_config:get([Name, enabled], true) of
        true ->
            start_http(Routes, Name);
        false ->
            ok
    end.



-spec start_http(list(), atom()) -> ok | {error, any()}.

start_http(Routes, Name) ->
    TransportOpts = listener_transport_opts(Name),
    ProtoOpts = listener_protocol_opts(Routes, Name),
    LogMeta = #{
        listener => Name,
        transport_opts => TransportOpts,
        protocol_opts => maps:without([env], ProtoOpts)
    },

    case cowboy:start_clear(Name, TransportOpts, ProtoOpts) of
        {ok, _} ->
            ?LOG_NOTICE(LogMeta#{description => "Started HTTP Listener"}),
            ok;

        {error, eaddrinuse = Reason} = Error ->
            ?LOG_ERROR(LogMeta#{
                description =>
                    "Failed to start HTTPS listener, "
                    "the address is already in use",
                reason => Reason
            }),
            Error;

        {error, Reason} = Error ->
            ?LOG_ERROR(LogMeta#{
                description => "Failed to start HTTP listener",
                reason => Reason
            }),
            Error
    end.

maybe_start_https(Routes, Name) ->
    case bondy_config:get([Name, enabled], true) of
        true ->
            start_https(Routes, Name);
        false ->
            ok
    end.


listener_protocol_opts(Routes, Name) ->
    ProtocolOpts0 = bondy_config:listener_protocol_opts(Name),
    ok = compile_dispatch(Routes, Name),
    ok = bondy_http_security_headers:init(Name),

    ProtocolOpts0#{
        env => #{
            bondy => #{
                auth => #{
                    %% REVIEW this in light of recent changes to auth methods
                    schemes => [basic, bearer]
                }
            },
            dispatch => {persistent_term, ?DISPATCH_KEY(Name)}
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
        ],
        hibernate => true,
        protocols => [http]
    }.




-spec start_https(list(), atom()) -> ok | {error, any()}.

start_https(Routes, Name) ->
    TransportOpts = listener_transport_opts(Name),
    ProtoOpts = listener_protocol_opts(Routes, Name),
    LogMeta = #{
        listener => Name,
        transport_opts => TransportOpts,
        protocol_opts => maps:without([env], ProtoOpts)
    },

    case cowboy:start_tls(Name, TransportOpts, ProtoOpts) of
        {ok, _} ->
            ?LOG_NOTICE(LogMeta#{description => "Started HTTPS Listener"}),
            ok;

        {error, eaddrinuse = Reason} = Error ->
            ?LOG_ERROR(LogMeta#{
                description =>
                    "Failed to start HTTPS listener, "
                    "the address is already in use",
                reason => Reason
            }),
            Error;

        {error, Reason} = Error ->
            ?LOG_ERROR(LogMeta#{
                description => "Failed to start HTTP listener",
                reason => Reason
            }),
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
                    description =>
                        "Loading and parsing API Gateway specification "
                        "from store",
                    name => maps:get(~"name", V),
                    id => maps:get(~"id", V),
                    timestamp => Ts
                }),
                {K, Ts, Parsed}
            catch
                _:_:_ ->
                    _ = delete(K),
                    ?LOG_WARNING(#{
                        description =>
                            "Removed invalid API Gateway specification "
                            "from store",
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
                {~"http", base_routes()},
                {~"https", base_routes()}
            ];
        _ ->
            Result
    end.


compile_dispatch(Routes, Name) ->
    _ = persistent_term:put(?DISPATCH_KEY(Name), cowboy_router:compile(Routes)),
    ok.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec rebuild_dispatch_table(atom() | binary(), list()) -> ok.

rebuild_dispatch_table(http, Routes) ->
    rebuild_dispatch_table(~"http", Routes);

rebuild_dispatch_table(https, Routes) ->
    rebuild_dispatch_table(~"https", Routes);

rebuild_dispatch_table(~"http", Routes) ->
    case bondy_config:get([?HTTP, enabled], true) of
        true ->
            compile_dispatch(Routes, ?HTTP);

        false ->
            ok
    end;
    
rebuild_dispatch_table(~"https", Routes) ->
    case bondy_config:get([?HTTPS, enabled], true) of
        true ->
            compile_dispatch(Routes, ?HTTPS);

        false ->
            ok
    end.


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
    %% The WS entrypoint required for WAMP WS subprotocol,
    %% SSE transport endpoints, and Longpoll transport endpoints
    [
        {'_', [
            {"/ws", bondy_wamp_ws_connection_handler, #{}},
            {"/wamp/sse/open", bondy_http_sse_handler, #{action => open}},
            {"/wamp/sse/:transport_id/receive",
                bondy_http_sse_stream_handler, #{}},
            {"/wamp/sse/:transport_id/send",
                bondy_http_sse_handler, #{action => send}},
            {"/wamp/sse/:transport_id/close",
                bondy_http_sse_handler, #{action => close}},
            {"/wamp/longpoll/open",
                bondy_http_longpoll_handler, #{action => open}},
            {"/wamp/longpoll/:transport_id/receive",
                bondy_http_longpoll_handler, #{action => receive_msgs}},
            {"/wamp/longpoll/:transport_id/send",
                bondy_http_longpoll_handler, #{action => send}},
            {"/wamp/longpoll/:transport_id/close",
                bondy_http_longpoll_handler, #{action => close}}
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
                {~"http", BaseRoutes},
                {~"https", BaseRoutes}
            ];
        L ->
            _ = [
                maybe_init_groups(maps:get(~"realm_uri", Spec))
                || Spec <- L
            ],
            bondy_http_gateway_api_spec_parser:dispatch_table(L, BaseRoutes)
    end.



%% @private
maybe_init_groups(RealmUri) ->
    Gs = [
        #{
            ~"name" => <<"resource_owners">>,
            <<"meta">> => #{
                <<"description">> => <<"A group of entities capable of granting access to a protected resource. When the resource owner is a person, it is referred to as an end-user.">>
            }
        },
        #{
            ~"name" => <<"api_clients">>,
            <<"meta">> => #{
                <<"description">> => <<"A group of applications making protected resource requests through Bondy API Gateway by themselves or on behalf of a Resource Owner.">>
                }
        }
    ],
    _ = [begin
        case bondy_rbac_group:lookup(RealmUri, maps:get(~"name", G)) of
            {error, not_found} ->
                bondy_rbac_group:add(RealmUri, bondy_rbac_group:new(G));
            _ ->
                ok
        end
    end || G <- Gs],
    ok.


listener_transport_opts(Name) ->
    Opts0 = bondy_config:listener_transport_opts(Name),
    MaxConnections = key_value:get(max_connections, Opts0),

    Threshold75 = trunc(MaxConnections * 0.75),
    Threshold90 = trunc(MaxConnections * 0.90),

    Opts = Opts0#{
        alarms => #{
            num_connections_70 => #{
                type => num_connections,
                threshold => Threshold75,
                cooldown => timer:seconds(5),
                callback => fun(LName, AlarmName, _SupPid, Pids) ->
                    ?LOG_WARNING(#{
                        description => "Connection 75% threshold exceeded",
                        listener => LName,
                        alarm_name => AlarmName,
                        connections => length(Pids)
                    })
                end
            },
            num_connections_90 => #{
                type => num_connections,
                threshold => Threshold90,
                cooldown => timer:seconds(5),
                callback => fun(LName, AlarmName, _SupPid, Pids) ->
                    ?LOG_ALERT(#{
                        description => "Connection 90% threshold exceeded",
                        listener => LName,
                        alarm_name => AlarmName,
                        connections => length(Pids)
                    })
                end
            }
        }
    },

    SocketOpts = key_value:get(socket_opts, Opts),

    case key_value:get(reuseport, SocketOpts, false) of
        true ->
            %% 15 acceptors per listen socket with at least 1 per scheduler
            NumAcceptors = key_value:get(num_acceptors, Opts),
            Schedulers = erlang:system_info(schedulers),
            Opts#{
                num_listen_sockets => max(Schedulers, trunc(NumAcceptors / 15))
            };

        false ->
            Opts
    end.



%% -----------------------------------------------------------------------------
%% @private
%% @doc Tear down all APIs for that realm when event occurs
%% @end
%% -----------------------------------------------------------------------------
on_realm_deleted(_RealmUri, State) ->
    %% TODO: tear down all APIs for this realm
    State.
