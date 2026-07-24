%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% @doc Property-based tests for the WAMP per-flow ordering pipeline.
%%
%% A flow is a source/destination session pair `{From, To}' — the unit over
%% which WAMP guarantees ordering: events between a publisher and a
%% subscriber (To = undefined, since relayed publications are
%% node-addressed) and invocations between a caller and a callee. The
%% pipeline preserving that order is:
%%
%%   egress partition_key (bondy_relay:routing_opts/2)
%%     -> one channel connection per flow (FIFO wire)
%%     -> relay mailbox (FIFO)
%%     -> flow pool worker keyed by the pair
%%          (bondy_router_worker:cast/2, FIFO per worker)
%%
%% `prop_pipeline_preserves_flow_order/0' models the multi-queue stages and
%% checks that, for EVERY interleaving of the independent queues, each
%% flow's messages come out in publication/call order, exactly once —
%% across topics, since the flow key deliberately ignores the topic.
%%
%% `prop_flow_pool_fifo/0' runs the real flow pool (real gproc-registered
%% workers, real keyed dispatch) and asserts per-flow FIFO delivery,
%% at-most-once (here: exactly-once, as nothing is shed at these sizes) and
%% termination (every message arrives; nothing waits on a gap).
%% @end
-module(prop_bondy_router_flow).

-include_lib("proper/include/proper.hrl").

%% The connection count of the `wamp_relay' Partisan channel
%% (parallelism => 2 in bondy_config:setup_partisan_channels/0).
-define(WIRE_CONNS, 2).
-define(POOL_SIZE, 4).

%% Properties
-export([
    prop_pipeline_preserves_flow_order/0,
    prop_pipeline_delivers_exactly_once/0,
    prop_partition_key_is_per_flow/0,
    prop_flow_pool_fifo/0
]).

%% =============================================================================
%% Generators
%% =============================================================================

%% A source session ref stand-in. Publishers and callers alike.
from_ref() ->
    ?LET(N, range(1, 5), {ref, source, N}).

%% A destination: undefined for the pub/sub case (node-addressed PUBLISH),
%% a callee ref for the RPC case.
to_ref() ->
    oneof([undefined, ?LET(N, range(1, 3), {ref, dest, N})]).

%% A batch of flows, each with its message count.
flows() ->
    ?LET(
        Pairs,
        non_empty(list({from_ref(), to_ref()})),
        [{Flow, range_size(I)} || {Flow, I} <- enumerate(lists:usort(Pairs))]
    ).

range_size(I) ->
    %% Deterministic but varied sizes, 3..10 messages per flow.
    3 + (I rem 8).

enumerate(L) ->
    lists:zip(L, lists:seq(1, length(L))).

%% An infinite-ish supply of interleaving decisions. Each decision picks
%% which nonempty queue advances next, so every per-queue FIFO order is
%% preserved while the cross-queue order is arbitrary.
schedule() ->
    non_empty(list(range(1, 1000))).

%% =============================================================================
%% Properties: pipeline model
%% =============================================================================

%% Every stage interleaving preserves each flow's internal order.
prop_pipeline_preserves_flow_order() ->
    ?FORALL(
        {Flows, WireSched, PoolSched},
        {flows(), schedule(), schedule()},
        begin
            Delivered = run_pipeline(Flows, WireSched, PoolSched),
            lists:all(
                fun({Flow, _}) ->
                    Seqs = [S || {F, S, _} <- Delivered, F =:= Flow],
                    Seqs =:= lists:sort(Seqs)
                end,
                Flows
            )
        end
    ).

%% No stage duplicates or loses a message (at-most-once holds trivially;
%% with no shedding in the model it is exactly-once), and the pipeline
%% terminates: everything submitted comes out.
prop_pipeline_delivers_exactly_once() ->
    ?FORALL(
        {Flows, WireSched, PoolSched},
        {flows(), schedule(), schedule()},
        begin
            Delivered = run_pipeline(Flows, WireSched, PoolSched),
            Expected = lists:sort(all_messages(Flows)),
            Expected =:= lists:sort(Delivered)
        end
    ).

%% The egress partition key is a pure, deterministic function of the flow
%% pair — equal within a flow across topics and payloads — so a flow can
%% never straddle two wire connections. This is the property the old code
%% violated (no key at all by default, a per-realm key with ack enabled).
prop_partition_key_is_per_flow() ->
    ?FORALL(
        {From, To},
        {from_ref(), to_ref()},
        begin
            ok = ensure_router_config(),
            #{partition_key := K1} = bondy_relay:routing_opts(From, To),
            #{partition_key := K2} = bondy_relay:routing_opts(From, To),
            is_integer(K1) andalso K1 =:= K2
        end
    ).

%% =============================================================================
%% Properties: real flow pool
%% =============================================================================

%% Real workers, real keyed dispatch: per-flow FIFO, exactly-once,
%% termination.
prop_flow_pool_fifo() ->
    ?FORALL(
        {Flows, Sched},
        {flows(), schedule()},
        begin
            ok = ensure_flow_pool(),
            Tag = make_ref(),
            Self = self(),
            Submissions = interleave(flow_queues(Flows), Sched),
            Total = length(Submissions),

            ok = lists:foreach(
                fun({Flow, Seq, _Topic}) ->
                    Job = fun() -> Self ! {Tag, Flow, Seq} end,
                    ok = bondy_router_worker:cast(Flow, Job)
                end,
                Submissions
            ),

            Delivered = gather(Tag, Total, []),

            PerFlowOrdered = lists:all(
                fun({Flow, _}) ->
                    Seqs = [S || {F, S} <- Delivered, F =:= Flow],
                    Seqs =:= lists:sort(Seqs)
                end,
                Flows
            ),
            ExactlyOnce =
                lists:sort(Delivered) =:=
                    lists:sort([{F, S} || {F, S, _} <- Submissions]),

            PerFlowOrdered andalso ExactlyOnce
        end
    ).

