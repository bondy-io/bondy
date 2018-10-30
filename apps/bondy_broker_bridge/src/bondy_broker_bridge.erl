%% =============================================================================
%%  bondy_broker_bridge.erl -
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
-module(bondy_broker_bridge).
-behaviour(gen_server).
-include("bondy_broker_bridge.hrl").
-include_lib("wamp/include/wamp.hrl").


-define(TIMEOUT, 30000).
-define(PREFIX, {broker_bridge, subscription_specs}).
-define(SPEC, #{
    <<"backend">> => #{
        alias => backend,
        required => true,
        allow_null => false,
        allow_undefined => false,
        validator => fun
            (Bin) when is_binary(Bin) ->
                try list_to_atom(binary_to_list(Bin)) of
                    Mod ->
                        erlang:module_loaded(Mod)
                catch
                    _:_ -> false
                end;
            (Mod) when is_atom(Mod) ->
                erlang:module_loaded(Mod)
        end
    },
    <<"action">> => #{
        alias => action,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => map
    }
}).


-record(state, {
    backends = #{}          ::  #{Name :: any() => Config :: map()},
    subscriptions = #{}     ::  #{Name :: any() => subscription_detail()},
    %% Cluster sync state
    exchange_ref            ::  {pid(), reference()} | undefined,
    updated_specs = []      ::  list()
}).

-type backend()             ::  map().
-type subscription_detail() ::  map().


%% API
-export([start_link/0]).
-export([load/1]).
-export([subscribe/4]).
-export([unsubscribe/1]).
-export([backends/0]).
-export([backend/1]).
-export([subscriptions/0]).
-export([subscriptions/1]).


%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).




%% =============================================================================
%% CALLBACKS
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Initialises the external broker or system as sink
%% @end
%% -----------------------------------------------------------------------------
-callback init(Config :: any()) ->
    ok | {error, Reason :: any()}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-callback validate_action(Action :: map()) ->
    {ok, ValidAction :: map()} | {error, Reason :: any()}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-callback apply_action(Action :: map(), Ctxt :: map()) ->
    ok
    | {retry, Reason :: any()}
    | {error, Reason :: any()}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-callback terminate(Reason :: any(), State :: any()) -> ok.



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
%% @end
%% -----------------------------------------------------------------------------
-spec backends() -> [backend()].
backends() ->
    gen_server:call(?MODULE, backends, 10000).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec backend(module()) -> [backend()].
backend(Mod) ->
    gen_server:call(?MODULE, {backend, Mod}, 10000).


%% -----------------------------------------------------------------------------
%% @doc
%% Parses the provided Spec.
%% @end
%% -----------------------------------------------------------------------------
-spec load(file:filename() | map()) ->
    ok | {error, invalid_specification_format | any()}.

load(Map) when is_map(Map) ->
    gen_server:call(?MODULE, {load, Map}).


%% -----------------------------------------------------------------------------
%% @doc For internal Bondy use
%% @end
%% -----------------------------------------------------------------------------
-spec subscribe(uri(), map(), uri(), Spec :: map()) ->
    {ok, id()} | {error, already_exists}.

subscribe(RealmUri, Opts, Topic, Spec) ->
    gen_server:call(
        ?MODULE, {subscribe, RealmUri, Opts, Topic, Spec}, ?TIMEOUT).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unsubscribe(id()) -> ok | {error, not_found}.

unsubscribe(Id) ->
    gen_server:call(?MODULE, {unsubscribe, Id}, ?TIMEOUT).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec subscriptions() -> [subscription_detail()].

