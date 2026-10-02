%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% The log core driven by a SECOND log adapter — this module.
%%
%% Records are `{Key, Payload}` pairs, the body is their concatenation with a
%% length prefix (no `term_to_binary`), the frame magic is `BDTS`, and
%% `max_seq/1` is `undefined`. Nothing here is an oplog event, and no oplog
%% module is loaded by this test, so any oplog call left in the writer,
%% reader, recovery scanner or index rebuild crashes on a pair — that is
%% the falsifier for "the core has no record-kind knowledge".
%%
%% The identity context is `#{name => binary()}` — no `instance_id`, no
%% `origin` — and both header fields are slices of `sha256(Name)`, so a
%% core that still derives the header from an instance id or an origin
%% crashes in `encode_identity/1` or writes bytes `verify_identity/2`
%% refuses.
%%
%% The directory is an ETS table owned by the fixture; the writer's pid
%% must land there (falsify: a core still publishing to the oplog's
%% registry, which would leave the table empty).
%%
%% Which paths each case exercises:
%%   - `roundtrip_through_rotation_and_recovery`: write across a rotation,
%%     read by iterator and by key seek, close, delete a sealed `.qidx`,
%%     reopen (sealed-segment verify + index REBUILD through the adapter,
%%     head-segment scan through the adapter), read again.
%%   - `torn_tail_recovers_to_last_valid_frame`: break-and-truncate lands on
%%     the last valid frame with the toy magic and body.
%%   - `rescan_resumes_at_the_next_toy_magic`: rescan-mode recovery searches
%%     for THIS adapter's magic, not the oplog's — with the wrong magic the
%%     search finds nothing and every frame after the corrupt one is lost.
%%   - `foreign_records_are_refused`: the writer validates membership with
%%     the adapter it was opened with.
%%   - `wrong_identity_is_refused_before_any_frame_is_read`: reopening
%%     under another identity is `{orphan_segment, name_mismatch}` — the
%%     adapter's own reason — and the segment file is byte-identical
%%     afterwards (falsify: verify called with the old `(InstanceId,
%%     Origin)` shape, or the head scan running before the identity check
%%     and truncating on the foreign frames).
%%   - `a_module_that_is_not_an_adapter_is_refused`: `adapter => lists`
%%     is `{invalid_opt, adapter, {missing_callback, _, _}}` and nothing
%%     is created (falsify: the core calling the adapter before checking
%%     it, which surfaces as an `undef` crash out of `init/1`).
%%   - `telemetry_is_named_under_the_default_prefix`: with no
%%     `telemetry_prefix` the writer's append event is `[bondy_log, append]`
%%     (falsify: a core still emitting under a hardcoded consumer name).
%%   - `explicit_rotate_seals_the_head_under_infinity`: opened with
%%     `max_segment_bytes => infinity` the writer never rotates by size
%%     (12 batches at a 600 B threshold that rotated the first case land
%%     in segment 0); `rotate/1` seals it with `reason => explicit`, the
%%     reader crosses the boundary, an empty head is refused, and a
%%     reopen recovers the sealed segment (falsify: `infinity` compared
%%     as a term, or the explicit rotation skipping the manifest commit,
%%     which the reopen would see as a missing sealed segment).
%%   - `max_segment_bytes_is_validated`: `0` and an atom other than
%%     `infinity` are `{invalid_opt, max_segment_bytes, _}`.
%% =============================================================================
-module(bondy_log_standalone_test).

-behaviour(bondy_log_record).
-behaviour(bondy_log_identity).
-behaviour(bondy_log_directory).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

