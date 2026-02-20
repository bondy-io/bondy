%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================


-module(bondy_transport_queue_manager).
-moduledoc """
A gen_server that manages the `bondy_transport_queue` lifecycle and runs
periodic TTL-based expiry sweeps.

On init, it calls `bondy_transport_queue:init/0` to create the sharded ETS
tables and metadata table. It then schedules a periodic eviction timer that
calls `bondy_transport_queue:evict_expired_all/0` to remove messages whose
TTL has elapsed.
""".
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-define(DEFAULT_EVICTION_INTERVAL, 5000).

-record(state, {
    evict_interval          ::  pos_integer()
}).


%% API
-export([start_link/0]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).



%% =============================================================================
%% API
%% =============================================================================



-doc """
Starts the transport queue manager as a locally registered gen_server.
""".
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init(_) ->
    process_flag(trap_exit, true),

    %% Initialise the sharded queue tables
    ok = bondy_transport_queue:init(),

    Interval = bondy_config:get(
        [transport_queue, eviction_interval],
        ?DEFAULT_EVICTION_INTERVAL
    ),

    State = #state{evict_interval = Interval},

    ok = schedule_eviction(State),

    {ok, State}.


handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        from => From,
        event => Event
    }),
    {noreply, State}.


handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.


handle_info(evict, State) ->
    try
        ok = bondy_transport_queue:evict_expired_all()
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error during transport queue eviction sweep",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            })
    end,
    ok = schedule_eviction(State),
    {noreply, State};

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



%% @private
schedule_eviction(State) ->
    Interval = State#state.evict_interval,
    _ = erlang:send_after(Interval, self(), evict),
    ok.
