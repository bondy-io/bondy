%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% EUnit suite for `bondy_mst_admin` (PR-BACKUP, TaskList #239).
%%
%% Covers:
%% 1. backup/2 on a plain directory tree — manifest written, files copied.
%% 2. verify/1 — happy path; reports missing / corrupted / oversized files.
%% 3. restore/2 — round-trip preserves bytes; refuses non-empty target.
%% 4. backup/2 refuses non-empty target unless allow_nonempty_target.
%% 5. End-to-end with a live oplog instance: append + compact + stop
%%    + backup + wipe + restore + start + verify state matches.
%% =============================================================================
-module(bondy_mst_admin_test).

-include_lib("eunit/include/eunit.hrl").

%% Top-level generator so the telemetry app is started before any
%% test in this module runs. The instance e2e test has its own
%% deeper fixture (it also needs the bondy_mst app).
admin_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(telemetry),
            ok
        end,
        [
            {timeout, 30, fun backup_writes_manifest/0},
            {timeout, 30, fun backup_refuses_nonempty_target/0},
            {timeout, 30, fun backup_allow_nonempty/0},
            {timeout, 30, fun backup_missing_source/0},
            {timeout, 30, fun verify_happy_path/0},
            {timeout, 30, fun verify_detects_missing_file/0},
            {timeout, 30, fun verify_detects_hash_mismatch/0},
            {timeout, 30, fun verify_detects_size_mismatch/0},
            {timeout, 30, fun verify_missing_manifest/0},
            {timeout, 30, fun verify_corrupted_manifest/0},
            {timeout, 30, fun restore_round_trip/0},
            {timeout, 30, fun restore_refuses_nonempty_target/0},
            {timeout, 30, fun backup_emits_telemetry/0}
        ]}.

%% =============================================================================
%% Fixture helpers
%% =============================================================================

mktemp_dir(Tag) ->
    Suffix = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join(
        ["/tmp", "bondy_mst_admin_" ++ Tag ++ "_" ++ Suffix]
    ),
    ok = filelib:ensure_path(Dir),
    Dir.

rmrf(Dir) ->
    _ = file:del_dir_r(Dir),
    ok.

write_file(Path, Bin) ->
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Bin).

populate_tree(Root) ->
    write_file(filename:join(Root, "a.bin"), <<"hello">>),
    write_file(
        filename:join([Root, "sub", "b.bin"]),
        <<"world", 0:8000/unit:8>>
    ),
    write_file(
        filename:join([Root, "sub", "deeper", "c.txt"]),
        <<"deeper">>
    ),
    ok.

%% =============================================================================
%% Plain-tree round trip
%% =============================================================================

backup_writes_manifest() ->
    Src = mktemp_dir("src"),
    Dst = mktemp_dir("dst"),
    try
        populate_tree(Src),
        {ok, Manifest} = bondy_mst_admin:backup(Src, Dst),
        ?assert(filelib:is_regular(filename:join(Dst, "manifest.etf"))),
        ?assertEqual(3, maps:get(file_count, Manifest)),
        Total = maps:get(total_bytes, Manifest),
        ?assert(Total > 8000),
        %% Files are present at the expected relative paths.
        ?assert(filelib:is_regular(filename:join(Dst, "a.bin"))),
        ?assert(filelib:is_regular(filename:join([Dst, "sub", "b.bin"]))),
        ?assert(
            filelib:is_regular(
                filename:join([Dst, "sub", "deeper", "c.txt"])
            )
        )
    after
        rmrf(Src),
        rmrf(Dst)
    end.

backup_refuses_nonempty_target() ->
    Src = mktemp_dir("src"),
    Dst = mktemp_dir("dst"),
    try
        populate_tree(Src),
        ok = file:write_file(filename:join(Dst, "preexisting"), <<"x">>),
        ?assertMatch(
            {error, {target, not_empty, _}},
            bondy_mst_admin:backup(Src, Dst)
        )
    after
        rmrf(Src),
        rmrf(Dst)
    end.

