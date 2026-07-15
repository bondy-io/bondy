%% Stage 4: anti-entropy sync tests.

-module(bondy_oplog_sync_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    %% Tests want full control: clear both default schedulers.
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup(_) ->
    [
        bondy_oplog:stop_instance(I)
     || I <- bondy_oplog:list_instances()
    ],
    ok.

sync_test_() ->
    %% 30s per-test timeout (eunit default is 5s). Sync tests call
    %% `bondy_oplog:sync/2` which internally awaits the applier's
    %% drain; under whole-suite load that occasionally takes longer
    %% than 5s and races the eunit watchdog.
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 30, fun pull_converges_two_replicas/0},
        {timeout, 30, fun pull_is_idempotent/0},
        {timeout, 30, fun bidirectional_sync_full_convergence/0},
        {timeout, 30, fun asymmetric_loads_converge/0},
        {timeout, 30, fun sync_records_peer_state/0},
        {timeout, 30, fun multi_instance_independence/0},
        {timeout, 30, fun pull_when_peer_empty_is_noop/0},
        {timeout, 30, fun pull_when_local_empty_pulls_everything/0},
        {timeout, 30, fun missing_set_excludes_locally_present_pages/0}
    ]}.

%% A pulls from B; A's tree afterwards must be the union of A's prior
%% tree and B's tree (which equals just B's tree if A was empty before).
pull_converges_two_replicas() ->
    A = mk_inst(),
    B = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(A, originated_opts()),
    {ok, _} = bondy_oplog:start_instance(B, originated_opts()),
    %% Distinct events on each side
    [bondy_oplog:append(A, {a, N}) || N <- lists:seq(1, 10)],
    [bondy_oplog:append(B, {b, N}) || N <- lists:seq(1, 5)],
    BSizeBefore = bondy_oplog:size(B),
    %% A pulls from B
    {ok, _} = bondy_oplog:sync(A, B),
    %% After the pull, A's missing_set against B's CURRENT root must be
    %% empty. Using B's current root (not a pre-captured one) avoids
    %% any TOCTOU window with concurrent schedulers.
    RootBNow = bondy_oplog:root_hash(B),
    ?assertEqual(
        [],
        bondy_oplog_instance:missing_set(A, RootBNow)
    ),
    %% B's logical content is unchanged (count of events).
    ?assertEqual(BSizeBefore, bondy_oplog:size(B)).

pull_is_idempotent() ->
    A = mk_inst(),
    B = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(A, originated_opts()),
    {ok, _} = bondy_oplog:start_instance(B, originated_opts()),
    [bondy_oplog:append(B, {b, N}) || N <- lists:seq(1, 20)],
    {ok, R1} = bondy_oplog:sync(A, B),
    {ok, R2} = bondy_oplog:sync(A, B),
    ?assertEqual(R1, R2).

%% After A pulls from B, B pulls from A. Both should now share root.
bidirectional_sync_full_convergence() ->
    A = mk_inst(),
    B = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(A, originated_opts()),
    {ok, _} = bondy_oplog:start_instance(B, originated_opts()),
    [bondy_oplog:append(A, {a, N}) || N <- lists:seq(1, 10)],
    [bondy_oplog:append(B, {b, N}) || N <- lists:seq(1, 10)],
    {ok, _} = bondy_oplog:sync(A, B),
    {ok, _} = bondy_oplog:sync(B, A),
    ?assertEqual(
        bondy_oplog:root_hash(A),
        bondy_oplog:root_hash(B)
    ),
    %% And total event count is the union (20 events).
    ?assertEqual(20, bondy_oplog:size(A)),
    ?assertEqual(20, bondy_oplog:size(B)).

asymmetric_loads_converge() ->
    A = mk_inst(),
    B = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(A, originated_opts()),
    {ok, _} = bondy_oplog:start_instance(B, originated_opts()),
    [bondy_oplog:append(A, {a, N}) || N <- lists:seq(1, 100)],
    [bondy_oplog:append(B, {b, N}) || N <- lists:seq(1, 200)],
    {ok, _} = bondy_oplog:sync(A, B),
    {ok, _} = bondy_oplog:sync(B, A),
    ?assertEqual(
        bondy_oplog:root_hash(A),
        bondy_oplog:root_hash(B)
    ),
    ?assertEqual(300, bondy_oplog:size(A)),
    ?assertEqual(300, bondy_oplog:size(B)).

