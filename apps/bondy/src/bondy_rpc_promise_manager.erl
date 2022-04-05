%% =============================================================================
%%  bondy_rpc_promise_manager.erl -
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

-module(bondy_rpc_promise_manager).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").

-define(DEFAULT_INTERVAL_MSECS, 1000).

-record(state, {
    evict_interval          ::  pos_integer()
}).

%% API
-export([start_link/0]).


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
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init(_) ->
    %% We will trap helper exists
    process_flag(trap_exit, true),

    State = #state{evict_interval = ?DEFAULT_INTERVAL_MSECS},

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
    %% Start a helper per table
    Fun = fun(Promise) ->
        Type = bondy_rpc_promise:type(Promise),
        case Type of
            call ->
                RealmUri = bondy_rpc_promise:realm_uri(Promise),
                CallId = bondy_rpc_promise:call_id(Promise),
                InvocationId = bondy_rpc_promise:invocation_id(Promise),
                Caller = bondy_rpc_promise:caller(Promise),
                Timeout = bondy_rpc_promise:timeout(Promise),
                ProcUri = bondy_rpc_promise:procedure_uri(Promise),

                ?LOG_DEBUG(#{
                    description => "RPC Promise evicted from queue",
                    realm_uri => RealmUri,
                    caller => Caller,
                    call_id => CallId,
                    procedure_uri => ProcUri,
                    invocation_id => InvocationId,
                    timeout => Timeout
                }),

                Mssg = iolist_to_binary(
                    io_lib:format(
                        "The operation could not be completed in time"
                        " (~p milliseconds).",
                        [Timeout]
                    )
                ),

                Error = wamp_message:error(
                    ?CALL,
                    CallId,
                    #{
                        procedure_uri => ProcUri,
                        timeout => Timeout
                    },
                    ?WAMP_TIMEOUT,
                    [Mssg]
                ),

                bondy:send(RealmUri, Caller, Error);

            invocation ->
                %% We only send a timeout message for call promises
                ok
        end
    end,

    Opts = #{
        parallel => true,
        on_evict => Fun
    },
    ok = bondy_rpc_promise:evict_expired(Opts),
    ok = schedule_eviction(State),

    {noreply, State};

handle_info({'DOWN', _, process, _Pid, _Reason}, State) ->
    %% A helper terminated, remove from state and schedule

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
    %% We set this to false during testing.
    case bondy_config:get(rpc_promise_eviction, true) of
        true ->
            Interval = State#state.evict_interval,
            _ = erlang:send_after(Interval, self(), evict),
            ok;
        false ->
            ok
    end.

