%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
-module(prop_bondy_oplog_frontier_holes).

-moduledoc """
Properties for the applied-frontier hole machinery, against a reference model.

Two halves, generated differently because they fail differently:

- the DETECTOR (`bondy_oplog_cell_apply:seq_gaps/2`, `detect_prefix_holes/2`) —
  what a fold reports as absent, against a naive enumerate-and-subtract model.
- the EPISODE MACHINE (`bondy_oplog_sync_scheduler:hole_step/4`) — when a
  standing hole becomes an alarm. Every claim worth making about it is over a
  SCHEDULE of observations, not over a state.

These carry the adequacy argument the detector previously got from a mutation
run. `prop_detector_matches_model` quantifies over a space that contains the
prefix-only implementation, so it fails on the first schedule that leaves
anything pending and shrinks to a minimal witness.

Rationale and rulings: `_design/applied_frontier_pending.md` §12.
""".

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(APPLY, bondy_oplog_cell_apply).
-define(SCHED, bondy_oplog_sync_scheduler).
-define(EVENT, [bondy_oplog, applier, prefix_hole]).
%% Small enough that a batch is more likely to straddle a gap than not; the
%% measured rate is in `generators_are_not_vacuous_test/0`.
-define(UNIVERSE, 10).
-define(T, 1000).

-export([prop_seq_gaps_matches_model/0]).
-export([prop_missing_is_the_absent_count/0]).
-export([prop_gaps_are_disjoint_ascending_and_above_the_prefix/0]).
-export([prop_detector_matches_model/0]).
-export([prop_never_raises_twice_without_a_clear/0]).
-export([prop_never_raises_early/0]).
-export([prop_a_standing_hole_ends_alarmed/0]).
-export([prop_a_closed_hole_ends_clear/0]).
-export([prop_the_clock_never_moves_while_an_episode_is_open/0]).
-export([prop_zero_threshold_never_raises/0]).

%% =============================================================================
%% GENERATORS
%% =============================================================================

seqs_gen() ->
    ?LET(L, list(integer(1, ?UNIVERSE)), lists:usort(L)).

%% A schedule of arrivals, not a state: the frontier's exactness result is over
%% schedules (`proofs/isabelle/Frontier_Pending.thy`, `pending_exact`).
arrivals_gen() ->
    list(seqs_gen()).

prefix_gen() ->
    integer(0, ?UNIVERSE).

set_gen() ->
    ?LET(
        L,
        list(
            ?LET(
                A,
                integer(1, ?UNIVERSE),
                oneof([A, ?LET(W, integer(0, 3), {A, A + W})])
            )
        ),
        bondy_interval_set:from_list(L)
    ).

observation_gen() ->
    {oneof([empty, hole]), integer(0, ?T * 2)}.

schedule_gen() ->
    list(observation_gen()).

%% =============================================================================
%% THE DETECTOR
%% =============================================================================

%% Quantifies over sets reaching BELOW the prefix too. One
%% `frontier_and_pending/1` read cannot produce that, but the function must
%% still terminate and claim nothing if a caller ever does.
prop_seq_gaps_matches_model() ->
    ?FORALL(
        {Prefix, Set},
        {prefix_gen(), set_gen()},
        ?APPLY:seq_gaps(Prefix, Set) =:=
            model_gaps(Prefix, bondy_interval_set:to_flat_list(Set))
    ).

prop_missing_is_the_absent_count() ->
    ?FORALL(
        {Prefix, Set},
        {prefix_gen(), set_gen()},
        begin
            Gaps = ?APPLY:seq_gaps(Prefix, Set),
            Points = bondy_interval_set:to_flat_list(Set),
            lists:sum([To - From + 1 || {From, To} <- Gaps]) =:=
                length(model_absent(Prefix, Points))
        end
    ).

prop_gaps_are_disjoint_ascending_and_above_the_prefix() ->
    ?FORALL(
        {Prefix, Set},
        {prefix_gen(), set_gen()},
        begin
            Gaps = ?APPLY:seq_gaps(Prefix, Set),
            lists:all(fun({F, T}) -> F =< T andalso F > Prefix end, Gaps) andalso
                ascending_and_separated(Gaps)
        end
    ).

