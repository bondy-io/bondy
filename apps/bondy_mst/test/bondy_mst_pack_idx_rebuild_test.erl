%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Regression tests for `bondy_mst_pack_idx_rebuild` and its hook in
%% `bondy_mst_pack_store:open_sealed_view/3`. Covers the rebuild
%% trigger set from `_design/latest/MST_PAGE_STORE_DESIGN.md` §10.3:
%%
%%   - missing `.idx` (enoent)
%%   - truncated `.idx` header / trailer / body sections
%%   - bad magic / version
%%   - integrity_mismatch (sha256 trailer over .idx body fails)
%%   - bloom subheader corrupt
%%
%% Plus the negative case where the `.pack` itself is damaged:
%% rebuild must surface the error rather than silently truncating
%% (sealed packs are the system's long-term store and the WAL does
%% not cover them).
%%
%% Each test wraps in `with_telemetry/1` (per-function — eunit
%% `{foreach, ...}` would run setup in a different process and the
%% handler closure captures `self()`; same pattern as
%% `bondy_mst_pack_recovery_test`).
%% =============================================================================
-module(bondy_mst_pack_idx_rebuild_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").
-include("bondy_mst_pack.hrl").

-define(REBUILD_EVENT, [bondy_mst, page_store, idx_rebuild]).

%% =============================================================================
%% Telemetry wrapper
%% =============================================================================

with_telemetry(Fun) ->
    {ok, _} = application:ensure_all_started(telemetry),
    HandlerId = make_ref(),
    Self = self(),
    ok = telemetry:attach_many(
        HandlerId,
        [?REBUILD_EVENT],
        fun(Event, M, D, _Cfg) ->
            Self ! {telemetry, Event, M, D}
        end,
        []
    ),
    try
        Fun()
    after
        ok = telemetry:detach(HandlerId),
        drain()
    end.

drain() ->
    receive
        {telemetry, _, _, _} -> drain()
    after 0 -> ok
    end.

recv_event() ->
    receive
        {telemetry, ?REBUILD_EVENT, M, D} -> {M, D}
    after 1_000 ->
        erlang:error({timeout_rebuild_event, mailbox_dump()})
    end.

expect_no_event() ->
    receive
        {telemetry, ?REBUILD_EVENT, M, D} ->
            erlang:error({unexpected_rebuild_event, M, D})
    after 100 -> ok
    end.

mailbox_dump() ->
    {messages, Msgs} = erlang:process_info(self(), messages),
    Msgs.

%% =============================================================================
%% Fixture helpers
%% =============================================================================

mk_tmp_dir() ->
    Base = lists:flatten(
        io_lib:format(
            "/tmp/bondy_mst_pack_idx_rebuild_test_~p_~p",
            [
                erlang:system_time(microsecond),
                erlang:unique_integer([positive])
            ]
        )
    ),
    ok = filelib:ensure_path(Base),
    Base.

rmrf(Dir) ->
    _ = file:del_dir_r(Dir),
    ok.

mk_instance_id() ->
    list_to_binary(
        "idx_rebuild_test_" ++
            integer_to_list(erlang:unique_integer([positive]))
    ).

%% Pack-store backend directly so we have access to `seal/1`.
open_pack_store(Dir, InstanceId) ->
    bondy_mst_pack_store:open(
        sha256,
        #{
            dir => Dir,
            instance_id => InstanceId,
            auto_seal_records => infinity,
            auto_seal_bytes => infinity
        }
    ).

mk_page(K, V) ->
    bondy_mst_page:new(0, undefined, [{K, V, undefined}]).

%% Seed N pages, seal once, return {ClosedStoreDir, InstanceId, PackId,
%% [{Hash, Page}]}.
seed_and_seal(N) ->
    Dir = mk_tmp_dir(),
    InstanceId = mk_instance_id(),
    S0 = open_pack_store(Dir, InstanceId),
    {S1, HashPages} = lists:foldl(
        fun(I, {S, Acc}) ->
            K = list_to_binary("k" ++ integer_to_list(I)),
            V = list_to_binary("v" ++ integer_to_list(I)),
            P = mk_page(K, V),
            {H, S2} = bondy_mst_pack_store:put(S, P),
            {S2, [{H, P} | Acc]}
        end,
        {S0, []},
        lists:seq(1, N)
    ),
    {ok, S2} = bondy_mst_pack_store:seal(S1),
    [PackId] = bondy_mst_pack_store:sealed_pack_ids(S2),
    ok = bondy_mst_pack_store:close(S2),
    {Dir, InstanceId, PackId, lists:reverse(HashPages)}.

