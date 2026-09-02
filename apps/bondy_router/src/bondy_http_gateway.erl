%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_gateway).

-moduledoc """
Owns the API Gateway specifications and the dispatch tables compiled from them.

This gen_server loads API specification documents, stores them in the bondy_db
`api_gateway` table, and rebuilds the Cowboy dispatch table of every HTTP
listener that exposes the API Gateway whenever a specification changes.

Listeners themselves belong to `bondy_listener_manager`: which listeners exist,
what each one serves and when it starts are properties of the listener
inventory, not of the API Gateway.

## API specifications

API specs are JSON documents parsed by `bondy_http_gateway_api_spec_parser`.
They are stored in the bondy_db `api_gateway` main table, keyed by spec id,
with the **source JSON** carried as a `term_to_binary/1` payload in an
`lww_register` cell. When a spec
is loaded:

1. The JSON document is validated and parsed
2. The parsed spec is compiled into a Cowboy dispatch table
   (`cowboy_router:compile/1`) to verify correctness
3. The **source JSON** (not the parsed form) is persisted in bondy_db —
   parsed specs can contain `mops` proxy funs that become invalid after a
   code upgrade, so we always re-parse from source
4. The dispatch table of every HTTP listener that exposes the API Gateway is
   rebuilt

## Cluster replication

The `api_gateway` table is opened with `publish => true`, so its appliers
publish every verified spec write — a local write OR one replicated from a
peer via bondy_db's anti-entropy — to the table namespace. The server
`bondy_oplog_core:subscribe/2`s to that namespace and, on any spec change,
rebuilds this node's dispatch tables. Rebuilds are **debounced**
(`?REBUILD_DEBOUNCE` ms) so a burst (boot config load, an AE sync) collapses
into a single rebuild. Cross-node propagation requires bondy_db anti-entropy
to be enabled (`db.aae`).

## WAMP subscriptions

The server subscribes to `bondy.realm.deleted` on the master realm. When
a realm is deleted the server can tear down all API specs associated with
that realm (currently a placeholder).

## Configuration

- `bondy.api_gateway.config_file` — optional path to a JSON file
  containing one or more API spec documents, loaded at startup via
  `apply_config/0`
""".

-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").

%% API specs live in the bondy_db `api_gateway` main table. The store is a flat,
%% id-keyed keyspace (a spec's realm is a field in the value, not part of the
%% key), so a single
%% fixed bucket is used. The spec map is stored directly in an `lww_register`
%% cell (the substrate serialises terms; no manual encoding); `clear` deletes
%% (non-terminal, so a re-`load` reanimates). The catalogue
%% (`bondy_namespace_catalog`) provisions the table.
-define(BUCKET, <<>>).
%% Debounce window (ms) for coalescing a burst of spec-change events (boot
%% config load, an AE sync) into a single dispatch-table rebuild.
-define(REBUILD_DEBOUNCE, 250).
%% Retry cadence for the oplog subscription when the api_gateway table is not
%% provisioned yet. Same value as `bondy_aae_reactor`'s, for one cadence
%% across the two subscribers of a `publish => true` table.
-define(RESUBSCRIBE_AFTER, 500).

-record(state, {
    %% Use for WAMP subscriptions
    bondy_ref :: bondy_ref:t(),
    %% bondy_oplog_core change-event subscription for the api_gateway table.
    oplog_sub :: reference() | undefined,
    %% Pending debounce timer for a coalesced rebuild.
    rebuild_timer :: reference() | undefined,
    updated_specs = [] :: list(),
    subscriptions = #{} :: #{id() => uri()}
}).

%% API
-export([admin_api_routes/1]).
-export([delete/1]).
-export([dispatch_table/1]).
-export([list/0]).
-export([apply_config/0]).
-export([load/1]).
-export([lookup/1]).
-export([rebuild_dispatch_tables/0]).
-export([routes/1]).
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

-doc "Starts the gen_server and registers it as `bondy_http_gateway`.".
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Loads API specs from the configuration file into the metadata store.

Reads the JSON file at `bondy.api_gateway.config_file`, parses each
spec, validates it, and stores it in bondy_db. Does **not** rebuild the
Cowboy dispatch tables — call `rebuild_dispatch_tables/0` or `load/1`
for that.
""".
-spec apply_config() ->
    ok | {error, invalid_specification_format | any()}.

apply_config() ->
    gen_server:call(?MODULE, apply_config).

-doc """
Parses an API spec, stores it in bondy_db, and rebuilds dispatch tables.

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
-spec dispatch_table(Listener :: atom()) -> any().

