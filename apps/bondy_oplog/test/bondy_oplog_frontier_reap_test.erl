-module(bondy_oplog_frontier_reap_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

%% The frontier is the only structure in the system that reaping moves
%% DOWN, so these pin the two halves that make that safe: the registry
%% primitive removes exactly what it is told and nothing else, and the
%% retirement pass refuses to use it unless every precondition holds.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    Dir = filename:join([
        "/tmp",
        "bondy_oplog_frontier_reap_test_" ++ os:getpid()
    ]),
    _ = file:del_dir_r(Dir),
    ok = application:set_env(
        bondy_oplog, retirement_path, filename:join(Dir, "retired")
    ),
    ok = restart_bans(),
    #{dir => Dir}.

cleanup(#{dir := Dir}) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok = application:unset_env(bondy_oplog, retirement_path),
    _ = file:del_dir_r(Dir),
    ok = restart_bans(),
    ok.

restart_bans() ->
    _ = supervisor:terminate_child(bondy_oplog_sup, bondy_oplog_origin_bans),
    {ok, _} = supervisor:restart_child(
        bondy_oplog_sup, bondy_oplog_origin_bans
    ),
    ok.

frontier_reap_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun reap_frontier_removes_only_named_origins/0,
        fun reap_frontier_is_idempotent/0,
        fun reap_frontier_ignores_unknown_instance/0,
        fun retired_origin_never_re_enters_the_frontier/0,
        fun solo_reaps_no_frontier/0,
        fun get_retired_answers_the_retirement_set/0,
        fun universal_is_the_intersection_of_member_sets/0,
        fun member_pass_reaps_only_retired_origins/0,
        fun unreachable_member_reaps_nothing/0,
        fun unreachable_member_still_learns_from_the_rest/0,
        fun reap_is_atomic_against_a_concurrent_merge/0,
        fun a_stale_frontier_compare_loses_no_origin/0,
        fun retired_set_is_total_without_the_table/0,
        fun retire_dead_refuses_while_an_instance_is_down/0,
        fun retire_dead_retires_the_complement/0
    ]}.

%% LEARNING IS NOT GATED BY THE REAP. The set is grow-only, so a union from
%% the members that DID answer is monotone and cannot be wrong; refusing it
%% because a third member was unreachable stalls propagation cluster-wide on
%% one flaky node. Only the reap needs every member to have agreed.
%%
%% In-VM every "peer" shares this node's ban table, so a genuinely divergent
%% peer set cannot be staged; the union is therefore driven directly, and the
%% gate is covered by `unreachable_member_reaps_nothing/0`.
unreachable_member_still_learns_from_the_rest() ->
    O = <<"reap-partial-learn">>,
    ?assertNot(bondy_oplog_origin_bans:is_retired(O)),
    %% One member answered with O, another was never asked.
    ?assertEqual(
        [O], bondy_oplog_origin_retirement:learn_retirements([[O]])
    ),
    ?assert(bondy_oplog_origin_bans:is_retired(O)),
    %% Idempotent: a second pass learns nothing new from the same answer.
    ?assertEqual(
        [], bondy_oplog_origin_retirement:learn_retirements([[O]])
    ),
    %% ...and an answer from no member at all teaches nothing.
    ?assertEqual([], bondy_oplog_origin_retirement:learn_retirements([])).

