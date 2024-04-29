%% =============================================================================
%%  bondy_bridge_relay_manager.erl -
%%
%%  Copyright (c) 2018-2024 Leapsight. All rights reserved.
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
%% @doc EARLY DRAFT implementation of the client-side connection between and
%% edge node (client) and a remote/core node (server).
%% At the moment there is not coordination support for Bridge Relays, this
%% means that if you add a bridge to the bondy.conf that is used to configure
%% more than one node, each node will start a bridge. This is ok for a single
%% node, but not ok for a cluster. In the future we will have some form of
%% leader election to have a singleton.
%%
%% Bridges created through the API will only start on the receiving node.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_bridge_relay_manager).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").


-define(TCP, bridge_relay_tcp).
-define(TLS, bridge_relay_tls).

-define(OPTS_SPEC, #{
    autostart => #{
        alias => <<"autostart">>,
        required => true,
        default => false,
        datatype => boolean
    }
}).

-record(state, {
    bridges = #{}   :: bridges(),
    started = []    :: [binary()]
}).

-type bridges()     ::  #{Name :: binary() => bondy_bridge_relay:t()}.
-type add_opts()    ::  #{
    autostart  => boolean()
}.
-type status()      ::  #{Name :: binary() => #{
                            status =>
                                running | restarting | stopped | not_started
                        }}.

%% API
-export([add_bridge/2]).
-export([connections/0]).
-export([disable_bridge/1]).
-export([enable_bridge/1]).
-export([get_bridge/1]).
-export([status/0]).
-export([list_bridges/0]).
-export([remove_bridge/1]).
-export([resume_listeners/0]).
-export([start_bridge/1]).
-export([start_bridges/0]).
-export([start_link/0]).
-export([start_listeners/0]).
-export([stop_bridge/1]).
-export([stop_bridges/0]).
-export([stop_listeners/0]).
-export([suspend_listeners/0]).
-export([tcp_connections/0]).
-export([tls_connections/0]).


%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_continue/2]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Starts the manager
%% @end
%% -----------------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%% -----------------------------------------------------------------------------
%% @doc Adds a bridge to the manager and optionally starts it.
%%
%% Options:
%%
%% <ul>
%% <li>`autostart :: boolean()' - if true and the add operation succeeded
%% the bridge will be immediately started. If `false' the bridge can be started
%% later using {@link start_bridge/1}.
%% </li>
%% </ul>
%% @end
%% -----------------------------------------------------------------------------
-spec add_bridge(Data :: map(), Opts :: add_opts()) ->
    {ok, bondy_bridge_relay:t()} | {error, Reason :: any()}.

add_bridge(Data, Opts0) ->
    try maps_utils:validate(Opts0, ?OPTS_SPEC) of
        Opts ->
            Timeout = timer:seconds(10),
            gen_server:call(?MODULE, {add_bridge, Data, Opts}, Timeout)
    catch
        _:Reason ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get_bridge(Name :: binary()) ->
    {ok, bondy_bridge_relay:t()} | {error, not_found}.

