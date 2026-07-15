%% Stage 5: GC / compaction tests.

-module(bondy_oplog_compaction_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    %% Tests want full control: clear the default schedulers.
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup(_) ->
    [
        bondy_oplog:stop_instance(I)
     || I <- bondy_oplog:list_instances()
    ],
    ok.

compaction_test_() ->
    %% Each test gets a 30s per-test timeout. The eunit default is 5s,
    %% which is too tight for tests that call `bondy_oplog:query/2` or
    %% `await_apply/1` — those wait for the applier to drain the WAL
    %% and under whole-suite load that occasionally takes longer than
    %% 5s, racing the eunit watchdog into a `*timed out*` cancellation
    %% even though the substrate is functioning correctly.
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 30, fun no_crdt_module_returns_error/0},
        {timeout, 30, fun compact_with_no_peers_is_no_change/0},
        {timeout, 30, fun compact_after_sync_advances_watermark/0},
        {timeout, 30, fun compaction_truncates_mst/0},
        {timeout, 30, fun snapshot_state_is_correct/0},
        {timeout, 30, fun query_after_compact_returns_consistent_value/0},
        {timeout, 30, fun query_stable_returns_snapshot_only/0},
        {timeout, 30, fun query_hot_includes_live_events/0},
        {timeout, 30, fun watermark_filter_drops_old_remote_events/0},
        {timeout, 30, fun deterministic_snapshot_across_replicas/0},
        {timeout, 30, fun idempotent_compact/0},
        {timeout, 30, fun query_with_no_events_yet/0}
    ]}.

no_crdt_module_returns_error() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    %% No crdt_module configured.
    ?assertEqual(
        {error, no_crdt_module},
        bondy_oplog:compact(Id)
    ),
    ok = bondy_oplog:stop_instance(Id).

compact_with_no_peers_is_no_change() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, counter_opts()),
    [bondy_oplog:append(Id, {inc, 1}) || _ <- lists:seq(1, 5)],
    %% No peer state recorded ⇒ no stability frontier ⇒ no compaction.
    ?assertEqual({ok, no_change}, bondy_oplog:compact(Id)),
    ?assertEqual(undefined, bondy_oplog:current_watermark(Id)),
    ?assertEqual(5, bondy_oplog:size(Id)),
    ok = bondy_oplog:stop_instance(Id).

compact_after_sync_advances_watermark() ->
    {A, B} = mk_pair(counter_opts()),
    [bondy_oplog:append(A, {inc, 1}) || _ <- lists:seq(1, 10)],
    [bondy_oplog:append(B, {inc, 1}) || _ <- lists:seq(1, 10)],
    %% Bidirectional sync converges both to the same root.
    {ok, _} = bondy_oplog:sync(A, B),
    {ok, _} = bondy_oplog:sync(B, A),
    %% Both instances now have peer_state for each other; compaction
    %% can advance to the largest common-prefix key.
    bondy_oplog_peer_state:sync(),
    ?assertMatch(
        {ok, {compacted, _, 20}},
        bondy_oplog:compact(A)
    ),
    ?assertNotEqual(undefined, bondy_oplog:current_watermark(A)),
    ok.

compaction_truncates_mst() ->
    {A, B} = mk_pair(counter_opts()),
    [bondy_oplog:append(A, {inc, 1}) || _ <- lists:seq(1, 5)],
    [bondy_oplog:append(B, {inc, 1}) || _ <- lists:seq(1, 5)],
    {ok, _} = bondy_oplog:sync(A, B),
    {ok, _} = bondy_oplog:sync(B, A),
    bondy_oplog_peer_state:sync(),
    SizeBefore = bondy_oplog:size(A),
    ?assertEqual(10, SizeBefore),
    ?assertMatch({ok, {compacted, _, _}}, bondy_oplog:compact(A)),
    ?assertEqual(0, bondy_oplog:size(A)).

snapshot_state_is_correct() ->
    {A, B} = mk_pair(counter_opts()),
    [bondy_oplog:append(A, {inc, 1}) || _ <- lists:seq(1, 7)],
    [bondy_oplog:append(B, {inc, 1}) || _ <- lists:seq(1, 3)],
    {ok, _} = bondy_oplog:sync(A, B),
    {ok, _} = bondy_oplog:sync(B, A),
    bondy_oplog_peer_state:sync(),
    {ok, {compacted, _, _}} = bondy_oplog:compact(A),
    {ok, _W, S} = bondy_oplog:compaction_checkpoint(A),
    ?assertEqual(10, S).

query_after_compact_returns_consistent_value() ->
    {A, B} = mk_pair(counter_opts()),
    [bondy_oplog:append(A, {inc, 1}) || _ <- lists:seq(1, 5)],
    [bondy_oplog:append(B, {inc, 2}) || _ <- lists:seq(1, 3)],
    {ok, _} = bondy_oplog:sync(A, B),
    {ok, _} = bondy_oplog:sync(B, A),
    bondy_oplog_peer_state:sync(),
    {ok, {compacted, _, _}} = bondy_oplog:compact(A),
    %% 5*1 + 3*2 = 11
    ?assertEqual(11, bondy_oplog:query(A, value)).

