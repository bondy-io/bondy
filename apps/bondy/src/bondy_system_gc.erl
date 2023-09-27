%% =============================================================================
%%  bondy_system_gc.erl -
%%
%%  Copyright (c) 2016-2023 Leapsight. All rights reserved.
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

-module(bondy_system_gc).
-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").

-record(state, {}).

%% API
-export([start_link/0]).
-export([garbage_collect/0]).

%% GEN_SERVER CALLBACKS
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([init/1]).
-export([terminate/2]).



%% =============================================================================
%% API
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @doc Starts the registry server. The server maintains the in-memory tries we
%% use for matching and it is also a subscriber for plum_db broadcast and AAE
%% events in order to keep the trie up-to-date with plum_db.
%% @end
%% -----------------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec garbage_collect() -> ok.

garbage_collect() ->
    gen_server:cast(?MODULE, garbage_collect).



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([]) ->
    ok = schedule_gc(),
    {ok, #state{}}.


handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State}.


handle_cast(garbage_collect, State) ->
    ok = do_gc(),
    {noreply, State};


handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.


handle_info(scheduled_gc, State) ->
    ok = do_gc(),
    ok = schedule_gc(),
    {noreply, State};

handle_info(Info, State) ->
    ?LOG_DEBUG(#{
        reason => unexpected_event,
        event => Info
    }),
    {noreply, State}.



terminate(_Reason, _State) ->
    %% TODO publish metaevent
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.





%% =============================================================================
%% PRIVATE
%% =============================================================================



schedule_gc() ->
    Interval = bondy_config:get(gc_interval, timer:minutes(5)),
    erlang:send_after(Interval, self(), scheduled_gc),
    ok.



do_gc() ->
    {process_count, Count} = erlang:system_info(process_count),
    Ratio = bondy_config:get(gc_ratio, 0.3),
    N = round(Count * Ratio),
    L = [element(1, X) || X <- recon:proc_count(memory, N)],

    [
        erlang:garbage_collect(P)
        || P <- L,  {status, waiting} == process_info(P, status)
    ],

    %% We gc ourselves
    erlang:garbage_collect(),
    ok.