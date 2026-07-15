%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% EUnit suite for the asynchronous-seal split of `bondy_mst_pack_writer`:
%% `roll_incoming/1` (sync, instance-owned), `run_seal_job/1` (async,
%% worker-owned), and `complete_seal/2` (sync, instance-owned), plus the
%% read-union that keeps rolled pages visible mid-seal and the crash-recovery
%% that re-seals an interrupted roll on reopen.
%%
%% Covers:
%% 1. roll → run → complete round-trip: state transitions, on-disk files,
%%    and the sealed pages readable through a fresh reader.
%% 2. Read-union: pending_read / member / pending_hashes serve a rolled page
%%    from the in-flight `sealing` snapshot before the seal completes.
%% 3. Guards: no_op on empty pending; seal_in_flight on a second roll;
%%    id-mismatch / no-seal-in-flight on complete_seal.
%% 4. Recovery on reopen:
%%    - an uncommitted roll (worker never ran) is re-sealed.
%%    - an uncommitted roll whose worker ran but never committed is re-sealed
%%      (the orphan pack-<id> is cleaned then rebuilt).
%%    - an already-committed seal whose frozen file lingered is deleted, not
%%      double-sealed.
%% =============================================================================

-module(bondy_mst_pack_writer_async_seal_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_mst_pack.hrl").

%% =============================================================================
%% Fixture helpers
%% =============================================================================

mktemp_dir() ->
    Base = filename:join(
        [
            "/tmp",
            io_lib:format(
                "bondy_mst_pack_async_seal_test_~p_~p",
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

with_tmp_dir(Fun) ->
    Dir = mktemp_dir(),
    try
        Fun(Dir)
    after
        rmrf(Dir)
    end.

open_writer(Dir) ->
    bondy_mst_pack_writer:open(Dir, #{instance_id => <<"async-seal-test">>}).

sha256(Bin) ->
    crypto:hash(sha256, Bin).

pages(N) ->
    [
        list_to_binary(io_lib:format("page-~4..0b-body", [I]))
     || I <- lists:seq(1, N)
    ].

%% Appends each page, returns {Writer, [{Hash, Page}]}.
append_all(W0, Pages) ->
    lists:foldl(
        fun(Page, {W, Acc}) ->
            {ok, Hash, W1} = bondy_mst_pack_writer:append(W, Page),
            {W1, [{Hash, Page} | Acc]}
        end,
        {W0, []},
        Pages
    ).

incoming_path(Dir) ->
    bondy_mst_pack_paths:incoming_pack_path(Dir).

sealing_path(Dir, PackId) ->
    bondy_mst_pack_paths:incoming_sealing_path(Dir, PackId).

sealed_pack_path(Dir, PackId) ->
    bondy_mst_pack_paths:sealed_pack_path(Dir, PackId).

%% Reads every {Hash, Page} pair back via a fresh sealed-pack reader.
assert_all_readable(Dir, Pairs) ->
    {ok, R} = bondy_mst_pack_reader:open(Dir),
    try
        lists:foreach(
            fun({Hash, Page}) ->
                ?assertEqual({ok, Page}, bondy_mst_pack_reader:get(R, Hash))
            end,
            Pairs
        )
    after
        bondy_mst_pack_reader:close(R)
    end.

%% =============================================================================
%% roll → run → complete round-trip
%% =============================================================================

roll_run_complete_roundtrip_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer(Dir),
        {W1, Pairs} = append_all(W0, pages(5)),

        %% Roll the incoming pack aside.
        {ok, Job, W2} = bondy_mst_pack_writer:roll_incoming(W1),

        %% Writer reset to a fresh empty incoming; the rolled snapshot is
        %% held for the in-flight seal.
        ?assertEqual(0, bondy_mst_pack_writer:pending_count(W2)),
        ?assertEqual(0, bondy_mst_pack_writer:incoming_offset(W2)),
        ?assertEqual(1, bondy_mst_pack_writer:sealing_pack_id(W2)),
        ?assertEqual(2, bondy_mst_pack_writer:next_pack_id(W2)),

        %% On-disk: the frozen sealing file exists, incoming.pack is gone,
        %% and the manifest declares incoming_pack=absent (roll committed).
        ?assert(filelib:is_regular(sealing_path(Dir, 1))),
        ?assertNot(filelib:is_regular(incoming_path(Dir))),
        {ok, M0} = bondy_mst_pack_manifest:read(Dir),
        ?assertEqual(absent, bondy_mst_pack_manifest:incoming_pack(M0)),
        ?assertEqual([], bondy_mst_pack_manifest:sealed_packs(M0)),

        %% The seal job is self-contained.
        ?assertEqual(1, maps:get(pack_id, Job)),
        ?assertEqual(5, map_size(maps:get(bodies, Job))),

        %% Run the (async) job — writes pack-0001.{pack,idx}.
        ?assertEqual(ok, bondy_mst_pack_writer:run_seal_job(Job)),
        ?assert(filelib:is_regular(sealed_pack_path(Dir, 1))),

        %% Complete the seal — manifest commit + drop the snapshot + delete
        %% the frozen file.
        {ok, W3} = bondy_mst_pack_writer:complete_seal(W2, 1),
        ?assertEqual(undefined, bondy_mst_pack_writer:sealing_pack_id(W3)),
        {ok, M1} = bondy_mst_pack_manifest:read(Dir),
        ?assertEqual([1], bondy_mst_pack_manifest:sealed_packs(M1)),
        ?assertEqual(absent, bondy_mst_pack_manifest:incoming_pack(M1)),
        ?assertNot(filelib:is_regular(sealing_path(Dir, 1))),

        bondy_mst_pack_writer:close(W3),

        %% Every page is readable from the committed sealed pack.
        assert_all_readable(Dir, Pairs)
    end).

%% A roll that committed (absent), followed by appends to a fresh incoming
%% pack, leaves the manifest declaring incoming_pack=present and the new
%% page durable — complete_seal must NOT clobber that flag.
roll_then_append_preserves_present_flag_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer(Dir),
        {W1, Pairs} = append_all(W0, pages(3)),
        {ok, Job, W2} = bondy_mst_pack_writer:roll_incoming(W1),

        %% Append to the fresh incoming pack while the seal is "in flight".
        NewPage = <<"post-roll-page">>,
        {ok, NewHash, W3} = bondy_mst_pack_writer:append(W2, NewPage),
        {ok, M0} = bondy_mst_pack_manifest:read(Dir),
        ?assertEqual(present, bondy_mst_pack_manifest:incoming_pack(M0)),

        ?assertEqual(ok, bondy_mst_pack_writer:run_seal_job(Job)),
        {ok, W4} = bondy_mst_pack_writer:complete_seal(W3, 1),

        %% The fresh incoming pack is still live — flag stays present.
        {ok, M1} = bondy_mst_pack_manifest:read(Dir),
        ?assertEqual(present, bondy_mst_pack_manifest:incoming_pack(M1)),
        ?assertEqual([1], bondy_mst_pack_manifest:sealed_packs(M1)),

        %% The post-roll page is still pending; the rolled pages are sealed.
        ?assertEqual(
            {ok, NewPage}, bondy_mst_pack_writer:pending_read(W4, NewHash)
        ),
        bondy_mst_pack_writer:close(W4),
        assert_all_readable(Dir, Pairs)
    end).

%% =============================================================================
%% Read-union mid-seal
%% =============================================================================

reads_visible_during_seal_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer(Dir),
        {W1, Pairs} = append_all(W0, pages(4)),
        {ok, _Job, W2} = bondy_mst_pack_writer:roll_incoming(W1),

        %% pending is empty, but every rolled page is served from the
        %% in-flight sealing snapshot.
        ?assertEqual(0, bondy_mst_pack_writer:pending_count(W2)),
        ExpectedHashes = lists:sort([H || {H, _} <- Pairs]),
        ?assertEqual(ExpectedHashes, bondy_mst_pack_writer:pending_hashes(W2)),
        lists:foreach(
            fun({Hash, Page}) ->
                ?assert(bondy_mst_pack_writer:member(W2, Hash)),
                ?assertEqual(
                    {ok, Page}, bondy_mst_pack_writer:pending_read(W2, Hash)
                )
            end,
            Pairs
        ),
        %% An unknown hash is still absent.
        ?assertNot(bondy_mst_pack_writer:member(W2, sha256(<<"nope">>))),
        ?assertEqual(
            not_found,
            bondy_mst_pack_writer:pending_read(W2, sha256(<<"nope">>))
        ),
        bondy_mst_pack_writer:close(W2)
    end).

%% =============================================================================
%% Guards
%% =============================================================================

roll_noop_on_empty_pending_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer(Dir),
        ?assertMatch({no_op, _}, bondy_mst_pack_writer:roll_incoming(W0)),
        bondy_mst_pack_writer:close(W0)
    end).

roll_rejects_while_seal_in_flight_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer(Dir),
        {W1, _} = append_all(W0, pages(2)),
        {ok, _Job, W2} = bondy_mst_pack_writer:roll_incoming(W1),
        %% Append again so pending is non-empty, then attempt a second roll.
        {ok, _, W3} = bondy_mst_pack_writer:append(W2, <<"more">>),
        ?assertEqual(
            {error, seal_in_flight}, bondy_mst_pack_writer:roll_incoming(W3)
        ),
        bondy_mst_pack_writer:close(W3)
    end).

