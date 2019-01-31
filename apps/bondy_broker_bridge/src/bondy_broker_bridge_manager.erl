%% =============================================================================
%%  bondy_broker_bridge_manager.erl -
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
%% @doc This module provides event bridging functionality, allowing
%% a supervised process (implemented via bondy_subscriber) to subscribe to WAMP
%% events and to process and or forward those events to an external system,
%% e.g. publish to another message broker.
%%
%% A subscription can be created at runtime using the `subscribe/5',
%% or at system boot time by setting the application's `subscribers_spec'
%% environment variable which should have the filename of a valid
%% Broker Bridge Specification File.
%%
%%
%% Each broker bridge is implemented as a callback module implementing the
%% bondy_broker_bridge behaviour.
%%
%% ## Action Specification Map.
%%
%% ## `mops' Evaluation Context
%%
%% The mops context is map containing the following:
%% ```erlang
%% #{
%%     <<"broker">> => #{
%%         <<"node">> => binary()
%%         <<"agent">> => binary()
%%     },
%%     <<"event">> => #{
%%         <<"realm_uri">> => uri(),
%%         <<"topic">> => uri(),
%%         <<"subscription_id">> => integer(),
%%         <<"publication_id">> => integer(),
%%         <<"details">> => map(), % WAMP EVENT.details
%%         <<"arguments">> => list(),
%%         <<"arguments_kw">> => map(),
%%         <<"processing_timestamp">> => integer()
%%     }
%% }.
%% ```
%%
%% ## Broker Bridge Specification File.
%%
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_broker_bridge_manager).
-behaviour(gen_server).
-include("bondy_broker_bridge.hrl").
-include_lib("wamp/include/wamp.hrl").

-define(TIMEOUT, 30000).
-define(PREFIX, {broker_bridge, subscription_specs}).

-define(SUBSCRIPTIONS_SPEC, #{
    <<"id">> => #{
        alias => id,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => binary
    },
    <<"meta">> => #{
        alias => meta,
        required => false,
        datatype => map
    },
    <<"subscriptions">> => #{
        alias => bridges,
        required => true,
        allow_null => false,
        allow_undefined => false,
        validator => {list, ?SUBS_SPEC}
    }
}).

-define(SUBS_SPEC, #{
    <<"bridge">> => #{
        alias => bridge,
        required => true,
        allow_null => false,
        allow_undefined => false,
        validator => fun
            (Bin) when is_binary(Bin) ->
                try list_to_atom(binary_to_list(Bin)) of
                    Mod ->
                        case erlang:module_loaded(Mod) of
                            true -> {ok, Mod};
                            false -> {error, {unknown_bridge, Mod}}
                        end
                catch
                    ?EXCEPTION(_, _, _) -> false
                end;
            (Mod) when is_atom(Mod) ->
                erlang:module_loaded(Mod)
        end
    },
    <<"match">> => #{
        alias => action,
        required => true,
        allow_null => false,
        allow_undefined => false,
        validator => ?MATCH_SPEC
    },
    %% The details of the action are validated by each
    %% bondy_broker_bridge callback implementation
    <<"action">> => #{
        alias => action,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => map
    }
}).

-define(MATCH_SPEC, #{
    <<"realm_uri">> => #{
        alias => realm_uri,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => binary
    },
    <<"topic">> => #{
        alias => topic,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => binary
    },
    <<"options">> => #{
        alias => options,
        required => true,
        default => #{},
        validator => ?SUBSCRIBE_OPTS_SPEC
    }
}).

-record(state, {
    nodename                        ::  binary(),
    broker_agent                    ::  binary(),
    bridges = #{}                   ::  #{module() => bridge()}
    %% Cluster sync state
    %% exchange_ref            ::  {pid(), reference()} | undefined,
    %% updated_specs = []      ::  list()
}).

-type bridge()              ::  map().
-type subscription_detail() ::  map().

%% API
-export([start_link/0]).
-export([load/1]).
-export([subscribe/5]).
-export([unsubscribe/1]).
-export([bridges/0]).
-export([bridge/1]).
-export([subscriptions/1]).
-export([validate_spec/1]).

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
%% @doc Internal function called by bondy_broker_bridge_sup.
%% @end
%% -----------------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%% -----------------------------------------------------------------------------
%% @doc Lists all the configured bridge configurations.
%% @end
%% -----------------------------------------------------------------------------
-spec bridges() -> [bridge()].
bridges() ->
    gen_server:call(?MODULE, bridges, 10000).


%% -----------------------------------------------------------------------------
%% @doc Returns the bridge configuration identified by its module name.
%% @end
%% -----------------------------------------------------------------------------
-spec bridge(module()) -> [bridge()].
bridge(Mod) ->
    gen_server:call(?MODULE, {bridge, Mod}, 10000).