dispatch_table(Listener) ->
    Map = ranch:get_protocol_options(Listener),
    maps_utils:get_path([env, dispatch], Map).

-doc """
Cowboy route rules compiled from the stored API Gateway specifications, for the
scheme `Listener` serves.

`bondy_http_gateway_api_spec_parser:dispatch_table/2` keys its result by the
scheme declared in each specification, so a listener takes the table matching
its own scheme: `https` when it terminates TLS, `http` otherwise.

The parser groups its rules BY HOST, and they are returned that way. Flattening
them discarded each specification's `host` field, so a specification declared for
one virtual host answered on every host.
""".
-spec routes(bondy_listener_config:t()) ->
    [bondy_http_service:route_rule()].

routes(Listener) ->
    Scheme = scheme(maps:get(transport, Listener)),
    Tables = load_dispatch_tables(),
    case lists:keyfind(Scheme, 1, Tables) of
        {Scheme, Rules} -> Rules;
        false -> []
    end.

-doc """
Routes compiled from the built-in Admin API specification, for one listener.

Distinct from `routes/1`, which returns the routes of every specification stored
in `bondy_db`. This specification ships in `priv/` and is mounted only on
listeners that declare the `admin_api` service, which is what keeps realm, user,
grant and backup administration off a listener that declares only
`api_gateway`.
""".
-spec admin_api_routes(bondy_listener_config:t()) ->
    [bondy_http_service:route_rule()].