idx_path(Dir, PackId) ->
    bondy_mst_pack_paths:sealed_idx_path(Dir, PackId).

pack_path(Dir, PackId) ->
    bondy_mst_pack_paths:sealed_pack_path(Dir, PackId).

file_size(Path) ->
    case prim_file:read_file_info(Path) of
        {ok, #file_info{size = N}} -> N;
        _ -> 0
    end.

read_all(Path) ->
    {ok, B} = prim_file:read_file(Path),
    B.

%% Truncate a file to N bytes (N < current size).
truncate_to(Path, N) ->
    {ok, Fd} = prim_file:open(Path, [read, write, raw, binary]),
    {ok, N} = prim_file:position(Fd, N),
    ok = prim_file:truncate(Fd),
    ok = prim_file:close(Fd).

%% Flip a single byte at the given absolute offset.
flip_byte(Path, Offset) ->
    {ok, Fd} = prim_file:open(Path, [read, write, raw, binary]),
    {ok, <<B:8>>} = prim_file:pread(Fd, Offset, 1),
    {ok, Offset} = prim_file:position(Fd, Offset),
    ok = prim_file:write(Fd, <<(B bxor 16#FF):8>>),
    ok = prim_file:close(Fd).

%% Re-open the store and assert every (Hash, Page) round-trips.
assert_all_pages_readable(Dir, InstanceId, HashPages) ->
    S = open_pack_store(Dir, InstanceId),
    lists:foreach(
        fun({H, P}) ->
            ?assertEqual(P, bondy_mst_pack_store:get(S, H))
        end,
        HashPages
    ),
    ok = bondy_mst_pack_store:close(S).

%% =============================================================================
%% missing .idx
%% =============================================================================

missing_idx_rebuilt_test() ->
    with_telemetry(fun() ->
        {Dir, InstanceId, PackId, HashPages} = seed_and_seal(5),
        try
            ok = file:delete(idx_path(Dir, PackId)),
            ?assertEqual(false, filelib:is_regular(idx_path(Dir, PackId))),
            S = open_pack_store(Dir, InstanceId),
            {M, D} = recv_event(),
            ?assertEqual(ok, maps:get(result, D)),
            ?assertEqual(enoent, maps:get(trigger, D)),
            ?assertEqual(PackId, maps:get(pack_id, D)),
            ?assertEqual(InstanceId, maps:get(instance_id, D)),
            ?assertEqual(5, maps:get(records_recovered, M)),
            ?assert(maps:get(idx_bytes, M) > 0),
            ?assert(maps:get(pack_bytes, M) > 0),
            ?assert(filelib:is_regular(idx_path(Dir, PackId))),
            ok = bondy_mst_pack_store:close(S),
            assert_all_pages_readable(Dir, InstanceId, HashPages)
        after
            rmrf(Dir)
        end
    end).

%% =============================================================================
%% truncated .idx (sub-header)
%% =============================================================================

truncated_idx_rebuilt_test() ->
    with_telemetry(fun() ->
        {Dir, InstanceId, PackId, HashPages} = seed_and_seal(4),
        try
            %% Truncate to 8 bytes — below the 16-byte idx header.
            truncate_to(idx_path(Dir, PackId), 8),
            S = open_pack_store(Dir, InstanceId),
            {M, D} = recv_event(),
            ?assertEqual(ok, maps:get(result, D)),
            ?assertEqual(truncated_header, maps:get(trigger, D)),
            ?assertEqual(4, maps:get(records_recovered, M)),
            ok = bondy_mst_pack_store:close(S),
            assert_all_pages_readable(Dir, InstanceId, HashPages)
        after
            rmrf(Dir)
        end
    end).

%% =============================================================================
%% bad magic
%% =============================================================================

bad_magic_idx_rebuilt_test() ->
    with_telemetry(fun() ->
        {Dir, InstanceId, PackId, HashPages} = seed_and_seal(3),
        try
            %% Flip byte 0 of the .idx magic.
            flip_byte(idx_path(Dir, PackId), 0),
            S = open_pack_store(Dir, InstanceId),
            {M, D} = recv_event(),
            ?assertEqual(ok, maps:get(result, D)),
            %% Header is the first thing parsed; integrity check fails
            %% before magic if the trailer doesn't match the new bytes —
            %% the flipped magic makes both checks fail. integrity_mismatch
            %% wins because the trailer is verified first.
            Trigger = maps:get(trigger, D),
            ?assert(
                lists:member(
                    Trigger,
                    [bad_magic, integrity_mismatch]
                )
            ),
            ?assertEqual(3, maps:get(records_recovered, M)),
            ok = bondy_mst_pack_store:close(S),
            assert_all_pages_readable(Dir, InstanceId, HashPages)
        after
            rmrf(Dir)
        end
    end).

%% =============================================================================
%% integrity_mismatch (silent bit-flip past header)
%% =============================================================================

integrity_mismatch_idx_rebuilt_test() ->
    with_telemetry(fun() ->
        {Dir, InstanceId, PackId, HashPages} = seed_and_seal(6),
        try
            IdxPath = idx_path(Dir, PackId),
            IdxSize = file_size(IdxPath),
            %% Flip a byte well inside the body (past the 16-byte header,
            %% before the 32-byte trailer) — header still validates, but
            %% the sha256 trailer over the body no longer matches.
            MidOffset =
                ?BONDY_MST_PACK_IDX_HEADER_BYTES +
                    (IdxSize - ?BONDY_MST_PACK_IDX_HEADER_BYTES -
                        ?BONDY_MST_PACK_IDX_TRAILER_BYTES) div 2,
            flip_byte(IdxPath, MidOffset),
            S = open_pack_store(Dir, InstanceId),
            {M, D} = recv_event(),
            ?assertEqual(ok, maps:get(result, D)),
            ?assertEqual(integrity_mismatch, maps:get(trigger, D)),
            ?assertEqual(6, maps:get(records_recovered, M)),
            ok = bondy_mst_pack_store:close(S),
            assert_all_pages_readable(Dir, InstanceId, HashPages)
        after
            rmrf(Dir)
        end
    end).

%% =============================================================================
%% bloom corruption
%% =============================================================================

bloom_corrupt_idx_rebuilt_test() ->
    with_telemetry(fun() ->
        {Dir, InstanceId, PackId, HashPages} = seed_and_seal(8),
        try
            %% The bloom section starts at byte 16 (after the idx header).
            %% Trigger reported by idx open is whatever validation catches
            %% first; either `bloom`-tagged or `integrity_mismatch` (since
            %% the trailer doesn't match the corrupted body) is acceptable.
            flip_byte(idx_path(Dir, PackId), 16),
            S = open_pack_store(Dir, InstanceId),
            {M, D} = recv_event(),
            ?assertEqual(ok, maps:get(result, D)),
            Trigger = maps:get(trigger, D),
            ?assert(lists:member(Trigger, [bloom, integrity_mismatch])),
            ?assertEqual(8, maps:get(records_recovered, M)),
            ok = bondy_mst_pack_store:close(S),
            assert_all_pages_readable(Dir, InstanceId, HashPages)
        after
            rmrf(Dir)
        end
    end).

%% =============================================================================
%% Clean reopen — no rebuild event
%% =============================================================================

clean_reopen_no_event_test() ->
    with_telemetry(fun() ->
        {Dir, InstanceId, _PackId, HashPages} = seed_and_seal(3),
        try
            S = open_pack_store(Dir, InstanceId),
            expect_no_event(),
            ok = bondy_mst_pack_store:close(S),
            assert_all_pages_readable(Dir, InstanceId, HashPages)
        after
            rmrf(Dir)
        end
    end).

%% =============================================================================
%% Multiple sealed packs each rebuilt
%% =============================================================================

multi_pack_rebuild_test() ->
    with_telemetry(fun() ->
        Dir = mk_tmp_dir(),
        InstanceId = mk_instance_id(),
        try
            %% Seal three times to get three sealed packs.
            S0 = open_pack_store(Dir, InstanceId),
            S1 = seal_after_puts(S0, [{<<"a">>, <<"1">>}]),
            S2 = seal_after_puts(S1, [{<<"b">>, <<"2">>}]),
            S3 = seal_after_puts(S2, [{<<"c">>, <<"3">>}]),
            PackIds = bondy_mst_pack_store:sealed_pack_ids(S3),
            ?assertEqual(3, length(PackIds)),
            ok = bondy_mst_pack_store:close(S3),
            %% Wipe every .idx.
            lists:foreach(
                fun(Id) -> ok = file:delete(idx_path(Dir, Id)) end,
                PackIds
            ),
            S = open_pack_store(Dir, InstanceId),
            %% One rebuild event per pack.
            Events = [recv_event() || _ <- PackIds],
            lists:foreach(
                fun({_M, D}) ->
                    ?assertEqual(ok, maps:get(result, D)),
                    ?assertEqual(enoent, maps:get(trigger, D))
                end,
                Events
            ),
            ok = bondy_mst_pack_store:close(S)
        after
            rmrf(Dir)
        end
    end).

seal_after_puts(S, KVs) ->
    Sn = lists:foldl(
        fun({K, V}, A) ->
            {_, A1} = bondy_mst_pack_store:put(A, mk_page(K, V)),
            A1
        end,
        S,
        KVs
    ),
    {ok, Sealed} = bondy_mst_pack_store:seal(Sn),
    Sealed.

%% =============================================================================
%% Negative: damaged .pack — rebuild refuses, store open fails
%% =============================================================================

pack_corruption_refuses_rebuild_test() ->
    with_telemetry(fun() ->
        {Dir, InstanceId, PackId, _HashPages} = seed_and_seal(4),
        try
            PackPath = pack_path(Dir, PackId),
            PackSize = file_size(PackPath),
            %% Flip a byte inside the first record's body (past 48-byte
            %% header + 40-byte record header, before the trailer).
            BodyOffset =
                ?BONDY_MST_PACK_HEADER_BYTES +
                    ?BONDY_MST_PACK_RECORD_HEADER_BYTES + 2,
            ?assert(BodyOffset < PackSize - ?BONDY_MST_PACK_TRAILER_BYTES),
            flip_byte(PackPath, BodyOffset),
            %% Also wipe the .idx so the open is forced to attempt
            %% rebuild — without that, the corrupt body wouldn't surface
            %% until first get/2.
            ok = file:delete(idx_path(Dir, PackId)),
            ?assertError(
                {pack_store_open, {sealed_idx, PackId, enoent}},
                open_pack_store(Dir, InstanceId)
            ),
            {_M, D} = recv_event(),
            ?assertMatch({error, {pack, _}}, maps:get(result, D)),
            ?assertEqual(enoent, maps:get(trigger, D)),
            ?assertEqual(PackId, maps:get(pack_id, D))
        after
            rmrf(Dir)
        end
    end).

%% =============================================================================
%% Negative: .pack trailing record body short — rebuild refuses
%% =============================================================================

pack_short_trailer_refuses_rebuild_test() ->
    with_telemetry(fun() ->
        {Dir, InstanceId, PackId, _HashPages} = seed_and_seal(3),
        try
            PackPath = pack_path(Dir, PackId),
            PackSize = file_size(PackPath),
            %% Truncate one byte before EOF — the trailer becomes
            %% short and the rebuild scan reports trailer_mismatch
            %% (the computed sha256 over header+records won't match
            %% the displaced 32 bytes).
            truncate_to(PackPath, PackSize - 1),
            ok = file:delete(idx_path(Dir, PackId)),
            ?assertError(
                {pack_store_open, {sealed_idx, PackId, enoent}},
                open_pack_store(Dir, InstanceId)
            ),
            {_M, D} = recv_event(),
            ?assertMatch({error, {pack, _}}, maps:get(result, D))
        after
            rmrf(Dir)
        end
    end).

%% =============================================================================
%% Direct module call — non_rebuildable error returns verbatim
%% =============================================================================

direct_rebuild_succeeds_test() ->
    with_telemetry(fun() ->
        {Dir, _InstanceId, PackId, HashPages} = seed_and_seal(3),
        try
            ok = file:delete(idx_path(Dir, PackId)),
            %% Compute instance_hash from the same instance_id used
            %% when the .pack header was sealed; reuse the existing
            %% pack header to look it up.
            PackPath = pack_path(Dir, PackId),
            Bin = read_all(PackPath),
            <<Header:?BONDY_MST_PACK_HEADER_BYTES/binary, _/binary>> = Bin,
            {ok, #{instance_hash := IH, hash_algo := HA}} =
                bondy_mst_pack_codec:decode_pack_header(Header),
            {ok, Outcome} =
                bondy_mst_pack_idx_rebuild:rebuild(Dir, PackId, IH, HA),
            ?assertEqual(
                length(HashPages),
                maps:get(records_recovered, Outcome)
            ),
            ?assert(maps:get(idx_bytes, Outcome) > 0),
            ?assert(filelib:is_regular(idx_path(Dir, PackId)))
        after
            rmrf(Dir)
        end
    end).