%% The reap runs on the retirement worker while merges run on the applier and
%% the instance. A plain read-modify-write would let a merge that read the
%% pre-reap map put the entry back; the compare-and-swap makes one of the two
%% lose and report it.
reap_is_atomic_against_a_concurrent_merge() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    O = <<"reap-cas">>,
    Other = <<"reap-cas-other">>,
    ok = bondy_oplog_registry:merge_frontier(Id, #{O => 4, Other => 1}),
    ok = bondy_oplog_origin_bans:retire(O, decommissioned),
    %% A merge racing the reap must not resurrect the entry: the ceiling in
    %% `merge_frontier/2` drops it from the incoming partial, and the CAS
    %% stops a stale read-modify-write writing the old map back.
    Self = self(),
    spawn(fun() ->
        [
            bondy_oplog_registry:merge_frontier(Id, #{O => 9, Other => N})
         || N <- lists:seq(1, 200)
        ],
        Self ! merged
    end),
    ?assertEqual([O], bondy_oplog_registry:reap_frontier(Id, [O])),
    receive
        merged -> ok
    after 5000 -> error(timeout)
    end,
    Frontier = bondy_oplog_instance:frontier(Id),
    ?assertNot(maps:is_key(O, Frontier)),
    %% The concurrent merges still landed for the unretired origin.
    ?assertEqual(200, maps:get(Other, Frontier, 0)),
    ok = bondy_oplog:stop_instance(Id).

%% THE DIRECTION `reap_is_atomic_against_a_concurrent_merge/0` DOES NOT COVER.
%% That case races merges that change an existing origin's SEQ, which a stale
%% compare catches. This one stages a merge that ADDS an origin — the common
%% case, since a new remote origin's first event adds a key, and
%% `finalize_catalogue_bootstrap/5` adds a whole peer frontier at once from
%% the sync-session process while the applier merges its own batch.
%%
%% A map in a match-spec head is a SUBSET pattern, so a stale head matches a
%% row that has gained an origin and the replace drops it.
%%
%% The interleaving is injected rather than raced: `cas_with_interleaving/3`
%% commits the second writer between the first writer's read and its swap,
%% which is the window the retry loop otherwise hides. Deterministic, and it
%% burns no CPU — a contention-based version of this reproduced the bug but
%% left `bondy_regulator_load_test` sampling a busy node in the shared VM.
a_stale_frontier_compare_loses_no_origin() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    A = <<"cas-stale-a">>,
    B = <<"cas-stale-b">>,
    C = <<"cas-stale-c">>,
    ok = bondy_oplog_registry:merge_frontier(Id, #{A => 1}),
    %% Writer 1 reads `#{A => 1}` and intends to add B. Writer 2 adds C in
    %% between, so writer 1's compare is stale and must lose, re-read, and
    %% reapply — keeping C.
    ok = bondy_oplog_registry:cas_with_interleaving(
        Id,
        fun(Cur) -> Cur#{B => 2} end,
        fun() -> bondy_oplog_registry:merge_frontier(Id, #{C => 3}) end
    ),
    Frontier = bondy_oplog_instance:frontier(Id),
    ?assertEqual(
        #{A => 1, B => 2, C => 3}, maps:with([A, B, C], Frontier)
    ),
    ok = bondy_oplog:stop_instance(Id).

%% The table dies with its gen_server, but `has_retired/0`'s persistent_term
%% would outlive a BRUTAL kill, which skips `terminate/2`. Readers sit on the
%% applier's fold, so they must answer rather than raise — and the answer must
%% be the safe direction: nothing retired, so nothing dropped and nothing
%% reaped until the set is loaded again.
retired_set_is_total_without_the_table() ->
    O = <<"reap-total">>,
    ok = bondy_oplog_origin_bans:retire(O, decommissioned),
    ?assert(bondy_oplog_origin_bans:has_retired()),
    %% Stop it and keep it stopped, so the observation is not a race with
    %% the supervisor.
    ok = supervisor:terminate_child(
        bondy_oplog_sup, bondy_oplog_origin_bans
    ),
    %% Re-assert the flag the brutal-kill path would have left behind.
    ok = persistent_term:put({bondy_oplog_origin_bans, any_retired}, true),
    ?assertEqual(#{}, bondy_oplog_origin_bans:retired_set()),
    ?assertNot(bondy_oplog_origin_bans:is_retired(O)),
    %% The stale flag must not send a caller to a table that is gone.
    ?assertNot(bondy_oplog_origin_bans:has_retired()),
    {ok, _} = supervisor:restart_child(
        bondy_oplog_sup, bondy_oplog_origin_bans
    ),
    %% The retirement is durable, so the restarted server has it back.
    ?assert(bondy_oplog_origin_bans:is_retired(O)),
    ?assert(bondy_oplog_origin_bans:has_retired()).

%% An instance that died without running `terminate/2` leaves a registry row
%% this node can see, and its origin is not advertised — so the complement
%% would call a LIVE origin dead and retiring it would ban a running replica.
retire_dead_refuses_while_an_instance_is_down() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    Pid = bondy_oplog_instance:whereis(Id),
    ?assert(is_pid(Pid)),
    suspend_supervisor(),
    exit(Pid, kill),
    ok = wait_until(
        fun() -> bondy_oplog_registry:down() =/= [] end, 2000
    ),
    ?assertMatch(
        {error, {instances_down, [_ | _]}},
        bondy_oplog_origin_retirement:retire_dead()
    ),
    resume_supervisor(),
    ok = wait_until(
        fun() -> bondy_oplog_registry:down() =:= [] end, 2000
    ),
    ok = bondy_oplog:stop_instance(Id).

%% The operator affordance. An origin carries no node attribution and a
%% decommissioned node cannot be asked which were its, so the complement is
%% the only way to name them.
retire_dead_retires_the_complement() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    Gone = <<"reap-complement">>,
    ok = bondy_oplog_registry:merge_frontier(Id, #{Gone => 8}),
    {ok, Retired} = bondy_oplog_origin_retirement:retire_dead(),
    ?assert(lists:member(Gone, Retired)),
    ?assert(bondy_oplog_origin_bans:is_retired(Gone)),
    %% This node's own origin is claimed, so it is never in the complement.
    [Own] = bondy_oplog_origin_retirement:local_origins(),
    ?assertNot(lists:member(Own, Retired)),
    ?assertNot(bondy_oplog_origin_bans:is_retired(Own)),
    %% Idempotent: nothing new is retired on a second call.
    ?assertEqual({ok, []}, bondy_oplog_origin_retirement:retire_dead()),
    ok = bondy_oplog:stop_instance(Id).

%% The replication verb: a peer's whole view of the grow-only set, answered
%% at NODE level so the instance id only routes the request.
get_retired_answers_the_retirement_set() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    O = <<"reap-verb">>,
    ok = bondy_oplog_origin_bans:retire(O, decommissioned),
    ?assertEqual(
        {ok, bondy_oplog_origin_bans:retired()},
        bondy_oplog_responder:dispatch(Id, get_retired)
    ),
    ?assert(
        lists:member(
            O, element(2, bondy_oplog_responder:dispatch(Id, get_retired))
        )
    ),
    ok = bondy_oplog:stop_instance(Id).

%% THE REAP'S LICENCE. An origin only some members have retired is one the
%% others still expect a deficit signal about, so it is not reapable.
universal_is_the_intersection_of_member_sets() ->
    A = <<"u-a">>,
    B = <<"u-b">>,
    C = <<"u-c">>,
    ?assertEqual([], bondy_oplog_origin_retirement:universal([])),
    ?assertEqual(
        [A, B], bondy_oplog_origin_retirement:universal([[A, B], [B, A]])
    ),
    %% B is retired by both members; A and C by one each.
    ?assertEqual(
        [B], bondy_oplog_origin_retirement:universal([[A, B], [B, C]])
    ),
    ?assertEqual(
        [], bondy_oplog_origin_retirement:universal([[A], [B], [C]])
    ),
    %% A member with an empty set blocks everything.
    ?assertEqual(
        [], bondy_oplog_origin_retirement:universal([[A, B], []])
    ).

%% With every member answering, a retired origin's entry goes and an
%% unretired one stays — the frontier is not a garbage collector, it is a
%% claim, and only a retirement releases it.
member_pass_reaps_only_retired_origins() ->
    Peer = mk_id(),
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Peer),
    {ok, _} = bondy_oplog:start_instance(Id),
    Gone = <<"reap-member-gone">>,
    Live = <<"reap-member-live">>,
    ok = bondy_oplog_registry:merge_frontier(Id, #{Gone => 4, Live => 6}),
    ok = bondy_oplog_origin_bans:retire(Gone, decommissioned),
    #{reaped := Reaped} =
        bondy_oplog_origin_retirement:replicate_and_reap([Peer]),
    ?assert(lists:member(Gone, Reaped)),
    ?assertNot(lists:member(Live, Reaped)),
    Frontier = bondy_oplog_instance:frontier(Id),
    ?assertNot(maps:is_key(Gone, Frontier)),
    ?assertEqual(6, maps:get(Live, Frontier, 0)),
    ok = bondy_oplog:stop_instance(Id),
    ok = bondy_oplog:stop_instance(Peer).

%% FAIL-CLOSED. A member that cannot be asked has not agreed, so nothing is
%% learned and nothing is reaped — the reap turns on ALL members holding the
%% retirement.
unreachable_member_reaps_nothing() ->
    Peer = mk_id(),
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Peer),
    {ok, _} = bondy_oplog:start_instance(Id),
    O = <<"reap-unreachable">>,
    ok = bondy_oplog_registry:merge_frontier(Id, #{O => 3}),
    ok = bondy_oplog_origin_bans:retire(O, decommissioned),
    ?assertEqual(
        #{reaped => [], learned => []},
        bondy_oplog_origin_retirement:replicate_and_reap([
            Peer, <<"never-started">>
        ])
    ),
    ?assertEqual(3, maps:get(O, bondy_oplog_instance:frontier(Id), 0)),
    ok = bondy_oplog:stop_instance(Id),
    ok = bondy_oplog:stop_instance(Peer).

reap_frontier_removes_only_named_origins() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    A = <<"reap-a">>,
    B = <<"reap-b">>,
    ok = bondy_oplog_registry:merge_frontier(Id, #{A => 3, B => 7}),
    ?assertEqual([A], bondy_oplog_registry:reap_frontier(Id, [A])),
    ?assertEqual(
        #{B => 7}, maps:with([A, B], bondy_oplog_instance:frontier(Id))
    ),
    ok = bondy_oplog:stop_instance(Id).

reap_frontier_is_idempotent() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    A = <<"reap-idem">>,
    ok = bondy_oplog_registry:merge_frontier(Id, #{A => 1}),
    ?assertEqual([A], bondy_oplog_registry:reap_frontier(Id, [A])),
    %% Reaping an absent origin reports nothing rather than inventing it.
    ?assertEqual([], bondy_oplog_registry:reap_frontier(Id, [A])),
    ?assertEqual([], bondy_oplog_registry:reap_frontier(Id, [])),
    ok = bondy_oplog:stop_instance(Id).

reap_frontier_ignores_unknown_instance() ->
    ?assertEqual(
        [], bondy_oplog_registry:reap_frontier(<<"no-such-inst">>, [<<"o">>])
    ).

%% THE CEILING. Once an origin is retired its entry must never rise again,
%% or the next round undoes every reap.
retired_origin_never_re_enters_the_frontier() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    O = <<"reap-retired">>,
    ok = bondy_oplog_registry:merge_frontier(Id, #{O => 5}),
    ?assertEqual(5, maps:get(O, bondy_oplog_instance:frontier(Id), 0)),
    ok = bondy_oplog_origin_bans:retire(O, decommissioned),
    ?assertEqual([O], bondy_oplog_registry:reap_frontier(Id, [O])),
    %% A peer still advertising the origin must not re-add it.
    ok = bondy_oplog_registry:merge_frontier(Id, #{O => 9}),
    ?assertEqual(
        false, maps:is_key(O, bondy_oplog_instance:frontier(Id))
    ),
    ok = bondy_oplog:stop_instance(Id).

%% Solitude licenses nothing for the frontier: a one-node cluster that
%% grows again meets a peer still advertising the entry.
solo_reaps_no_frontier() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    O = <<"reap-solo">>,
    ok = bondy_oplog_registry:merge_frontier(Id, #{O => 2}),
    ok = bondy_oplog_origin_bans:retire(O, decommissioned),
    {ok, Report} = bondy_oplog_origin_retirement:run([]),
    ?assertEqual([], maps:get(frontiers_reaped, Report)),
    ?assertEqual(2, maps:get(O, bondy_oplog_instance:frontier(Id), 0)),
    ok = bondy_oplog:stop_instance(Id).

%% Keeps the per-instance subtree from restarting so a killed instance stays
%% down long enough to observe. `sys:suspend/1` on the dynamic supervisor
%% defers its `'EXIT'` handling, not the instance's death.
suspend_supervisor() ->
    ok = sys:suspend(bondy_oplog_instance_dyn_sup).

resume_supervisor() ->
    ok = sys:resume(bondy_oplog_instance_dyn_sup).

wait_until(_F, T) when T =< 0 -> error(timeout);
wait_until(F, T) ->
    case F() of
        true ->
            ok;
        false ->
            timer:sleep(20),
            wait_until(F, T - 20)
    end.

mk_id() ->
    list_to_binary(
        "fr_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).