%% =============================================================================
%% Helpers: pipeline model
%% =============================================================================

%% All messages of all flows: {Flow, Seq, Topic}. Topics rotate so every
%% flow crosses topics.
all_messages(Flows) ->
    Topics = [<<"com.test.a">>, <<"com.test.b">>, <<"com.test.c">>],
    [
        {Flow, Seq, lists:nth(1 + (Seq rem length(Topics)), Topics)}
     || {Flow, N} <- Flows,
        Seq <- lists:seq(1, N)
    ].

flow_queues(Flows) ->
    [
        [Msg || {F, _, _} = Msg <- all_messages(Flows), F =:= Flow]
     || {Flow, _} <- Flows
    ].

%% Runs the model: egress assignment -> wire (per-connection FIFO,
%% arbitrary interleave) -> ingress assignment -> pool (per-worker FIFO,
%% arbitrary interleave). Assignment functions mirror the shipped ones:
%% the egress key comes from the REAL bondy_relay:routing_opts/2 and the
%% partisan connection choice replicates
%% partisan_peer_connections:do_dispatch_pid/3 for an integer key.
run_pipeline(Flows, WireSched, PoolSched) ->
    ok = ensure_router_config(),

    %% Egress: submission order per flow is the flow queue itself; each
    %% flow is assigned one wire connection via the real partition key.
    ConnOf = fun({From, To}) ->
        #{partition_key := K} = bondy_relay:routing_opts(From, To),
        K rem ?WIRE_CONNS + 1
    end,
    WireQueues = [
        [
            Msg
         || Queue <- flow_queues(Flows),
            {Flow, _, _} = Msg <- Queue,
            ConnOf(Flow) =:= Conn
        ]
     || Conn <- lists:seq(1, ?WIRE_CONNS)
    ],

    %% Wire: connections drain concurrently — any interleaving that
    %% respects per-connection FIFO can arrive at the relay mailbox.
    Arrived = interleave(WireQueues, WireSched),

    %% Ingress: the relay dispatches in mailbox order to the worker owning
    %% the flow key; per-worker queues preserve that order.
    WorkerOf = fun(Flow) -> erlang:phash2(Flow, ?POOL_SIZE) + 1 end,
    PoolQueues = [
        [Msg || {Flow, _, _} = Msg <- Arrived, WorkerOf(Flow) =:= W]
     || W <- lists:seq(1, ?POOL_SIZE)
    ],

    %% Workers execute concurrently — again any FIFO-respecting
    %% interleaving is a possible delivery order.
    interleave(PoolQueues, PoolSched).

%% Merges queues preserving each queue's internal order; `Sched' drives
%% which nonempty queue advances at each step, cycling by position so any
%% message count is served regardless of the schedule's length.
interleave(Queues0, Sched) ->
    interleave(
        [Q || Q <- Queues0, Q =/= []], list_to_tuple(Sched), 0, []
    ).

interleave([], _Sched, _Pos, Acc) ->
    lists:reverse(Acc);
interleave(Queues, Sched, Pos, Acc) ->
    Choice = element(Pos rem tuple_size(Sched) + 1, Sched),
    N = length(Queues),
    Index = Choice rem N + 1,
    {Before, [[H | T] | After]} = lists:split(Index - 1, Queues),
    Rest =
        case T of
            [] -> Before ++ After;
            _ -> Before ++ [T | After]
        end,
    interleave(Rest, Sched, Pos + 1, [H | Acc]).

%% =============================================================================
%% Helpers: real pool fixture
%% =============================================================================

ensure_router_config() ->
    case persistent_term:get({?MODULE, configured}, false) of
        true ->
            ok;
        false ->
            {ok, _} = application:ensure_all_started(gproc),
            ok = bondy_config:set(
                router, [{forward, #{ack => false, retransmission => false}}]
            ),
            ok = bondy_config:set(
                router_pool,
                [{size, ?POOL_SIZE}, {capacity, 100000}, {type, transient}]
            ),
            persistent_term:put({?MODULE, configured}, true)
    end.

%% Starts the real flow pool supervisor once, owned by a detached holder
%% process so it survives across ?FORALL executions.
ensure_flow_pool() ->
    ok = ensure_router_config(),
    case whereis(bondy_router_flow_sup) of
        undefined ->
            Caller = self(),
            _ = spawn(fun() ->
                case bondy_router_flow_sup:start_link() of
                    {ok, _} ->
                        Caller ! {flow_pool, ready},
                        receive
                            stop -> ok
                        end;
                    {error, {already_started, _}} ->
                        Caller ! {flow_pool, ready}
                end
            end),
            receive
                {flow_pool, ready} -> ok
            after 5000 ->
                error(flow_pool_start_timeout)
            end;
        _ ->
            ok
    end.

gather(_Tag, 0, Acc) ->
    lists:reverse(Acc);
gather(Tag, N, Acc) ->
    receive
        {Tag, Flow, Seq} ->
            gather(Tag, N - 1, [{Flow, Seq} | Acc])
    after 10000 ->
        error({termination_violated, missing, N})
    end.
