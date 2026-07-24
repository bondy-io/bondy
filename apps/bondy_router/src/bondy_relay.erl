%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_relay).
-moduledoc """
A gen_server that forwards INVOCATION (their RESULT or ERROR), INTERRUPT
and EVENT messages between WAMP clients connected to different Bondy peers
(nodes).

```
+-------------------------+                    +-------------------------+
|         node_1          |                    |         node_2          |
|                         |                    |                         |
|                         |                    |                         |
| +---------------------+ |    cast_message    | +---------------------+ |
| |partisan_peer_service| |                    | |partisan_peer_service| |
| |      _manager       |<+--------------------+>|      _manager       | |
| |                     | |                    | |                     | |
| +---------------------+ |                    | +---------------------+ |
|    ^          |         |                    |         |          ^    |
|    |          v         |                    |         v          |    |
|    |  +---------------+ |                    | +---------------+  |    |
|    |  |  bondy_router | |                    | |  bondy_router |  |    |
|    |  |    _relay     | |                    | |    _relay     |  |    |
|    |  |               | |                    | |               |  |    |
|    |  +---------------+ |                    | +---------------+  |    |
|    |          |         |                    |         |          |    |
|    |          |         |                    |         |          |    |
|    |          |         |                    |         |          |    |
|    |          v         |                    |         v          |    |
| +---------------------+ |                    | +---------------------+ |
| | bondy_router_worker | |                    | | bondy_router_worker | |
| |     (flow pool)     | |                    | |     (flow pool)     | |
| |                     | |                    | |                     | |
| |                     | |                    | |                     | |
| |                     | |                    | |                     | |
| |                     | |                    | |                     | |
| |                     | |                    | |                     | |
| |                     | |                    | |                     | |
| |                     | |                    | |                     | |
| +---------------------+ |                    | +---------------------+ |
|         ^    |          |                    |          |   ^          |
|         |    |          |                    |          |   |          |
|         |    v          |                    |          v   |          |
| +---------------------+ |                    | +---------------------+ |
| |bondy_wamp_*_handler | |                    | |bondy_wamp_*_handler | |
| |                     | |                    | |                     | |
| |                     | |                    | |                     | |
| +---------------------+ |                    | +---------------------+ |
|         ^    |          |                    |          |   ^          |
|         |    |          |                    |          |   |          |
+---------+----+----------+                    +----------+---+----------+
          |    |                                          |   |
          |    |                                          |   |
     CALL |    | RESULT | ERROR                INVOCATION |   | YIELD
          |    |                                          |   |
          |    v                                          v   |
+-------------------------+                    +-------------------------+
|         Caller          |                    |         Callee          |
|                         |                    |                         |
|                         |                    |                         |
+-------------------------+                    +-------------------------+
```
""".
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").

-record(state, {
    ref :: bondy_ref:t()
}).

%% API
-export([forward/2]).
-export([forward/3]).
-export([routing_opts/2]).
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

-spec start_link() -> {'ok', pid()} | 'ignore' | {'error', term()}.

start_link() ->
    %% bondy_relay may receive a huge amount of
    %% messages. Make sure that they are stored off heap to
    %% avoid exessive GCs. This makes messaging slower though.
    SpawnOpts = [
        {spawn_opt, [{message_queue_data, off_heap}]}
    ],
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], SpawnOpts).

-spec forward(Node :: node() | [node()], Msg :: any()) -> ok.

forward(Node, Msg) ->
    forward(Node, Msg, #{}).

-doc """
Forwards a wamp message to a peer (cluster node).
It returns `ok`.

This only works for PUBLISH, ERROR, INTERRUPT, INVOCATION and RESULT WAMP
message types. It will fail with an exception if another type is passed
as the third argument.
""".
-spec forward(Node :: node() | [node()], Msg :: any(), Opts :: map()) -> ok.

forward(Node, Msg, Opts0) when is_atom(Node) ->
    Channel = bondy_config:get(wamp_peer_channel, undefined),
    Opts = Opts0#{channel => Channel},
    partisan:cast_message(Node, ?MODULE, Msg, Opts);
forward(Nodes, Msg, Opts0) when is_list(Nodes) ->
    Channel = bondy_config:get(wamp_peer_channel, undefined),
    Opts = Opts0#{channel => Channel},
    _ = [
        partisan:cast_message(Node, ?MODULE, Msg, Opts)
     || Node <- Nodes
    ],
    ok.

-doc """
Returns the options to use when forwarding a WAMP message that flows from
source ref `From` to destination ref `To` — the `router.forward` options
plus a `partition_key` derived from the pair.

The partition key pins every message of the same flow to one connection of
the (possibly parallel) `wamp_relay` Partisan channel, so the wire preserves
per-flow order while unrelated flows still spread across connections. WAMP
ordering guarantees are all pairwise between a source and a destination
session — events between a publisher and a subscriber, invocations between
a caller and a callee — so the pair is the finest key that preserves them.

`To` is `undefined` for PUBLISH forwards (they are node-addressed): the key
degrades to per-publisher, which those guarantees still require since the
receiving node mints the EVENTs for all its local subscribers from the
relayed PUBLISH.

The receiving node's ingress uses the same pair to pick a flow pool worker
(see `handle_cast/2`), so a flow is a single ordered pipeline end to end.
""".
-spec routing_opts(
    From :: optional(bondy_ref:t()), To :: optional(bondy_ref:t())
) -> map().

routing_opts(From, To) ->
    Opts = bondy_config:get([router, forward]),
    Opts#{partition_key => erlang:phash2({From, To})}.

%% =============================================================================
%% API : GEN_SERVER CALLBACKS
%% =============================================================================

init([]) ->
    true = bondy_gproc:register(?MODULE),
    {ok, #state{ref = bondy_ref:new(relay)}}.

handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State}.

handle_cast({forward, To, Msg, Opts0} = M, State) ->
    %% We are receiving a message from peer
    try
        Job = fun() ->
            try
                Opts = Opts0#{relayed_by => State#state.ref},
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

        %% We receive the relayed messages of a flow in wire order (the
        %% sender pins each flow to one channel connection — see
        %% routing_opts/2 — and this server's mailbox is FIFO). Dispatching
        %% by the same source/destination pair serialises the flow on one
        %% flow pool worker, preserving that order through delivery, while
        %% different flows keep running concurrently.
        Key = {maps:get(from, Opts0, undefined), To},

        case bondy_router_worker:cast(Key, Job) of
            ok ->
                ok;
            {error, overload} ->
                %% We shed the message: delivery is at-most-once and gaps
                %% are permissible, whereas executing it here (or on another
                %% worker) would overtake the messages already queued for
                %% the same flow.
                %% TODO send back WAMP message
                %% We should synchronoulsy call bondy_router:forward to get back
                %% a WAMP ERROR we can send back to the Opts.from
                ok = bondy_router_worker:report_shed(relay)
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
