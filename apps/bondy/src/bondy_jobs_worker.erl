%% =============================================================================
%%  bondy_jobs_worker .erl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
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

-module(bondy_jobs_worker).
-behaviour(gen_server).

-include("bondy.hrl").

-define(SERVER_NAME(Index), {?MODULE, Index}).
-define(QUEUE_NAME(Index), {?MODULE, Index, queue}).

-record(state, {
    index               :: integer(),
    queue               :: {?MODULE, pos_integer(), queue}
}).


%% API
-export([enqueue/2]).
-export([pick_queue/1]).
-export([pick_worker/1]).
-export([start_link/1]).


%% GEN_SERVER CALLBACKS
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_continue/2]).
-export([handle_info/2]).
-export([init/1]).
-export([terminate/2]).



%% =============================================================================
%% API
%% =============================================================================



start_link(Index) ->
    ServerName = {via, gproc, bondy_gproc:local_name(?SERVER_NAME(Index))},
    gen_server:start_link(ServerName, ?MODULE, [?JOBS_POOLNAME, Index], []).


-spec pick_queue(Value :: any()) -> Name :: any() | false.

pick_queue(PartitionKey) ->
    {n, l, [_, _, _, {?MODULE, Index}]} = gproc_pool:pick(
        ?JOBS_POOLNAME, PartitionKey
    ),
    ?QUEUE_NAME(Index).


-spec pick_worker(RealmUri :: binary()) -> pid().

pick_worker(RealmUri) when is_binary(RealmUri) ->
    gproc_pool:pick_worker(?JOBS_POOLNAME, RealmUri).



-spec enqueue(Fun :: function(), PartitionKey :: any()) -> ok | {error, any()}.

enqueue(Fun, PartitionKey) when is_function(Fun, 0) ->
    jobs:enqueue(pick_queue(PartitionKey), Fun).




%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([PoolName, Index]) ->
    %% We create a dedicated jobs queue for the worker
    %% TODO get config
    PoolSize = bondy_config:get([job_manager_pool, size], 32),
    MaxSize = round(
        bondy_config:get([job_manager_queue, max_size], 20000) / PoolSize
    ),
    QOpts = [
        {type, {passive, fifo}},
        {max_time, bondy_config:get(
            [job_manager_queue, ttl], timer:minutes(10))
        },
        {max_size, MaxSize},
        {link, self()}
    ],
    Queue = ?QUEUE_NAME(Index),
    ok = jobs:add_queue(Queue, QOpts),

    %% We connect this worker to the pool worker name
    WorkerName = ?SERVER_NAME(Index),
    true = gproc_pool:connect_worker(PoolName, WorkerName),

    State = #state{index = Index, queue = Queue},
    {ok, State, {continue, dequeue}}.


handle_continue(dequeue, State) ->
    %% This will block the server until there is at least 1 job
    Jobs = jobs:dequeue(State#state.queue, 10),
    ok = safe_execute([Fun || {_, Fun} <- Jobs]),
    %% We wait 10 msecs just for the server to consume any inbox message
    Timeout = 10,
    {noreply, State, Timeout}.


handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State, {continue, dequeue}}.


handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State, {continue, dequeue}}.


handle_info(timeout, State) ->
    {noreply, State, {continue, dequeue}};

handle_info(Info, State) ->
    ?LOG_DEBUG(#{
        reason => unexpected_event,
        event => Info
    }),
    {noreply, State, {continue, dequeue}}.


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




%% =============================================================================
%% PRIVATE
%% =============================================================================


safe_execute([Fun | Funs]) ->
    try
        Fun()
    catch
      Class:Reason:Stacktrace ->
        ?LOG_ERROR(#{
            description => "Failed while executing job",
            class => Class,
            reason => Reason,
            stacktrace => Stacktrace
        })
    end,
    safe_execute(Funs);

safe_execute([]) ->
    ok.







