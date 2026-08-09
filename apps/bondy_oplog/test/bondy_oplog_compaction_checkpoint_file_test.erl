%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% EUnit suite for `bondy_oplog_compaction_checkpoint_file`. Covers:
%%
%% 1. Round-trip: put + get returns the stored watermark + checkpoint.
%% 2. Not-found: a fresh directory returns `not_found` and `undefined`.
%% 3. Overwrite: the second put replaces the first; single-checkpoint policy.
%% 4. Restart: a new state opened against the same path recovers the
%%    last persisted checkpoint — confirms file durability.
%% 5. Corruption detection:
%%    - truncated tail (random truncation after the first byte) → {error, _};
%%    - garbage bytes → {error, _};
%%    - empty file → {error, _};
%%    - same paths surface via `current_watermark/1`.
%% 6. Atomic-rename invariant: a stale `*.tmp` left behind by a prior
%%    interrupted write does not contaminate the live read.
%% =============================================================================
-module(bondy_oplog_compaction_checkpoint_file_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

%% =============================================================================
%% Fixture helpers
%% =============================================================================

mktemp_dir() ->
    Base = filename:join(
        [
            "/tmp",
            io_lib:format(
                "bondy_oplog_ckpt_file_test_~p_~p",
                [
                    erlang:system_time(microsecond),
                    erlang:unique_integer([positive])
                ]
            )
        ]
    ),
    Dir = lists:flatten(Base),
    ok = filelib:ensure_path(Dir),
    Dir.

rmrf(Dir) ->
    _ = file:del_dir_r(Dir),
    ok.

with_state(Fun) ->
    Dir = mktemp_dir(),
    Id = list_to_binary(
        io_lib:format(
            "inst_~p",
            [erlang:unique_integer([positive])]
        )
    ),
    {ok, S} = bondy_oplog_compaction_checkpoint_file:init(
        Id, #{path => Dir}
    ),
    try
        Fun(S, Dir, Id)
    after
        ok = bondy_oplog_compaction_checkpoint_file:close(S),
        rmrf(Dir)
    end.

%% The file path the backend will write to (mirrors `init/2`).
checkpoint_path(Dir, Id) ->
    filename:join([Dir, Id, "checkpoint.etf"]).

mk_watermark(Hlc, Seq) ->
    bondy_oplog_event:key(Hlc, bondy_oplog_origin:new(), Seq).

%% =============================================================================
%% Round-trip
%% =============================================================================

init_then_get_not_found_test() ->
    with_state(fun(S, _Dir, _Id) ->
        ?assertEqual(
            not_found,
            bondy_oplog_compaction_checkpoint_file:get_checkpoint(S)
        ),
        ?assertEqual(
            undefined,
            bondy_oplog_compaction_checkpoint_file:current_watermark(S)
        )
    end).

put_then_get_round_trip_test() ->
    with_state(fun(S, _Dir, _Id) ->
        W = mk_watermark(123, 7),
        Ckpt = #{counter => 42, set => [a, b, c]},
        ?assertEqual(
            ok,
            bondy_oplog_compaction_checkpoint_file:put_checkpoint(S, W, Ckpt)
        ),
        ?assertEqual(
            {ok, W, Ckpt},
            bondy_oplog_compaction_checkpoint_file:get_checkpoint(S)
        ),
        ?assertEqual(
            W,
            bondy_oplog_compaction_checkpoint_file:current_watermark(S)
        )
    end).

overwrite_preserves_only_latest_test() ->
    with_state(fun(S, _Dir, _Id) ->
        W1 = mk_watermark(1, 1),
        W2 = mk_watermark(2, 2),
        ok = bondy_oplog_compaction_checkpoint_file:put_checkpoint(
            S, W1, ckpt1
        ),
        ok = bondy_oplog_compaction_checkpoint_file:put_checkpoint(
            S, W2, ckpt2
        ),
        ?assertEqual(
            {ok, W2, ckpt2},
            bondy_oplog_compaction_checkpoint_file:get_checkpoint(S)
        )
    end).

restart_recovers_persisted_checkpoint_test() ->
    Dir = mktemp_dir(),
    Id = <<"inst_restart">>,
    {ok, S1} = bondy_oplog_compaction_checkpoint_file:init(
        Id, #{path => Dir}
    ),
    W = mk_watermark(99, 3),
    Ckpt = {durable, [1, 2, 3]},
    ok = bondy_oplog_compaction_checkpoint_file:put_checkpoint(S1, W, Ckpt),
    ok = bondy_oplog_compaction_checkpoint_file:close(S1),
    {ok, S2} = bondy_oplog_compaction_checkpoint_file:init(
        Id, #{path => Dir}
    ),
    try
        ?assertEqual(
            {ok, W, Ckpt},
            bondy_oplog_compaction_checkpoint_file:get_checkpoint(S2)
        )
    after
        ok = bondy_oplog_compaction_checkpoint_file:close(S2),
        rmrf(Dir)
    end.

%% =============================================================================
%% Corruption detection
%% =============================================================================

corrupted_truncated_file_returns_error_test() ->
    with_state(fun(S, Dir, Id) ->
        W = mk_watermark(50, 1),
        ok = bondy_oplog_compaction_checkpoint_file:put_checkpoint(
            S, W, big_ckpt
        ),
        Path = checkpoint_path(Dir, Id),
        {ok, Bin} = file:read_file(Path),
        Truncated = binary:part(Bin, 0, byte_size(Bin) div 2),
        ok = file:write_file(Path, Truncated),
        ?assertMatch(
            {error, {corrupted, _}},
            bondy_oplog_compaction_checkpoint_file:get_checkpoint(S)
        ),
        ?assertMatch(
            {error, {corrupted, _}},
            bondy_oplog_compaction_checkpoint_file:current_watermark(S)
        )
    end).

corrupted_garbage_bytes_returns_error_test() ->
    with_state(fun(S, Dir, Id) ->
        ok = bondy_oplog_compaction_checkpoint_file:put_checkpoint(
            S, mk_watermark(1, 1), payload
        ),
        Path = checkpoint_path(Dir, Id),
        ok = file:write_file(Path, <<"this is not a valid ETF binary at all">>),
        ?assertMatch(
            {error, {corrupted, _}},
            bondy_oplog_compaction_checkpoint_file:get_checkpoint(S)
        )
    end).

corrupted_empty_file_returns_error_test() ->
    with_state(fun(S, Dir, Id) ->
        ok = bondy_oplog_compaction_checkpoint_file:put_checkpoint(
            S, mk_watermark(1, 1), payload
        ),
        Path = checkpoint_path(Dir, Id),
        ok = file:write_file(Path, <<>>),
        ?assertMatch(
            {error, {corrupted, _}},
            bondy_oplog_compaction_checkpoint_file:get_checkpoint(S)
        )
    end).

%% =============================================================================
%% Atom table
%% =============================================================================

%% A checkpoint carries atoms from modules that need not be loaded when the
%% instance reads it at boot. Decoding with `[safe]` rejects any atom the
%% reading node has not created yet, so an intact checkpoint would be reported
%% as corrupt and the instance would refuse to start. The file holds bytes this
%% node wrote itself, so the decode must accept them.
checkpoint_naming_an_unknown_atom_is_not_corrupt_test() ->
    with_state(fun(S, Dir, Id) ->
        Bin = checkpoint_bytes_naming_a_novel_atom(),

        %% The fixture is only meaningful if it really does name an atom this
        %% node has never created. Assert that before asserting the fix.
        ?assertError(badarg, binary_to_term(Bin, [safe])),

        Path = checkpoint_path(Dir, Id),
        ok = filelib:ensure_dir(Path),
        ok = file:write_file(Path, Bin),

        ?assertMatch(
            {ok, 42, #{tag := _}},
            bondy_oplog_compaction_checkpoint_file:get_checkpoint(S)
        ),
        ?assertEqual(
            42, bondy_oplog_compaction_checkpoint_file:current_watermark(S)
        )
    end).

%% `term_to_binary/2` can only encode an atom that already exists, so the
%% novel name is patched into the encoded bytes. ATOM_UTF8_EXT is
%% length-prefixed, so a same-length substitution leaves a well-formed ETF
%% binary and needs no length fixup.
checkpoint_bytes_naming_a_novel_atom() ->
    Placeholder = 'bondy_ckpt_placeholder_atom_nm',
    Novel = <<"bondy_ckpt_atom_never_created1">>,
    PlaceholderBin = atom_to_binary(Placeholder, utf8),
    ?assertEqual(byte_size(PlaceholderBin), byte_size(Novel)),
    Bin = term_to_binary(
        {checkpoint_v1, 42, #{tag => Placeholder}}, [{minor_version, 2}]
    ),
    binary:replace(Bin, PlaceholderBin, Novel, [global]).

%% =============================================================================
%% Atomic-rename invariant
%% =============================================================================

stale_tmp_file_does_not_contaminate_read_test() ->
    %% A pre-existing `.tmp` from a prior interrupted write must not
    %% be picked up by `get_checkpoint/1` — the live `checkpoint.etf`
    %% is authoritative.
    with_state(fun(S, Dir, Id) ->
        W = mk_watermark(7, 7),
        ok = bondy_oplog_compaction_checkpoint_file:put_checkpoint(
            S, W, real_ckpt
        ),
        Path = checkpoint_path(Dir, Id),
        Tmp = iolist_to_binary([Path, ".tmp"]),
        ok = file:write_file(Tmp, <<"garbage from a crashed prior writer">>),
        ?assertEqual(
            {ok, W, real_ckpt},
            bondy_oplog_compaction_checkpoint_file:get_checkpoint(S)
        )
    end).

%% =============================================================================
%% init/2 input validation
%% =============================================================================

init_missing_path_returns_error_test() ->
    ?assertEqual(
        {error, {missing_option, path}},
        bondy_oplog_compaction_checkpoint_file:init(<<"id">>, #{})
    ).

%% =============================================================================
%% Instance-level: corruption surfaces as a fatal init error
%% =============================================================================

%% Requires the bondy_mst application to be running. Wrap in a setup
%% fixture so a bare `eunit:test/1` of this module still works.
instance_init_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(bondy_db),
            bondy_oplog_sync_scheduler:set_dispatch(undefined),
            bondy_oplog_gc_scheduler:set_trigger(undefined),
            ok
        end,
        fun(_) ->
            [
                bondy_oplog:stop_instance(I)
             || I <- bondy_oplog:list_instances()
            ],
            ok
        end,
        [{timeout, 60, fun instance_init_fails_loudly_on_corrupt_checkpoint/0}]}.

instance_init_fails_loudly_on_corrupt_checkpoint() ->
    %% If the checkpoint file is unreadable, the instance refuses to
    %% start (rather than silently rebuilding from a partial state).
    %% The operator can then restore from backup.
    Suffix = integer_to_list(os:system_time(microsecond)),
    Tmp = filename:join(
        <<"/tmp">>,
        list_to_binary("bondy_oplog_corrupt_" ++ Suffix)
    ),
    ok = filelib:ensure_path(Tmp),
    Id = list_to_binary("corrupt_" ++ Suffix),
    Opts = #{
        crdt_module => bondy_oplog_test_counter,
        compaction_checkpoint => bondy_oplog_compaction_checkpoint_file,
        compaction_checkpoint_opts => #{path => Tmp},
        origin => bondy_oplog_origin:new()
    },
    try
        {ok, _} = bondy_oplog:start_instance(Id, Opts),
        [bondy_oplog:append(Id, {inc, 1}) || _ <- lists:seq(1, 3)],
        ok = bondy_oplog:await_apply(Id),
        LocalRoot = bondy_oplog:root_hash(Id),
        bondy_oplog_peer_state:record_sync_complete(
            {peer, dummy_corrupt}, Id, LocalRoot
        ),
        bondy_oplog_peer_state:sync(),
        {ok, {compacted, _, _}} = bondy_oplog:compact(Id),
        ok = bondy_oplog:stop_instance(Id),
        %% Corrupt the persisted checkpoint.
        Path = checkpoint_path(Tmp, Id),
        ok = file:write_file(Path, <<"corrupted">>),
        %% Re-open must fail with our tagged reason — surfaced by the
        %% supervisor as `{shutdown, {compaction_checkpoint_corrupted,
        %% _, _}}` wrapped in a `start_link` error tuple.
        Result = bondy_oplog:start_instance(Id, Opts),
        ?assertMatch({error, _}, Result),
        ?assert(contains_corruption_marker(Result))
    after
        bondy_oplog_peer_state:forget_peer({peer, dummy_corrupt}),
        rmrf(Tmp)
    end.

contains_corruption_marker(Term) ->
    Bin = iolist_to_binary(io_lib:format("~p", [Term])),
    binary:match(Bin, <<"compaction_checkpoint_corrupted">>) =/= nomatch.

%% =============================================================================
%% Default-backend resolution
%% =============================================================================
%%
%% PR-DEFAULT: when an instance has `storage_path` configured but no
%% explicit `compaction_checkpoint`, the file backend is picked
%% automatically and the checkpoint file is written under the sharded
%% per-instance directory. Without `storage_path`, instances stay on
%% the ETS backend (ephemeral).

default_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(bondy_db),
            bondy_oplog_sync_scheduler:set_dispatch(undefined),
            bondy_oplog_gc_scheduler:set_trigger(undefined),
            ok
        end,
        fun(_) ->
            [
                bondy_oplog:stop_instance(I)
             || I <- bondy_oplog:list_instances()
            ],
            ok
        end,
        [
            {timeout, 60, fun default_file_when_storage_path/0},
            {timeout, 60, fun default_ets_when_ephemeral/0},
            {timeout, 60, fun checkpoint_persists_via_default/0}
        ]}.

%% With `storage_path`, the instance picks the file backend by default
%% and writes the checkpoint under the sharded per-instance dir.
default_file_when_storage_path() ->
    Suffix = integer_to_list(os:system_time(microsecond)),
    Tmp = filename:join(
        <<"/tmp">>,
        list_to_binary("bondy_oplog_def_fp_" ++ Suffix)
    ),
    ok = filelib:ensure_path(Tmp),
    Id = list_to_binary("def_fp_" ++ Suffix),
    Opts = #{
        crdt_module => bondy_oplog_test_counter,
        storage_path => Tmp,
        seed => true,
        origin => bondy_oplog_origin:new()
    },
    try
        {ok, _} = bondy_oplog:start_instance(Id, Opts),
        [bondy_oplog:append(Id, {inc, 1}) || _ <- lists:seq(1, 3)],
        ok = bondy_oplog:await_apply(Id),
        LocalRoot = bondy_oplog:root_hash(Id),
        bondy_oplog_peer_state:record_sync_complete(
            {peer, def_fp_peer}, Id, LocalRoot
        ),
        bondy_oplog_peer_state:sync(),
        {ok, {compacted, _, _}} = bondy_oplog:compact(Id),
        %% Expected on-disk path: same sharded instance dir as MST/WAL.
        Sharded = bondy_oplog_path:storage_path(Id, Tmp, sharded),
        ExpectedFile = filename:join(Sharded, "checkpoint.etf"),
        ?assert(filelib:is_regular(ExpectedFile))
    after
        bondy_oplog:stop_instance(Id),
        bondy_oplog_peer_state:forget_peer({peer, def_fp_peer}),
        rmrf(Tmp)
    end.

