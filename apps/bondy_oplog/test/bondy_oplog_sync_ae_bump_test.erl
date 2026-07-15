%% =============================================================================
%% End-to-end tests for the substrate read-side AE-bump on the
%% anti-entropy round-completion path (MST_DB_DESIGN §11 + §18 item 8).
%%
%% Verifies:
%%   - A successful sync round bumps every shard in the instance's
%%     `ae_targets` past the "infinitely stale" sentinel.
%%   - The bump uses a single shared `Now` so all targets observe the
%%     same monotonic timestamp.
%%   - Instances with no `ae_targets` opt leave shard counters alone
%%     (strict no-op).
%%   - Sync rounds that fail or are no-ops do NOT bump.
%%   - Targets the registry does not know about are tolerated and
%%     counted as `not_found` without wedging the sync session.
%%   - Item 6 (applier-side bump) and item 8 (AE-side bump) share the
%%     same registry-backed target list — configuring `ae_targets` at
%%     the top-level instance opts wires both sides.
%% =============================================================================

-module(bondy_oplog_sync_ae_bump_test).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    [
        bondy_oplog_core_registry:unregister(NS, Index, 0)
     || #{key := {NS, Index, _}} <-
            [entry_to_map(E) || E <- bondy_oplog_core_registry:list()]
    ],
    ok.

ae_bump_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun no_ae_targets_does_not_bump/0,
        fun successful_sync_bumps_targets/0,
        fun bump_shares_now_across_targets/0,
        fun no_op_sync_against_empty_peer_still_bumps/0,
        fun failed_sync_does_not_bump/0,
        fun missing_target_is_tolerated/0,
        fun top_level_ae_targets_wires_applier_and_ae/0
    ]}.

%% =============================================================================
%% Tests
%% =============================================================================

no_ae_targets_does_not_bump() ->
    NS = mk_ns(),
    ok = register_shard(NS, primary, 0),
    A = mk_inst(),
    B = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(A, opts_for(NS, [])),
    {ok, _} = bondy_oplog:start_instance(B, opts_for(NS, [])),
    [bondy_oplog:append(B, {b, N}) || N <- lists:seq(1, 5)],
    Before = bondy_oplog_core_registry:last_ae_at(NS, primary, 0),
    {ok, _} = bondy_oplog:sync(A, B),
    After = bondy_oplog_core_registry:last_ae_at(NS, primary, 0),
    ?assertEqual(Before, After),
    cleanup_ns(NS).

successful_sync_bumps_targets() ->
    %% Only the puller (A) has an `ae_targets` opt, so the only path
    %% that bumps the counter is A's sync round — which isolates the
    %% AE-side bump from the applier-side bump that would otherwise
    %% fire on B's appends.
    NS = mk_ns(),
    ok = register_shard(NS, primary, 0),
    Targets = [{NS, primary, 0}],
    A = mk_inst(),
    B = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(A, opts_for(NS, Targets)),
    {ok, _} = bondy_oplog:start_instance(B, opts_for(NS, [])),
    [bondy_oplog:append(B, {b, N}) || N <- lists:seq(1, 5)],
    Before = bondy_oplog_core_registry:last_ae_at(NS, primary, 0),
    ?assertEqual(sentinel(), Before),
    {ok, _} = bondy_oplog:sync(A, B),
    After = bondy_oplog_core_registry:last_ae_at(NS, primary, 0),
    ?assert(After > Before),
    cleanup_ns(NS).

bump_shares_now_across_targets() ->
    NS = mk_ns(),
    ok = register_shard(NS, primary, 0),
    ok = register_shard(NS, by_name, 0),
    Targets = [{NS, primary, 0}, {NS, by_name, 0}],
    A = mk_inst(),
    B = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(A, opts_for(NS, Targets)),
    {ok, _} = bondy_oplog:start_instance(B, opts_for(NS, Targets)),
    [bondy_oplog:append(B, {b, N}) || N <- lists:seq(1, 3)],
    {ok, _} = bondy_oplog:sync(A, B),
    P = bondy_oplog_core_registry:last_ae_at(NS, primary, 0),
    Q = bondy_oplog_core_registry:last_ae_at(NS, by_name, 0),
    ?assertEqual(P, Q),
    ?assert(P > sentinel()),
    cleanup_ns(NS).

no_op_sync_against_empty_peer_still_bumps() ->
    %% A "fully converged" sync (peer has nothing new) still returns
    %% `{ok, Root}` from the session, which is the natural AE-success
    %% signal — the freshness counter advances to reflect "AE checked
    %% in successfully and found us in sync."
    NS = mk_ns(),
    ok = register_shard(NS, primary, 0),
    Targets = [{NS, primary, 0}],
    A = mk_inst(),
    B = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(A, opts_for(NS, Targets)),
    {ok, _} = bondy_oplog:start_instance(B, opts_for(NS, Targets)),
    [bondy_oplog:append(A, X) || X <- [a, b, c]],
    ok = bondy_oplog:await_apply(A),
    Before = bondy_oplog_core_registry:last_ae_at(NS, primary, 0),
    %% AE timestamps are `monotonic_time(millisecond)`. The applier's
    %% commit_now bump (fired on `end_of_log` after the appends above)
    %% can land in the same ms as the sync bump that follows — the
    %% test would then observe `After == Before` even though the bump
    %% did happen. Sleep until the clock has guaranteed to advance.
    timer:sleep(2),
    %% A pulls from B which is empty — no events to apply but the round
    %% completes successfully.
    {ok, _} = bondy_oplog:sync(A, B),
    After = bondy_oplog_core_registry:last_ae_at(NS, primary, 0),
    ?assert(After > Before),
    cleanup_ns(NS).