sync_records_peer_state() ->
    A = mk_inst(),
    B = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(A, originated_opts()),
    {ok, _} = bondy_oplog:start_instance(B, originated_opts()),
    [bondy_oplog:append(B, {b, N}) || N <- lists:seq(1, 5)],
    {ok, FinalRoot} = bondy_oplog:sync(A, B),
    bondy_oplog_peer_state:sync(),
    ?assertEqual(
        {ok, FinalRoot},
        bondy_oplog_peer_state:get_peer_root_hash(B, A)
    ),
    %% Cross-check: get_known_peers(A) lists B (with default
    %% peer_timeout_ms of 30s, the entry is fresh).
    ?assert(
        lists:member(B, bondy_oplog_peer_state:get_known_peers(A))
    ).

%% Sync of one (logical) instance does not affect another.
multi_instance_independence() ->
    A1 = mk_inst(),
    A2 = mk_inst(),
    B1 = mk_inst(),
    B2 = mk_inst(),
    [
        {ok, _} = bondy_oplog:start_instance(I, originated_opts())
     || I <- [A1, A2, B1, B2]
    ],
    [bondy_oplog:append(B1, {b1, N}) || N <- lists:seq(1, 5)],
    [bondy_oplog:append(B2, {b2, N}) || N <- lists:seq(1, 7)],
    {ok, _} = bondy_oplog:sync(A1, B1),
    %% A2 still empty since we didn't sync it.
    ?assertEqual(0, bondy_oplog:size(A2)),
    ?assertEqual(5, bondy_oplog:size(A1)).

pull_when_peer_empty_is_noop() ->
    A = mk_inst(),
    B = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(A, originated_opts()),
    {ok, _} = bondy_oplog:start_instance(B, originated_opts()),
    [bondy_oplog:append(A, X) || X <- [a, b, c]],
    ok = bondy_oplog:await_apply(A),
    R0 = bondy_oplog:root_hash(A),
    {ok, R1} = bondy_oplog:sync(A, B),
    ?assertEqual(R0, R1),
    ?assertEqual(3, bondy_oplog:size(A)).

pull_when_local_empty_pulls_everything() ->
    A = mk_inst(),
    B = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(A, originated_opts()),
    {ok, _} = bondy_oplog:start_instance(B, originated_opts()),
    [bondy_oplog:append(B, {b, N}) || N <- lists:seq(1, 50)],
    {ok, _} = bondy_oplog:sync(A, B),
    ?assertEqual(50, bondy_oplog:size(A)),
    ?assertEqual(
        bondy_oplog:root_hash(A),
        bondy_oplog:root_hash(B)
    ).

%% After A pulls from B, A's missing_set against B's root is empty.
%% This is the convergence invariant in its sharpest form.
missing_set_excludes_locally_present_pages() ->
    A = mk_inst(),
    B = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(A, originated_opts()),
    {ok, _} = bondy_oplog:start_instance(B, originated_opts()),
    [bondy_oplog:append(B, X) || X <- lists:seq(1, 30)],
    ok = bondy_oplog:await_apply(B),
    RootB = bondy_oplog:root_hash(B),
    %% Before sync, A is missing all of B's pages (root + descendants).
    BeforeMissing = bondy_oplog_instance:missing_set(A, RootB),
    ?assertNotEqual([], BeforeMissing),
    {ok, _} = bondy_oplog:sync(A, B),
    AfterMissing = bondy_oplog_instance:missing_set(A, RootB),
    ?assertEqual([], AfterMissing).

%% Helpers

mk_inst() ->
    list_to_binary(
        "sync_" ++
            integer_to_list(
                erlang:unique_integer([positive, monotonic])
            )
    ).

%% Each instance gets its own Origin so they can mutually replicate
%% without tripping the "remote event with local origin" guard.
originated_opts() ->
    #{origin => bondy_oplog_origin:new()}.