%% -----------------------------------------------------------------------------
%% @doc Parses the provided Broker Bridge Specification and creates all the
%% provided subscriptions.
%% @end
%% -----------------------------------------------------------------------------
-spec load(file:filename() | map()) ->
    ok | {error, invalid_specification_format | any()}.

load(Term) when is_map(Term) orelse is_list(Term) ->
    gen_server:call(?MODULE, {load, Term}).


%% -----------------------------------------------------------------------------
%% @doc Creates a subscription using bondy_broker.
%% This results in a new supervised bondy_subscriber processed that subcribes
%% to {Realm, Topic} and forwards any received publication (event) to the
%% bridge identified by `Bridge'.
%%
%% Returns the tuple {ok, Pid} where Pid is the pid() of the supervised process
%% or the tuple {error, Reason}.
%% @end
%% -----------------------------------------------------------------------------
-spec subscribe(uri(), map(), uri(), Bridge :: module(), Spec :: map()) ->
    {ok, id()} | {error, already_exists}.

subscribe(RealmUri, Opts, Topic, Bridge, Spec) ->
    gen_server:call(
        ?MODULE, {subscribe, RealmUri, Opts, Topic, Bridge, Spec}, ?TIMEOUT).


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
-spec subscriptions(BridgeId :: bridge()) -> [subscription_detail()].

subscriptions(BridgeId) ->
    gen_server:call(?MODULE, {subscriptions, BridgeId}, 10000).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec validate_spec(map()) -> {ok, map()} | {error, any()}.
validate_spec(Map) ->
    try
        Val = maps_utils:validate(Map, ?SUBSCRIPTIONS_SPEC),
        {ok, Val}
    catch
        ?EXCEPTION(_, Reason, _) ->
            {error, Reason}
    end.




%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([]) ->
    %% We store the bridges configurations provided
    Bridges = application:get_env(bondy_broker_bridge, bridges, []),
    SpecFile = application:get_env(
        bondy_broker_bridge, subscribers_spec, undefined),
    BridgesMap = maps:from_list(
        [{Mod, #{id => Mod, config => Config}} || {Mod, Config} <- Bridges]
    ),
    State0 = #state{
        nodename = list_to_binary(atom_to_list(bondy_peer_service:mynode())),
        broker_agent = bondy_router:agent(),
        bridges = BridgesMap
    },

    %% Uncomment the following if we decide to store config in plum_db
    %% At the moment we are assumming bridges are only configured on startup
    %% through a config file
    %% ok = plum_db_subscribe(),

    case init_bridges(State0) of
        {ok, State1} ->
            load_spec(SpecFile, State1);
        {error, _} = Error ->
            Error
    end.



handle_call(bridges, _From, State) ->
    Res = bridges(State),
    {reply, Res, State};

handle_call({bridge, Mod}, _From, State) ->
    Res = get_bridge(Mod, State),
    {reply, Res, State};

handle_call({subscriptions, Bridge}, _From, State) ->
    Res = get_subscriptions(Bridge),
    {reply, Res, State};

handle_call({subscribe, RealmUri, Opts, Topic, Bridge, Spec0}, _From, State) ->
    try do_subscribe(RealmUri, Opts, Topic, Bridge, Spec0, State) of
        {ok, Id, _Pid} ->
            {reply, {ok, Id}, State}
    catch
        ?EXCEPTION(_, Reason, _) ->
            {reply, {error, Reason}, State}
    end;

handle_call({unsubscribe, Id}, _From, State) ->
    Res = bondy_broker:unsubscribe(Id),
    {reply, Res, State};

handle_call({load, Term}, _From, State) ->
    {Res, NewState} = load_spec(Term, State),
    {reply, Res, NewState};

handle_call(Event, From, State) ->
    _ = lager:error("Unexpected event, event=~p, from=~p", [Event, From]),
    {noreply, State}.


handle_cast(Event, State) ->
    _ = lager:error("Unexpected event, event=~p", [Event]),
    {noreply, State}.


%% handle_info({plum_db_event, exchange_started, {Pid, _Node}}, State) ->
%%     Ref = erlang:monitor(process, Pid),
%%     {noreply, State#state{exchange_ref = {Pid, Ref}}};

%% handle_info(
%%     {plum_db_event, exchange_finished, {Pid, _Reason}},
%%     #state{exchange_ref = {Pid, Ref}} = State0) ->

%%     true = erlang:demonitor(Ref),
%%     %% ok = handle_spec_updates(State0),
%%     State1 = State0#state{updated_specs = [], exchange_ref = undefined},
%%     {noreply, State1};

%% handle_info({plum_db_event, exchange_finished, {_, _}}, State) ->
%%     %% We are receiving the notification after we recevied a DOWN message
%%     %% we do nothing
%%     {noreply, State};

%% handle_info({plum_db_event, object_update, {{?PREFIX, Key}, _, _}}, State) ->
%%     %% We've got a notification that an API Spec object has been updated
%%     %% in the database via cluster replication, so we need to rebuild the
%%     %% Cowboy dispatch tables
%%     %% But since Specs depend on other objects being present and we also want
%%     %% to avoid rebuilding the dispatch table multiple times, we just set a
%%     %% flag on the state to rebuild the dispatch tables once we received an
%%     %% exchange_finished event,
%%     _ = lager:info("API Spec object_update received; key=~p", [Key]),
%%     Acc = State#state.updated_specs,
%%     {noreply, State#state{updated_specs = [Key|Acc]}};

%% handle_info(
%%     {'DOWN', Ref, process, Pid, _Reason},
%%     #state{exchange_ref = {Pid, Ref}} = State0) ->

%%     %% ok = handle_spec_updates(State0),
%%     State1 = State0#state{updated_specs = [], exchange_ref = undefined},
%%     {noreply, State1};

handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    _ = lager:debug("Subscriber down, pid=~p", [Pid]),
    %% TODO
    {noreply, State};


handle_info(Info, State) ->
    _ = lager:debug("Unexpected event, event=~p, state=~p", [Info, State]),
    {noreply, State}.


terminate(normal, State) ->
    do_terminate(normal, State);
terminate(shutdown, State) ->
    do_terminate(shutdown, State);
terminate({shutdown, _}, State) ->
    do_terminate(shutdown, State);
terminate(Reason, State) ->
    do_terminate(Reason, State).


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.





%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
init_bridges(State) ->
    try
        Bridges0 = State#state.bridges,
        Fun = fun(Mod, #{config := Config} = Bridge, Acc) ->
            case Mod:init(Config) of
                {ok, Ctxt} when is_map(Ctxt) ->
                    maps:put(Mod, maps:put(ctxt, Ctxt, Bridge), Acc);
                {error, Reason} ->
                    error(Reason)
            end
        end,
        Bridges1 = maps:fold(Fun, Bridges0, Bridges0),
        {ok, State#state{bridges = Bridges1}}
    catch
        ?EXCEPTION(_, Reason, Stacktrace) ->
            _ = lager:error(
                "Error; reason ~p, stacktrace=~p",
                [Reason, ?STACKTRACE(Stacktrace)]
            ),
            {error, Reason}
    end.


%% @private
terminate_bridges(Reason, #state{bridges = Map} = State) ->
    Fun = fun(Bridge, _Config, Acc) ->
        ok = Bridge:terminate(Reason),
        Acc#state{bridges = maps:delete(Bridge, Map)}
    end,
    maps:fold(Fun, State, Map).


%% @private
get_bridge(Mod, State) ->
    maps:get(Mod, State#state.bridges, undefined).


%% -----------------------------------------------------------------------------
%% @private
%% @doc We subscribe to change notifications in plum_db_events, we are
%% interested in updates to Bridge Specs coming from another node so that we
%% recompile them and generate the Cowboy dispatch tables
%% @end
%% -----------------------------------------------------------------------------
%% plum_db_subscribe() ->
%%     ok = plum_db_events:subscribe(exchange_started),
%%     ok = plum_db_events:subscribe(exchange_finished),
%%     MS = [{
%%         %% {{{_, _} = FullPrefix, Key}, NewObj, ExistingObj}
%%         {{?PREFIX, '_'}, '_', '_'}, [], [true]
%%     }],
%%     ok = plum_db_events:subscribe(object_update, MS),
%%     ok.


%% -----------------------------------------------------------------------------
%% @private
%% @doc Unsubscribes the process from the plum_db notifications that were setup
%% by plum_db_subscribe/0
%% @end
%% -----------------------------------------------------------------------------
%% plum_db_unsubscribe() ->
%%     _ = plum_db_events:unsubscribe(exchange_started),
%%     _ = plum_db_events:unsubscribe(exchange_finished),
%%     _ = plum_db_events:unsubscribe(object_update),
%%     ok.


%% @private
do_terminate(Reason, State) ->
    %% ok = plum_db_unsubscribe(),
    _ = unsubscribe_all(State),
    _ = terminate_bridges(Reason, State),
    ok.


%% @private
load_spec(Map, State) when is_map(Map) ->
    case validate_spec(Map) of
        {ok, Spec} ->
            #{<<"subscriptions">> := Subscriptions} = Spec,
            %% We instantiate the subscribers
            Folder = fun(Subs, Acc) ->
                {ok, _, _} = do_subscribe(Subs, Acc),
                Acc
            end,
            NewState = lists:foldl(Folder, State, Subscriptions),
            %% We store the specification, see add/2 for an explanation
            %% ok = plum_db:put(?PREFIX,
            %%     Id,
            %%     maps:put(<<"ts">>, erlang:monotonic_time(millisecond), Spec)
            %% ),
            %% %% We rebuild the dispatch table
            %% rebuild_dispatch_tables();
            {ok, NewState};
        {error, _} = Error ->
            {Error, State}
    end;

load_spec(FName, State) when is_list(FName) orelse is_binary(FName) ->
    _ = lager:info("Loading subscribers specification file; file=~p", [FName]),

    try jsx:consult(FName, [return_maps]) of
        [Spec] ->
            load_spec(Spec, State)
    catch
        ?EXCEPTION(_, badarg, _) ->
            {{error, invalid_specification_format}, State}
    end;

load_spec(undefined, State) ->
    _ = lager:info("Subscribers specification file undefined"),
    {ok, State};

load_spec(_, State) ->
    {{error, badarg}, State}.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
mops_ctxt(Event, RealmUri, _Opts, Topic, Bridge, State) ->
    %% mops requiere binary keys
    Base = maps:get(ctxt, bridge(Bridge)),
    Base#{
        <<"broker">> => #{
            <<"node">> => State#state.nodename,
            <<"agent">> => State#state.broker_agent
        },
        <<"event">> => #{
            <<"realm_uri">> => RealmUri,
            <<"topic">> => Topic,
            <<"subscription_id">> => Event#event.subscription_id,
            <<"publication_id">> => Event#event.publication_id,
            <<"details">> => Event#event.details,
            <<"arguments">> => Event#event.arguments,
            <<"arguments_kw">> => Event#event.arguments_kw,
            <<"processing_timestamp">> => erlang:system_time(millisecond)
        }
    }.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
do_subscribe(Subscription, State) ->
    #{
        <<"bridge">> := Bridge,
        <<"match">> := #{
            <<"realm_uri">> := RealmUri,
            <<"topic">> := Topic,
            <<"options">> := Opts
        },
        <<"action">> := Action
    } = Subscription,

    case get_bridge(Bridge, State) of
        undefined ->
            error({unknown_bridge, Bridge});
        #{id := Bridge} ->
            do_subscribe(RealmUri, Opts, Topic, Bridge, Action, State)
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
do_subscribe(RealmUri, Opts, Topic, Bridge, Action0, State) ->
    try
        %% We build the fun that we will use for the subscriber
        Fun = fun
            (Topic1, Event) when Topic1 == Topic ->
                Ctxt = mops_ctxt(Event, RealmUri, Opts, Topic, Bridge, State),
                Action1 = mops:eval(Action0, Ctxt),
                case Bridge:validate_action(Action1) of
                    {ok, Action2} ->
                        %% TODO: Also handle acknowledge to publisher when
                        %% Action.options.acknowledge == true
                        Bridge:apply_action(Action2);
                    {error, Reason} ->
                        throw({invalid_action, Reason})
                end;
            (_Topic1, {brod_produce_reply, _ ,brod_produce_req_acked}) ->
                %% Required to handle in case of Action.type == produce (async)
                ok
        end,
        %% We use bondy_broker subscribers, this is an intance of a
        %% bondy_subscriber gen_server supervised by bondy_subscribers_sup
        {ok, Id, Pid} = Res = bondy_broker:subscribe(
            RealmUri, Opts, Topic, Fun),
        %% Add to registry and set properties
        true = gproc:reg_other({n, l, {subscriber, Id}}, Pid),
        true = gproc:reg_other({r, l, subscription_id}, Pid, Id),
        true = gproc:reg_other({r, l, bondy_broker_bridge}, Pid, Bridge),
        Res
    catch
        ?EXCEPTION(_, Reason, Stacktrace) ->
            _ = lager:error(
                "Error while evaluating action; reason=~p, "
                "bridge = ~p "
                "stacktrace=~p",
                [Reason, Bridge, ?STACKTRACE(Stacktrace)]
            ),
            {{error, Reason}, State}
    end.



%% @private
unsubscribe_all(State) ->
    _ = [bondy_broker:unsubscribe(Pid) || Pid <- all_subscribers(State)],
    ok.


%% @private
bridges(State) ->
    maps:values(State#state.bridges).


%% @private
all_subscribers(State) ->
    Ids = maps:keys(State#state.bridges),
    lists:append([subscribers(Id) || Id <- Ids]).


%% @private
subscribers(Bridge) ->
    %% {{{p,l,bondy_broker_bridge},<0.2738.0>},<0.2738.0>,Bridge},
    MatchSpec = [{
        {{r, l, bondy_broker_bridge}, '$1', Bridge},
        [],
        ['$1']
    }],
    gproc:select({l, resources}, MatchSpec).


%% @private
get_subscriptions(Bridge) ->
    [{gproc:get_value({r, l, subscription_id}, Pid), Pid}
        || Pid <- subscribers(Bridge)].