complete_seal_guards_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer(Dir),
        {W1, _} = append_all(W0, pages(2)),

        %% No seal in flight.
        ?assertEqual(
            {error, no_seal_in_flight},
            bondy_mst_pack_writer:complete_seal(W1, 1)
        ),

        {ok, Job, W2} = bondy_mst_pack_writer:roll_incoming(W1),
        ?assertEqual(ok, bondy_mst_pack_writer:run_seal_job(Job)),

        %% Wrong pack id.
        ?assertEqual(
            {error, {seal_id_mismatch, 1, 99}},
            bondy_mst_pack_writer:complete_seal(W2, 99)
        ),

        %% Correct id completes.
        ?assertMatch({ok, _}, bondy_mst_pack_writer:complete_seal(W2, 1)),
        bondy_mst_pack_writer:close(W2)
    end).

%% =============================================================================
%% Crash recovery on reopen
%% =============================================================================

%% Roll committed, worker never ran, crash. Reopen must re-seal the frozen
%% file into pack-0001 and make every page durable.
recovery_reseals_uncommitted_roll_no_worker_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer(Dir),
        {W1, Pairs} = append_all(W0, pages(6)),
        {ok, _Job, _W2} = bondy_mst_pack_writer:roll_incoming(W1),
        %% Simulate a crash: drop the writer WITHOUT running/completing the seal.
        ?assert(filelib:is_regular(sealing_path(Dir, 1))),
        ?assertNot(filelib:is_regular(sealed_pack_path(Dir, 1))),

        %% Reopen → recovery re-seals.
        {ok, WR} = open_writer(Dir),
        {ok, M} = bondy_mst_pack_manifest:read(Dir),
        ?assertEqual([1], bondy_mst_pack_manifest:sealed_packs(M)),
        ?assertEqual(absent, bondy_mst_pack_manifest:incoming_pack(M)),
        ?assertNot(filelib:is_regular(sealing_path(Dir, 1))),
        ?assert(filelib:is_regular(sealed_pack_path(Dir, 1))),
        bondy_mst_pack_writer:close(WR),

        assert_all_readable(Dir, Pairs)
    end).

