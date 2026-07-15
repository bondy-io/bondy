%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_jepsen_net_monitor).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

%% =============================================================================
%% Public API
%% =============================================================================

-export([start_link/0]).
-export([up_peers/0]).
-export([all_peers/0]).
-export([info/0]).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

-define(SERVER, ?MODULE).
-define(TABLE, ?MODULE).

-record(state, {
    configured    :: [node()],
    reconnect_ms  :: pos_integer(),
    timer_ref     :: undefined | reference()
}).

%% =============================================================================
%% API
%% =============================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec up_peers() -> [node()].
up_peers() ->
    case ets:whereis(?TABLE) of
        undefined ->
            [];
        _ ->
            ets:select(?TABLE, [{{'$1', true}, [], ['$1']}])
    end.

-spec all_peers() -> [node()].
all_peers() ->
    case ets:whereis(?TABLE) of
        undefined ->
            [];
        _ ->
            ets:select(?TABLE, [{{'$1', '_'}, [], ['$1']}])
    end.

-spec info() -> map().
info() ->
    case ets:whereis(?TABLE) of
        undefined ->
            #{configured => [], up => [], down => []};
        _ ->
            Up = ets:select(?TABLE, [{{'$1', true},  [], ['$1']}]),
            Down = ets:select(?TABLE, [{{'$1', false}, [], ['$1']}]),
            #{
                configured => Up ++ Down,
                up         => Up,
                down       => Down
            }
    end.

%% =============================================================================
%% gen_server CALLBACKS
%% =============================================================================

init([]) ->
    process_flag(trap_exit, true),
    %% `read_concurrency` is the right knob — the scheduler tick reads
    %% this table on every iteration; writes happen only when a peer
    %% transitions up/down. We do not use persistent_term here because
    %% the up-set churns under Jepsen's nemesis, and every
    %% persistent_term:put/2 forces a global GC of every process on
    %% the node.
    ?TABLE = ets:new(?TABLE, [
        named_table, public, set, {read_concurrency, true}
    ]),
    Configured = [
        N || N <- application:get_env(bondy_mst_jepsen, peers, []),
             N =/= node()
    ],
    ReconnectMs = application:get_env(
        bondy_mst_jepsen, reconnect_interval_ms, 1_000
    ),
    %% `monitor_nodes/2` accepts a Flag plus an options list. Visibility
    %% defaults to "visible only" only when no list is given; passing a
    %% list of options resets defaults — so we must restate
    %% `{node_type, visible}` even though that's the historical default,
    %% or the subscription silently filters out our connect_node-driven
    %% nodeups.
    ok = net_kernel:monitor_nodes(true, [{node_type, visible},
                                         nodedown_reason]),
    %% Seed the table from the *current* disterl state, not just
    %% "everything down". When this process starts AFTER another
    %% reconnect cycle has already brought peers up (e.g. the OS-mon
    %% / Cowboy / leveled sup take long enough to start that
    %% `kernel`'s autoconnect has handshaked already), the
    %% `monitor_nodes/2` subscription will never see a `nodeup` for
    %% those peers — they were already up. Cross-checking against
    %% `nodes()` at boot closes that race.
    AlreadyUp = nodes(),
    lists:foreach(
        fun(N) ->
            IsUp = lists:member(N, AlreadyUp),
            ets:insert(?TABLE, {N, IsUp})
        end,
        Configured
    ),
    %% Kick the first reconnect cycle immediately so we do not wait a
    %% full tick before trying the configured peers.
    self() ! reconnect_tick,
    {ok, #state{
        configured   = Configured,
        reconnect_ms = ReconnectMs
    }}.

handle_call(_Req, _From, State) ->
    {reply, {error, badcall}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({nodeup, Node}, State) ->
    case lists:member(Node, State#state.configured) of
        true ->
            ?LOG_INFO(#{
                description => "peer up",
                node => node(),
                peer => Node
            }),
            ets:insert(?TABLE, {Node, true});
        false ->
            ok
    end,
    {noreply, State};
handle_info({nodedown, Node, Reason}, State) ->
    case lists:member(Node, State#state.configured) of
        true ->
            ?LOG_INFO(#{
                description => "peer down",
                node => node(),
                peer => Node,
                reason => Reason
            }),
            ets:insert(?TABLE, {Node, false});
        false ->
            ok
    end,
    {noreply, State};
handle_info(reconnect_tick, State) ->
    %% Re-sync the ETS table against `nodes()` on every tick.
    %% `monitor_nodes/2` events are best-effort and can be lost
    %% (subscription race, options filter, controller restart), so we
    %% treat `nodes()` as the source of truth and only treat the
    %% monitor events as a low-latency hint. The cost is one `nodes()`
    %% call per second — trivial.
    Connected = nodes(),
    lists:foreach(
        fun(N) ->
            IsUp = lists:member(N, Connected),
            ets:insert(?TABLE, {N, IsUp}),
            %% If not connected, kick a non-blocking reconnect attempt.
            case IsUp of
                true  -> ok;
                false -> _ = net_kernel:connect_node(N)
            end
        end,
        State#state.configured
    ),
    Ref = erlang:send_after(State#state.reconnect_ms, self(),
                            reconnect_tick),
    {noreply, State#state{timer_ref = Ref}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    _ = catch net_kernel:monitor_nodes(false),
    _ = catch ets:delete(?TABLE),
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

is_up(Node) ->
    case ets:lookup(?TABLE, Node) of
        [{_, true}] -> true;
        _           -> false
    end.
