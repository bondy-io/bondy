%% =============================================================================
%%  bondy_registry_partition .erl -
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

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_registry_partition).
-behaviour(gen_server).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_registry.hrl").


-define(SERVER_NAME(Index), {?MODULE, Index}).
-define(REGISTRY_TRIE_KEY(Index), {?SERVER_NAME(Index), trie}).
-define(REGISTRY_REMOTE_IDX_KEY(Index), {?SERVER_NAME(Index), remote_tab}).


-record(state, {
    index               ::  integer(),
    trie                ::  bondy_registry_trie:t(),
    remote_tab          ::  bondy_registry_remote_index:t(),
    start_ts            ::  pos_integer()
}).


-type execute_fun()     ::  fun((bondy_registry_trie:t()) -> execute_ret())
                            | fun((...) -> execute_ret()).
-type execute_ret()     ::  any().


%% API
-export([async_execute/2]).
-export([async_execute/3]).
-export([execute/2]).
-export([execute/3]).
-export([execute/4]).
-export([partitions/0]).
-export([pick/1]).
-export([start_link/1]).
-export([trie/1]).
-export([remote_index/1]).


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



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start_link(Index) ->
    Opts = [{spawn_opt, bondy_config:get([registry, partition_spawn_opts])}],
    ServerName = {via, gproc, bondy_gproc:local_name(?SERVER_NAME(Index))},
    gen_server:start_link(ServerName, ?MODULE, [Index], Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec partitions() -> [pid()].

partitions() ->
    gproc_pool:active_workers(?REGISTRY_POOL).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec pick(Arg :: binary() | nodestring()) -> pid().

pick(Arg) when is_binary(Arg) ->
    gproc_pool:pick_worker(?REGISTRY_POOL, Arg).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec trie(Arg :: integer() | binary()) -> bondy_registry_trie:t() | undefined.

trie(Index) when is_integer(Index) ->
    persistent_term:get(?REGISTRY_TRIE_KEY(Index), undefined);

trie(Uri) when is_binary(Uri) ->
    %% This is the same hashing algorithm used by gproc_pool but using
    %% gproc_pool:pick to determine the Index is 2x slower.
    %% We assume there gproc will not stop using phash2.
    N = bondy_config:get([registry, partitions]),
    Index = erlang:phash2(Uri, N) + 1,
    trie(Index).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remote_index(Arg :: integer() | nodestring()) ->
    bondy_registry_remote_index:t() | undefined.

remote_index(Index) when is_integer(Index) ->
    persistent_term:get(?REGISTRY_REMOTE_IDX_KEY(Index), undefined);

remote_index(Uri) when is_binary(Uri) ->
    %% This is the same hashing algorithm used by gproc_pool but using
    %% gproc_pool:pick to determine the Index is 2x slower.
    %% We assume there gproc will not stop using phash2.
    N = bondy_config:get([registry, partitions]),
    Index = erlang:phash2(Uri, N) + 1,
    remote_index(Index).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec execute(Server :: pid(), Fun :: execute_fun())->
    execute_ret().

execute(Server, Fun) ->
    execute(Server, Fun, []).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec execute(Server :: pid(), Fun :: execute_fun(), Args :: [any()]) ->
    execute_ret().

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
    Timetout :: timeout()) -> execute_ret().

execute(Server, Fun, Args, Timeout) when is_function(Fun, length(Args) + 1) ->
    gen_server:call(Server, {execute, Fun, Args}, Timeout).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec async_execute(Server :: pid(), Fun :: execute_fun()) ->
    execute_ret().

async_execute(Server, Fun) ->
    async_execute(Server, Fun, []).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec async_execute(Server :: pid(), Fun :: execute_fun(), Args :: [any()]) ->
    execute_ret().

async_execute(Server, Fun, Args) ->
    gen_server:cast(Server, {execute, Fun, Args}).



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([Index]) ->
    %% We connect this worker to the pool worker name
    PoolName = ?REGISTRY_POOL,
    WorkerName = ?SERVER_NAME(Index),
    true = gproc_pool:connect_worker(PoolName, WorkerName),

    State = #state{
        index = Index,
        start_ts = erlang:system_time()
    },

    {ok, State, {continue, {init_storage, Index}}}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
handle_continue({init_storage, Index}, State0) ->

    Tab = bondy_registry_remote_index:new(Index),
    Trie = bondy_registry_trie:new(Index),

    %% Store the trie and tab so that concurrent processes can access them
    %% without calling the server
    _ = persistent_term:put(?REGISTRY_TRIE_KEY(Index), Trie),
    _ = persistent_term:put(?REGISTRY_REMOTE_IDX_KEY(Index), Tab),

    %% Also storing it on the state for quicker access when handling a
    %% sequential operation ourselves
    State = State0#state{
        remote_tab = Tab,
        trie = Trie
    },
    {noreply, State}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
handle_call({execute, Fun, []}, _From, State) ->
    Reply =
        try
            Fun(State#state.trie)
        catch
            _:Reason ->
                {error, Reason}
        end,

    {reply, Reply, State};

handle_call({execute, Fun, Args}, _From, State) ->
    Reply =
        try
            erlang:apply(Fun, Args ++ [State#state.trie])
        catch
            _:Reason ->
                {error, Reason}
        end,

    {reply, Reply, State};

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
        Fun(State#state.trie)
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
        erlang:apply(Fun, Args ++ [State#state.trie])
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
    %% The remote_tab and trie ets tables use bondy_table_owner.
    %% We ignore as tables are named.
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