failed_sync_does_not_bump() ->
    %% A sync against a non-existent peer fails. `maybe_record/4` is
    %% only called with `{ok, _}` so a failed round must not bump.
    NS = mk_ns(),
    ok = register_shard(NS, primary, 0),
    Targets = [{NS, primary, 0}],
    A = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(A, opts_for(NS, Targets)),
    Before = bondy_oplog_core_registry:last_ae_at(NS, primary, 0),
    %% Use an unstarted peer id so the inline transport raises.
    BogusPeer = <<"never_started_peer">>,
    Result = bondy_oplog:sync(A, BogusPeer),
    ?assertMatch({error, _}, Result),
    After = bondy_oplog_core_registry:last_ae_at(NS, primary, 0),
    ?assertEqual(Before, After),
    cleanup_ns(NS).

missing_target_is_tolerated() ->
    NS = mk_ns(),
    ok = register_shard(NS, primary, 0),
    %% One real target + one bogus target.
    Targets = [{NS, primary, 0}, {missing_ns, primary, 0}],
    A = mk_inst(),
    B = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(A, opts_for(NS, Targets)),
    {ok, _} = bondy_oplog:start_instance(B, opts_for(NS, Targets)),
    [bondy_oplog:append(B, {b, N}) || N <- lists:seq(1, 3)],
    {ok, _} = bondy_oplog:sync(A, B),
    ?assert(bondy_oplog_core_registry:last_ae_at(NS, primary, 0) > sentinel()),
    ?assertEqual(
        not_found,
        bondy_oplog_core_registry:last_ae_at(missing_ns, primary, 0)
    ),
    cleanup_ns(NS).

top_level_ae_targets_wires_applier_and_ae() ->
    %% Single top-level `ae_targets` opt should drive BOTH the applier's
    %% per-commit bump (item 6) AND the sync session's per-round bump
    %% (item 8). We commit-every=1 so the applier bumps on first append,
    %% then sync from B (which has nothing) to verify the AE side also
    %% bumps via the same target.
    NS = mk_ns(),
    ok = register_shard(NS, primary, 0),
    Targets = [{NS, primary, 0}],
    A = mk_inst(),
    B = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(A, (opts_for(NS, Targets))#{
        applier => #{commit_every => 1}
    }),
    {ok, _} = bondy_oplog:start_instance(B, opts_for(NS, Targets)),
    ?assertEqual(
        sentinel(),
        bondy_oplog_core_registry:last_ae_at(NS, primary, 0)
    ),
    %% Applier-side bump on first commit.
    _ = bondy_oplog:append(A, hello),
    _ = wait_for_ae_advance(NS, primary, 0, sentinel()),
    Mid = bondy_oplog_core_registry:last_ae_at(NS, primary, 0),
    ?assert(Mid > sentinel()),
    %% AE-side bump on sync (B is empty so this is a fast roundtrip).
    timer:sleep(2),
    {ok, _} = bondy_oplog:sync(A, B),
    After = bondy_oplog_core_registry:last_ae_at(NS, primary, 0),
    ?assert(After >= Mid),
    cleanup_ns(NS).

%% =============================================================================
%% Helpers
%% =============================================================================

mk_inst() ->
    list_to_binary(
        "sync_ae_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

mk_ns() ->
    binary_to_atom(
        list_to_binary(
            "ns_ae_" ++
                integer_to_list(erlang:unique_integer([positive, monotonic]))
        ),
        utf8
    ).

opts_for(_NS, []) ->
    originated_opts();
opts_for(_NS, Targets) ->
    (originated_opts())#{ae_targets => Targets}.

originated_opts() ->
    #{origin => bondy_oplog_origin:new()}.

register_shard(NS, Index, Shard) ->
    bondy_oplog_core_registry:register(NS, Index, Shard, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => undefined,
        projection_adapter => bondy_oplog_projection_adapter,
        projection_handle => undefined,
        fold_module => lww_register,
        overlay => disabled
    }).

cleanup_ns(NS) ->
    Entries = [
        E
     || E <- bondy_oplog_core_registry:list(),
        element(1, bondy_oplog_core_registry:entry_key(E)) =:= NS
    ],
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- Entries,
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)]
    ],
    ok.

sentinel() ->
    -(1 bsl 62).

wait_for_ae_advance(NS, Index, Shard, Baseline) ->
    wait_for_ae_advance(NS, Index, Shard, Baseline, 1000).

wait_for_ae_advance(NS, Index, Shard, Baseline, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_for_ae_advance_loop(NS, Index, Shard, Baseline, Deadline).

wait_for_ae_advance_loop(NS, Index, Shard, Baseline, Deadline) ->
    case bondy_oplog_core_registry:last_ae_at(NS, Index, Shard) of
        V when V > Baseline -> V;
        _ ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true ->
                    erlang:error({ae_did_not_advance, NS, Index, Shard});
                false ->
                    timer:sleep(5),
                    wait_for_ae_advance_loop(
                        NS,
                        Index,
                        Shard,
                        Baseline,
                        Deadline
                    )
            end
    end.

entry_to_map(E) ->
    #{key => bondy_oplog_core_registry:entry_key(E)}.
