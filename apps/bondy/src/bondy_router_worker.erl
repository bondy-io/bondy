%% =============================================================================
%%  bondy_router_worker -
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
-module(bondy_router_worker).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").

-define(POOL_NAME, router_pool).

-record(state, {
    pool_type                   ::  permanent | transient,
    op                          ::  function()
}).


%% API
-export([start_pool/0]).
-export([cast/1]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_info/2]).
-export([handle_continue/2]).
-export([terminate/2]).
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).




%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% Starts a sidejob pool of workers according to the configuration
%% for the entry named 'router_pool'.
%% @end
%% -----------------------------------------------------------------------------
-spec start_pool() -> ok.

start_pool() ->
    case do_start_pool() of
        {ok, _Child} -> ok;
        {ok, _Child, _Info} -> ok;
        {error, already_present} -> ok;
        {error, {already_started, _Child}} -> ok;
        {error, Reason} -> error(Reason)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
cast(Fun) when is_function(Fun, 0) ->
    {_, PoolType} = lists:keyfind(type, 1, bondy_config:get(router_pool)),
    case do_cast(PoolType, router_pool, Fun) of
        ok ->
            ok;
        {ok, _} ->
            ok;
        {error, overload} = Error ->
            Error

    end.



%% =============================================================================
%% API : GEN_SERVER CALLBACKS FOR SIDEJOB WORKER
%% =============================================================================



init([?POOL_NAME]) ->
    %% We've been called by sidejob_worker
    %% We will be called via a a cast (handle_cast/2)
    %% TODO publish metaevent and stats
    {ok, #state{pool_type = permanent}};

init([Fun]) ->
    %% We've been called by sidejob_supervisor
    State = #state{pool_type = transient},
    {ok, State, {continue, {apply, Fun}}}.


handle_continue({apply, Fun}, State) ->
    %% We apply and terminate as this is a transient worker.
    _ = Fun(),
    {stop, normal, State}.


handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State}.


handle_cast(Fun, State) when is_function(Fun, 0) ->
    try
        _ = Fun(),
        {noreply, State}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {noreply, State}
    after
        %% We cleanup, liberating the Fun from having to try..catch and do it
        bondy:unset_process_metadata()
    end;

handle_cast(Event, State) ->
    ?LOG_DEBUG(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.


handle_info(Info, State) ->
    ?LOG_DEBUG(#{
        reason => unsupported_event,
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



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Actually starts a sidejob pool based on system configuration.
%% @end
%% -----------------------------------------------------------------------------
do_start_pool() ->
    Opts = bondy_config:get(router_pool),
    {_, Size} = lists:keyfind(size, 1, Opts),
    {_, Capacity} = lists:keyfind(capacity, 1, Opts),
    case lists:keyfind(type, 1, Opts) of
        {_, permanent} ->
            sidejob:new_resource(?POOL_NAME, ?MODULE, Capacity, Size);
        {_, transient} ->
            sidejob:new_resource(?POOL_NAME, sidejob_supervisor, Capacity, Size)
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Helper function for {@link async_forward/2}
%% @end
%% -----------------------------------------------------------------------------
do_cast(permanent, PoolName, Fun) ->
    %% We send a request to an existing permanent worker
    %% using bondy_router acting as a sidejob_worker
    case sidejob:cast(PoolName, Fun) of
        ok -> ok;
        overload -> {error, overload}
    end;

do_cast(transient, PoolName, Fun) ->
    Opts = [
        {spawn_opt, [
            {min_heap_size, 1598}
        ]}
    ],
    %% We spawn a transient worker using sidejob_supervisor
    sidejob_supervisor:start_child(
        PoolName,
        gen_server,
        start_link,
        [?MODULE, [Fun], Opts]
    ).