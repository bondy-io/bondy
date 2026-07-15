%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Regression tests for `bondy_mst_pack_recovery` and its hook in
%% `bondy_mst_pack_store:open/2`. Covers the four trigger conditions
%% from `_design/latest/MST_PAGE_STORE_DESIGN.md` §10:
%%
%%   1. Manifest `incoming_pack = absent`, file present  (orphan)
%%   2. Manifest `incoming_pack = present`, file missing (lost)
%%   3. `incoming.pack` header missing / unparseable     (header_reset)
%%   4. Trailing record(s) torn / fail verify            (truncate)
%%
%% Each test creates the trigger condition out-of-band against a
%% closed store, then re-opens the store and asserts:
%%   - the `[bondy_mst, page_store, recovery]` telemetry event fires
%%     with the expected `actions` / state transitions;
%%   - the post-recovery store is usable.
%%
%% Tests follow the per-function `with_telemetry/1` pattern from
%% `bondy_mst_pack_store_telemetry_test` (eunit `{foreach, ...}`
%% would run setup in a different process from the test body and
%% the handler captures `self()` at attach time).
%% =============================================================================
-module(bondy_mst_pack_recovery_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").
-include("bondy_mst_pack.hrl").

-define(RECOVERY_EVENT, [bondy_mst, page_store, recovery]).

%% =============================================================================
%% Telemetry wrapper
%% =============================================================================

with_telemetry(Fun) ->
    {ok, _} = application:ensure_all_started(telemetry),
    HandlerId = make_ref(),
    Self = self(),
    ok = telemetry:attach_many(
        HandlerId,
        [?RECOVERY_EVENT],
        fun(Event, Measurements, Metadata, _Cfg) ->
            Self ! {telemetry, Event, Measurements, Metadata}
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
        {telemetry, ?RECOVERY_EVENT, M, D} -> {M, D}
    after 1_000 ->
        erlang:error({timeout_recovery_event, mailbox_dump()})
    end.

expect_no_event() ->
    receive
        {telemetry, ?RECOVERY_EVENT, M, D} ->
            erlang:error({unexpected_recovery_event, M, D})
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
            "/tmp/bondy_mst_pack_recovery_test_~p_~p",
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
        "recovery_test_" ++
            integer_to_list(erlang:unique_integer([positive]))
    ).

open_store(Dir, InstanceId) ->
    bondy_mst_store:open(
        bondy_mst_pack_store,
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

incoming_path(Dir) ->
    bondy_mst_pack_paths:incoming_pack_path(Dir).

incoming_size(Dir) ->
    case prim_file:read_file_info(incoming_path(Dir)) of
        {ok, #file_info{size = N}} -> N;
        {error, _} -> 0
    end.

%% Open the closed-store's incoming.pack and append `Bytes` at EOF.
append_raw(Dir, Bytes) ->
    Path = incoming_path(Dir),
    {ok, Fd} = prim_file:open(Path, [read, write, raw, binary]),
    {ok, _} = prim_file:position(Fd, eof),
    ok = prim_file:write(Fd, Bytes),
    ok = prim_file:close(Fd).

%% Overwrite the first 48 bytes of the incoming pack with zeros.
clobber_header(Dir) ->
    Path = incoming_path(Dir),
    {ok, Fd} = prim_file:open(Path, [read, write, raw, binary]),
    {ok, 0} = prim_file:position(Fd, bof),
    ok = prim_file:write(Fd, <<0:(?BONDY_MST_PACK_HEADER_BYTES * 8)>>),
    ok = prim_file:close(Fd).

%% Create an `incoming.pack` file in a fresh dir that has no manifest
%% yet — used to simulate the Case A orphan condition. The newly
%% created manifest will declare `incoming_pack = absent`, so the
%% writer's open finds the (absent, true) mismatch.
plant_orphan(Dir) ->
    Path = incoming_path(Dir),
    {ok, Fd} = prim_file:open(Path, [write, raw, binary, exclusive]),
    ok = prim_file:write(Fd, <<"orphan-garbage">>),
    ok = prim_file:close(Fd).

%% Open a store, put N distinct pages, close, return the dir + id.
seed_n_pages(Dir, InstanceId, N) ->
    S0 = open_store(Dir, InstanceId),
    S1 = lists:foldl(
        fun(I, S) ->
            K = list_to_binary("k" ++ integer_to_list(I)),
            V = list_to_binary("v" ++ integer_to_list(I)),
            {_, S2} = bondy_mst_store:put(S, mk_page(K, V)),
            S2
        end,
        S0,
        lists:seq(1, N)
    ),
    ok = bondy_mst_store:close(S1),
    ok.

%% =============================================================================
%% Case A — orphan incoming file (manifest absent, file present)
%% =============================================================================

orphan_incoming_file_test() ->
    with_telemetry(fun() ->
        Dir = mk_tmp_dir(),
        try
            plant_orphan(Dir),
            InstanceId = mk_instance_id(),
            S = open_store(Dir, InstanceId),
            {M, D} = recv_event(),
            ?assertEqual(ok, maps:get(result, D)),
            ?assertEqual([orphan_incoming_deleted], maps:get(actions, D)),
            ?assertEqual(
                absent,
                maps:get(incoming_state_before, D)
            ),
            ?assertEqual(
                absent,
                maps:get(incoming_state_after, D)
            ),
            ?assertEqual(0, maps:get(bytes_truncated, M)),
            ?assertEqual(0, maps:get(records_recovered, M)),
            ?assertEqual(InstanceId, maps:get(instance_id, D)),
            %% Post-recovery: store is fresh and usable.
            {_, S1} = bondy_mst_store:put(S, mk_page(<<"a">>, <<"1">>)),
            ok = bondy_mst_store:close(S1)
        after
            rmrf(Dir)
        end
    end).

%% =============================================================================
%% Case B — manifest says present, file missing
%% =============================================================================

missing_incoming_file_test() ->
    with_telemetry(fun() ->
        Dir = mk_tmp_dir(),
        try
            InstanceId = mk_instance_id(),
            ok = seed_n_pages(Dir, InstanceId, 3),
            %% Drain the seed-open's telemetry (none expected, but be
            %% defensive — no event should have fired in the clean
            %% open path).
            expect_no_event(),
            ok = file:delete(incoming_path(Dir)),
            S = open_store(Dir, InstanceId),
            {M, D} = recv_event(),
            ?assertEqual(ok, maps:get(result, D)),
            ?assertEqual(
                [manifest_flipped_to_absent],
                maps:get(actions, D)
            ),
            ?assertEqual(present, maps:get(incoming_state_before, D)),
            ?assertEqual(absent, maps:get(incoming_state_after, D)),
            ?assertEqual(0, maps:get(bytes_truncated, M)),
            ?assertEqual(0, maps:get(records_recovered, M)),
            ok = bondy_mst_store:close(S)
        after
            rmrf(Dir)
        end
    end).

%% =============================================================================
%% Case C — header corrupt (clobbered)
%% =============================================================================

header_corrupt_test() ->
    with_telemetry(fun() ->
        Dir = mk_tmp_dir(),
        try
            InstanceId = mk_instance_id(),
            ok = seed_n_pages(Dir, InstanceId, 2),
            expect_no_event(),
            OrigSize = incoming_size(Dir),
            ?assert(OrigSize >= ?BONDY_MST_PACK_HEADER_BYTES),
            clobber_header(Dir),
            S = open_store(Dir, InstanceId),
            {M, D} = recv_event(),
            ?assertEqual(ok, maps:get(result, D)),
            ?assertEqual(
                [header_reset, manifest_flipped_to_absent],
                maps:get(actions, D)
            ),
            ?assertEqual(present, maps:get(incoming_state_before, D)),
            ?assertEqual(absent, maps:get(incoming_state_after, D)),
            ?assertEqual(OrigSize, maps:get(bytes_truncated, M)),
            ?assertEqual(0, maps:get(records_recovered, M)),
            %% After Case C the records are gone (WAL would replay them
            %% in production); the store is fresh and usable.
            ?assertEqual(false, filelib:is_regular(incoming_path(Dir))),
            ok = bondy_mst_store:close(S)
        after
            rmrf(Dir)
        end
    end).

%% =============================================================================
%% Case C — header too short (file truncated below 48 bytes)
%% =============================================================================

header_short_test() ->
    with_telemetry(fun() ->
        Dir = mk_tmp_dir(),
        try
            InstanceId = mk_instance_id(),
            ok = seed_n_pages(Dir, InstanceId, 1),
            expect_no_event(),
            %% Truncate the file to 10 bytes — below the 48-byte header.
            Path = incoming_path(Dir),
            {ok, Fd} = prim_file:open(Path, [read, write, raw, binary]),
            {ok, 10} = prim_file:position(Fd, 10),
            ok = prim_file:truncate(Fd),
            ok = prim_file:close(Fd),
            S = open_store(Dir, InstanceId),
            {_M, D} = recv_event(),
            ?assertEqual(ok, maps:get(result, D)),
            ?assertEqual(
                [header_reset, manifest_flipped_to_absent],
                maps:get(actions, D)
            ),
            ?assertEqual(present, maps:get(incoming_state_before, D)),
            ?assertEqual(absent, maps:get(incoming_state_after, D)),
            ?assertEqual(false, filelib:is_regular(incoming_path(Dir))),
            ok = bondy_mst_store:close(S)
        after
            rmrf(Dir)
        end
    end).

%% =============================================================================
%% Case D — trailing torn record (20 bytes of garbage appended)
%% =============================================================================

trailing_garbage_test() ->
    with_telemetry(fun() ->
        Dir = mk_tmp_dir(),
        try
            InstanceId = mk_instance_id(),
            ok = seed_n_pages(Dir, InstanceId, 5),
            expect_no_event(),
            OrigSize = incoming_size(Dir),
            %% 20 bytes < record header (40)
            append_raw(Dir, <<0:160>>),
            ?assertEqual(OrigSize + 20, incoming_size(Dir)),
            S = open_store(Dir, InstanceId),
            {M, D} = recv_event(),
            ?assertEqual(ok, maps:get(result, D)),
            ?assertEqual(
                [trailing_records_truncated],
                maps:get(actions, D)
            ),
            ?assertEqual(present, maps:get(incoming_state_before, D)),
            ?assertEqual(present, maps:get(incoming_state_after, D)),
            ?assertEqual(20, maps:get(bytes_truncated, M)),
            ?assertEqual(5, maps:get(records_recovered, M)),
            ?assertEqual(OrigSize, incoming_size(Dir)),
            ok = bondy_mst_store:close(S)
        after
            rmrf(Dir)
        end
    end).

%% =============================================================================
%% Case D — torn body (full record header but corrupted body bytes)
%% =============================================================================

torn_record_body_test() ->
    with_telemetry(fun() ->
        Dir = mk_tmp_dir(),
        try
            InstanceId = mk_instance_id(),
            ok = seed_n_pages(Dir, InstanceId, 3),
            expect_no_event(),
            OrigSize = incoming_size(Dir),
            %% Append a 40-byte plausible-looking record header pointing
            %% at a 16-byte body, plus only 16 zero bytes (so the body
            %% is the right length but its CRC fails verify).
            Hash = crypto:hash(sha256, <<"not-the-real-body">>),
            BodyLen = 16,
            Crc = erlang:crc32(<<0:128>>),
            BadHeader =
                <<Hash/binary, BodyLen:32/big-unsigned,
                    (Crc + 1):32/big-unsigned>>,
            BadBody = <<0:128>>,
            append_raw(Dir, <<BadHeader/binary, BadBody/binary>>),
            ?assertEqual(OrigSize + 40 + 16, incoming_size(Dir)),
            S = open_store(Dir, InstanceId),
            {M, D} = recv_event(),
            ?assertEqual(
                [trailing_records_truncated],
                maps:get(actions, D)
            ),
            ?assertEqual(present, maps:get(incoming_state_after, D)),
            ?assertEqual(40 + 16, maps:get(bytes_truncated, M)),
            ?assertEqual(3, maps:get(records_recovered, M)),
            ?assertEqual(OrigSize, incoming_size(Dir)),
            ok = bondy_mst_store:close(S)
        after
            rmrf(Dir)
        end
    end).

%% =============================================================================
%% Clean reopen emits no recovery event
%% =============================================================================

clean_reopen_no_event_test() ->
    with_telemetry(fun() ->
        Dir = mk_tmp_dir(),
        try
            InstanceId = mk_instance_id(),
            ok = seed_n_pages(Dir, InstanceId, 2),
            S = open_store(Dir, InstanceId),
            expect_no_event(),
            ok = bondy_mst_store:close(S)
        after
            rmrf(Dir)
        end
    end).

%% =============================================================================
%% After Case D recovery, the writer can continue appending
%% =============================================================================

append_after_truncate_test() ->
    with_telemetry(fun() ->
        Dir = mk_tmp_dir(),
        try
            InstanceId = mk_instance_id(),
            ok = seed_n_pages(Dir, InstanceId, 2),
            append_raw(Dir, <<0:160>>),
            S = open_store(Dir, InstanceId),
            {_M, D} = recv_event(),
            ?assertEqual(
                [trailing_records_truncated],
                maps:get(actions, D)
            ),
            {_, S1} = bondy_mst_store:put(S, mk_page(<<"new">>, <<"v">>)),
            ok = bondy_mst_store:close(S1),
            %% Reopen again — should be clean now.
            S2 = open_store(Dir, InstanceId),
            expect_no_event(),
            ok = bondy_mst_store:close(S2)
        after
            rmrf(Dir)
        end
    end).