admin_api_routes(Listener) ->
    Scheme = scheme(maps:get(transport, Listener)),
    Spec = bondy_http_gateway_api_spec_parser:parse(admin_spec()),
    %% Reads the store only to compile — `dispatch_table/2` consults the
    %% realm table to drop routes whose realm is absent — and writes nothing.
    %% The admin API's RBAC groups used to be provisioned from here, which
    %% made building the EARLY `admin` listener's table a durable write; they
    %% are provisioned by `apply_config/0` on the durable boot path instead
    %% (`do_apply_config/0`). On a degraded boot this carrier is not asked
    %% for routes at all (`bondy_http_services:specification_routes/3`).
    %%
    %% No base routes: the service route sets in `bondy_http_services' supply
    %% those, and each is mounted by naming its own service.
    Tables = bondy_http_gateway_api_spec_parser:dispatch_table([Spec], []),
    case lists:keyfind(Scheme, 1, Tables) of
        {Scheme, Rules} -> Rules;
        false -> []
    end.

-doc """
Rebuilds the Cowboy dispatch table of every HTTP listener that exposes the
API Gateway.

A listener that does not include the `api_gateway` service has no routes derived
from a STORED specification, so a stored-specification change cannot affect it.
The built-in Admin API specification ships in `priv/` and cannot change at
runtime, so an `admin_api`-only listener needs no rebuild either.
""".
rebuild_dispatch_tables() ->
    ?LOG_NOTICE(#{description => "Rebuilding HTTP Gateway dispatch tables"}),
    _ = [
        bondy_listener_ranch:recompile_dispatch(L)
     || L <- bondy_listener_manager:listeners(),
        maps:get(protocol, L) =:= http,
        lists:member(api_gateway, maps:get(services, L))
    ],
    ok.

-doc """
Returns the API specification stored under `Id`, or `{error, not_found}`.

The returned map is the **source JSON** as originally loaded, not the
parsed form.
""".
-spec lookup(binary()) -> map() | {error, not_found}.

lookup(Id) ->
    case bondy_db:read(spec_table(), ?BUCKET, Id) of
        {ok, {Spec, _Hlc}} ->
            Spec;
        {error, not_found} ->
            {error, not_found}
    end.

-doc "Returns the list of all stored API specification objects.".
-spec list() -> [ParsedSpec :: map()].

list() ->
    [Spec || {_Id, Spec} <- stored_specs()].

-doc """
Deletes the API specification identified by `Id` and rebuilds dispatch tables.

The spec is removed from bondy_db and the Cowboy dispatch tables are
recompiled to reflect the removal.
""".
-spec delete(binary()) -> ok.

delete(Id) when is_binary(Id) ->
    ok = bondy_db:apply(spec_table(), ?BUCKET, Id, clear),
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

handle_info(
    {bondy_oplog_core_event, _NS, Key, _Hlc, _Op}, State0
) ->
    %% An API spec changed locally in bondy_db. Debounce-batch so a burst (e.g.
    %% boot config load) collapses into a single dispatch-table rebuild.
    {noreply, note_spec_change(Key, State0)};
handle_info(
    {bondy_oplog_core_merge_event, _NS, Key, _Hlc, _Op, _Old}, State0
) ->
    %% A peer's API spec change arrived via anti-entropy (the merge-side hook).
    %% Rebuild this node's dispatch table too, debounced like the local case.
    {noreply, note_spec_change(Key, State0)};
handle_info(retry_subscribe, State0) ->
    %% The api_gateway table was not provisioned when we last tried; try
    %% again rather than stay deaf to spec changes. `subscribe_oplog/1`
    %% re-arms this timer if it is still unavailable.
    {noreply, subscribe_oplog(State0)};
handle_info({bondy_oplog_core_bootstrap_event, _NS, _Bucket}, State0) ->
    %% A catalogue-snapshot bootstrap installed the API-spec table's
    %% projection wholesale. That path emits no per-cell event, so without
    %% this clause a freshly bootstrapped node keeps serving the dispatch
    %% tables it built at `init/1` — which, on a fresh replica, are the specs
    %% it did not have yet, i.e. none. The routes would simply be missing,
    %% and nothing would rebuild them until the next live spec change.
    %%
    %% There is no key to accumulate: every spec in the table is new to us.
    %% Rebuild the whole dispatch table rather than a keyed subset.
    ok = rebuild_dispatch_tables(),
    {noreply, State0};
handle_info(rebuild_specs, State0) ->
    %% The debounce window elapsed — rebuild once for the whole batch.
    ok = handle_spec_updates(State0),
    {noreply, State0#state{updated_specs = [], rebuild_timer = undefined}};
handle_info({?BONDY_REQ, _, ?MASTER_REALM_URI, #event{} = Event}, State) ->
    %% We informally implement bondy_subscriber
    Id = Event#event.subscription_id,
    Topic = maps:get(Id, State#state.subscriptions, undefined),
    NewState =
        case {Topic, Event#event.args} of
            {undefined, _} ->
                State;
            {?BONDY_REALM_DELETED, [Uri]} ->
                on_realm_deleted(Uri, State)
        end,
    {noreply, NewState};
handle_info(Info, State) ->
    ?LOG_WARNING(#{
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
subscribe(State0) ->
    %% Subscribe to API Gateway spec change events from the bondy_db
    %% `api_gateway` table (opened with `publish => true`). The applier
    %% publishes every verified apply — a local write OR an AE-replicated
    %% remote write — to the table namespace, so we rebuild this node's Cowboy
    %% dispatch tables on any spec change cluster-wide.
    State1 = subscribe_oplog(State0),

    %% We subscribe to WAMP events
    %% We will handle then in handle_cast/2
    {ok, Id} = bondy_broker:subscribe(
        ?MASTER_REALM_URI,
        #{
            subscription_id => bondy_message_id:global(),
            match => <<"exact">>
        },
        ?BONDY_REALM_DELETED,
        State1#state.bondy_ref
    ),
    Subs = maps:put(Id, ?BONDY_REALM_DELETED, State1#state.subscriptions),

    State1#state{
        subscriptions = Subs
    }.

%% @private
subscribe_oplog(State) ->
    case spec_table_opt() of
        undefined ->
            %% RETRY rather than give up. The catalogue provisions its tables
            %% synchronously in `init/1` and `bondy_sup` starts it before this
            %% process, so in a healthy boot this branch is unreachable — but
            %% it IS reachable when a DB open failed, and returning here left
            %% the spec-change reactor disabled for the LIFETIME of the node,
            %% marked only by this warning. A later recovery of the table
            %% would never be picked up.
            ?LOG_WARNING(#{
                description =>
                    "API Gateway bondy_db table is not available; the "
                    "spec-change reactor is not subscribed yet and will "
                    "retry (is the namespace catalogue running?)",
                retry_in_ms => ?RESUBSCRIBE_AFTER
            }),
            _ = erlang:send_after(?RESUBSCRIBE_AFTER, self(), retry_subscribe),
            State;
        Table ->
            {ok, Ref} = bondy_oplog_core:subscribe(
                bondy_db:namespace(Table), all
            ),
            %% RECONCILE ON ATTACH, do not assume we heard the event.
            %%
            %% A catalogue-snapshot bootstrap announces itself ONCE
            %% (`bondy_oplog_core_bootstrap_event`), and that fanout reaches
            %% only the subscribers that exist when it fires. The catalogue
            %% provisions — and therefore AAE can bootstrap — the
            %% `api_gateway` table before this process is started by
            %% `bondy_sup`, so an install completing in that window would be
            %% missed and this node would serve the dispatch tables it had
            %% before, which on a fresh replica is no routes at all.
            %%
            %% The dispatch tables are DERIVED from the projection, so
            %% rebuilding them here is correct regardless of what happened
            %% before, and idempotent. Same discipline as
            %% `bondy_aae_reactor:ensure_subscribed/1`.
            ok = rebuild_dispatch_tables(),
            State#state{oplog_sub = Ref}
    end.

%% @private
unsubscribe(State) ->
    _ =
        case State#state.oplog_sub of
            undefined -> ok;
            Ref -> bondy_oplog_core:unsubscribe(Ref)
        end,

    _ = [
        bondy_broker:unsubscribe(Id, ?MASTER_REALM_URI)
     || Id <- maps:keys(State#state.subscriptions)
    ],

    State#state{subscriptions = #{}, oplog_sub = undefined}.

%% @private
%% The open bondy_db `api_gateway` table handle. Raises if the catalogue has
%% not provisioned it — the table is a hard dependency (the catalogue, a
%% `bondy_sup` child, opens it before this gen_server starts).
spec_table() ->
    case spec_table_opt() of
        undefined -> error(api_gateway_table_unavailable);
        Table -> Table
    end.

%% @private
spec_table_opt() ->
    bondy_namespace_catalog:table(api_gateway).

%% @private
%% Every stored spec as `{Id, SpecMap}` (cleared / tombstoned cells excluded).
stored_specs() ->
    {ok, Cells} = bondy_db:list(spec_table(), ?BUCKET),
    [{Id, Spec} || {Id, Spec, _Hlc} <- Cells, is_map(Spec)].

%% @private
%% Record a changed spec id and (re)arm the debounce timer for a coalesced
%% rebuild. Repeated changes inside the window accumulate behind one timer.
note_spec_change(
    Key, #state{updated_specs = Specs, rebuild_timer = Timer} = St
) ->
    Specs1 =
        case lists:member(Key, Specs) of
            true -> Specs;
            false -> [Key | Specs]
        end,
    Timer1 =
        case Timer of
            undefined ->
                erlang:send_after(?REBUILD_DEBOUNCE, self(), rebuild_specs);
            _ ->
                Timer
        end,
    St#state{updated_specs = Specs1, rebuild_timer = Timer1}.

%% @private
-spec do_apply_config() -> ok | no_return().

do_apply_config() ->
    %% The built-in admin API's declarative half: the two RBAC groups its
    %% spec authorises against, ensured on its realm on every boot that takes
    %% the durable path (`bondy_app:configure_services/0` calls
    %% `apply_config/0` before any listener starts). A durable write, so it
    %% belongs here and NOT in `admin_api_routes/1`, which the early
    %% listeners build on a degraded boot as well.
    AdminSpec = bondy_http_gateway_api_spec_parser:parse(admin_spec()),
    ok = init_groups(maps:get(~"realm_uri", AdminSpec)),
    case bondy_config:get([api_gateway, config_file], undefined) of
        undefined -> ok;
        FName -> do_apply_config(FName)
    end.

%% @private
do_apply_config(FName) ->
    try
        case bondy_utils:json_consult(FName) of
            {ok, Spec} when is_map(Spec) ->
                load_spec(Spec, #{declarative => true});
            {ok, []} ->
                ok;
            {ok, Specs} when is_list(Specs) ->
                ?LOG_INFO(#{
                    description => "Loading configuration file found",
                    filename => FName
                }),
                _ = [load_spec(Spec, #{declarative => true}) || Spec <- Specs],
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
load_spec(MapOrFName) ->
    load_spec(MapOrFName, #{}).

%% @private
%% `Opts` may carry `declarative => true` (a config-file apply, run on every
%% boot). Under that flag the spec is stored IDEMPOTENTLY — see `store_spec/3`.
%% A runtime load (no flag) always writes.
load_spec(Map, Opts) when is_map(Map) ->
    case validate_spec(Map) of
        {ok, #{~"id" := Id} = Spec} ->
            %% We store the source specification, see add/2 for an explanation
            ok = init_groups(maps:get(~"realm_uri", Spec)),
            store_spec(Id, Map, Opts);
        {error, Reason} ->
            ?LOG_ERROR(#{
                description => "Error while loading API specification",
                reason => Reason,
                api_id => maps:get(~"id", Map, undefined)
            }),
            throw(Reason)
    end;
load_spec(FName, Opts) ->
    case bondy_utils:json_consult(FName) of
        {ok, Spec} when is_map(Spec) ->
            ok = load_spec(Spec, Opts),
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

%% @private
%% Persist the source spec under `Id`. A runtime load always writes, stamping a
%% fresh `ts` (the per-node load time `load_dispatch_tables/0` uses to FIFO-order
%% overlapping specs). A DECLARATIVE config apply writes only when the spec
%% source actually changed (compared modulo `ts`): re-reading the config file on
%% every boot must NOT re-stamp `ts`, because `ts` is a per-node wall clock and
%% a fresh value on each node/boot diverges the replicated cell (and its content
%% digest). The op-based CRDT + anti-entropy reconcile multi-node writes, so an
%% unchanged spec needs no per-boot rewrite.
store_spec(Id, Map, Opts) ->
    case maps:get(declarative, Opts, false) of
        true ->
            Desired = maps:remove(<<"ts">>, Map),
            case lookup(Id) of
                Stored when is_map(Stored) ->
                    case maps:remove(<<"ts">>, Stored) =:= Desired of
                        true ->
                            %% Unchanged — keep the replicated value (and its
                            %% already-converged ts); emit no operation.
                            ok;
                        false ->
                            add(Id, with_ts(Map))
                    end;
                {error, not_found} ->
                    add(Id, with_ts(Map))
            end;
        false ->
            add(Id, with_ts(Map))
    end.

%% @private
%% Stamp the per-node load time used to FIFO-order overlapping specs
%% (`load_dispatch_tables/0`).
with_ts(Map) ->
    maps:put(<<"ts">>, erlang:monotonic_time(millisecond), Map).

-doc """
We store the API Spec in the metadata store. Notice that we store the JSON
and not the parsed spec as the parsed spec might contain mops proxy
functions.  In case we upgrade the code of the mops.erl module those funs
will no longer be valid and will fail with a badfun exception.
""".
add(Id, Spec) when is_binary(Id), is_map(Spec) ->
    bondy_db:apply(spec_table(), ?BUCKET, Id, {set, Spec}).

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

%% @private
-doc """
Loads all the existing API specs from store, parses them and generates a
dispatch table per scheme.
""".
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
        end
     || {K, V} <- stored_specs()
    ]),

    %% No base routes: the paths a listener serves besides its
    %% specification-derived ones come from the services it declares, and
    %% `bondy_http_services:dispatch/1` assembles them.
    Result = bondy_http_gateway_api_spec_parser:dispatch_table(
        [element(3, S) || S <- Specs], []
    ),

    case Result of
        [] -> [{~"http", []}, {~"https", []}];
        _ -> Result
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

%% @private
%% The built-in Admin API specification, read from `priv/'. Mandatory, not
%% best-effort: a missing or malformed file means the node cannot serve its own
%% admin API, which must not degrade silently into a listener that binds and
%% answers 404.
admin_spec() ->
    Base = bondy_config:get(priv_dir),
    File = filename:join(Base, "specs/bondy_admin_api.json"),
    case bondy_utils:json_consult(File) of
        {ok, Spec} ->
            Spec;
        {error, enoent} ->
            ?LOG_ERROR(#{
                description =>
                    "Error processing API Gateway Specification file.",
                filename => File,
                reason => file:format_error(enoent)
            }),
            exit(enoent);
        {error, Reason} ->
            ?LOG_ERROR(#{
                description =>
                    "Error while parsing API Gateway Specification file",
                filename => File,
                reason => Reason
            }),
            exit(invalid_json_format)
    end.

