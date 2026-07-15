%% Stage 6 stress test: random interleavings of (append, sync) on two
%% replicas, verifying convergence after quiescence.
%%
%% Not a full PropEr property, but exercises the same shape: many
%% randomized executions, each ending with the SEC invariant check.

-module(bondy_oplog_stress_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup(_) ->
    [
        bondy_oplog:stop_instance(I)
     || I <- bondy_oplog:list_instances()
    ],
    ok.

stress_test_() ->
    %% The convergence test drives ~30 random sequences each doing up
    %% to 80 append/sync ops on two replicas. Total work is bounded
    %% but heavy enough that under whole-suite load (registry pressure,
    %% ETS contention, scheduler latency) it can exceed a tight 60s
    %% timeout intermittently. 180s leaves headroom without masking a
    %% real regression.
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 180, fun convergence_under_random_interleaving/0},
        {timeout, 180, fun convergence_with_file_compaction_checkpoint/0},
        {timeout, 180, fun hlc_seeds_from_persisted_watermark/0}
    ]}.

%% Drive 30 random sequences of (append-A, append-B, sync-A-B,
%% sync-B-A); after each sequence, run a final sync round in both
%% directions and assert both replicas have the same root and event
%% count.
convergence_under_random_interleaving() ->
    %% Stable seed for reproducibility:
    rand:seed(exsss, {1, 2, 3}),
    [run_one(N) || N <- lists:seq(1, 30)],
    ok.

run_one(N) ->
    A = list_to_binary("st_a_" ++ integer_to_list(N)),
    B = list_to_binary("st_b_" ++ integer_to_list(N)),
    {ok, _} = bondy_oplog:start_instance(A, originated_opts()),
    {ok, _} = bondy_oplog:start_instance(B, originated_opts()),
    Steps = 30 + rand:uniform(50),
    Counts =
        lists:foldl(
            fun(_, {Ka, Kb}) ->
                case rand:uniform(4) of
                    1 ->
                        bondy_oplog:append(A, {a, Ka}),
                        {Ka + 1, Kb};
                    2 ->
                        bondy_oplog:append(B, {b, Kb}),
                        {Ka, Kb + 1};
                    3 ->
                        {ok, _} = bondy_oplog:sync(A, B),
                        {Ka, Kb};
                    4 ->
                        {ok, _} = bondy_oplog:sync(B, A),
                        {Ka, Kb}
                end
            end,
            {0, 0},
            lists:seq(1, Steps)
        ),
    %% Final convergence round.
    {ok, _} = bondy_oplog:sync(A, B),
    {ok, _} = bondy_oplog:sync(B, A),
    {Ka, Kb} = Counts,
    Total = Ka + Kb,
    ?assertEqual(
        bondy_oplog:root_hash(A),
        bondy_oplog:root_hash(B)
    ),
    ?assertEqual(Total, bondy_oplog:size(A)),
    ?assertEqual(Total, bondy_oplog:size(B)),
    ok = bondy_oplog:stop_instance(A),
    ok = bondy_oplog:stop_instance(B),
    ok.

%% File-backed snapshot store smoke test: compact, stop, restart with
%% same path, verify snapshot survives.
convergence_with_file_compaction_checkpoint() ->
    Suffix = integer_to_list(os:system_time(microsecond)),
    Tmp = filename:join(
        <<"/tmp">>,
        list_to_binary("bondy_mst_stress_" ++ Suffix)
    ),
    ok = filelib:ensure_path(Tmp),
    Id = list_to_binary("file_" ++ Suffix),
    Opts = #{
        crdt_module => bondy_oplog_test_counter,
        compaction_checkpoint => bondy_oplog_compaction_checkpoint_file,
        compaction_checkpoint_opts => #{path => Tmp},
        origin => bondy_oplog_origin:new()
    },
    {ok, _} = bondy_oplog:start_instance(Id, Opts),
    [bondy_oplog:append(Id, {inc, 1}) || _ <- lists:seq(1, 3)],
    ok = bondy_oplog:await_apply(Id),
    %% Force a peer state for compaction (single-replica self-peer).
    LocalRoot = bondy_oplog:root_hash(Id),
    bondy_oplog_peer_state:record_sync_complete(
        {peer, dummy}, Id, LocalRoot
    ),
    bondy_oplog_peer_state:sync(),
    {ok, {compacted, _, EventCount}} = bondy_oplog:compact(Id),
    ?assertEqual(3, EventCount),
    {ok, _, S1} = bondy_oplog:compaction_checkpoint(Id),
    ?assertEqual(3, S1),
    %% Stop the instance and re-open against the same path.
    ok = bondy_oplog:stop_instance(Id),
    {ok, _} = bondy_oplog:start_instance(Id, Opts),
    {ok, _, S2} = bondy_oplog:compaction_checkpoint(Id),
    ?assertEqual(S1, S2),
    %% Watermark is also recovered.
    ?assertNotEqual(
        undefined,
        bondy_oplog:current_watermark(Id)
    ),
    ok = bondy_oplog:stop_instance(Id),
    %% Cleanup.
    bondy_oplog_peer_state:forget_peer({peer, dummy}),
    _ = file:del_dir_r(Tmp),
    ok.

%% After compaction + restart, the HLC must be seeded so a new local
%% append produces a key strictly greater than the prior watermark.
hlc_seeds_from_persisted_watermark() ->
    Suffix = integer_to_list(os:system_time(microsecond)),
    Tmp = filename:join(
        <<"/tmp">>,
        list_to_binary("bondy_oplog_hlc_" ++ Suffix)
    ),
    ok = filelib:ensure_path(Tmp),
    Id = list_to_binary("hlc_" ++ Suffix),
    Origin = bondy_oplog_origin:new(),
    Opts = #{
        crdt_module => bondy_oplog_test_counter,
        compaction_checkpoint => bondy_oplog_compaction_checkpoint_file,
        compaction_checkpoint_opts => #{path => Tmp},
        origin => Origin
    },
    {ok, _} = bondy_oplog:start_instance(Id, Opts),
    [bondy_oplog:append(Id, {inc, 1}) || _ <- lists:seq(1, 5)],
    LocalRoot = bondy_oplog:root_hash(Id),
    bondy_oplog_peer_state:record_sync_complete(
        {peer, dummy_hlc}, Id, LocalRoot
    ),
    bondy_oplog_peer_state:sync(),
    {ok, {compacted, Watermark, _}} = bondy_oplog:compact(Id),
    %% Stop and re-open with same path.
    ok = bondy_oplog:stop_instance(Id),
    {ok, _} = bondy_oplog:start_instance(Id, Opts),
    %% A new local append must produce a key strictly greater than
    %% the watermark — proving HLC was seeded.
    NewKey = bondy_oplog:append(Id, {inc, 100}),
    ?assert(NewKey > Watermark),
    %% Hot query sees the new event on top of the snapshot.
    ?assertEqual(105, bondy_oplog:query(Id, value)),
    ok = bondy_oplog:stop_instance(Id),
    bondy_oplog_peer_state:forget_peer({peer, dummy_hlc}),
    _ = file:del_dir_r(Tmp),
    ok.

%% Helpers

originated_opts() ->
    #{origin => bondy_oplog_origin:new()}.
