%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_bridge_relay_manager).
-moduledoc """
EARLY DRAFT implementation of the client-side connection between and
edge node (client) and a remote/core node (server).

At the moment there is not coordination support for Bridge Relays, this
means that if you add a bridge to the bondy.conf that is used to configure
more than one node, each node will start a bridge. This is ok for a single
node, but not ok for a cluster. In the future we will have some form of
leader election to have a singleton.

Bridges created through the API will only start on the receiving node.
""".
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-define(OPTS_SPEC, #{
    autostart => #{
        alias => <<"autostart">>,
        required => true,
        default => false,
        datatype => boolean
    }
}).

-record(state, {
    bridges = #{} :: bridges(),
    started = [] :: [binary()]
}).

-type bridges() :: #{Name :: binary() => bondy_bridge_relay:t()}.
-type add_opts() :: #{
    autostart => boolean()
}.
-type status() :: #{
    Name ::
        binary() => #{
            status =>
                running | restarting | stopped | not_started
        }
}.

%% API
-export([add_bridge/2]).
-export([disable_bridge/1]).
-export([enable_bridge/1]).
-export([get_bridge/1]).
-export([status/0]).
-export([list_bridges/0]).
-export([remove_bridge/1]).
-export([start_bridge/1]).
-export([start_bridges/0]).
-export([start_link/0]).
-export([stop_bridge/1]).
-export([stop_bridges/0]).

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

-doc "Starts the manager.".
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Adds a bridge to the manager and optionally starts it.

Options:

- `autostart :: boolean()` - if true and the add operation succeeded
  the bridge will be immediately started. If `false` the bridge can be started
  later using `start_bridge/1`.
""".
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

-spec get_bridge(Name :: binary()) ->
    {ok, bondy_bridge_relay:t()} | {error, not_found}.

get_bridge(Name) ->
    gen_server:call(?MODULE, {get_bridge, Name}, timer:seconds(30)).

-spec list_bridges() -> [bondy_bridge_relay:t()].

list_bridges() ->
    gen_server:call(?MODULE, list_bridges, timer:seconds(15)).

-spec status() -> status().

status() ->
    gen_server:call(?MODULE, status, timer:seconds(15)).

-spec remove_bridge(Name :: binary()) ->
    ok | {error, running | restarting | not_found}.

remove_bridge(Name) ->
    gen_server:call(?MODULE, {remove_bridge, Name}, timer:seconds(30)).

-spec enable_bridge(Name :: binary()) -> ok | {error, any()}.

enable_bridge(Name) ->
    gen_server:call(?MODULE, {enable_bridge, Name}, timer:seconds(30)).

-spec disable_bridge(Name :: binary()) -> ok | {error, any()}.

disable_bridge(Name) ->
    gen_server:call(?MODULE, {disable_bridge, Name}, timer:seconds(30)).

-doc """
Boot-time entry point, called once by `bondy_app` on the durable boot path
(`start_normal_listeners/0`), after the `main` store is known to be open.

Loads the bridges to manage — the `bridges` section of `bondy.conf` merged
over the permanent bridges this node persisted through the API, the former
overriding the latter — and then starts every enabled one.

The load reads and writes the durable `bondy_bridge_relay` table, which is
why it lives here and NOT in `init/1`: the manager is a `bondy_sup` child
that comes up on every boot, including a degraded one where `main` failed
to open (`bondy_namespace_catalog:open_main_into/1`). Reading the table
then raises `bridge_relay_table_unavailable`, and a raise from `init/1` or
its continuation crash-loops this manager into
`reached_max_restart_intensity`, taking `bondy_sup` — and the node the
catalogue deliberately left standing — down with it. On a degraded boot
`bondy_app:start_services/1` never calls this, so the manager holds no
bridges and touches no table. Exercised end-to-end by
`bondy_degraded_boot_SUITE`.

Replaces the manager's bridge set; it is not additive across calls.
""".
-spec start_bridges() -> ok.

start_bridges() ->
    gen_server:call(?MODULE, start_bridges, timer:seconds(30)).

-doc "Starts a bridge.".
-spec start_bridge(Name :: binary()) -> ok | {error, any()}.

start_bridge(Name) ->
    gen_server:call(?MODULE, {start_bridge, Name}, timer:seconds(30)).

-doc "Stops a bridge.".
-spec stop_bridge(Name :: binary()) -> ok | {error, any()}.

stop_bridge(Name) ->
    gen_server:call(?MODULE, {stop_bridge, Name}, timer:seconds(30)).

-doc "Stops all bridges.".
-spec stop_bridges() -> ok.

stop_bridges() ->
    gen_server:call(?MODULE, stop_bridges, timer:seconds(30)).

%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

init([]) ->
    %% No store access here — see `start_bridges/0`.
    {ok, #state{}}.

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
    State = start_all(load_bridges(State0)),
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

    maps:is_key(Name, State#state.bridges) andalso
        throw(already_exists),

    Bridges = State#state.bridges,

    case bondy_bridge_relay:add(Bridge) of
        ok ->
            State#state{bridges = maps:put(Name, Bridge, Bridges)};
        {error, Reason} ->
            throw(Reason)
    end;
add_bridge_to_state(#{restart := transient} = Bridge, State) ->
    Name = maps:get(name, Bridge),

    maps:is_key(Name, State#state.bridges) andalso
        throw(already_exists),

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

%% @private
%% The bridge set this node manages: `bondy.conf` bridges merged over the
%% permanent bridges persisted for this node, the former overriding the
%% latter (an overridden permanent bridge is removed from the store). Reads
%% and writes the durable table — only reachable through `start_bridges/0`.
load_bridges(State0) ->
    Config = bondy_config:get(bridges, #{}),
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

    %% We read all the known bridges previously created by the user using
    %% bondy_bridge_relay_wamp_api and defined as permanent (and thus
    %% persisted in the database).
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

    State0#state{bridges = Bridges}.

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
    ?LOG_INFO(#{
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