%% Without `storage_path`, the default stays on ETS — no checkpoint
%% file is written even after compaction.
default_ets_when_ephemeral() ->
    Suffix = integer_to_list(os:system_time(microsecond)),
    Id = list_to_binary("def_eph_" ++ Suffix),
    Opts = #{
        crdt_module => bondy_oplog_test_counter,
        origin => bondy_oplog_origin:new()
    },
    try
        {ok, _} = bondy_oplog:start_instance(Id, Opts),
        [bondy_oplog:append(Id, {inc, 1}) || _ <- lists:seq(1, 3)],
        ok = bondy_oplog:await_apply(Id),
        LocalRoot = bondy_oplog:root_hash(Id),
        bondy_oplog_peer_state:record_sync_complete(
            {peer, def_eph_peer}, Id, LocalRoot
        ),
        bondy_oplog_peer_state:sync(),
        {ok, {compacted, _, _}} = bondy_oplog:compact(Id),
        %% Checkpoint is in ETS, queryable in-memory.
        ?assertMatch({ok, _, _}, bondy_oplog:compaction_checkpoint(Id))
    after
        bondy_oplog:stop_instance(Id),
        bondy_oplog_peer_state:forget_peer({peer, def_eph_peer})
    end.

%% End-to-end: with the new default, checkpoint survives an instance
%% restart even though the caller didn't ask for a file backend.
checkpoint_persists_via_default() ->
    Suffix = integer_to_list(os:system_time(microsecond)),
    Tmp = filename:join(
        <<"/tmp">>,
        list_to_binary("bondy_oplog_def_p_" ++ Suffix)
    ),
    ok = filelib:ensure_path(Tmp),
    Id = list_to_binary("def_p_" ++ Suffix),
    Opts = #{
        crdt_module => bondy_oplog_test_counter,
        storage_path => Tmp,
        seed => true,
        origin => bondy_oplog_origin:new()
    },
    try
        {ok, _} = bondy_oplog:start_instance(Id, Opts),
        [bondy_oplog:append(Id, {inc, 1}) || _ <- lists:seq(1, 3)],
        ok = bondy_oplog:await_apply(Id),
        LocalRoot = bondy_oplog:root_hash(Id),
        bondy_oplog_peer_state:record_sync_complete(
            {peer, def_p_peer}, Id, LocalRoot
        ),
        bondy_oplog_peer_state:sync(),
        {ok, {compacted, _, _}} = bondy_oplog:compact(Id),
        {ok, W1, S1} = bondy_oplog:compaction_checkpoint(Id),
        ok = bondy_oplog:stop_instance(Id),
        {ok, _} = bondy_oplog:start_instance(Id, Opts),
        {ok, W2, S2} = bondy_oplog:compaction_checkpoint(Id),
        ?assertEqual(W1, W2),
        ?assertEqual(S1, S2)
    after
        bondy_oplog:stop_instance(Id),
        bondy_oplog_peer_state:forget_peer({peer, def_p_peer}),
        rmrf(Tmp)
    end.