get_bridge(Name) ->
    gen_server:call(?MODULE, {get_bridge, Name}, timer:seconds(30)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec list_bridges() -> [bondy_bridge_relay:t()].

list_bridges() ->
    gen_server:call(?MODULE, list_bridges, timer:seconds(15)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec status() -> status().

status() ->
    gen_server:call(?MODULE, status, timer:seconds(15)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove_bridge(Name :: binary()) ->
    ok | {error, running | restarting | not_found}.

remove_bridge(Name) ->
    gen_server:call(?MODULE, {remove_bridge, Name}, timer:seconds(30)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec enable_bridge(Name :: binary()) -> ok | {error, any()}.

enable_bridge(Name) ->
    gen_server:call(?MODULE, {enable_bridge, Name}, timer:seconds(30)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec disable_bridge(Name :: binary()) -> ok | {error, any()}.

disable_bridge(Name) ->
    gen_server:call(?MODULE, {disable_bridge, Name}, timer:seconds(30)).


%% -----------------------------------------------------------------------------
%% @doc Adds a bridge to the manager and optionally starts it.
%% Options:
%% <ul>
%% <li>`autostart :: boolean()'</li> - if true and the add operation succeeded
%% the bridge will be immediately started.
%% </ul>
%% @end
%% -----------------------------------------------------------------------------
-spec start_bridges() -> ok.

start_bridges() ->
    gen_server:call(?MODULE, start_bridges, timer:seconds(30)).


%% -----------------------------------------------------------------------------
%% @doc Starts a bridge.
%% @end
%% -----------------------------------------------------------------------------
-spec start_bridge(Name :: binary()) -> ok | {error, any()}.

start_bridge(Name) ->
    gen_server:call(?MODULE, {start_bridge, Name}, timer:seconds(30)).


%% -----------------------------------------------------------------------------
%% @doc Stops a bridge.
%% @end
%% -----------------------------------------------------------------------------
-spec stop_bridge(Name :: binary()) -> ok | {error, any()}.

stop_bridge(Name) ->
    gen_server:call(?MODULE, {stop_bridge, Name}, timer:seconds(30)).


%% -----------------------------------------------------------------------------
%% @doc
%% Stops all bridges
%% @end
%% -----------------------------------------------------------------------------
-spec stop_bridges() -> ok.

stop_bridges() ->
    gen_server:call(?MODULE, stop_bridges, timer:seconds(30)).


%% -----------------------------------------------------------------------------
%% @doc
%% Starts the tcp and tls raw socket listeners
%% @end
%% -----------------------------------------------------------------------------
-spec start_listeners() -> ok.

start_listeners() ->
    Protocol = bondy_bridge_relay_server,
    ok = bondy_ranch_listener:start(?TCP, Protocol, bondy_config:get(?TCP)),
    ok = bondy_ranch_listener:start(?TLS, Protocol, bondy_config:get(?TLS)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec stop_listeners() -> ok.

stop_listeners() ->
    ok = bondy_ranch_listener:stop(?TCP),
    ok = bondy_ranch_listener:stop(?TLS).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec suspend_listeners() -> ok.

suspend_listeners() ->
    ok = bondy_ranch_listener:suspend(?TCP),
    ok = bondy_ranch_listener:suspend(?TLS).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec resume_listeners() -> ok.

resume_listeners() ->
    bondy_ranch_listener:resume(?TCP),
    bondy_ranch_listener:resume(?TLS).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
connections() ->
    bondy_ranch_listener:connections(?TCP)
        ++ bondy_ranch_listener:connections(?TLS).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
tls_connections() ->
    bondy_ranch_listener:connections(?TLS).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
tcp_connections() ->
    bondy_ranch_listener:connections(?TCP).




%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([]) ->
    Config = bondy_config:get(bridges, #{}),
    {ok, #state{}, {continue, {add_bridges, Config}}}.


handle_continue({add_bridges, Config}, State0) ->
    %% Initialize all Bridges which have been configured via bondy.conf file
    %% This is a map where the bridge name is the key and the value has an
    %% almost valid structure but we calidate it again to set some defaults.
    Transient = maps:fold(
        fun(Name, Data, Acc) ->
            %% The call to new can fail with a validation exception
            Bridge = bondy_bridge_relay:new(Data#{name => Name}),
            maps:put(Name, Bridge, Acc)
        end,
        #{},
        Config
    ),

    %% We read all the known bridges previously created by the user using     %% bondy_bridge_relay_wamp_api and defined as permanent (and thus
    %% peristed in the database).
    AllPermanent = bondy_bridge_relay:list(),

    %% We will only consider the bridges defined for this node as we do not
    %% want to run a bridge per node in the cluster!
    %% This is to be replaced by a leader election capability in the future
    %% which will determine which node runs which bridge.
    %% So at the moment we assume the edge router (bridge relay client) is
    %% running in single node.
    MyNodeStr = bondy_config:nodestring(),

    Permanent = maps:from_list([
        {Name, B}
        || #{name := Name, nodestring := NodeStr} = B <- AllPermanent,
            NodeStr =:= MyNodeStr
    ]),

    %% bondy.conf defined bridges override the previous permanent bridges
    CommonKeys = maps:keys(maps:intersect(Permanent, Transient)),

    %% We delete the previous definitions on store as bondy.conf bridges
    %% override those in the store.
    _ = [bondy_bridge_relay:remove(K) || K <- CommonKeys],

    %% We merge overriding the common keys
    Bridges = maps:merge(Permanent, Transient),

    State = State0#state{bridges = Bridges},

    {noreply, State}.


handle_call({add_bridge, Data, Opts}, _From, State0) ->
    {Reply, State} = do_add_bridge(Data, Opts, State0),
    {reply, Reply, State};

handle_call({enable_bridge, _Name}, _From, State) ->
    Reply = {error, not_implemented},
    {reply, Reply, State};

handle_call({disable_bridge, _Name}, _From, State) ->
    Reply = {error, not_implemented},
    {reply, Reply, State};

handle_call({remove_bridge, Name}, _From, State0) ->
    {Reply, State} = do_remove_bridge(Name, State0),
    {reply, Reply, State};

handle_call(start_bridges, _From, State0) ->
    State = start_all(State0),
    {reply, ok, State};

handle_call({start_bridge, Name}, _From, State0) ->
    case maps:find(Name, State0#state.bridges) of
        {ok, Bridge} ->
            try
                State = do_start_bridge(Bridge, State0),
                {reply, ok, State}
            catch
                throw:Reason ->
                    {reply, {error, Reason}, State0}
            end;
        error ->
            {reply, {error, not_found}, State0}
    end;

handle_call(stop_bridges, _From, State0) ->
    State = stop_all(State0),
    {reply, ok, State};

handle_call({stop_bridge, Name}, _From, State0) ->
    try
        State = do_stop_bridge(Name, State0),
        {reply, ok, State}
    catch
        throw:Reason ->
            {reply, {error, Reason}, State0}
    end;

handle_call({get_bridge, Name}, _From, State) ->
    Reply =
        case maps:find(Name, State#state.bridges) of
            {ok, _} = OK ->
                OK;
            error ->
                {error, not_found}
        end,
    {reply, Reply, State};

handle_call(list_bridges, _From, State) ->
    Reply = maps:values(State#state.bridges),
    {reply, Reply, State};

handle_call(status, _From, State) ->
    Managed = maps:keys(State#state.bridges),
    Default = lists:foldl(
        fun(K, Acc) ->
            maps:put(K, #{status => not_started}, Acc)
        end,
        #{},
        Managed
    ),

    Started = supervisor:which_children(bondy_bridge_relay_client_sup),
    Status = lists:foldl(
        fun
            ({K, Term, _, _}, Acc) when is_pid(Term) ->
                maps:put(K, #{status => running}, Acc);
            ({K, restarting, _, _}, Acc) ->
                maps:put(K, #{status => restarting}, Acc);
            ({K, undefined, _, _}, Acc) ->
                maps:put(K, #{status => stopped}, Acc)
        end,
        Default,
        Started
    ),
    {reply, Status, State};


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


handle_info(Info, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Info
    }),
    {noreply, State}.


terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



new_bridge(Data) ->
    try
        bondy_bridge_relay:new(Data)
    catch
        error:Reason ->
            throw(Reason)
    end.


add_bridge_to_state(#{restart := permanent} = Bridge, State) ->
    Name = maps:get(name, Bridge),

    maps:is_key(Name, State#state.bridges)
        andalso throw(already_exists),

    Bridges = State#state.bridges,

    case bondy_bridge_relay:add(Bridge) of
        ok ->
            State#state{bridges = maps:put(Name, Bridge, Bridges)};

        {error, Reason} ->
            throw(Reason)
    end;

add_bridge_to_state(#{restart := transient} = Bridge, State) ->
    Name = maps:get(name, Bridge),

    maps:is_key(Name, State#state.bridges)
        andalso throw(already_exists),

    Bridges = State#state.bridges,
    State#state{bridges = maps:put(Name, Bridge, Bridges)}.


do_add_bridge(Data, Opts, State0) ->
    try
        Bridge = new_bridge(Data),
        State = add_bridge_to_state(Bridge, State0),
        maybe_start_bridge(Bridge, Opts, State)
    catch
        throw:Reason ->
            {{error, Reason}, State0}
    end.


do_remove_bridge(Name, State0) when is_binary(Name) ->

    case bondy_bridge_relay_client_sup:delete_child(Name) of
        ok ->
            remove_from_state(Name, State0);

        {error, not_found} ->
            remove_from_state(Name, State0);

        {error, _} = Error ->
            {Error, State0}
    end.



remove_from_state(Name, State) ->
    case maps:take(Name, State#state.bridges) of
        {Bridge, Bridges} ->
            ok = maybe_delete_from_store(Bridge),
            {ok, State#state{bridges = Bridges}};
        error ->
            {ok, State}
    end.



maybe_delete_from_store(#{restart := permanent, name := Name}) ->
    bondy_bridge_relay:remove(Name);

maybe_delete_from_store(_) ->
    ok.


start_all(State) ->
    maps:fold(
        fun
            (_Name, #{enabled := true} = Bridge, Acc) ->
                %% We only start the enabled bridges
                try
                    do_start_bridge(Bridge, Acc)
                catch
                    throw:_ ->
                        Acc
                end;
            (_, _, Acc) ->
                Acc
        end,
        State,
        State#state.bridges
    ).


stop_all(State) ->
    Running = supervised_bridges(State),

    maps:fold(
        fun(Name, Acc) ->
            try
                do_stop_bridge(Name, Acc)
            catch
                throw:_ ->
                    Acc
            end
        end,
        State,
        Running
    ).


supervised_bridges(_State) ->
    %% TODO montior pids and add them to 'started'
    %% when created to avoid asking the supervisor
    All = supervisor:which_children(bondy_bridge_relay_client_sup),
    [Id || {Id, _, _, _} <- All].


maybe_start_bridge(Bridge, #{autostart := true}, State0) ->
    try
        State = do_start_bridge(Bridge, State0),
        Reply = {ok, Bridge},
        {Reply, State}
    catch
        throw:Reason ->
            {{error, Reason}, State0}
    end;

maybe_start_bridge(Bridge, _, State) ->
    {{ok, Bridge}, State}.


do_start_bridge(Bridge, State) ->
    case bondy_bridge_relay_client_sup:start_child(Bridge) of
        {ok, _} ->
            Name = maps:get(name, Bridge),
            Started = State#state.started,
            State#state{started = [Name | Started]};
        {error, {already_started, _}} ->
            State;
        {error, Reason} ->
            throw(Reason)
    end.


do_stop_bridge(Name, State) ->
    ?LOG_INFO(# {
        description => "Stopping bridge relay.",
        id => Name
    }),
    case bondy_bridge_relay_client_sup:terminate_child(Name) of
        ok ->
            Started = lists:delete(Name, State#state.started),
            State#state{started = Started};
        {error, Reason} ->
            throw(Reason)
    end.