query_stable_returns_snapshot_only() ->
    {A, B} = mk_pair(counter_opts()),
    [bondy_oplog:append(A, {inc, 1}) || _ <- lists:seq(1, 4)],
    [bondy_oplog:append(B, {inc, 1}) || _ <- lists:seq(1, 4)],
    {ok, _} = bondy_oplog:sync(A, B),
    {ok, _} = bondy_oplog:sync(B, A),
    bondy_oplog_peer_state:sync(),
    {ok, {compacted, _, _}} = bondy_oplog:compact(A),
    %% Add a *new* event after compaction; stable query should NOT see it.
    bondy_oplog:append(A, {inc, 100}),
    ?assertEqual(8, bondy_oplog:query_stable(A, value)),
    ?assertEqual(108, bondy_oplog:query(A, value)).

query_hot_includes_live_events() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, counter_opts()),
    [bondy_oplog:append(Id, {inc, N}) || N <- lists:seq(1, 5)],
    %% Hot query: no compaction yet, all events are live.
    %% 1+2+3+4+5 = 15
    ?assertEqual(15, bondy_oplog:query(Id, value)),
    ok = bondy_oplog:stop_instance(Id).

%% After A compacts and B re-sends the same (now-stable) events to A
%% via sync, A's MST should NOT regrow — the watermark filter drops
%% them on receipt and on post-merge re-truncation.
watermark_filter_drops_old_remote_events() ->
    {A, B} = mk_pair(counter_opts()),
    [bondy_oplog:append(A, {inc, 1}) || _ <- lists:seq(1, 5)],
    [bondy_oplog:append(B, {inc, 1}) || _ <- lists:seq(1, 5)],
    {ok, _} = bondy_oplog:sync(A, B),
    {ok, _} = bondy_oplog:sync(B, A),
    bondy_oplog_peer_state:sync(),
    {ok, {compacted, _, _}} = bondy_oplog:compact(A),
    ?assertEqual(0, bondy_oplog:size(A)),
    %% B has not compacted, so it still has all 10 events.
    %% A pulls from B again; the filter must drop the old events.
    {ok, _} = bondy_oplog:sync(A, B),
    ?assertEqual(0, bondy_oplog:size(A)),
    %% Snapshot value unchanged.
    {ok, _, S} = bondy_oplog:compaction_checkpoint(A),
    ?assertEqual(10, S).

deterministic_snapshot_across_replicas() ->
    {A, B} = mk_pair(counter_opts()),
    [bondy_oplog:append(A, {inc, 1}) || _ <- lists:seq(1, 8)],
    [bondy_oplog:append(B, {inc, 1}) || _ <- lists:seq(1, 8)],
    {ok, _} = bondy_oplog:sync(A, B),
    {ok, _} = bondy_oplog:sync(B, A),
    bondy_oplog_peer_state:sync(),
    {ok, {compacted, _, _}} = bondy_oplog:compact(A),
    {ok, {compacted, _, _}} = bondy_oplog:compact(B),
    {ok, WA, SA} = bondy_oplog:compaction_checkpoint(A),
    {ok, WB, SB} = bondy_oplog:compaction_checkpoint(B),
    ?assertEqual(WA, WB),
    ?assertEqual(SA, SB).

idempotent_compact() ->
    {A, B} = mk_pair(counter_opts()),
    [bondy_oplog:append(A, {inc, 1}) || _ <- lists:seq(1, 4)],
    [bondy_oplog:append(B, {inc, 1}) || _ <- lists:seq(1, 4)],
    {ok, _} = bondy_oplog:sync(A, B),
    {ok, _} = bondy_oplog:sync(B, A),
    bondy_oplog_peer_state:sync(),
    {ok, {compacted, W1, _}} = bondy_oplog:compact(A),
    %% Second compact with no new events ⇒ no_change.
    ?assertEqual({ok, no_change}, bondy_oplog:compact(A)),
    ?assertEqual(W1, bondy_oplog:current_watermark(A)).

query_with_no_events_yet() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, counter_opts()),
    ?assertEqual(0, bondy_oplog:query(Id, value)),
    ?assertEqual(0, bondy_oplog:query_stable(Id, value)),
    ok = bondy_oplog:stop_instance(Id).

%% Helpers

mk_id() ->
    list_to_binary(
        "comp_" ++
            integer_to_list(
                erlang:unique_integer([positive, monotonic])
            )
    ).

counter_opts() ->
    #{
        crdt_module => bondy_oplog_test_counter,
        origin => bondy_oplog_origin:new()
    }.

%% Two replicas of the same logical CRDT, with distinct origins so the
%% sync layer doesn't reject one as "remote with local origin".
mk_pair(Opts) ->
    A = mk_id(),
    B = mk_id(),
    OptsA = Opts#{origin => bondy_oplog_origin:new()},
    OptsB = Opts#{origin => bondy_oplog_origin:new()},
    {ok, _} = bondy_oplog:start_instance(A, OptsA),
    {ok, _} = bondy_oplog:start_instance(B, OptsB),
    {A, B}.
