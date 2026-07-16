%% =============================================================================
%% EUnit + PropEr suite for `bondy_mst_pack_writer` and
%% `bondy_mst_pack_reader`. Covers:
%%
%% 1. Writer lifecycle:
%%    - open in an empty dir produces a fresh manifest + creates
%%      incoming.pack with just the header.
%%    - append round-trip: hash returned matches sha256(page),
%%      pending_lookup recovers offset, incoming_offset advances.
%%    - append is idempotent for a hash already in pending.
%%    - close/reopen preserves the pending map by scanning
%%      incoming.pack.
%% 2. Seal lifecycle:
%%    - seal on empty pending is a no-op.
%%    - seal materialises pack-NNNN.pack + pack-NNNN.idx and
%%      removes incoming.pack.
%%    - manifest reflects the new pack and incoming_pack=absent.
%%    - next_pack_id advances.
%%    - subsequent appends start a fresh incoming.pack.
%% 3. Reader:
%%    - open after seal sees every sealed pack.
%%    - get/2 returns the original page bytes for every appended
%%      hash; not_found for an arbitrary hash.
%%    - get/2 across multiple sealed packs short-circuits on the
%%      newest pack first.
%%    - list/1 enumerates every appended hash.
%%    - has/2 mirrors get/2's true/false answer.
%% 4. End-to-end PropEr:
%%    - For any sequence of N appends (with possible dedup hits),
%%      sealing + opening a reader resolves every distinct hash
%%      back to its original page.
%% =============================================================================

-module(bondy_mst_pack_writer_test).

-include_lib("proper/include/proper.hrl").
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
                "bondy_mst_pack_writer_test_~p_~p",
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
    bondy_mst_pack_writer:open(Dir, #{instance_id => <<"writer-test">>}).

sha256(Bin) ->
    crypto:hash(sha256, Bin).

%% =============================================================================
%% Open / close
%% =============================================================================

open_empty_dir_creates_manifest_lazy_incoming_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W} = open_writer(Dir),
        try
            %% Manifest exists on disk and matches the in-memory state.
            {ok, OnDisk} = bondy_mst_pack_manifest:read(Dir),
            ?assertEqual(
                bondy_mst_pack_manifest:instance_id(OnDisk),
                <<"writer-test">>
            ),
            ?assertEqual(sha256, bondy_mst_pack_manifest:hash_algo(OnDisk)),
            ?assertEqual([], bondy_mst_pack_manifest:sealed_packs(OnDisk)),
            ?assertEqual(
                absent,
                bondy_mst_pack_manifest:incoming_pack(OnDisk)
            ),
            %% Lazy creation: incoming.pack does NOT exist until the
            %% first append. This keeps `open ; close` cycles a no-op
            %% against the on-disk state.
            ?assertNot(
                filelib:is_regular(
                    bondy_mst_pack_paths:incoming_pack_path(Dir)
                )
            ),
            ?assertEqual(0, bondy_mst_pack_writer:incoming_offset(W)),
            ?assertEqual(1, bondy_mst_pack_writer:next_pack_id(W)),
            ?assertEqual(0, bondy_mst_pack_writer:pending_count(W))
        after
            bondy_mst_pack_writer:close(W)
        end
    end).

first_append_materialises_incoming_and_flips_manifest_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W} = open_writer(Dir),
        try
            {ok, _, W1} = bondy_mst_pack_writer:append(W, <<"x">>),
            ?assert(
                filelib:is_regular(
                    bondy_mst_pack_paths:incoming_pack_path(Dir)
                )
            ),
            %% 48-byte pack header + 40-byte record header + 1-byte page.
            ?assertEqual(
                48 + 40 + 1,
                bondy_mst_pack_writer:incoming_offset(W1)
            ),
            {ok, OnDisk} = bondy_mst_pack_manifest:read(Dir),
            ?assertEqual(
                present,
                bondy_mst_pack_manifest:incoming_pack(OnDisk)
            )
        after
            bondy_mst_pack_writer:close(W)
        end
    end).

open_missing_instance_id_rejected_test() ->
    with_tmp_dir(fun(Dir) ->
        ?assertEqual(
            {error, {missing_field, instance_id}},
            bondy_mst_pack_writer:open(Dir, #{})
        )
    end).

reopen_uses_existing_manifest_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W1} = open_writer(Dir),
        bondy_mst_pack_writer:close(W1),
        {ok, W2} = open_writer(Dir),
        try
            ?assertEqual(
                <<"writer-test">>,
                bondy_mst_pack_writer:instance_id(W2)
            ),
            ?assertEqual(0, bondy_mst_pack_writer:pending_count(W2))
        after
            bondy_mst_pack_writer:close(W2)
        end
    end).

reopen_with_different_instance_id_rejected_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W1} = open_writer(Dir),
        bondy_mst_pack_writer:close(W1),
        ?assertMatch(
            {error, {instance_id_mismatch, _, _}},
            bondy_mst_pack_writer:open(Dir, #{instance_id => <<"other">>})
        )
    end).

%% =============================================================================
%% Append
%% =============================================================================

append_returns_correct_hash_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W} = open_writer(Dir),
        try
            Page = <<"hello, world">>,
            {ok, Hash, W1} = bondy_mst_pack_writer:append(W, Page),
            ?assertEqual(sha256(Page), Hash),
            ?assertEqual(1, bondy_mst_pack_writer:pending_count(W1)),
            {ok, {_Off, Len}} = bondy_mst_pack_writer:pending_lookup(W1, Hash),
            ?assertEqual(byte_size(Page), Len)
        after
            bondy_mst_pack_writer:close(W)
        end
    end).

append_advances_offset_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W} = open_writer(Dir),
        try
            %% First append also writes the 48-byte pack header. Use a
            %% second append to verify the per-record delta.
            {ok, _, W1} = bondy_mst_pack_writer:append(W, <<"prime">>),
            Off1 = bondy_mst_pack_writer:incoming_offset(W1),
            Page = <<"hello">>,
            {ok, _, W2} = bondy_mst_pack_writer:append(W1, Page),
            Off2 = bondy_mst_pack_writer:incoming_offset(W2),
            ?assertEqual(Off1 + 40 + byte_size(Page), Off2)
        after
            bondy_mst_pack_writer:close(W)
        end
    end).