-define(MAGIC, 16#42445453).
-define(DIRECTORY, bondy_log_standalone_test_directory).

%% =============================================================================
%% bondy_log_record CALLBACKS — the toy adapter
%% =============================================================================

-export([frame_magic/0]).
-export([is_valid/1]).
-export([key/1]).
-export([max_seq/1]).
-export([encode_body/1]).
-export([decode_body/1]).

-export([encode_identity/1]).
-export([verify_identity/2]).

-export([register/2]).
-export([lookup_pid/1]).

frame_magic() -> ?MAGIC.

is_valid({K, B}) when is_integer(K), K >= 0, is_binary(B) -> true;
is_valid(_) -> false.

key({K, _}) -> K.

max_seq(_) -> undefined.

encode_body(Records) ->
    iolist_to_binary([
        <<K:64/big-unsigned, (byte_size(B)):32/big-unsigned, B/binary>>
     || {K, B} <- Records
    ]).

decode_body(<<>>) ->
    {error, empty};
decode_body(Bin) ->
    decode_records(Bin, []).

decode_records(<<>>, Acc) ->
    {ok, lists:reverse(Acc)};
decode_records(
    <<K:64/big-unsigned, Len:32/big-unsigned, B:Len/binary, Rest/binary>>, Acc
) ->
    decode_records(Rest, [{K, B} | Acc]);
decode_records(_, _) ->
    {error, malformed}.

encode_identity(#{name := Name}) when is_binary(Name) ->
    <<Hash8:8/binary, _:8/binary, Id16:16/binary>> =
        crypto:hash(sha256, Name),
    {ok, #{hash8 => Hash8, id16 => Id16}};
encode_identity(_) ->
    {error, {missing_opt, name}}.

verify_identity(Identity, Ctx) ->
    case encode_identity(Ctx) of
        {ok, Identity} -> ok;
        {ok, _} -> {error, name_mismatch};
        {error, _} = E -> E
    end.

register(InstanceId, Pid) ->
    true = ets:insert(?DIRECTORY, {InstanceId, Pid}),
    ok.

lookup_pid(InstanceId) ->
    case ets:lookup(?DIRECTORY, InstanceId) of
        [{_, Pid}] -> Pid;
        [] -> undefined
    end.

%% =============================================================================
%% Tests
%% =============================================================================

record_adapter_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(telemetry),
            ?DIRECTORY = ets:new(?DIRECTORY, [named_table, public, set]),
            ok
        end,
        fun(_) ->
            true = ets:delete(?DIRECTORY),
            ok
        end,
        [
            {timeout, 30, fun roundtrip_through_rotation_and_recovery/0},
            {timeout, 30, fun torn_tail_recovers_to_last_valid_frame/0},
            {timeout, 30, fun rescan_resumes_at_the_next_toy_magic/0},
            {timeout, 30, fun foreign_records_are_refused/0},
            {timeout, 30,
                fun wrong_identity_is_refused_before_any_frame_is_read/0},
            {timeout, 30, fun telemetry_is_named_under_the_default_prefix/0},
            {timeout, 30, fun a_module_that_is_not_an_adapter_is_refused/0},
            {timeout, 30, fun explicit_rotate_seals_the_head_under_infinity/0},
            {timeout, 30, fun max_segment_bytes_is_validated/0}
        ]}.

roundtrip_through_rotation_and_recovery() ->
    Dir = mktemp_dir(),
    try
        Opts = opts(Dir, #{max_segment_bytes => 600}),
        {ok, P1, #{max_seq := 0}} = bondy_log_wal:open(instance_id(), Opts),
        %% The writer published itself through the adapter's directory.
        ?assertEqual(P1, lookup_pid(instance_id())),
        %% 12 batches of 3 records, 300 B each: several rotations at 600 B.
        Batches = [batch(B) || B <- lists:seq(1, 12)],
        Acks = [
            begin
                {ok, Entries} = bondy_log_wal:append_batch(P1, Batch),
                Entries
            end
         || Batch <- Batches
        ],
        %% The acks carry the adapter's keys, one per record.
        ?assertEqual(
            [[K || {K, _} <- Batch] || Batch <- Batches],
            [[K || {K, _Pos} <- Entries] || Entries <- Acks]
        ),
        Info = bondy_log_wal:info(P1),
        ?assert(maps:get(current_segment, Info) > 0),
        ?assertEqual(?MODULE, maps:get(adapter, Info)),
        ?assertEqual(identity(), maps:get(identity, Info)),
        ?assertEqual(?MAGIC, maps:get(frame_magic, Info)),
        %% max_seq never moves for a record kind without a sequence.
        ?assertEqual(0, maps:get(max_seq, Info)),
        All = lists:append(Batches),
        ?assertEqual(All, read_all(P1, beginning)),
        %% Key seek goes through the sparse index and the adapter's keys.
        {K7, _} = hd(batch(7)),
        ?assertEqual(
            lists:append(lists:nthtail(6, Batches)), read_all(P1, {key, K7})
        ),
        ok = bondy_log_wal:close(P1),
        %% Force the sealed-segment index rebuild through the adapter.
        Idx0 = filename:join(
            instance_dir(Dir), bondy_log_idx:filename(0)
        ),
        ?assert(filelib:is_regular(Idx0)),
        ok = file:delete(Idx0),
        {ok, P2, #{max_seq := 0}} = bondy_log_wal:open(instance_id(), Opts),
        ?assert(filelib:is_regular(Idx0)),
        ?assertEqual(All, read_all(P2, beginning)),
        ?assertEqual(
            lists:append(lists:nthtail(6, Batches)), read_all(P2, {key, K7})
        ),
        ok = bondy_log_wal:close(P2)
    after
        rmrf(Dir)
    end.

torn_tail_recovers_to_last_valid_frame() ->
    Dir = mktemp_dir(),
    try
        Opts = opts(Dir, #{}),
        {ok, P1, _} = bondy_log_wal:open(instance_id(), Opts),
        Records = [{K, payload(K)} || K <- lists:seq(1, 5)],
        _ = [{ok, _} = bondy_log_wal:append_batch(P1, [R]) || R <- Records],
        ok = bondy_log_wal:close(P1),
        SegPath = filename:join(
            instance_dir(Dir), bondy_log_segment:filename(0)
        ),
        {ok, #file_info{size = Size}} = file:read_file_info(SegPath),
        {ok, Fd} = file:open(SegPath, [read, write, raw, binary]),
        {ok, _} = file:position(Fd, Size - 10),
        ok = file:truncate(Fd),
        ok = file:close(Fd),
        {ok, P2, _} = bondy_log_wal:open(instance_id(), Opts),
        Read = read_all(P2, beginning),
        ?assertEqual(4, length(Read)),
        ?assertEqual(lists:sublist(Records, 4), Read),
        %% The writer resumes right after the last surviving frame.
        {ok, #file_info{size = NewSize}} = file:read_file_info(SegPath),
        ?assertEqual(NewSize, maps:get(head_offset, bondy_log_wal:info(P2))),
        {ok, [{6, {0, Off}}]} = bondy_log_wal:append_batch(
            P2, [{6, payload(6)}]
        ),
        ?assertEqual(NewSize, Off),
        ok = bondy_log_wal:close(P2)
    after
        rmrf(Dir)
    end.

rescan_resumes_at_the_next_toy_magic() ->
    Dir = mktemp_dir(),
    try
        Opts = opts(Dir, #{recovery_mode => rescan}),
        {ok, P1, _} = bondy_log_wal:open(instance_id(), Opts),
        Records = [{K, payload(K)} || K <- lists:seq(1, 5)],
        Positions = [
            begin
                {ok, [{_, {0, Off}}]} = bondy_log_wal:append_batch(P1, [R]),
                Off
            end
         || R <- Records
        ],
        ok = bondy_log_wal:close(P1),
        %% Corrupt the THIRD frame's magic. Rescan must skip to the fourth
        %% frame by searching for `BDTS`; a search for `BDOP` finds nothing
        %% and truncates frames 3..5 away.
        SegPath = filename:join(
            instance_dir(Dir), bondy_log_segment:filename(0)
        ),
        Off3 = lists:nth(3, Positions),
        {ok, Fd} = file:open(SegPath, [read, write, raw, binary]),
        ok = file:pwrite(Fd, Off3, <<"XXXX">>),
        ok = file:close(Fd),
        {ok, P2, _} = bondy_log_wal:open(instance_id(), Opts),
        Read = read_all(P2, beginning),
        ?assertEqual(
            [R || {K, _} = R <- Records, K =/= 3], Read
        ),
        ok = bondy_log_wal:close(P2)
    after
        rmrf(Dir)
    end.

foreign_records_are_refused() ->
    Dir = mktemp_dir(),
    try
        {ok, P, _} = bondy_log_wal:open(instance_id(), opts(Dir, #{})),
        %% Another kind's record: a tagged tuple that is not a pair.
        Foreign = {some_other_record, 1, <<1:128>>, {op, 1}},
        ?assertEqual(
            {error, {invalid_batch, non_event}},
            bondy_log_wal:append_batch(P, [Foreign])
        ),
        ?assertEqual(
            {error, {invalid_batch, non_event}},
            bondy_log_wal:append_batch(P, [{1, payload(1)}, not_a_record])
        ),
        %% Nothing was written.
        ?assertEqual(0, maps:get(append_count, bondy_log_wal:info(P))),
        ok = bondy_log_wal:close(P)
    after
        rmrf(Dir)
    end.

wrong_identity_is_refused_before_any_frame_is_read() ->
    Dir = mktemp_dir(),
    try
        Opts = opts(Dir, #{}),
        {ok, P1, _} = bondy_log_wal:open(instance_id(), Opts),
        Records = [{K, payload(K)} || K <- lists:seq(1, 5)],
        _ = [{ok, _} = bondy_log_wal:append_batch(P1, [R]) || R <- Records],
        ok = bondy_log_wal:close(P1),
        SegPath = filename:join(
            instance_dir(Dir), bondy_log_segment:filename(0)
        ),
        {ok, Before} = file:read_file(SegPath),
        Other = Opts#{identity => #{name => <<"someone-else">>}},
        OldFlag = process_flag(trap_exit, true),
        try
            ?assertEqual(
                {error, {head_segment, 0, {orphan_segment, name_mismatch}}},
                bondy_log_wal:start_link(instance_id(), Other)
            ),
            receive
                {'EXIT', _, _} -> ok
            after 0 -> ok
            end
        after
            process_flag(trap_exit, OldFlag)
        end,
        ?assertEqual({ok, Before}, file:read_file(SegPath)),
        %% The right identity still opens it, with every frame intact.
        {ok, P2, _} = bondy_log_wal:open(instance_id(), Opts),
        ?assertEqual(Records, read_all(P2, beginning)),
        ok = bondy_log_wal:close(P2)
    after
        rmrf(Dir)
    end.

telemetry_is_named_under_the_default_prefix() ->
    Dir = mktemp_dir(),
    Ref = make_ref(),
    Self = self(),
    HandlerId = {?MODULE, Ref},
    ok = telemetry:attach(
        HandlerId,
        [bondy_log, append],
        fun(Event, Meas, Meta, _) -> Self ! {Ref, Event, Meas, Meta} end,
        []
    ),
    try
        {ok, P, _} = bondy_log_wal:open(instance_id(), opts(Dir, #{})),
        {ok, _} = bondy_log_wal:append_batch(P, [{1, payload(1)}]),
        receive
            {Ref, [bondy_log, append], #{batch_size := 1}, Meta} ->
                ?assertEqual(instance_id(), maps:get(instance_id, Meta))
        after 1000 ->
            error(no_append_event)
        end,
        ok = bondy_log_wal:close(P)
    after
        _ = telemetry:detach(HandlerId),
        rmrf(Dir)
    end.

a_module_that_is_not_an_adapter_is_refused() ->
    Dir = mktemp_dir(),
    try
        ?assertMatch(
            {error, {invalid_opt, adapter, {missing_callback, _, _}}},
            bondy_log_wal:start(instance_id(), opts(Dir, #{adapter => lists}))
        ),
        ?assertMatch(
            {error, {invalid_opt, adapter, {not_loaded, _, _}}},
            bondy_log_wal:start(
                instance_id(), opts(Dir, #{adapter => no_such_module})
            )
        ),
        ?assertMatch(
            {error, {invalid_opt, adapter, "lists"}},
            bondy_log_wal:start(instance_id(), opts(Dir, #{adapter => "lists"}))
        ),
        ?assertNot(filelib:is_dir(instance_dir(Dir)))
    after
        rmrf(Dir)
    end.

explicit_rotate_seals_the_head_under_infinity() ->
    Dir = mktemp_dir(),
    Ref = make_ref(),
    Self = self(),
    HandlerId = {?MODULE, Ref},
    ok = telemetry:attach(
        HandlerId,
        [bondy_log, rotate],
        fun(Event, Meas, Meta, _) -> Self ! {Ref, Event, Meas, Meta} end,
        []
    ),
    try
        Opts = opts(Dir, #{max_segment_bytes => infinity}),
        {ok, P1, _} = bondy_log_wal:open(instance_id(), Opts),
        ?assertEqual(
            infinity, maps:get(max_segment_bytes, bondy_log_wal:info(P1))
        ),
        %% A fresh head holds no frame: nothing to seal.
        ?assertEqual({error, empty_segment}, bondy_log_wal:rotate(P1)),
        %% The 12 batches that rotated several times at 600 B in the
        %% first case all land in segment 0 here.
        Batches = [batch(B) || B <- lists:seq(1, 12)],
        _ = [{ok, _} = bondy_log_wal:append_batch(P1, B) || B <- Batches],
        ?assertEqual(0, maps:get(current_segment, bondy_log_wal:info(P1))),
        receive
            {Ref, [bondy_log, rotate], _, _} -> error(rotated_by_size)
        after 0 -> ok
        end,
        ?assertEqual({ok, 0}, bondy_log_wal:rotate(P1)),
        Info = bondy_log_wal:info(P1),
        ?assertEqual(1, maps:get(current_segment, Info)),
        ?assertEqual([0, 1], maps:get(live_segments, Info)),
        %% The sealed segment is durable before the call returned.
        ?assertEqual({1, 48}, bondy_log_wal:durable_position(P1)),
        receive
            {Ref, [bondy_log, rotate], #{old_size_bytes := Size}, Meta} ->
                ?assertEqual(explicit, maps:get(reason, Meta)),
                ?assertEqual(0, maps:get(old_segment, Meta)),
                ?assertEqual(1, maps:get(new_segment, Meta)),
                ?assert(Size > 48)
        after 1000 ->
            error(no_rotate_event)
        end,
        %% The new head is empty again, so a second seal is refused.
        ?assertEqual({error, empty_segment}, bondy_log_wal:rotate(P1)),
        More = batch(13),
        {ok, [{_, {1, 48}} | _]} = bondy_log_wal:append_batch(P1, More),
        All = lists:append(Batches ++ [More]),
        ?assertEqual(All, read_all(P1, beginning)),
        ok = bondy_log_wal:close(P1),
        %% The manifest named both segments: recovery verifies the sealed
        %% one and the writer resumes on segment 1.
        {ok, P2, #{head_pos := {1, _}}} = bondy_log_wal:open(
            instance_id(), Opts
        ),
        ?assertEqual(All, read_all(P2, beginning)),
        ?assert(
            filelib:is_regular(
                filename:join(instance_dir(Dir), bondy_log_idx:filename(0))
            )
        ),
        ok = bondy_log_wal:close(P2)
    after
        _ = telemetry:detach(HandlerId),
        rmrf(Dir)
    end.

max_segment_bytes_is_validated() ->
    Dir = mktemp_dir(),
    try
        ?assertEqual(
            {error, {invalid_opt, max_segment_bytes, 0}},
            bondy_log_wal:start(
                instance_id(), opts(Dir, #{max_segment_bytes => 0})
            )
        ),
        ?assertEqual(
            {error, {invalid_opt, max_segment_bytes, unbounded}},
            bondy_log_wal:start(
                instance_id(), opts(Dir, #{max_segment_bytes => unbounded})
            )
        ),
        ?assertEqual([], filelib:wildcard(filename:join(Dir, "*")))
    after
        rmrf(Dir)
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

instance_id() ->
    <<"toy-record-instance">>.

identity() ->
    #{name => <<"toy-log">>}.

opts(Dir, Extra) ->
    maps:merge(
        #{
            dir => Dir,
            adapter => ?MODULE,
            identity => identity(),
            retention_sweep_interval => 24 * 60 * 60 * 1000
        },
        Extra
    ).

%% Batch B holds keys 100B+1..100B+3; keys ascend across batches.
batch(B) ->
    [{100 * B + I, payload(100 * B + I)} || I <- lists:seq(1, 3)].

payload(K) ->
    binary:copy(<<(K rem 251)>>, 300).

read_all(Wal, Start) ->
    {ok, Iter} = bondy_log_reader:open(Wal, Start),
    read_loop(Iter, []).

read_loop(Iter, Acc) ->
    case bondy_log_reader:next(Iter) of
        {ok, Batch, Keys, _Pos, Iter1} ->
            ?assertEqual([K || {K, _} <- Batch], Keys),
            read_loop(Iter1, [Batch | Acc]);
        end_of_log ->
            ok = bondy_log_reader:close(Iter),
            lists:append(lists:reverse(Acc))
    end.

instance_dir(Dir) ->
    filename:join(Dir, instance_id()).

mktemp_dir() ->
    Dir = filename:join(
        "/tmp",
        io_lib:format(
            "bondy_log_standalone_test_~p_~p",
            [erlang:system_time(microsecond), erlang:unique_integer([positive])]
        )
    ),
    Flat = lists:flatten(Dir),
    ok = filelib:ensure_path(Flat),
    Flat.

rmrf(Dir) ->
    _ = file:del_dir_r(Dir),
    ok.
