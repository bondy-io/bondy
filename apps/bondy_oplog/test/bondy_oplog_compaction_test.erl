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
    %% which is too tight for tests that call `await_apply/1`, which
    %% waits for the applier to drain the WAL
    %% and under whole-suite load that occasionally takes longer than
    %% 5s, racing the eunit watchdog into a `*timed out*` cancellation
    %% even though the substrate is functioning correctly.
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 30, fun compact_with_no_peers_is_no_change/0},
        {timeout, 30, fun compact_after_sync_advances_watermark/0},
        {timeout, 30, fun compaction_truncates_mst/0},
        {timeout, 30, fun watermark_filter_drops_old_remote_events/0},
        {timeout, 30, fun deterministic_watermark_across_replicas/0},
        {timeout, 30, fun idempotent_compact/0}
    ]}.

compact_with_no_peers_is_no_change() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog_test_projection:start_instance(Id),
    ok = append_cells(Id, 1, 5),
    %% No peer state recorded ⇒ no stability frontier ⇒ no compaction.
    ?assertEqual({ok, no_change}, bondy_oplog:compact(Id)),
    ?assertEqual(undefined, bondy_oplog:current_watermark(Id)),
    ?assertEqual(5, bondy_oplog:size(Id)),
    ok = bondy_oplog:stop_instance(Id).

compact_after_sync_advances_watermark() ->
    {A, B} = mk_pair(),
    ok = append_cells(A, 1, 10),
    ok = append_cells(B, 11, 20),
    ok = converge(A, B),
    ?assertMatch(
        {ok, {compacted, _, 20}},
        bondy_oplog:compact(A)
    ),
    ?assertNotEqual(undefined, bondy_oplog:current_watermark(A)),
    ok.

compaction_truncates_mst() ->
    {A, B} = mk_pair(),
    ok = append_cells(A, 1, 5),
    ok = append_cells(B, 6, 10),
    ok = converge(A, B),
    SizeBefore = bondy_oplog:size(A),
    ?assertEqual(10, SizeBefore),
    ?assertMatch({ok, {compacted, _, _}}, bondy_oplog:compact(A)),
    ?assertEqual(0, bondy_oplog:size(A)).

%% After A compacts and B re-sends the same (now-stable) events to A
%% via sync, A's MST should NOT regrow — the watermark filter drops
%% them on receipt and on post-merge re-truncation.
watermark_filter_drops_old_remote_events() ->
    {A, B} = mk_pair(),
    ok = append_cells(A, 1, 5),
    ok = append_cells(B, 6, 10),
    ok = converge(A, B),
    {ok, {compacted, _, _}} = bondy_oplog:compact(A),
    ?assertEqual(0, bondy_oplog:size(A)),
    Cells = bondy_oplog_test_projection:cells(A),
    ?assertEqual(10, length(Cells)),
    %% B has not compacted, so it still has all 10 events.
    %% A pulls from B again; the filter must drop the old events.
    {ok, _} = bondy_oplog:sync(A, B),
    ?assertEqual(0, bondy_oplog:size(A)),
    ?assertEqual(Cells, bondy_oplog_test_projection:cells(A)).

deterministic_watermark_across_replicas() ->
    {A, B} = mk_pair(),
    ok = append_cells(A, 1, 8),
    ok = append_cells(B, 9, 16),
    ok = converge(A, B),
    {ok, {compacted, WA, _}} = bondy_oplog:compact(A),
    {ok, {compacted, WB, _}} = bondy_oplog:compact(B),
    ?assertEqual(WA, WB),
    ?assertEqual(
        bondy_oplog_test_projection:cells(A),
        bondy_oplog_test_projection:cells(B)
    ).

idempotent_compact() ->
    {A, B} = mk_pair(),
    ok = append_cells(A, 1, 4),
    ok = append_cells(B, 5, 8),
    ok = converge(A, B),
    {ok, {compacted, W1, _}} = bondy_oplog:compact(A),
    %% Second compact with no new events ⇒ no_change.
    ?assertEqual({ok, no_change}, bondy_oplog:compact(A)),
    ?assertEqual(W1, bondy_oplog:current_watermark(A)).

%% Helpers

mk_id() ->
    list_to_binary(
        "comp_" ++
            integer_to_list(
                erlang:unique_integer([positive, monotonic])
            )
    ).

%% Two replicas with distinct origins, so the sync layer doesn't reject one as
%% "remote with local origin".
mk_pair() ->
    A = mk_id(),
    B = mk_id(),
    {ok, _} = bondy_oplog_test_projection:start_instance(A, #{
        origin => bondy_oplog_origin:new()
    }),
    {ok, _} = bondy_oplog_test_projection:start_instance(B, #{
        origin => bondy_oplog_origin:new()
    }),
    {A, B}.

append_cells(Id, From, To) ->
    _ = [
        bondy_oplog:append(Id, bondy_oplog_test_projection:cell_op(N))
     || N <- lists:seq(From, To)
    ],
    ok.

%% @private
%% Converges A and B and leaves BOTH with a checkpointed peer root covering the
%% converged state.
%%
%% Two rounds suffice because each session ends with a swap confirmation: the
%% initiator tells the peer it now holds the advertised root, so BOTH sides
%% checkpoint the same root. Without that confirmation each side would hold
%% only what it unilaterally observed, and a third round would be needed for
%% the frontier to catch up.
converge(A, B) ->
    {ok, _} = bondy_oplog:sync(A, B),
    {ok, _} = bondy_oplog:sync(B, A),
    bondy_oplog_peer_state:sync(),
    ok.
