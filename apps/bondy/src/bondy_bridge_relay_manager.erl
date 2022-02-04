%% =============================================================================
%%  bondy_bridge_relay_manager.erl -
%%
%%  Copyright (c) 2018-2022 Leapsight. All rights reserved.
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

-record(state, {
    bridges = #{}   :: map(),
    started = []    :: [binary()]
}).

%% API
-export([connections/0]).
-export([resume_listeners/0]).
-export([start_bridges/0]).
-export([start_link/0]).
-export([start_listeners/0]).
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
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%% -----------------------------------------------------------------------------
%% @doc
%% Starts the tcp and tls raw socket listeners
%% @end
%% -----------------------------------------------------------------------------
-spec start_listeners() -> ok.

start_listeners() ->
    Protocol = bondy_bridge_relay_server,
    %% TODO
    ProtocolOpts = [],
    ok = bondy_ranch_listener:start(?TCP, Protocol, ProtocolOpts),
    ok = bondy_ranch_listener:start(?TLS, Protocol, ProtocolOpts).


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


%% -----------------------------------------------------------------------------
%% @doc
%% Starts the tcp and tls raw socket listeners
%% @end
%% -----------------------------------------------------------------------------
-spec start_bridges() -> ok.

start_bridges() ->
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% Stops all bridges
%% @end
%% -----------------------------------------------------------------------------
-spec stop_bridges() -> ok.

stop_bridges() ->
    ok.



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([]) ->
    Config = bondy_config:get(bridges),

    {ok, #state{}, {continue, {init_bridges, Config}}}.


handle_continue({init_bridges, Config}, State0) ->
    %% Initialize all Bridges which have been configured via bondy.conf file
    %% This is amp where the bridge name is the key and the value has an
    %% almost valid structure but we still have to validate them to set some
    %% defaults.
    Transient = maps:fold(
        fun(Name, Data, Acc) ->
            Bridge = bondy_bridge_relay:new(Data#{name => Name}),
            maps:put(Name, Bridge, Acc)
        end,
        #{},
        Config
    ),

    %% Retrieve all permanent bridges (persisted).
    Permanent = maps:from_list([
        {Name, B} || #{name := Name} = B <- bondy_bridge_relay:list()
    ]),

    %% bondy.conf defined bridges override the previous permanent bridges
    CommonKeys = maps:keys(maps:intersect(Permanent, Transient)),

    %% We delete the previous definitions on store
    _ = [bondy_bridge_relay:remove(K) || K <- CommonKeys],

    %% We merge overriding the common keys
    Bridges = maps:merge(Permanent, Transient),

    Started = maps:fold(
        fun
            (Name, #{enabled := true} = Bridge, Acc) ->
                {ok, _} = bondy_bridge_relay_client_sup:start_child(Bridge),
                [Name|Acc];
            (_, _, Acc) ->
                Acc
        end,
        [],
        Bridges
    ),

    State = State0#state{bridges = Bridges, started = Started},

    {noreply, State}.


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