backup_allow_nonempty() ->
    Src = mktemp_dir("src"),
    Dst = mktemp_dir("dst"),
    try
        populate_tree(Src),
        ok = file:write_file(filename:join(Dst, "preexisting"), <<"x">>),
        ?assertMatch(
            {ok, _},
            bondy_mst_admin:backup(Src, Dst, #{allow_nonempty_target => true})
        )
    after
        rmrf(Src),
        rmrf(Dst)
    end.

backup_missing_source() ->
    Src = mktemp_dir("src"),
    Dst = mktemp_dir("dst"),
    rmrf(Src),
    try
        ?assertMatch(
            {error, {source, enoent, _}},
            bondy_mst_admin:backup(Src, Dst)
        )
    after
        rmrf(Dst)
    end.

verify_happy_path() ->
    Src = mktemp_dir("src"),
    Dst = mktemp_dir("dst"),
    try
        populate_tree(Src),
        {ok, _} = bondy_mst_admin:backup(Src, Dst),
        ?assertMatch({ok, _}, bondy_mst_admin:verify(Dst))
    after
        rmrf(Src),
        rmrf(Dst)
    end.

verify_detects_missing_file() ->
    Src = mktemp_dir("src"),
    Dst = mktemp_dir("dst"),
    try
        populate_tree(Src),
        {ok, _} = bondy_mst_admin:backup(Src, Dst),
        ok = file:delete(filename:join(Dst, "a.bin")),
        ?assertMatch(
            {error, {file, <<"a.bin">>, missing}},
            bondy_mst_admin:verify(Dst)
        )
    after
        rmrf(Src),
        rmrf(Dst)
    end.

verify_detects_hash_mismatch() ->
    Src = mktemp_dir("src"),
    Dst = mktemp_dir("dst"),
    try
        populate_tree(Src),
        {ok, _} = bondy_mst_admin:backup(Src, Dst),
        Target = filename:join(Dst, "a.bin"),
        ok = file:write_file(Target, <<"tampered">>),
        %% Same byte size 5 -> 8 actually different. Force matched size.
        ok = file:write_file(Target, <<"HELLO">>),
        ?assertMatch(
            {error, {file, <<"a.bin">>, hash_mismatch}},
            bondy_mst_admin:verify(Dst)
        )
    after
        rmrf(Src),
        rmrf(Dst)
    end.

verify_detects_size_mismatch() ->
    Src = mktemp_dir("src"),
    Dst = mktemp_dir("dst"),
    try
        populate_tree(Src),
        {ok, _} = bondy_mst_admin:backup(Src, Dst),
        ok = file:write_file(filename:join(Dst, "a.bin"), <<"different size">>),
        ?assertMatch(
            {error, {file, <<"a.bin">>, size_mismatch}},
            bondy_mst_admin:verify(Dst)
        )
    after
        rmrf(Src),
        rmrf(Dst)
    end.

verify_missing_manifest() ->
    Dst = mktemp_dir("dst"),
    try
        ?assertMatch(
            {error, {manifest, not_found}},
            bondy_mst_admin:verify(Dst)
        )
    after
        rmrf(Dst)
    end.

verify_corrupted_manifest() ->
    Dst = mktemp_dir("dst"),
    try
        ok = file:write_file(
            filename:join(Dst, "manifest.etf"), <<"not etf">>
        ),
        ?assertMatch(
            {error, {manifest, {corrupted, _}}},
            bondy_mst_admin:verify(Dst)
        )
    after
        rmrf(Dst)
    end.

restore_round_trip() ->
    Src = mktemp_dir("src"),
    Dst = mktemp_dir("dst"),
    Restored = mktemp_dir("restored"),
    try
        populate_tree(Src),
        {ok, _} = bondy_mst_admin:backup(Src, Dst),
        {ok, _} = bondy_mst_admin:restore(Dst, Restored),
        ?assertEqual(
            file:read_file(filename:join(Src, "a.bin")),
            file:read_file(filename:join(Restored, "a.bin"))
        ),
        ?assertEqual(
            file:read_file(filename:join([Src, "sub", "b.bin"])),
            file:read_file(filename:join([Restored, "sub", "b.bin"]))
        ),
        ?assertEqual(
            file:read_file(filename:join([Src, "sub", "deeper", "c.txt"])),
            file:read_file(filename:join([Restored, "sub", "deeper", "c.txt"]))
        )
    after
        rmrf(Src),
        rmrf(Dst),
        rmrf(Restored)
    end.

restore_refuses_nonempty_target() ->
    Src = mktemp_dir("src"),
    Dst = mktemp_dir("dst"),
    Restored = mktemp_dir("restored"),
    try
        populate_tree(Src),
        {ok, _} = bondy_mst_admin:backup(Src, Dst),
        ok = file:write_file(filename:join(Restored, "x"), <<"y">>),
        ?assertMatch(
            {error, {target, not_empty, _}},
            bondy_mst_admin:restore(Dst, Restored)
        )
    after
        rmrf(Src),
        rmrf(Dst),
        rmrf(Restored)
    end.

%% =============================================================================
%% Telemetry: success path emits start + complete; failure emits failed.
%% =============================================================================

backup_emits_telemetry() ->
    Src = mktemp_dir("src"),
    Dst = mktemp_dir("dst"),
    Self = self(),
    Ref = make_ref(),
    HandlerId = {?MODULE, ?FUNCTION_NAME, Ref},
    ok = telemetry:attach_many(
        HandlerId,
        [
            [bondy_mst, admin, backup, start],
            [bondy_mst, admin, backup, complete]
        ],
        fun(E, M, Meta, _) -> Self ! {Ref, E, M, Meta} end,
        []
    ),
    try
        populate_tree(Src),
        {ok, _} = bondy_mst_admin:backup(Src, Dst),
        receive
            {Ref, [bondy_mst, admin, backup, start], _, _} -> ok
        after 1000 -> error(no_start_event)
        end,
        receive
            {Ref, [bondy_mst, admin, backup, complete],
                #{file_count := 3, total_bytes := _, duration_us := _}, _} ->
                ok
        after 1000 -> error(no_complete_event)
        end
    after
        telemetry:detach(HandlerId),
        rmrf(Src),
        rmrf(Dst)
    end.

%% =============================================================================
%% End-to-end with a live oplog instance.
%% =============================================================================

instance_e2e_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(bondy_db),
            bondy_oplog_sync_scheduler:set_dispatch(undefined),
            bondy_oplog_gc_scheduler:set_trigger(undefined),
            ok
        end,
        fun(_) ->
            [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
            ok
        end,
        [{timeout, 120, fun roundtrip_with_live_instance/0}]}.

%% Drive a persistent oplog instance, take a backup after stopping,
%% wipe the storage_path, restore, restart, verify state matches.
roundtrip_with_live_instance() ->
    Suffix = integer_to_list(os:system_time(microsecond)),
    Storage = filename:join(
        <<"/tmp">>,
        list_to_binary("bondy_mst_admin_e2e_" ++ Suffix)
    ),
    Backup = filename:join(
        <<"/tmp">>,
        list_to_binary("bondy_mst_admin_e2e_bk_" ++ Suffix)
    ),
    ok = filelib:ensure_path(Storage),
    Id = list_to_binary("e2e_" ++ Suffix),
    Origin = bondy_oplog_origin:new(),
    Opts = #{
        crdt_module => bondy_oplog_test_counter,
        storage_path => Storage,
        seed => true,
        origin => Origin
    },
    try
        %% Phase 1: populate + compact. After compact, the live MST is
        %% truncated; durable state lives in the WAL + pack-store +
        %% checkpoint, which is what the backup must capture.
        {ok, _} = bondy_oplog:start_instance(Id, Opts),
        [bondy_oplog:append(Id, {inc, 1}) || _ <- lists:seq(1, 5)],
        ok = bondy_oplog:await_apply(Id),
        LocalRoot = bondy_oplog:root_hash(Id),
        bondy_oplog_peer_state:record_sync_complete(
            {peer, e2e_peer}, Id, LocalRoot
        ),
        bondy_oplog_peer_state:sync(),
        {ok, {compacted, W1, _}} = bondy_oplog:compact(Id),
        {ok, W1, S1} = bondy_oplog:compaction_checkpoint(Id),
        ok = bondy_oplog:stop_instance(Id),

        %% Phase 2: back up.
        {ok, Manifest} = bondy_mst_admin:backup(Storage, Backup),
        ?assert(maps:get(file_count, Manifest) >= 1),
        ?assertMatch({ok, _}, bondy_mst_admin:verify(Backup)),

        %% Phase 3: wipe + restore.
        ok = file:del_dir_r(Storage),
        ok = filelib:ensure_path(Storage),
        ?assertMatch(
            {ok, _},
            bondy_mst_admin:restore(
                Backup,
                Storage,
                #{
                    allow_nonempty_target =>
                        true
                }
            )
        ),

        %% Phase 4: bring instance back up + assert state matches.
        %% The compacted-state assertion that proves the backup is
        %% sound is the checkpoint round-trip: same watermark, same
        %% folded CRDT state. The HLC must seed from the restored
        %% watermark too, so further work is on a consistent timeline.
        {ok, _} = bondy_oplog:start_instance(Id, Opts),
        {ok, W2, S2} = bondy_oplog:compaction_checkpoint(Id),
        ?assertEqual(W1, W2),
        ?assertEqual(S1, S2),
        ?assertEqual(W1, bondy_oplog:current_watermark(Id))
    after
        bondy_oplog:stop_instance(Id),
        bondy_oplog_peer_state:forget_peer({peer, e2e_peer}),
        rmrf(Storage),
        rmrf(Backup)
    end.
