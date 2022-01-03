%% =============================================================================
%%  bondy_router_relay.erl - forwards INVOCATION (their RESULT or
%%  ERROR), INTERRUPT and PUBLISH messages between WAMP clients connected to
%%  different Bondy peers (nodes).
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
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
%% @doc A gen_server that forwards INVOCATION (their RESULT or ERROR), INTERRUPT
%% and EVENT messages between WAMP clients connected to different Bondy peers
%% (nodes).
%%
%% ```
%% +-------------------------+                    +-------------------------+
%% |         node_1          |                    |         node_2          |
%% |                         |                    |                         |
%% |                         |                    |                         |
%% | +---------------------+ |    cast_message    | +---------------------+ |
%% | |partisan_peer_service| |                    | |partisan_peer_service| |
%% | |      _manager       |<+--------------------+>|      _manager       | |
%% | |                     | |                    | |                     | |
%% | +---------------------+ |                    | +---------------------+ |
%% |    ^          |         |                    |         |          ^    |
%% |    |          v         |                    |         v          |    |
%% |    |  +---------------+ |                    | +---------------+  |    |
%% |    |  |  bondy_router | |                    | |  bondy_router |  |    |
%% |    |  |    _relay     | |                    | |    _relay     |  |    |
%% |    |  |               | |                    | |               |  |    |
%% |    |  +---------------+ |                    | +---------------+  |    |
%% |    |          |         |                    |         |          |    |
%% |    |          |         |                    |         |          |    |
%% |    |          |         |                    |         |          |    |
%% |    |          v         |                    |         v          |    |
%% | +---------------------+ |                    | +---------------------+ |
%% | | bondy_router_worker | |                    | | bondy_router_worker | |
%% | |    (router_pool)    | |                    | |    (router_pool)    | |
%% | |                     | |                    | |                     | |
%% | |                     | |                    | |                     | |
%% | |                     | |                    | |                     | |
%% | |                     | |                    | |                     | |
%% | |                     | |                    | |                     | |
%% | |                     | |                    | |                     | |
%% | |                     | |                    | |                     | |
%% | +---------------------+ |                    | +---------------------+ |
%% |         ^    |          |                    |          |   ^          |
%% |         |    |          |                    |          |   |          |
%% |         |    v          |                    |          v   |          |
%% | +---------------------+ |                    | +---------------------+ |
%% | |bondy_wamp_*_handler | |                    | |bondy_wamp_*_handler | |
%% | |                     | |                    | |                     | |
%% | |                     | |                    | |                     | |
%% | +---------------------+ |                    | +---------------------+ |
%% |         ^    |          |                    |          |   ^          |
%% |         |    |          |                    |          |   |          |
%% +---------+----+----------+                    +----------+---+----------+
%%           |    |                                          |   |
%%           |    |                                          |   |
%%      CALL |    | RESULT | ERROR                INVOCATION |   | YIELD
%%           |    |                                          |   |
%%           |    v                                          v   |
%% +-------------------------+                    +-------------------------+
%% |         Caller          |                    |         Callee          |
%% |                         |                    |                         |
%% |                         |                    |                         |
%% +-------------------------+                    +-------------------------+
%% '''
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_router_relay).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").

-record(state, {
}).



%% API
-export([forward/2]).
-export([forward/3]).
-export([ref/1]).
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
-spec start_link() -> {'ok', pid()} | 'ignore' | {'error', term()}.

start_link() ->
    %% bondy_router_relay may receive a huge amount of
    %% messages. Make sure that they are stored off heap to
    %% avoid exessive GCs. This makes messaging slower though.
    SpawnOpts = [
        {spawn_opt, [{message_queue_data, off_heap}]}
    ],
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], SpawnOpts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec forward(Node :: node() | [node()], Msg :: any()) -> ok.

forward(Node, Msg) ->
    forward(Node, Msg, #{}).


%% -----------------------------------------------------------------------------
%% @doc Forwards a wamp message to a peer (cluster node).
%% It returns `ok'.
%%
%% This only works for PUBLISH, ERROR, INTERRUPT, INVOCATION and RESULT WAMP
%% message types. It will fail with an exception if another type is passed
%% as the third argument.
%%
%% @end
%% -----------------------------------------------------------------------------
-spec forward(Node :: node() | [node()], Msg :: any(), Opts :: map()) -> ok.

forward(Node, Msg, Opts) when is_atom(Node) ->
    Manager = bondy_peer_service:manager(),
    Channel = bondy_config:get(wamp_peer_channel, default),
    Manager:cast_message(Node, Channel, ?MODULE, Msg, Opts);

forward(Nodes, Msg, Opts) when is_list(Nodes) ->
    Manager = bondy_peer_service:manager(),
    Channel = bondy_config:get(wamp_peer_channel, default),
    _ = [
        Manager:cast_message(Node, Channel, ?MODULE, Msg, Opts)
        || Node <- Nodes
    ],
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec ref(RealmUri :: uri()) -> bondy_ref:t().

ref(RealmUri) ->
    %% We use our name which we registered using gproc on init/1
    %% By using a registered name we might be able to continue routing messages
    %% after a relay crash (provided it comes back on time).
    bondy_ref:new(relay, RealmUri, ?MODULE).



%% =============================================================================
%% API : GEN_SERVER CALLBACKS
%% =============================================================================



init([]) ->
    true = gproc:reg({n, l, ?MODULE}),
    {ok, #state{}}.


handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State}.


handle_cast({forward, To, Msg, Opts} = M, State) ->
    %% We are receiving a message from peer
    try
        %% This in theory breaks the CALL order guarantee!!!
        %% We either implement causality or we just use hashing over a pool of
        %% workers by {CallerID, CalleeId}
        Job = fun() ->
            try
                bondy_router:forward(Msg, To, Opts)
            catch
                Class:Reason:Stacktrace ->
                    ?LOG_ERROR(#{
                        description => "Error while forwarding peer message",
                        class => Class,
                        reason => Reason,
                        stacktrace => Stacktrace,
                        message => M
                    }),
                    ok
            end
        end,

        case bondy_router_worker:cast(Job) of
            ok ->
                ok;
            {error, overload} ->
                %% TODO send back WAMP message
                %% We should synchronoulsy call bondy_router:forward to get back a WAMP ERROR we can send back to the Opts.from
                ?LOG_DEBUG(#{
                    description => "Error while forwarding peer message",
                    reason => overload
                }),
                ok
        end,

        {noreply, State}

    catch
        Class:Reason:Stacktrace ->
            %% TODO send back WAMP message
            %% TODO publish metaevent
            ?LOG_ERROR(#{
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {noreply, State}
    end;

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