append_is_idempotent_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W} = open_writer(Dir),
        try
            Page = <<"dup">>,
            {ok, H, W1} = bondy_mst_pack_writer:append(W, Page),
            Off1 = bondy_mst_pack_writer:incoming_offset(W1),
            {ok, H, W2} = bondy_mst_pack_writer:append(W1, Page),
            %% Second append is a no-op: offset & pending unchanged.
            ?assertEqual(Off1, bondy_mst_pack_writer:incoming_offset(W2)),
            ?assertEqual(1, bondy_mst_pack_writer:pending_count(W2))
        after
            bondy_mst_pack_writer:close(W)
        end
    end).

append_then_reopen_preserves_pending_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W} = open_writer(Dir),
        Pages = [
            <<"page-", (integer_to_binary(I))/binary>>
         || I <- lists:seq(1, 5)
        ],
        W1 = lists:foldl(
            fun(P, Acc) ->
                {ok, _, A} = bondy_mst_pack_writer:append(Acc, P),
                A
            end,
            W,
            Pages
        ),
        Off = bondy_mst_pack_writer:incoming_offset(W1),
        Hashes = bondy_mst_pack_writer:pending_hashes(W1),
        bondy_mst_pack_writer:close(W1),
        {ok, W2} = open_writer(Dir),
        try
            ?assertEqual(Off, bondy_mst_pack_writer:incoming_offset(W2)),
            ?assertEqual(Hashes, bondy_mst_pack_writer:pending_hashes(W2))
        after
            bondy_mst_pack_writer:close(W2)
        end
    end).

%% Regression: prior to the resume_incoming fix, `scan_incoming` used
%% `pread` only — which does not move the fd's file pointer. The
%% pointer therefore stayed at offset 0 after resume, and the next
%% `prim_file:write` in `do_append` overwrote the 48-byte pack
%% header, surfacing on the next reopen as `{pending_scan, bad_magic}`.
%% Pin the fix: append after reopen must preserve the header and the
%% existing records, and a second reopen must scan cleanly.
append_after_reopen_preserves_header_and_existing_records_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer(Dir),
        {ok, _, W1} = bondy_mst_pack_writer:append(W0, <<"first">>),
        {ok, _, W2} = bondy_mst_pack_writer:append(W1, <<"second">>),
        OffBefore = bondy_mst_pack_writer:incoming_offset(W2),
        HashesBefore = bondy_mst_pack_writer:pending_hashes(W2),
        bondy_mst_pack_writer:close(W2),
        {ok, W3} = open_writer(Dir),
        {ok, _, W4} = bondy_mst_pack_writer:append(W3, <<"third">>),
        bondy_mst_pack_writer:close(W4),
        {ok, W5} = open_writer(Dir),
        try
            HashesAfter = bondy_mst_pack_writer:pending_hashes(W5),
            OffAfter = bondy_mst_pack_writer:incoming_offset(W5),
            %% All three appends survived the reopen — the post-reopen
            %% write went at `OffBefore`, not at 0.
            ?assertEqual(3, length(HashesAfter)),
            ?assertEqual(OffBefore + 40 + byte_size(<<"third">>), OffAfter),
            %% First two hashes from the original session are still
            %% present (bag equality — order is map iteration order).
            ?assertEqual(
                lists:sort(HashesBefore),
                lists:sort(HashesAfter -- [sha256(<<"third">>)])
            )
        after
            bondy_mst_pack_writer:close(W5)
        end
    end).