%% Constrains WHERE the detector reads presence from, not just its arithmetic:
%% it runs against a registry entry built by real `merge_applied/2` calls, so a
%% detector consulting the prefix alone disagrees on any schedule that leaves
%% something pending.
prop_detector_matches_model() ->
    ?FORALL(
        {Arrivals, Batch},
        {arrivals_gen(), seqs_gen()},
        begin
            {Id, Origin} = fresh_origin(),
            _ = [
                ok = bondy_oplog_registry:merge_applied(Id, #{Origin => A})
             || A <- Arrivals
            ],
            {VV, Pending} = bondy_oplog_registry:frontier_and_pending(Id),
            Held = bondy_interval_set:to_flat_list(
                maps:get(Origin, Pending, bondy_interval_set:new())
            ),
            model_gaps(maps:get(Origin, VV, 0), Held ++ Batch) =:=
                detect(Id, Origin, Batch)
        end
    ).

%% =============================================================================
%% THE EPISODE MACHINE
%% =============================================================================

%% `alarm_handler` does not de-duplicate: two raises without an intervening
%% clear leave two entries that one clear does not remove.
prop_never_raises_twice_without_a_clear() ->
    ?FORALL(
        Schedule,
        schedule_gen(),
        no_double_raise(actions(run(Schedule, ?T)))
    ).

%% Checked against the trace, not the state: at every raise, walk back and
%% require an unbroken run of holes spanning more than the threshold.
prop_never_raises_early() ->
    ?FORALL(
        Schedule,
        schedule_gen(),
        begin
            Trace = run(Schedule, ?T),
            lists:all(fun(I) -> raise_is_earned(I, Trace) end, raises(Trace))
        end
    ).

prop_a_standing_hole_ends_alarmed() ->
    ?FORALL(
        Schedule,
        schedule_gen(),
        begin
            Trace = run(Schedule, ?T),
            case trailing_hole_span(Trace) of
                {span, Span} when Span > ?T -> alarmed(final_episode(Trace));
                _ -> true
            end
        end
    ).

%% The episode map and `alarm_handler` must not disagree, so the trace's net
%% alarm state is asserted alongside the episode.
prop_a_closed_hole_ends_clear() ->
    ?FORALL(
        Schedule,
        schedule_gen(),
        begin
            Trace = run(Schedule, ?T),
            case lists:reverse(Trace) of
                [#{shape := empty, episode := Ep} | _] ->
                    Ep =:= healthy andalso net_alarm(actions(Trace)) =:= down;
                _ ->
                    true
            end
        end
    ).

%% The clock is the AGE of the condition, so a hole that changes shape is the
%% same hole.
prop_the_clock_never_moves_while_an_episode_is_open() ->
    ?FORALL(
        Schedule,
        schedule_gen(),
        clock_is_stable(run(Schedule, ?T))
    ).

prop_zero_threshold_never_raises() ->
    ?FORALL(
        Schedule,
        schedule_gen(),
        raises(run(Schedule, 0)) =:= []
    ).

%% =============================================================================
%% NON-VACUITY
%% =============================================================================

%% Sampled, NOT quantified. A distribution claim is not closed under shrinking,
%% so as a property this is self-defeating: PropEr drives `vector(N, Gen)` to N
%% empty samples and "some sample is interesting" fails on the degenerate case.
%% Measured rates on 400 samples: 192 arrival schedules open a hole, 152
%% observation schedules reach a raise; the floors below sit many deviations
%% under those.
generators_are_not_vacuous_test() ->
    Arrivals = sample(fun arrivals_gen/0, 200),
    ?assert(length([A || A <- Arrivals, opens_a_hole(A)]) >= 40),

    Traces = [run(S, ?T) || S <- sample(fun schedule_gen/0, 200)],
    ?assert(length([T || T <- Traces, raises(T) =/= []]) >= 20),
    ?assertEqual(
        [healthy, open, raised],
        lists:usort([episode_tag(I) || T <- Traces, I <- T])
    ),
    ?assertEqual(
        [clear, none, raise],
        lists:usort([A || T <- Traces, A <- actions(T)])
    ).

sample(GenFun, N) ->
    [
        begin
            {ok, V} = proper_gen:pick(GenFun()),
            V
        end
     || _ <- lists:seq(1, N)
    ].

%% =============================================================================
%% REFERENCE MODEL
%% =============================================================================

%% Enumerate the whole range and subtract: O(range) and obviously right, which
%% is what a reference model is for.
model_absent(Prefix, Points) ->
    case lists:usort([S || S <- Points, S > Prefix]) of
        [] ->
            [];
        Present ->
            [
                S
             || S <- lists:seq(Prefix + 1, lists:max(Present)),
                not lists:member(S, Present)
            ]
    end.

model_gaps(Prefix, Points) ->
    group_runs(model_absent(Prefix, Points)).

group_runs([]) -> [];
group_runs([H | T]) -> group_runs(T, H, H).

group_runs([], Lo, Hi) -> [{Lo, Hi}];
group_runs([S | T], Lo, Hi) when S =:= Hi + 1 -> group_runs(T, Lo, S);
group_runs([S | T], Lo, Hi) -> [{Lo, Hi} | group_runs(T, S, S)].

%% =============================================================================
%% THE TRACE
%% =============================================================================

run(Schedule, Threshold) ->
    {_Now, _Ep, Trace} = lists:foldl(
        fun({Shape, Dt}, {Now0, Ep0, Acc}) ->
            Now = Now0 + Dt,
            {Ep, Action} = ?SCHED:hole_step(
                pending(Shape), Ep0, Now, Threshold
            ),
            Item = #{
                now => Now, shape => Shape, episode => Ep, action => Action
            },
            {Now, Ep, [Item | Acc]}
        end,
        {0, undefined, []},
        Schedule
    ),
    lists:reverse(Trace).

pending(empty) -> #{};
pending(hole) -> #{<<"o">> => [2]}.

actions(Trace) -> [maps:get(action, I) || I <- Trace].

raises(Trace) -> [I || I <- Trace, maps:get(action, I) =:= raise].

final_episode([]) -> undefined;
final_episode(Trace) -> maps:get(episode, lists:last(Trace)).

alarmed({_Since, true}) -> true;
alarmed(_) -> false.

episode_tag(#{episode := healthy}) -> healthy;
episode_tag(#{episode := {_, false}}) -> open;
episode_tag(#{episode := {_, true}}) -> raised.

no_double_raise(Actions) ->
    no_double_raise(Actions, false).

no_double_raise([], _) -> true;
no_double_raise([raise | _], true) -> false;
no_double_raise([raise | T], false) -> no_double_raise(T, true);
no_double_raise([clear | T], _) -> no_double_raise(T, false);
no_double_raise([none | T], Up) -> no_double_raise(T, Up).

net_alarm(Actions) ->
    lists:foldl(
        fun
            (raise, _) -> up;
            (clear, _) -> down;
            (none, S) -> S
        end,
        down,
        Actions
    ).

raise_is_earned(Item, Trace) ->
    Upto = lists:takewhile(fun(I) -> I =/= Item end, Trace) ++ [Item],
    case trailing_hole_run(Upto) of
        [] -> false;
        [First | _] -> maps:get(now, Item) - maps:get(now, First) > ?T
    end.

trailing_hole_span(Trace) ->
    case trailing_hole_run(Trace) of
        [] ->
            none;
        [First | _] = Run ->
            {span, maps:get(now, lists:last(Run)) - maps:get(now, First)}
    end.

trailing_hole_run(Trace) ->
    lists:reverse(
        lists:takewhile(
            fun(I) -> maps:get(shape, I) =:= hole end, lists:reverse(Trace)
        )
    ).

clock_is_stable([A, B | T]) ->
    Ok =
        case {maps:get(episode, A), maps:get(episode, B)} of
            {{S1, _}, {S2, _}} -> S1 =:= S2;
            _ -> true
        end,
    Ok andalso clock_is_stable([B | T]);
clock_is_stable(_) ->
    true.

%% =============================================================================
%% HELPERS
%% =============================================================================

%% Mirrors `bondy_oplog_registry:absorb/5` on the model side, to classify a
%% schedule without a registry.
opens_a_hole(Arrivals) ->
    {_Prefix, Set} = lists:foldl(
        fun(Seqs, {P, S}) ->
            absorb(P, lists:foldl(fun add/2, S, [X || X <- Seqs, X > P]))
        end,
        {0, bondy_interval_set:new()},
        Arrivals
    ),
    Set =/= [].

add(Seq, S) -> bondy_interval_set:add_element(Seq, S).

absorb(P, [N | _] = S) when is_integer(N), N =:= P + 1 ->
    absorb(N, bondy_interval_set:subtract(S, [{0, N}]));
absorb(P, [{Min, Max} | _] = S) when Min =:= P + 1 ->
    absorb(Max, bondy_interval_set:subtract(S, [{0, Max}]));
absorb(P, S) ->
    {P, S}.

detect(Id, Origin, Batch) ->
    Ref = make_ref(),
    HandlerId = {?MODULE, Ref},
    Self = self(),
    ok = telemetry:attach(
        HandlerId,
        ?EVENT,
        fun(_E, _Meas, Meta, _Cfg) -> Self ! {Ref, Meta} end,
        []
    ),
    try
        ok = ?APPLY:detect_prefix_holes(Id, #{Origin => Batch}),
        receive
            {Ref, Meta} -> maps:get(gaps, Meta)
        after 0 -> []
        end
    after
        telemetry:detach(HandlerId)
    end.

%% One instance for the module, a fresh ORIGIN per execution: the frontier is
%% pointwise over origins (`FrontierPending_Pending_TwoOrigins.cfg`), so this
%% isolates without paying to start an instance per case.
fresh_origin() ->
    {ensure_started(), bondy_oplog_origin:new()}.

ensure_started() ->
    case persistent_term:get({?MODULE, instance}, undefined) of
        undefined ->
            {ok, _} = application:ensure_all_started(bondy_db),
            ok = bondy_oplog_sync_scheduler:set_dispatch(undefined),
            ok = bondy_oplog_gc_scheduler:set_trigger(undefined),
            Id = <<"prop_frontier_holes">>,
            {ok, _} = bondy_oplog:start_instance(Id),
            persistent_term:put({?MODULE, instance}, Id),
            Id;
        Id ->
            Id
    end.

ascending_and_separated([{_, T1}, {F2, _} = B | T]) ->
    F2 > T1 + 1 andalso ascending_and_separated([B | T]);
ascending_and_separated(_) ->
    true.