subscriptions() ->
    lists:append([subscriptions(Sink) || Sink <- backends()]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec subscriptions(Sink :: backend()) -> [subscription_detail()].

subscriptions(Sink) ->
    gen_server:call(?MODULE, {subscriptions, Sink}, 10000).



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([]) ->
    Backends = application:get_env(bondy_broker_bridge, backends, []),
    State0 = #state{backends = maps:from_list(Backends)},

    case init_backends(State0) of
        {ok, State1} ->
            plum_db_subscribe(State1);
        {error, _} = Error ->
            Error
    end.



handle_call(backends, _From, State) ->
    Res = maps:to_list(State#state.backends),
    {reply, Res, State};

handle_call({backend, Mod}, _From, State) ->
    Res = maps:get(Mod, State#state.backends, undefined),
    {reply, Res, State};

handle_call({subscriptions, Bridge}, _From, State) ->
    Res = maps:get(Bridge, State#state.subscriptions, []),
    {reply, Res, State};

handle_call({subscribe, RealmUri, Opts, Topic, Spec0}, _From, State) ->
    Res = try maps_utils:validate(Spec0, ?SPEC) of
        Spec1 ->
            Mod = list_to_atom(binary_to_list(maps:get(<<"backend">>, Spec1))),
            Action0 = maps:get(<<"action">>, Spec1),
            case Mod:validate_action(Action0) of
                {ok, Action1} ->
                    Fun = fun(Topic1, Event) when Topic1 == Topic ->
                        Ctxt = mops_ctxt(Event, RealmUri, Opts, Topic),
                        Mod:apply_action(Action1, Ctxt)
                    end,
                    bondy_broker:subscribe(RealmUri, Opts, Topic, Fun);
                Error ->
                    Error
            end
    catch
        ?EXCEPTION(_, Reason, Stacktrace) ->
            _ = lager:error(
                "Error while evaluating action; reason=~p, "
                "stacktrace=~p",
                [Reason, ?STACKTRACE(Stacktrace)]
            ),
            {error, Reason}
    end,
    {reply, Res, State};

handle_call({unsubscribe, _Id}, _From, State) ->
    Res = {error, not_implemented},
    {reply, Res, State};

handle_call({load, _Map}, _From, State) ->
    %% Res = load_spec(Map),
    Res = ok,
    {reply, Res, State};

handle_call(Event, From, State) ->
    _ = lager:error("Unexpected event, event=~p, from=~p", [Event, From]),
    {noreply, State}.


handle_cast(Event, State) ->
    _ = lager:error("Unexpected event, event=~p", [Event]),
    {noreply, State}.


handle_info({plum_db_event, exchange_started, {Pid, _Node}}, State) ->
    Ref = erlang:monitor(process, Pid),
    {noreply, State#state{exchange_ref = {Pid, Ref}}};

handle_info(
    {plum_db_event, exchange_finished, {Pid, _Reason}},
    #state{exchange_ref = {Pid, Ref}} = State0) ->

    true = erlang:demonitor(Ref),
    %% ok = handle_spec_updates(State0),
    State1 = State0#state{updated_specs = [], exchange_ref = undefined},
    {noreply, State1};

handle_info({plum_db_event, exchange_finished, {_, _}}, State) ->
    %% We are receiving the notification after we recevied a DOWN message
    %% we do nothing
    {noreply, State};

handle_info(
    {'DOWN', Ref, process, Pid, _Reason},
    #state{exchange_ref = {Pid, Ref}} = State0) ->

    %% ok = handle_spec_updates(State0),
    State1 = State0#state{updated_specs = [], exchange_ref = undefined},
    {noreply, State1};

handle_info({plum_db_event, object_update, {{?PREFIX, Key}, _, _}}, State) ->
    %% We've got a notification that an API Spec object has been updated
    %% in the database via cluster replication, so we need to rebuild the
    %% Cowboy dispatch tables
    %% But since Specs depend on other objects being present and we also want
    %% to avoid rebuilding the dispatch table multiple times, we just set a
    %% flag on the state to rebuild the dispatch tables once we received an
    %% exchange_finished event,
    _ = lager:info("API Spec object_update received; key=~p", [Key]),
    Acc = State#state.updated_specs,
    {noreply, State#state{updated_specs = [Key|Acc]}};

handle_info(Info, State) ->
    _ = lager:debug("Unexpected event, event=~p, state=~p", [Info, State]),
    {noreply, State}.


terminate(normal, _State) ->
    plum_db_unsubscribe();
terminate(shutdown, _State) ->
    plum_db_unsubscribe();
terminate({shutdown, _}, _State) ->
    plum_db_unsubscribe();
terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.





%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
init_backends(State) ->
    try
         Backends = maps:to_list(State#state.backends),
        _ = [
                begin
                    case Mod:init(Config) of
                        ok -> ok;
                        {error, Reason} -> error(Reason)
                    end
                end || {Mod, Config} <- Backends
        ],
        {ok, State}
    catch
        _:Reason ->
            {error, Reason}
    end.


%% @private
plum_db_subscribe(State) ->
    %% We subscribe to change notifications in plum_db_events, we are
    %% interested in updates to API Specs coming from another node so that we
    %% recompile them and generate the Cowboy dispatch tables
    ok = plum_db_events:subscribe(exchange_started),
    ok = plum_db_events:subscribe(exchange_finished),
    MS = [{
        %% {{{_, _} = FullPrefix, Key}, NewObj, ExistingObj}
        {{?PREFIX, '_'}, '_', '_'}, [], [true]
    }],
    ok = plum_db_events:subscribe(object_update, MS),
    {ok, State}.


%% @private
plum_db_unsubscribe() ->
    _ = plum_db_events:unsubscribe(exchange_started),
    _ = plum_db_events:unsubscribe(exchange_finished),
    _ = plum_db_events:unsubscribe(object_update),
    ok.


mops_ctxt(Event, RealmUri, _Opts, Topic) ->
    #{
        <<"event">> => #{
            <<"realm_uri">> => RealmUri,
            <<"topic">> => Topic,
            <<"subscription_id">> => Event#event.subscription_id,
            <<"publication_id">> => Event#event.publication_id,
            <<"details">> => Event#event.details,
            <<"arguments">> => Event#event.arguments,
            <<"arguments_kw">> => Event#event.arguments_kw,
            <<"timestamp">> => erlang:system_time(millisecond)
        }
    }.