%% Regression: prior to the scan_incoming normalisation, a 48-byte
%% header with bad magic / bad version returned `{pending_scan, R}`,
%% which the store's `open/2` raised as `{pack_store_open,
%% {pending_scan, _}}` — not recoverable via `bondy_mst_pack_recovery`.
%% Pin the fix: corrupted header bytes now surface as
%% `needs_recovery` so the store-level recovery can reset the file.
corrupt_header_surfaces_as_needs_recovery_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer(Dir),
        {ok, _, W1} = bondy_mst_pack_writer:append(W0, <<"x">>),
        bondy_mst_pack_writer:close(W1),
        %% Zero out the 48-byte header — body remains intact but the
        %% magic is gone.
        Path = bondy_mst_pack_paths:incoming_pack_path(Dir),
        {ok, Fd} = prim_file:open(Path, [read, write, raw, binary]),
        {ok, 0} = prim_file:position(Fd, bof),
        ok = prim_file:write(Fd, <<0:(?BONDY_MST_PACK_HEADER_BYTES * 8)>>),
        ok = prim_file:close(Fd),
        ?assertEqual(
            {error, needs_recovery},
            bondy_mst_pack_writer:open(
                Dir, #{instance_id => <<"writer-test">>}
            )
        )
    end).

%% =============================================================================
%% Seal
%% =============================================================================

seal_on_empty_pending_is_noop_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W} = open_writer(Dir),
        try
            ?assertMatch({ok, no_op, _}, bondy_mst_pack_writer:seal(W))
        after
            bondy_mst_pack_writer:close(W)
        end
    end).

seal_materialises_pack_and_idx_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W} = open_writer(Dir),
        Pages = [<<"alpha">>, <<"beta">>, <<"gamma">>],
        W1 = lists:foldl(
            fun(P, Acc) ->
                {ok, _, A} = bondy_mst_pack_writer:append(Acc, P),
                A
            end,
            W,
            Pages
        ),
        {ok, PackId, W2} = bondy_mst_pack_writer:seal(W1),
        try
            ?assertEqual(1, PackId),
            ?assert(
                filelib:is_regular(
                    bondy_mst_pack_paths:sealed_pack_path(Dir, 1)
                )
            ),
            ?assert(
                filelib:is_regular(
                    bondy_mst_pack_paths:sealed_idx_path(Dir, 1)
                )
            ),
            %% Post-seal the writer is in fresh-state: no incoming fd,
            %% offset 0; the next append re-creates incoming.pack lazily.
            ?assertNot(
                filelib:is_regular(
                    bondy_mst_pack_paths:incoming_pack_path(Dir)
                )
            ),
            ?assertEqual(0, bondy_mst_pack_writer:incoming_offset(W2)),
            ?assertEqual(0, bondy_mst_pack_writer:pending_count(W2)),
            ?assertEqual(2, bondy_mst_pack_writer:next_pack_id(W2)),
            %% Manifest reflects the new pack.
            {ok, M} = bondy_mst_pack_manifest:read(Dir),
            ?assertEqual([1], bondy_mst_pack_manifest:sealed_packs(M)),
            ?assertEqual(
                absent,
                bondy_mst_pack_manifest:incoming_pack(M)
            )
        after
            bondy_mst_pack_writer:close(W2)
        end
    end).

seal_then_append_advances_to_next_pack_id_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W} = open_writer(Dir),
        {ok, _, W1} = bondy_mst_pack_writer:append(W, <<"first">>),
        {ok, 1, W2} = bondy_mst_pack_writer:seal(W1),
        {ok, _, W3} = bondy_mst_pack_writer:append(W2, <<"second">>),
        {ok, 2, W4} = bondy_mst_pack_writer:seal(W3),
        try
            ?assert(
                filelib:is_regular(
                    bondy_mst_pack_paths:sealed_pack_path(Dir, 1)
                )
            ),
            ?assert(
                filelib:is_regular(
                    bondy_mst_pack_paths:sealed_pack_path(Dir, 2)
                )
            ),
            {ok, M} = bondy_mst_pack_manifest:read(Dir),
            ?assertEqual([1, 2], bondy_mst_pack_manifest:sealed_packs(M)),
            ?assertEqual(3, bondy_mst_pack_writer:next_pack_id(W4))
        after
            bondy_mst_pack_writer:close(W4)
        end
    end).

%% =============================================================================
%% Orphan cleanup on open (design doc §10.1, step 2)
%% =============================================================================

orphan_pack_without_manifest_entry_deleted_on_reopen_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer(Dir),
        bondy_mst_pack_writer:close(W0),
        %% Inject an orphan pack id that the manifest never recorded.
        OrphanPack = bondy_mst_pack_paths:sealed_pack_path(Dir, 9999),
        ok = file:write_file(OrphanPack, <<"orphan body">>),
        ?assert(filelib:is_regular(OrphanPack)),
        {ok, W1} = open_writer(Dir),
        try
            ?assertNot(filelib:is_regular(OrphanPack))
        after
            bondy_mst_pack_writer:close(W1)
        end
    end).

orphan_idx_without_manifest_entry_deleted_on_reopen_test() ->
    %% A half-renamed seal can leave just `pack-NNNN.idx`. Same orphan
    %% rule applies.
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer(Dir),
        bondy_mst_pack_writer:close(W0),
        OrphanIdx = bondy_mst_pack_paths:sealed_idx_path(Dir, 9999),
        ok = file:write_file(OrphanIdx, <<"orphan idx">>),
        ?assert(filelib:is_regular(OrphanIdx)),
        {ok, W1} = open_writer(Dir),
        try
            ?assertNot(filelib:is_regular(OrphanIdx))
        after
            bondy_mst_pack_writer:close(W1)
        end
    end).

orphan_pack_and_idx_both_deleted_on_reopen_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer(Dir),
        bondy_mst_pack_writer:close(W0),
        OrphanPack = bondy_mst_pack_paths:sealed_pack_path(Dir, 9999),
        OrphanIdx = bondy_mst_pack_paths:sealed_idx_path(Dir, 9999),
        ok = file:write_file(OrphanPack, <<>>),
        ok = file:write_file(OrphanIdx, <<>>),
        {ok, W1} = open_writer(Dir),
        try
            ?assertNot(filelib:is_regular(OrphanPack)),
            ?assertNot(filelib:is_regular(OrphanIdx))
        after
            bondy_mst_pack_writer:close(W1)
        end
    end).

valid_sealed_pack_preserved_alongside_orphan_test() ->
    %% Seal a real pack, then inject an orphan id. Reopen and verify
    %% the manifest-referenced pack is untouched and the orphan is gone.
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer(Dir),
        {ok, _, W1} = bondy_mst_pack_writer:append(W0, <<"real">>),
        {ok, 1, W2} = bondy_mst_pack_writer:seal(W1),
        bondy_mst_pack_writer:close(W2),
        RealPack = bondy_mst_pack_paths:sealed_pack_path(Dir, 1),
        RealIdx = bondy_mst_pack_paths:sealed_idx_path(Dir, 1),
        OrphanPack = bondy_mst_pack_paths:sealed_pack_path(Dir, 7),
        OrphanIdx = bondy_mst_pack_paths:sealed_idx_path(Dir, 7),
        ok = file:write_file(OrphanPack, <<"junk">>),
        ok = file:write_file(OrphanIdx, <<"junk">>),
        {ok, W3} = open_writer(Dir),
        try
            ?assert(filelib:is_regular(RealPack)),
            ?assert(filelib:is_regular(RealIdx)),
            ?assertNot(filelib:is_regular(OrphanPack)),
            ?assertNot(filelib:is_regular(OrphanIdx)),
            %% Manifest still records the valid pack.
            {ok, M} = bondy_mst_pack_manifest:read(Dir),
            ?assertEqual([1], bondy_mst_pack_manifest:sealed_packs(M))
        after
            bondy_mst_pack_writer:close(W3)
        end
    end).

tmp_pack_artefact_deleted_on_reopen_test() ->
    %% `.pack.tmp` from an interrupted rename — always orphan.
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer(Dir),
        bondy_mst_pack_writer:close(W0),
        TmpPack = bondy_mst_pack_paths:sealed_pack_tmp_path(Dir, 1),
        ok = file:write_file(TmpPack, <<"tmp">>),
        {ok, W1} = open_writer(Dir),
        try
            ?assertNot(filelib:is_regular(TmpPack))
        after
            bondy_mst_pack_writer:close(W1)
        end
    end).

tmp_idx_artefact_deleted_on_reopen_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer(Dir),
        bondy_mst_pack_writer:close(W0),
        TmpIdx = bondy_mst_pack_paths:sealed_idx_tmp_path(Dir, 1),
        ok = file:write_file(TmpIdx, <<"tmp">>),
        {ok, W1} = open_writer(Dir),
        try
            ?assertNot(filelib:is_regular(TmpIdx))
        after
            bondy_mst_pack_writer:close(W1)
        end
    end).

tmp_artefact_deleted_even_when_id_is_in_manifest_test() ->
    %% A `.tmp` sibling of a *valid* sealed pack is also deleted —
    %% it's always a mid-rename artefact and cannot be the source
    %% of truth after a crash.
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer(Dir),
        {ok, _, W1} = bondy_mst_pack_writer:append(W0, <<"a">>),
        {ok, 1, W2} = bondy_mst_pack_writer:seal(W1),
        bondy_mst_pack_writer:close(W2),
        TmpPack = bondy_mst_pack_paths:sealed_pack_tmp_path(Dir, 1),
        TmpIdx = bondy_mst_pack_paths:sealed_idx_tmp_path(Dir, 1),
        ok = file:write_file(TmpPack, <<"residue">>),
        ok = file:write_file(TmpIdx, <<"residue">>),
        {ok, W3} = open_writer(Dir),
        try
            ?assertNot(filelib:is_regular(TmpPack)),
            ?assertNot(filelib:is_regular(TmpIdx)),
            %% Real files unchanged.
            ?assert(
                filelib:is_regular(
                    bondy_mst_pack_paths:sealed_pack_path(Dir, 1)
                )
            ),
            ?assert(
                filelib:is_regular(
                    bondy_mst_pack_paths:sealed_idx_path(Dir, 1)
                )
            )
        after
            bondy_mst_pack_writer:close(W3)
        end
    end).

non_pack_files_left_alone_test() ->
    %% Anything not matching `pack-<digits>.(pack|idx)[.tmp]` is none
    %% of the scanner's business — manifests, root file, future
    %% filenames, stray notes from operators, etc.
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer(Dir),
        bondy_mst_pack_writer:close(W0),
        Stray = filename:join(Dir, "operator-notes.txt"),
        WeirdName = filename:join(Dir, "pack-without-digits.pack"),
        ok = file:write_file(Stray, <<"do not delete">>),
        ok = file:write_file(WeirdName, <<"also keep">>),
        {ok, W1} = open_writer(Dir),
        try
            ?assert(filelib:is_regular(Stray)),
            ?assert(filelib:is_regular(WeirdName))
        after
            bondy_mst_pack_writer:close(W1)
        end
    end).

orphan_cleanup_runs_before_incoming_resume_test() ->
    %% Mixed scenario: real sealed pack #1, orphan #7, incoming.pack
    %% with one record. Reopen must clean orphans AND resume the
    %% pending map from the incoming pack.
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer(Dir),
        {ok, _, W1} = bondy_mst_pack_writer:append(W0, <<"sealed">>),
        {ok, 1, W2} = bondy_mst_pack_writer:seal(W1),
        {ok, _, W3} = bondy_mst_pack_writer:append(W2, <<"pending">>),
        bondy_mst_pack_writer:close(W3),
        OrphanPack = bondy_mst_pack_paths:sealed_pack_path(Dir, 7),
        ok = file:write_file(OrphanPack, <<"orphan">>),
        {ok, W4} = open_writer(Dir),
        try
            ?assertNot(filelib:is_regular(OrphanPack)),
            ?assertEqual(1, bondy_mst_pack_writer:pending_count(W4))
        after
            bondy_mst_pack_writer:close(W4)
        end
    end).

%% =============================================================================
%% Reader — basic
%% =============================================================================

reader_open_no_sealed_packs_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W} = open_writer(Dir),
        bondy_mst_pack_writer:close(W),
        {ok, R} = bondy_mst_pack_reader:open(Dir),
        try
            ?assertEqual([], bondy_mst_pack_reader:sealed_pack_ids(R)),
            ?assertEqual([], bondy_mst_pack_reader:list(R)),
            ?assertEqual(
                not_found,
                bondy_mst_pack_reader:get(R, sha256(<<"nope">>))
            )
        after
            bondy_mst_pack_reader:close(R)
        end
    end).

reader_resolves_every_sealed_page_test() ->
    with_tmp_dir(fun(Dir) ->
        Pages = [<<"alpha">>, <<"beta">>, <<"gamma">>, <<"delta">>],
        Hashes = seal_pages(Dir, Pages),
        {ok, R} = bondy_mst_pack_reader:open(Dir),
        try
            ?assertEqual([1], bondy_mst_pack_reader:sealed_pack_ids(R)),
            lists:foreach(
                fun({H, P}) ->
                    ?assertEqual({ok, P}, bondy_mst_pack_reader:get(R, H)),
                    ?assert(bondy_mst_pack_reader:has(R, H))
                end,
                lists:zip(Hashes, Pages)
            ),
            ?assertEqual(
                not_found,
                bondy_mst_pack_reader:get(
                    R,
                    sha256(<<"missing">>)
                )
            ),
            ?assertNot(bondy_mst_pack_reader:has(R, sha256(<<"missing">>))),
            ?assertEqual(lists:sort(Hashes), bondy_mst_pack_reader:list(R))
        after
            bondy_mst_pack_reader:close(R)
        end
    end).

reader_iterates_multi_pack_test() ->
    with_tmp_dir(fun(Dir) ->
        PagesA = [<<"a1">>, <<"a2">>, <<"a3">>],
        PagesB = [<<"b1">>, <<"b2">>],
        HashesA = seal_pages(Dir, PagesA),
        HashesB = seal_pages(Dir, PagesB),
        {ok, R} = bondy_mst_pack_reader:open(Dir),
        try
            ?assertEqual([2, 1], bondy_mst_pack_reader:sealed_pack_ids(R)),
            All = lists:zip(HashesA ++ HashesB, PagesA ++ PagesB),
            lists:foreach(
                fun({H, P}) ->
                    ?assertEqual({ok, P}, bondy_mst_pack_reader:get(R, H))
                end,
                All
            ),
            ?assertEqual(
                lists:sort(HashesA ++ HashesB),
                bondy_mst_pack_reader:list(R)
            )
        after
            bondy_mst_pack_reader:close(R)
        end
    end).

reader_open_missing_manifest_test() ->
    with_tmp_dir(fun(Dir) ->
        ?assertMatch(
            {error, {manifest, enoent}},
            bondy_mst_pack_reader:open(Dir)
        )
    end).

%% =============================================================================
%% PropEr — end-to-end
%% =============================================================================

proper_writer_test_() ->
    Opts = [{numtests, 50}, {to_file, user}],
    [
        {timeout, 60, ?_assert(proper:quickcheck(prop_seal_then_read(), Opts))}
    ].

prop_seal_then_read() ->
    ?FORALL(
        Pages,
        ?LET(
            N,
            choose(0, 30),
            vector(N, ?LET(M, choose(0, 64), binary(M)))
        ),
        with_tmp_dir_prop(fun(Dir) ->
            UniqueByHash = uniq_by_hash(Pages),
            {ok, W0} = open_writer(Dir),
            W1 = lists:foldl(
                fun(P, Acc) ->
                    {ok, _, A} = bondy_mst_pack_writer:append(Acc, P),
                    A
                end,
                W0,
                Pages
            ),
            ResultSeal = bondy_mst_pack_writer:seal(W1),
            ok = bondy_mst_pack_writer:close(
                case ResultSeal of
                    {ok, no_op, X} -> X;
                    {ok, _, X} -> X
                end
            ),
            {ok, R} = bondy_mst_pack_reader:open(Dir),
            try
                lists:all(
                    fun({H, P}) ->
                        {ok, P} =:= bondy_mst_pack_reader:get(R, H)
                    end,
                    UniqueByHash
                )
            after
                bondy_mst_pack_reader:close(R)
            end
        end)
    ).

%% =============================================================================
%% Batched datasync policy
%% =============================================================================

open_writer_k(Dir, K) ->
    bondy_mst_pack_writer:open(
        Dir,
        #{instance_id => <<"writer-test">>, sync_every_records => K}
    ).

open_writer_t(Dir, TMs) ->
    bondy_mst_pack_writer:open(
        Dir,
        #{instance_id => <<"writer-test">>, sync_every_ms => TMs}
    ).

default_policy_batches_appends_test() ->
    %% Default `sync_every_records` (32, see bondy_mst_pack.hrl) means
    %% the first few appends are buffered without datasync. Production
    %% callers needing per-record durability set `sync_every_records=1`
    %% explicitly (covered by k=1 tests below).
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer(Dir),
        try
            {ok, _, W1} = bondy_mst_pack_writer:append(W0, <<"a">>),
            ?assertEqual(1, bondy_mst_pack_writer:unsynced_count(W1)),
            {ok, _, W2} = bondy_mst_pack_writer:append(W1, <<"b">>),
            ?assertEqual(2, bondy_mst_pack_writer:unsynced_count(W2))
        after
            bondy_mst_pack_writer:close(W0)
        end
    end).

k_batching_buffers_until_threshold_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer_k(Dir, 4),
        try
            %% Three appends: still buffered.
            {ok, _, W1} = bondy_mst_pack_writer:append(W0, <<"a">>),
            ?assertEqual(1, bondy_mst_pack_writer:unsynced_count(W1)),
            {ok, _, W2} = bondy_mst_pack_writer:append(W1, <<"b">>),
            ?assertEqual(2, bondy_mst_pack_writer:unsynced_count(W2)),
            {ok, _, W3} = bondy_mst_pack_writer:append(W2, <<"c">>),
            ?assertEqual(3, bondy_mst_pack_writer:unsynced_count(W3)),
            %% Fourth append crosses K=4 and triggers a flush.
            {ok, _, W4} = bondy_mst_pack_writer:append(W3, <<"d">>),
            ?assertEqual(0, bondy_mst_pack_writer:unsynced_count(W4))
        after
            bondy_mst_pack_writer:close(W0)
        end
    end).

flush_drains_unsynced_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer_k(Dir, 1000),
        try
            W1 = lists:foldl(
                fun(I, Acc) ->
                    {ok, _, A} = bondy_mst_pack_writer:append(
                        Acc, integer_to_binary(I)
                    ),
                    A
                end,
                W0,
                lists:seq(1, 5)
            ),
            ?assertEqual(5, bondy_mst_pack_writer:unsynced_count(W1)),
            {ok, W2} = bondy_mst_pack_writer:flush(W1),
            ?assertEqual(0, bondy_mst_pack_writer:unsynced_count(W2)),
            %% Calling flush again is a no-op.
            {ok, W3} = bondy_mst_pack_writer:flush(W2),
            ?assertEqual(0, bondy_mst_pack_writer:unsynced_count(W3))
        after
            bondy_mst_pack_writer:close(W0)
        end
    end).

flush_no_op_before_first_append_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer_k(Dir, 100),
        try
            %% incoming.pack hasn't been created yet — flush is a no-op.
            {ok, W1} = bondy_mst_pack_writer:flush(W0),
            ?assertEqual(0, bondy_mst_pack_writer:unsynced_count(W1)),
            ?assertNot(
                filelib:is_regular(
                    bondy_mst_pack_paths:incoming_pack_path(Dir)
                )
            )
        after
            bondy_mst_pack_writer:close(W0)
        end
    end).

close_flushes_unsynced_records_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer_k(Dir, 1000),
        %% Append 5 records and close — close must flush so that
        %% on reopen we still see them.
        Pages = [<<I>> || I <- lists:seq(1, 5)],
        Hashes = lists:foldl(
            fun(P, {Hs, Acc}) ->
                {ok, H, A} = bondy_mst_pack_writer:append(Acc, P),
                {[H | Hs], A}
            end,
            {[], W0},
            Pages
        ),
        {HashList, W1} = Hashes,
        ?assertEqual(5, bondy_mst_pack_writer:unsynced_count(W1)),
        ok = bondy_mst_pack_writer:close(W1),
        {ok, W2} = open_writer_k(Dir, 1000),
        try
            ?assertEqual(5, bondy_mst_pack_writer:pending_count(W2)),
            ?assertEqual(
                lists:sort(HashList),
                bondy_mst_pack_writer:pending_hashes(W2)
            )
        after
            bondy_mst_pack_writer:close(W2)
        end
    end).

seal_works_with_high_k_test() ->
    %% With K well above the number of appends, no per-append sync
    %% happens — seal still produces a correct sealed pack because
    %% the OS page cache makes unsynced writes visible to preads on
    %% the same fd, and the sealed pack is itself datasync'd.
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer_k(Dir, 1000),
        Pages = [<<I>> || I <- lists:seq(1, 10)],
        W1 = lists:foldl(
            fun(P, Acc) ->
                {ok, _, A} = bondy_mst_pack_writer:append(Acc, P),
                A
            end,
            W0,
            Pages
        ),
        ?assertEqual(10, bondy_mst_pack_writer:unsynced_count(W1)),
        {ok, 1, W2} = bondy_mst_pack_writer:seal(W1),
        try
            %% Post-seal state is fresh — no pending, no unsynced.
            ?assertEqual(0, bondy_mst_pack_writer:unsynced_count(W2)),
            ?assertEqual(0, bondy_mst_pack_writer:pending_count(W2)),
            %% Sealed pack on disk should resolve every hash via the
            %% reader.
            {ok, R} = bondy_mst_pack_reader:open(Dir),
            try
                ExpectedHashes = [sha256(P) || P <- Pages],
                lists:foreach(
                    fun({P, H}) ->
                        ?assertEqual({ok, P}, bondy_mst_pack_reader:get(R, H))
                    end,
                    lists:zip(Pages, ExpectedHashes)
                )
            after
                bondy_mst_pack_reader:close(R)
            end
        after
            bondy_mst_pack_writer:close(W2)
        end
    end).

t_threshold_fires_eventually_test() ->
    %% The ms-threshold `T` must sit COMFORTABLY above the wall-clock cost of a
    %% single record write, or the first append itself can trip it: `do_append`
    %% checks `now - last_sync_ms >= T` AFTER writing the record, and although
    %% `flip_manifest_to_present` rebases `last_sync_ms` to "now" at incoming-pack
    %% creation, the tiny window that remains (one `prim_file:write`) can still
    %% exceed a pathologically small `T` under heavy full-suite load with /tmp
    %% contention — spuriously syncing the first append (`unsynced_count` 0, not
    %% 1). A former `T=1ms` was below that jitter and flaked. Use 30ms (matching
    %% `set_root_ms_threshold_flushes_eventually_test`), far above single-write
    %% jitter, and pace the second append behind a 60ms sleep (> T) so the
    %% ms-trigger on it is deterministic. Still exercises the ms path end to end.
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = bondy_mst_pack_writer:open(
            Dir,
            #{
                instance_id => <<"writer-test">>,
                sync_every_records => 1000,
                sync_every_ms => 30
            }
        ),
        try
            {ok, _, W1} = bondy_mst_pack_writer:append(W0, <<"a">>),
            ?assertEqual(1, bondy_mst_pack_writer:unsynced_count(W1)),
            timer:sleep(60),
            {ok, _, W2} = bondy_mst_pack_writer:append(W1, <<"b">>),
            ?assertEqual(0, bondy_mst_pack_writer:unsynced_count(W2))
        after
            bondy_mst_pack_writer:close(W0)
        end
    end).

%% =============================================================================
%% Rename-failure fault injection
%%
%% Inject `{error, eio}` at each rename point in the seal flow via
%% the `bondy_mst_io:rename/2` seam and verify (a) the seal
%% returns a typed error, (b) the on-disk state immediately after
%% failure matches the expected partial state, and (c) reopening
%% with the orphan scanner produces a clean directory and an
%% intact manifest.
%% =============================================================================

pack_rename_failure_returns_seal_error_test() ->
    %% Failure at step 3a (PackTmp → Pack). `create_sealed_pack/6`
    %% runs `cleanup_tmp/2` so neither `.tmp` survives; the manifest
    %% is unchanged.
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer(Dir),
        {ok, _, W1} = bondy_mst_pack_writer:append(W0, <<"a">>),
        SealRes = with_rename_fault(
            ".pack.tmp",
            eio,
            fun() -> bondy_mst_pack_writer:seal(W1) end
        ),
        ?assertMatch({error, {seal, {rename_pack, eio}}}, SealRes),
        bondy_mst_pack_writer:close(W1),
        %% No artefacts left over by `create_sealed_pack`'s cleanup.
        PackTmp = bondy_mst_pack_paths:sealed_pack_tmp_path(Dir, 1),
        IdxTmp = bondy_mst_pack_paths:sealed_idx_tmp_path(Dir, 1),
        ?assertNot(filelib:is_regular(PackTmp)),
        ?assertNot(filelib:is_regular(IdxTmp)),
        %% Manifest unchanged: still no sealed packs, incoming present.
        {ok, M} = bondy_mst_pack_manifest:read(Dir),
        ?assertEqual([], bondy_mst_pack_manifest:sealed_packs(M)),
        ?assertEqual(present, bondy_mst_pack_manifest:incoming_pack(M)),
        %% Reopen: orphan scanner has nothing to do, pending map is
        %% restored from incoming.pack.
        {ok, W2} = open_writer(Dir),
        try
            ?assertEqual(1, bondy_mst_pack_writer:pending_count(W2))
        after
            bondy_mst_pack_writer:close(W2)
        end
    end).

idx_rename_failure_returns_seal_error_test() ->
    %% Failure at step 3b (IdxTmp → Idx) after the pack rename
    %% succeeded. `rename_sealed_pair/2` deletes the now-renamed
    %% `pack-NNNN.pack`, then `create_sealed_pack/6` runs
    %% `cleanup_tmp/2`. Result: nothing on disk.
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer(Dir),
        {ok, _, W1} = bondy_mst_pack_writer:append(W0, <<"a">>),
        SealRes = with_rename_fault(
            ".idx.tmp",
            eio,
            fun() -> bondy_mst_pack_writer:seal(W1) end
        ),
        ?assertMatch({error, {seal, {rename_idx, eio}}}, SealRes),
        bondy_mst_pack_writer:close(W1),
        Pack = bondy_mst_pack_paths:sealed_pack_path(Dir, 1),
        Idx = bondy_mst_pack_paths:sealed_idx_path(Dir, 1),
        PackTmp = bondy_mst_pack_paths:sealed_pack_tmp_path(Dir, 1),
        IdxTmp = bondy_mst_pack_paths:sealed_idx_tmp_path(Dir, 1),
        ?assertNot(filelib:is_regular(Pack)),
        ?assertNot(filelib:is_regular(Idx)),
        ?assertNot(filelib:is_regular(PackTmp)),
        ?assertNot(filelib:is_regular(IdxTmp)),
        {ok, M} = bondy_mst_pack_manifest:read(Dir),
        ?assertEqual([], bondy_mst_pack_manifest:sealed_packs(M)),
        ?assertEqual(present, bondy_mst_pack_manifest:incoming_pack(M)),
        {ok, W2} = open_writer(Dir),
        try
            ?assertEqual(1, bondy_mst_pack_writer:pending_count(W2))
        after
            bondy_mst_pack_writer:close(W2)
        end
    end).

manifest_rename_failure_leaves_orphan_pack_and_idx_test() ->
    %% Failure at step 4 (manifest swap) after both pack + idx
    %% renames succeeded. `pack-0001.{pack,idx}` are on disk but the
    %% manifest still says no sealed packs and incoming present —
    %% they are orphans by the seal-step-3-vs-step-4 crash window.
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer(Dir),
        {ok, _, W1} = bondy_mst_pack_writer:append(W0, <<"a">>),
        SealRes = with_rename_fault(
            "manifest.tmp",
            eio,
            fun() -> bondy_mst_pack_writer:seal(W1) end
        ),
        ?assertMatch({error, {manifest, eio}}, SealRes),
        bondy_mst_pack_writer:close(W1),
        Pack = bondy_mst_pack_paths:sealed_pack_path(Dir, 1),
        Idx = bondy_mst_pack_paths:sealed_idx_path(Dir, 1),
        %% Orphan state on disk.
        ?assert(filelib:is_regular(Pack)),
        ?assert(filelib:is_regular(Idx)),
        %% Manifest reverted by `manifest:write/2`'s own cleanup
        %% (deletes manifest.tmp on rename failure); old manifest is
        %% authoritative — no sealed packs.
        {ok, M} = bondy_mst_pack_manifest:read(Dir),
        ?assertEqual([], bondy_mst_pack_manifest:sealed_packs(M)),
        ?assertEqual(present, bondy_mst_pack_manifest:incoming_pack(M)),
        %% Reopen → orphan scanner deletes the half-committed pair.
        {ok, W2} = open_writer(Dir),
        try
            ?assertNot(filelib:is_regular(Pack)),
            ?assertNot(filelib:is_regular(Idx)),
            ?assertEqual(1, bondy_mst_pack_writer:pending_count(W2)),
            %% Retry seal works against a fresh slot.
            {ok, 1, W3} = bondy_mst_pack_writer:seal(W2),
            ?assert(filelib:is_regular(Pack)),
            ?assert(filelib:is_regular(Idx)),
            bondy_mst_pack_writer:close(W3)
        catch
            _:E:S ->
                bondy_mst_pack_writer:close(W2),
                erlang:raise(error, E, S)
        end
    end).

manifest_rename_failure_at_present_flip_test() ->
    %% Adjacent rename point: first-append manifest flip-to-`present`
    %% (in `flip_manifest_to_present/3`). Failure leaves an
    %% incoming.pack on disk that the manifest still declares
    %% `absent`. The writer rolls back by deleting the just-created
    %% file; reopen finds a clean fresh state.
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer(Dir),
        AppendRes = with_rename_fault(
            "manifest.tmp",
            eio,
            fun() -> bondy_mst_pack_writer:append(W0, <<"never lands">>) end
        ),
        ?assertMatch({error, {manifest, eio}}, AppendRes),
        bondy_mst_pack_writer:close(W0),
        IncomingPath =
            bondy_mst_pack_paths:incoming_pack_path(Dir),
        ?assertNot(filelib:is_regular(IncomingPath)),
        {ok, M} = bondy_mst_pack_manifest:read(Dir),
        ?assertEqual(absent, bondy_mst_pack_manifest:incoming_pack(M)),
        {ok, W1} = open_writer(Dir),
        try
            ?assertEqual(0, bondy_mst_pack_writer:pending_count(W1)),
            ?assertEqual(1, bondy_mst_pack_writer:next_pack_id(W1))
        after
            bondy_mst_pack_writer:close(W1)
        end
    end).

%% =============================================================================
%% Helpers
%% =============================================================================

%% @private Selectively fails `bondy_mst_io:rename/2` calls whose
%% source path ends with `Suffix`. Other renames pass through. Holds the
%% same global lock as the WAL fault tests so concurrent suites don't
%% see each other's mocks.
with_rename_fault(Suffix, Reason, Body) ->
    with_io_fault_lock(fun() ->
        meck:expect(
            bondy_mst_io,
            rename,
            fun(From, To) ->
                FromStr = unicode:characters_to_list(From),
                case lists:suffix(Suffix, FromStr) of
                    true -> {error, Reason};
                    false -> meck:passthrough([From, To])
                end
            end
        ),
        Body()
    end).

%% @private Same shape as `bondy_oplog_wal_proper_test:with_io_fault_lock/1`.
%% Acquires a node-scoped global lock so sibling suites that fault-inject
%% `bondy_mst_io` cannot collide. The lock resource is keyed by the MOCKED
%% module (NOT `?MODULE`) so it is the SAME resource those sibling suites
%% contend on — a `?MODULE`-scoped key would give no cross-suite exclusion.
with_io_fault_lock(Body) ->
    Lock = {meck_vm_lock, bondy_mst_io},
    global:trans(
        {Lock, self()},
        fun() ->
            ok = meck:new(bondy_mst_io, [passthrough]),
            try
                Body()
            after
                _ = meck:unload(bondy_mst_io)
            end
        end,
        [node()],
        infinity
    ).

%% @private Open + append + seal in one shot; returns the hashes (in
%% append order). Closes the writer.
seal_pages(Dir, Pages) ->
    {ok, W} = open_writer(Dir),
    {Hashes, W1} = lists:foldl(
        fun(P, {Hs, Acc}) ->
            {ok, H, A} = bondy_mst_pack_writer:append(Acc, P),
            {[H | Hs], A}
        end,
        {[], W},
        Pages
    ),
    case bondy_mst_pack_writer:seal(W1) of
        {ok, no_op, W2} ->
            bondy_mst_pack_writer:close(W2);
        {ok, PackId, W2} when is_integer(PackId) ->
            bondy_mst_pack_writer:close(W2)
    end,
    lists:reverse(Hashes).

%% @private Dedup pages by sha256 hash, keep first occurrence.
uniq_by_hash(Pages) ->
    {Seen, Acc} = lists:foldl(
        fun(P, {S, A}) ->
            H = sha256(P),
            case maps:is_key(H, S) of
                true -> {S, A};
                false -> {S#{H => true}, [{H, P} | A]}
            end
        end,
        {#{}, []},
        Pages
    ),
    _ = Seen,
    lists:reverse(Acc).

%% @private PropEr expects pure booleans; the standard with_tmp_dir
%% returns whatever its callback returns, so wrap.
with_tmp_dir_prop(Fun) ->
    Dir = mktemp_dir(),
    try
        Fun(Dir)
    after
        rmrf(Dir)
    end.

%% =============================================================================
%% Root-flush debounce (set_root)
%% =============================================================================
%%
%% `set_root/2` rewrites the manifest. Each rewrite costs 4 fsyncs
%% (tmp+datasync+rename+fsync_dir). The MST applier issues one
%% set_root per drain batch, so without debouncing the per-call
%% chain serialises the entire write path. These tests verify the
%% debounce knobs (`root_flush_every_records` / `root_flush_every_ms`)
%% so calls under threshold update the in-memory manifest but skip
%% the disk write, while seal / explicit flush / close force-write
%% any pending root.

open_writer_root(Dir, RootEveryRecords, RootEveryMs) ->
    bondy_mst_pack_writer:open(
        Dir,
        #{
            instance_id => <<"writer-test">>,
            %% Keep the data-path policy out of the way so we're
            %% isolating manifest-write behaviour.
            sync_every_records => 1000,
            sync_every_ms => infinity,
            root_flush_every_records => RootEveryRecords,
            root_flush_every_ms => RootEveryMs
        }
    ).

disk_root(Dir) ->
    {ok, M} = bondy_mst_pack_manifest:read(Dir),
    bondy_mst_pack_manifest:current_root(M).

mem_root(W) ->
    bondy_mst_pack_manifest:current_root(bondy_mst_pack_writer:manifest(W)).

set_root_below_threshold_does_not_touch_manifest_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer_root(Dir, 4, infinity),
        try
            R1 = sha256(<<"root-1">>),
            R2 = sha256(<<"root-2">>),
            R3 = sha256(<<"root-3">>),
            {ok, W1} = bondy_mst_pack_writer:set_root(W0, R1),
            {ok, W2} = bondy_mst_pack_writer:set_root(W1, R2),
            {ok, W3} = bondy_mst_pack_writer:set_root(W2, R3),
            ?assertEqual(R3, mem_root(W3)),
            ?assertEqual(undefined, disk_root(Dir))
        after
            bondy_mst_pack_writer:close(W0)
        end
    end).

set_root_threshold_flushes_to_manifest_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer_root(Dir, 3, infinity),
        try
            R1 = sha256(<<"root-1">>),
            R2 = sha256(<<"root-2">>),
            R3 = sha256(<<"root-3">>),
            {ok, W1} = bondy_mst_pack_writer:set_root(W0, R1),
            {ok, W2} = bondy_mst_pack_writer:set_root(W1, R2),
            ?assertEqual(undefined, disk_root(Dir)),
            %% Third call crosses the records=3 threshold.
            {ok, W3} = bondy_mst_pack_writer:set_root(W2, R3),
            ?assertEqual(R3, mem_root(W3)),
            ?assertEqual(R3, disk_root(Dir))
        after
            bondy_mst_pack_writer:close(W0)
        end
    end).

set_root_ms_threshold_flushes_eventually_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer_root(Dir, infinity, 30),
        try
            R1 = sha256(<<"root-1">>),
            R2 = sha256(<<"root-2">>),
            {ok, W1} = bondy_mst_pack_writer:set_root(W0, R1),
            ?assertEqual(undefined, disk_root(Dir)),
            timer:sleep(60),
            %% Next set_root past the 30 ms wall-clock threshold flushes.
            {ok, W2} = bondy_mst_pack_writer:set_root(W1, R2),
            ?assertEqual(R2, disk_root(Dir)),
            _ = W2,
            ok
        after
            bondy_mst_pack_writer:close(W0)
        end
    end).

flush_persists_pending_root_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer_root(Dir, infinity, infinity),
        try
            R = sha256(<<"root-X">>),
            {ok, W1} = bondy_mst_pack_writer:set_root(W0, R),
            ?assertEqual(undefined, disk_root(Dir)),
            {ok, _W2} = bondy_mst_pack_writer:flush(W1),
            ?assertEqual(R, disk_root(Dir))
        after
            bondy_mst_pack_writer:close(W0)
        end
    end).

close_persists_pending_root_test() ->
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer_root(Dir, infinity, infinity),
        R = sha256(<<"root-Y">>),
        {ok, W1} = bondy_mst_pack_writer:set_root(W0, R),
        ?assertEqual(undefined, disk_root(Dir)),
        ok = bondy_mst_pack_writer:close(W1),
        ?assertEqual(R, disk_root(Dir))
    end).

seal_carries_pending_root_test() ->
    %% A pending root and a non-empty pending set: seal already
    %% rewrites the manifest, so the staged root rides along for
    %% free. Verify the on-disk root matches the staged value
    %% after seal returns.
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer_root(Dir, infinity, infinity),
        try
            R = sha256(<<"root-Z">>),
            {ok, _, W1} = bondy_mst_pack_writer:append(W0, <<"page-1">>),
            {ok, W2} = bondy_mst_pack_writer:set_root(W1, R),
            ?assertEqual(undefined, disk_root(Dir)),
            {ok, _PackId, _W3} = bondy_mst_pack_writer:seal(W2),
            ?assertEqual(R, disk_root(Dir))
        after
            bondy_mst_pack_writer:close(W0)
        end
    end).

empty_seal_with_pending_root_flushes_test() ->
    %% No pending records, manifest already absent: seal would
    %% normally be a pure no-op, but a staged root must still be
    %% flushed so callers can rely on `seal/1` as a durability
    %% boundary.
    with_tmp_dir(fun(Dir) ->
        {ok, W0} = open_writer_root(Dir, infinity, infinity),
        try
            R = sha256(<<"root-empty-seal">>),
            {ok, W1} = bondy_mst_pack_writer:set_root(W0, R),
            ?assertEqual(undefined, disk_root(Dir)),
            {ok, no_op, _W2} = bondy_mst_pack_writer:seal(W1),
            ?assertEqual(R, disk_root(Dir))
        after
            bondy_mst_pack_writer:close(W0)
        end
    end).

reopen_with_unflushed_root_sees_prior_disk_root_test() ->
    %% Simulates a crash: opening a writer, staging a root via
    %% set_root, then *NOT* calling flush/close — instead closing
    %% the incoming fd by hand and reopening. The reopen reads the
    %% on-disk manifest, which still has the prior root. (Documents
    %% the staleness window: WAL replay would advance it.)
    with_tmp_dir(fun(Dir) ->
        Persisted = sha256(<<"persisted">>),
        Staged = sha256(<<"staged">>),
        {ok, W0} = open_writer_root(Dir, 1, infinity),
        %% First call: records=1 threshold flushes immediately.
        {ok, W1} = bondy_mst_pack_writer:set_root(W0, Persisted),
        ?assertEqual(Persisted, disk_root(Dir)),
        %% Now reopen with a high threshold to debounce.
        ok = bondy_mst_pack_writer:close(W1),
        {ok, W2} = open_writer_root(Dir, 1000, infinity),
        {ok, _W3} = bondy_mst_pack_writer:set_root(W2, Staged),
        %% Disk still shows the previously persisted root.
        ?assertEqual(Persisted, disk_root(Dir))
    end).
