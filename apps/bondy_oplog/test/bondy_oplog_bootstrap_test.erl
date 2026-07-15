%% Stage 9: bootstrap / snapshot-transfer tests.
%%
%% A fresh replica that bootstraps from a long-running peer should
%% receive the peer's snapshot first, then a small set of post-snapshot
%% live events — instead of pulling the entire append history.

-module(bondy_oplog_bootstrap_test).

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

bootstrap_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun bootstrap_from_peer_with_snapshot/0,
        fun bootstrap_from_peer_without_snapshot/0,
        fun load_snapshot_refuses_to_go_backwards/0,
        fun bootstrap_idempotent/0,
        fun bootstrap_then_query_returns_snapshot_value/0
    ]}.

%% B has compacted to a snapshot, then has live events past the watermark.
%% A bootstraps from B: A's snapshot becomes B's, A's live events become
%% B's post-snapshot events. Final A query == final B query.
bootstrap_from_peer_with_snapshot() ->
    {A, B} = mk_pair(counter_opts()),
    %% Step 1: append a batch and compact on B.
    [bondy_oplog:append(B, {inc, 1}) || _ <- lists:seq(1, 10)],
    %% Drain the applier so root_hash reflects every appended event;
    %% the new write path returns after WAL fsync + overlay insert,
    %% not after the applier has promoted the event to the MST.
    ok = bondy_oplog:await_apply(B),
    LocalRoot = bondy_oplog:root_hash(B),
    bondy_oplog_peer_state:record_sync_complete(
        {peer, dummy_b}, B, LocalRoot
    ),
    bondy_oplog_peer_state:sync(),
    {ok, {compacted, _, 10}} = bondy_oplog:compact(B),
    %% Step 2: more events, NOT compacted.
    [bondy_oplog:append(B, {inc, 5}) || _ <- lists:seq(1, 3)],
    BValue = bondy_oplog:query(B, value),
    %% A starts fresh; bootstrap from B.
    {ok, _} = bondy_oplog:bootstrap(A, B),
    ?assertEqual(BValue, bondy_oplog:query(A, value)),
    %% A's snapshot watermark should equal B's snapshot watermark.
    {ok, WA, _} = bondy_oplog:compaction_checkpoint(A),
    {ok, WB, _} = bondy_oplog:compaction_checkpoint(B),
    ?assertEqual(WA, WB),
    %% A's live MST should only have the 3 post-snapshot events.
    ?assertEqual(3, bondy_oplog:size(A)),
    bondy_oplog_peer_state:forget_peer({peer, dummy_b}),
    ok.

%% Bootstrap when the peer has no snapshot falls back to regular sync.
bootstrap_from_peer_without_snapshot() ->
    {A, B} = mk_pair(counter_opts()),
    [bondy_oplog:append(B, {inc, 1}) || _ <- lists:seq(1, 5)],
    {ok, _} = bondy_oplog:bootstrap(A, B),
    ?assertEqual(
        bondy_oplog:query(B, value),
        bondy_oplog:query(A, value)
    ),
    %% No snapshot was installed.
    ?assertEqual(not_found, bondy_oplog:compaction_checkpoint(A)),
    %% A's MST has the 5 live events.
    ?assertEqual(5, bondy_oplog:size(A)),
    ok.

%% A snapshot whose watermark is `=<` the current local watermark is
%% rejected — going backwards would break monotonicity.
load_snapshot_refuses_to_go_backwards() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, counter_opts()),
    %% Build a small synthetic snapshot.
    SmallWatermark = bondy_oplog_event:key(10, <<"x">>, 1),
    LargeWatermark = bondy_oplog_event:key(20, <<"x">>, 1),
    {ok, _} = bondy_oplog_instance:load_snapshot(
        Id, LargeWatermark, 99
    ),
    ?assertEqual(
        {error, watermark_not_advancing},
        bondy_oplog_instance:load_snapshot(Id, SmallWatermark, 0)
    ),
    %% Equal watermark is also a no-op.
    ?assertEqual(
        {error, watermark_not_advancing},
        bondy_oplog_instance:load_snapshot(Id, LargeWatermark, 99)
    ),
    ok = bondy_oplog:stop_instance(Id).

%% Bootstrapping twice is harmless — the second call sees the watermark
%% is unchanged and proceeds straight to the regular sync (no error).
bootstrap_idempotent() ->
    {A, B} = mk_pair(counter_opts()),
    [bondy_oplog:append(B, {inc, 1}) || _ <- lists:seq(1, 6)],
    LocalRoot = bondy_oplog:root_hash(B),
    bondy_oplog_peer_state:record_sync_complete(
        {peer, dummy_b2}, B, LocalRoot
    ),
    bondy_oplog_peer_state:sync(),
    {ok, {compacted, _, _}} = bondy_oplog:compact(B),
    {ok, _} = bondy_oplog:bootstrap(A, B),
    {ok, _} = bondy_oplog:bootstrap(A, B),
    ?assertEqual(
        bondy_oplog:query(B, value),
        bondy_oplog:query(A, value)
    ),
    bondy_oplog_peer_state:forget_peer({peer, dummy_b2}),
    ok.

%% After bootstrap, a stable query returns the snapshot value (no
%% live-event replay needed).
bootstrap_then_query_returns_snapshot_value() ->
    {A, B} = mk_pair(counter_opts()),
    [bondy_oplog:append(B, {inc, 7}) || _ <- lists:seq(1, 4)],
    %% 4 * 7 = 28
    ok = bondy_oplog:await_apply(B),
    LocalRoot = bondy_oplog:root_hash(B),
    bondy_oplog_peer_state:record_sync_complete(
        {peer, dummy_b3}, B, LocalRoot
    ),
    bondy_oplog_peer_state:sync(),
    {ok, {compacted, _, _}} = bondy_oplog:compact(B),
    {ok, _} = bondy_oplog:bootstrap(A, B),
    ?assertEqual(28, bondy_oplog:query_stable(A, value)),
    bondy_oplog_peer_state:forget_peer({peer, dummy_b3}),
    ok.

%% Helpers

mk_id() ->
    list_to_binary(
        "bs_" ++
            integer_to_list(
                erlang:unique_integer([positive, monotonic])
            )
    ).

counter_opts() ->
    #{
        crdt_module => bondy_oplog_test_counter,
        origin => bondy_oplog_origin:new()
    }.

mk_pair(Opts) ->
    A = mk_id(),
    B = mk_id(),
    OptsA = Opts#{origin => bondy_oplog_origin:new()},
    OptsB = Opts#{origin => bondy_oplog_origin:new()},
    {ok, _} = bondy_oplog:start_instance(A, OptsA),
    {ok, _} = bondy_oplog:start_instance(B, OptsB),
    {A, B}.
