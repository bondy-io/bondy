%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% PropEr properties for the gap-tolerant mem-WAL reader
%% (`bondy_oplog_wal_mem_reader`). The lock-free `append_local/2` reserves a
%% dense `Seq` and then inserts, so a concurrent reader can momentarily see a
%% `Seq` gap (a later reservation inserted before an earlier one). The reader's
%% load-bearing invariant is that it reads the CONTIGUOUS PREFIX and STOPS at the
%% first gap — never skipping it — so every event is delivered exactly once, in
%% Seq order, no matter the insertion schedule.
%%
%% These properties drive the real reader (`open_over/4` + `next/1`) over a
%% hand-built ETS table + atomics, feeding events in an ADVERSARIAL order (any
%% permutation) and asserting exactly-once/in-order/complete delivery. This is
%% the model the happy-path concurrency stress test cannot pin: that NO insertion
%% order can make the reader skip a gap.
-module(bondy_oplog_wal_mem_reader_proper_test).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%% Mirror of the `?A_*` atomics slots in `bondy_oplog_wal_mem`. Coupled by
%% contract; kept here so the test can set `committed` without the gen_server.
-define(A_RESERVED, 1).
-define(A_COMMITTED, 2).

-export([prop_contiguous_exactly_once/0]).
-export([prop_gc_prefix_is_skipped/0]).

-define(NUMTESTS, 200).

%% =============================================================================
%% EUnit wrapper — runs the properties in the standard test gate (the default
%% `rebar3 proper` provider only auto-discovers `prop_*`-named modules).
%% =============================================================================

properties_test_() ->
    {timeout, 120, fun() ->
        Opts = [{to_file, user}, {numtests, ?NUMTESTS}],
        lists:foreach(
            fun(Prop) -> ?assert(proper:quickcheck(Prop, Opts)) end,
            [
                prop_contiguous_exactly_once(),
                prop_gc_prefix_is_skipped()
            ]
        )
    end}.

%% =============================================================================
%% Properties
%% =============================================================================

%% Fed events with Seqs `1..N` in ANY order, one at a time, draining the reader
%% after each insert, the reader delivers exactly `[1..N]` — in order, once each,
%% never skipping a gap. A skip would drop a Seq inserted late (its slot already
%% passed), so the final list would be missing it and the property fails.
prop_contiguous_exactly_once() ->
    ?FORALL(
        Order,
        insert_order(),
        begin
            N = length(Order),
            {Tab, ARef} = fresh_view(),
            View = view(Tab, ARef),
            Iter0 = bondy_oplog_wal_mem_reader:open_over(
                undefined, View, beginning, []
            ),
            Delivered = feed(Tab, Iter0, Order),
            ets:delete(Tab),
            equals(seqs(Delivered), lists:seq(1, N))
        end
    ).

%% A reader that opens behind the GC watermark (`beginning`, cursor `0`, while
%% `committed = C`) must jump forward over the GC'd prefix `1..C` and deliver
%% only the live suffix — not stall on the absent `Seq 1`.
prop_gc_prefix_is_skipped() ->
    ?FORALL(
        {C, Order},
        gc_scenario(),
        begin
            M = length(Order),
            {Tab, ARef} = fresh_view(),
            atomics:put(ARef, ?A_COMMITTED, C),
            View = view(Tab, ARef),
            Iter0 = bondy_oplog_wal_mem_reader:open_over(
                undefined, View, beginning, []
            ),
            %% Seqs 1..C are absent (GC'd); the live events are C+1..C+M.
            Delivered = feed(Tab, Iter0, [S + C || S <- Order]),
            ets:delete(Tab),
            equals(seqs(Delivered), lists:seq(C + 1, C + M))
        end
    ).

%% =============================================================================
%% Generators
%% =============================================================================

insert_order() ->
    ?LET(N, choose(1, 40), permutation(lists:seq(1, N))).

gc_scenario() ->
    ?LET(
        {C, M},
        {choose(1, 20), choose(1, 30)},
        {C, permutation(lists:seq(1, M))}
    ).

%% A uniform random permutation of a concrete list: repeatedly pick a remaining
%% element. (PropEr has no built-in permutation generator.)
permutation([]) ->
    [];
permutation(L) ->
    ?LET(
        X,
        elements(L),
        ?LET(
            Rest,
            permutation(L -- [X]),
            [X | Rest]
        )
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

fresh_view() ->
    Tab = ets:new(mem_reader_prop, [ordered_set, public]),
    ARef = atomics:new(3, [{signed, false}]),
    {Tab, ARef}.

view(Tab, ARef) ->
    #{tab => Tab, mem_seg => 0, atomics => ARef}.

%% Insert each Seq (in the given order), draining the reader to end_of_log after
%% each insert. Returns the events delivered, in delivery order.
feed(Tab, Iter, Order) ->
    {Acc, _Iter} = lists:foldl(
        fun(Seq, {Delivered, It}) ->
            true = ets:insert(Tab, {Seq, {ev, Seq}}),
            {Batch, It1} = drain(It, []),
            {Delivered ++ Batch, It1}
        end,
        {[], Iter},
        Order
    ),
    Acc.

drain(It, Acc) ->
    case bondy_oplog_wal_mem_reader:next(It) of
        end_of_log ->
            {lists:append(lists:reverse(Acc)), It};
        {ok, Batch, _Hlcs, _Pos, It1} ->
            drain(It1, [Batch | Acc])
    end.

seqs(Events) ->
    [S || {ev, S} <- Events].
