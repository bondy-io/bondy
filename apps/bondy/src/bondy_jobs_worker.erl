%% =============================================================================
%%  bondy_jobs_worker .erl -
%%
%%  Copyright (c) 2016-2022 Leapsight. All rights reserved.
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
-module(bondy_jobs_worker).
-behaviour(gen_server).

-include("bondy.hrl").

-define(SERVER_NAME(Index), {?MODULE, Index}).

-type execute_fun()     ::  fun(() -> any()).

-record(state, {
    index               :: integer()
}).


%% API
-export([start_link/1]).
-export([pick/1]).
-export([execute/2]).
-export([execute/3]).
-export([execute/4]).
-export([async_execute/2]).
-export([async_execute/3]).


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
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start_link(Index) ->
    ServerName = {via, gproc, bondy_gproc:local_name(?SERVER_NAME(Index))},
    gen_server:start_link(ServerName, ?MODULE, [?JOBS_POOLNAME, Index], []).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec pick(RealmUri :: binary()) -> pid().

pick(RealmUri) when is_binary(RealmUri) ->
    gproc_pool:pick_worker(?JOBS_POOLNAME, RealmUri).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec execute(Server :: pid(), Fun :: execute_fun())->
    ok.

execute(Server, Fun) ->
    execute(Server, Fun, []).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec execute(Server :: pid(), Fun :: execute_fun(), Args :: [any()]) ->
    ok.

execute(Server, Fun, Args) ->
    execute(Server, Fun, Args, infinity).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec execute(
    Server :: pid(),
    Fun :: execute_fun(),
    Args :: [any()],
    Timetout :: timeout()) -> ok.

execute(Server, Fun, Args, Timeout) when is_function(Fun, length(Args) + 1) ->
    gen_server:call(Server, {execute, Fun, Args}, Timeout).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec async_execute(Server :: pid(), Fun :: execute_fun()) ->
    ok.

async_execute(Server, Fun) ->
    async_execute(Server, Fun, []).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec async_execute(Server :: pid(), Fun :: execute_fun(), Args :: [any()]) ->
    ok.

async_execute(Server, Fun, Args) ->
    gen_server:cast(Server, {execute, Fun, Args}).



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([PoolName, Index]) ->
    %% We connect this worker to the pool worker name
    WorkerName = ?SERVER_NAME(Index),
    true = gproc_pool:connect_worker(PoolName, WorkerName),

    State = #state{
        index = Index
    },

    {ok, State}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
handle_call({execute, Fun, []}, _From, State) ->
    try
        Fun()
    catch
        _:Reason ->
            {error, Reason}
    end,

    {reply, ok, State};

handle_call({execute, Fun, Args}, _From, State) ->
    try
        erlang:apply(Fun, Args)
    catch
        _:Reason ->
            {error, Reason}
    end,

    {reply, ok, State};

handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
handle_cast({execute, Fun, []}, State) ->
    try
        Fun()
    catch
        _:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error during async execute",
                reason => Reason,
                stacktrace => Stacktrace
            })
    end,
    {noreply, State};

handle_cast({execute, Fun, Args}, State) ->
    try
        erlang:apply(Fun, Args)
    catch
        _:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error during async execute",
                reason => Reason,
                stacktrace => Stacktrace
            })
    end,
    {noreply, State};

handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
handle_info({'ETS-TRANSFER', _, _, _}, State) ->
    %% The trie ets tables uses bondy_table_owner.
    %% We ignore as tables are named.
    {noreply, State};

handle_info({nodeup, _Node} = Event, State) ->
    ?LOG_DEBUG(#{
        event => Event
    }),
    {noreply, State};

handle_info({nodedown, _Node} = Event, State) ->
    %% A connection with node has gone down
    ?LOG_DEBUG(#{
        event => Event
    }),
    %% TODO deactivate (keep a bloomfilter or list) to filter
    %% future searches or delete?
    {noreply, State};

handle_info(Info, State) ->
    ?LOG_DEBUG(#{
        reason => unexpected_event,
        event => Info
    }),
    {noreply, State}.


terminate(normal, _State) ->
    ok;

terminate(shutdown, _State) ->
    ok;

terminate({shutdown, _}, _State) ->
    ok;

terminate(_Reason, _State) ->
    %% TODO publish metaevent
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.