%% @private
scheme(tls) -> ~"https";
scheme(_) -> ~"http".

%% @private
%% Ensures the two RBAC groups every gateway spec's authorisation refers to
%% exist on `RealmUri`. Idempotent (lookup, then add). Writes the durable
%% store, so every caller is on a path where `main` is open: `do_apply_config/0`
%% (boot, durable path) and `load_spec/2` (a runtime spec load, which writes
%% the spec itself right after).
init_groups(RealmUri) ->
    Gs = [
        #{
            ~"name" => <<"resource_owners">>,
            <<"meta">> => #{
                <<"description">> =>
                    <<"A group of entities capable of granting access to a protected resource. When the resource owner is a person, it is referred to as an end-user.">>
            }
        },
        #{
            ~"name" => <<"api_clients">>,
            <<"meta">> => #{
                <<"description">> =>
                    <<"A group of applications making protected resource requests through Bondy API Gateway by themselves or on behalf of a Resource Owner.">>
            }
        }
    ],
    _ = [
        begin
            case bondy_rbac_group:lookup(RealmUri, maps:get(~"name", G)) of
                {error, not_found} ->
                    bondy_rbac_group:add(RealmUri, bondy_rbac_group:new(G));
                _ ->
                    ok
            end
        end
     || G <- Gs
    ],
    ok.

%% @private
-doc "Tear down all APIs for that realm when event occurs.".
on_realm_deleted(_RealmUri, State) ->
    %% TODO: tear down all APIs for this realm
    State.