%% Roll committed, worker ran (pack-0001 on disk) but complete never landed,
%% crash. Reopen must clean the orphan pack and re-seal from the frozen file.
recovery_reseals_uncommitted_roll_worker_ran_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer(Dir),
        {W1, Pairs} = append_all(W0, pages(6)),
        {ok, Job, _W2} = bondy_mst_pack_writer:roll_incoming(W1),
        ?assertEqual(ok, bondy_mst_pack_writer:run_seal_job(Job)),
        %% pack-0001 is on disk but NOT in the manifest (complete never ran).
        ?assert(filelib:is_regular(sealed_pack_path(Dir, 1))),
        {ok, M0} = bondy_mst_pack_manifest:read(Dir),
        ?assertEqual([], bondy_mst_pack_manifest:sealed_packs(M0)),

        %% Reopen → orphan pack cleaned, frozen file re-sealed.
        {ok, WR} = open_writer(Dir),
        {ok, M1} = bondy_mst_pack_manifest:read(Dir),
        ?assertEqual([1], bondy_mst_pack_manifest:sealed_packs(M1)),
        ?assertNot(filelib:is_regular(sealing_path(Dir, 1))),
        ?assert(filelib:is_regular(sealed_pack_path(Dir, 1))),
        bondy_mst_pack_writer:close(WR),

        assert_all_readable(Dir, Pairs)
    end).

%% A committed seal whose frozen file lingered (crash between manifest commit
%% and file delete) must be cleaned as an orphan on reopen, NOT re-sealed.
recovery_deletes_committed_sealing_orphan_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer(Dir),
        {W1, Pairs} = append_all(W0, pages(4)),
        {ok, Job, W2} = bondy_mst_pack_writer:roll_incoming(W1),
        SealingPath = sealing_path(Dir, 1),
        {ok, FrozenBytes} = file:read_file(SealingPath),
        ?assertEqual(ok, bondy_mst_pack_writer:run_seal_job(Job)),
        {ok, W3} = bondy_mst_pack_writer:complete_seal(W2, 1),
        bondy_mst_pack_writer:close(W3),
        %% complete_seal deleted the frozen file; resurrect it to simulate a
        %% crash before the delete landed.
        ?assertNot(filelib:is_regular(SealingPath)),
        ok = file:write_file(SealingPath, FrozenBytes),

        %% Reopen → the orphan is deleted, the pack is NOT re-sealed (id 1
        %% stays the only sealed pack; no pack-0002).
        {ok, WR} = open_writer(Dir),
        {ok, M} = bondy_mst_pack_manifest:read(Dir),
        ?assertEqual([1], bondy_mst_pack_manifest:sealed_packs(M)),
        ?assertNot(filelib:is_regular(SealingPath)),
        ?assertNot(filelib:is_regular(sealed_pack_path(Dir, 2))),
        bondy_mst_pack_writer:close(WR),

        assert_all_readable(Dir, Pairs)
    end).
