%% =============================================================================
%% EUnit suite for `bondy_mst_pack_io:read_record/3`. Covers the four
%% terminal return shapes — `{ok, _}`, `not_found`, `{error, {pack_io,
%% _, _}}`, `{error, {crc_mismatch, _, _}}` — against a real sealed
%% pack built by `bondy_mst_pack_seal:create_sealed_pack/6` and then
%% opened directly so the test exercises the I/O module in isolation
%% from the reader/store wrappers.
%% =============================================================================

-module(bondy_mst_pack_io_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_mst_pack.hrl").

%% =============================================================================
%% Fixtures
%% =============================================================================

mktemp_dir() ->
    Base = filename:join(
        [
            "/tmp",
            io_lib:format(
                "bondy_mst_pack_io_test_~p_~p",
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

with_sealed_view(BodiesByHash, Fun) ->
    %% Builds pack-0001.pack + pack-0001.idx in a fresh tmp dir, opens
    %% them into a `#sealed_view{}`, runs `Fun(View, Dir)`, then closes
    %% the fd and wipes the dir.
    Dir = mktemp_dir(),
    try
        Hashes = lists:sort(maps:keys(BodiesByHash)),
        InstanceHash = erlang:phash2(<<"io-test">>, 1 bsl 32),
        Reader = fun(H) -> {ok, maps:get(H, BodiesByHash)} end,
        ok = bondy_mst_pack_seal:create_sealed_pack(
            Dir, InstanceHash, sha256, 1, Hashes, Reader
        ),
        View = open_sealed_view(Dir, 1),
        try
            Fun(View, Dir)
        after
            _ = prim_file:close(View#sealed_view.pack_fd)
        end
    after
        rmrf(Dir)
    end.

open_sealed_view(Dir, PackId) ->
    IdxPath = bondy_mst_pack_paths:sealed_idx_path(Dir, PackId),
    PackPath = bondy_mst_pack_paths:sealed_pack_path(Dir, PackId),
    {ok, IdxBin} = prim_file:read_file(IdxPath),
    {ok, Idx} = bondy_mst_pack_index:open(IdxBin),
    {ok, Fd} = prim_file:open(PackPath, [read, raw, binary]),
    #sealed_view{pack_id = PackId, idx = Idx, pack_fd = Fd}.

hashes_with_offsets(#sealed_view{idx = Idx}) ->
    bondy_mst_pack_index:entries(Idx).

h(I) -> crypto:hash(sha256, <<"io-test-", I:32>>).

body(I) -> <<"body-", I:32>>.

%% Use the real sha256 of a body so the on-disk header carries a hash
%% that matches the body bytes (otherwise the seal-time content-address
%% check would write a record we then can't verify).
mk_corpus(N) ->
    lists:foldl(
        fun(I, Acc) ->
            B = body(I),
            H = crypto:hash(sha256, B),
            Acc#{H => B}
        end,
        #{},
        lists:seq(1, N)
    ).

%% =============================================================================
%% Happy path
%% =============================================================================

read_returns_body_for_known_hash_test() ->
    Corpus = mk_corpus(5),
    with_sealed_view(Corpus, fun(View, _Dir) ->
        lists:foreach(
            fun({H, Off}) ->
                ?assertEqual(
                    {ok, maps:get(H, Corpus)},
                    bondy_mst_pack_io:read_record(View, H, Off)
                )
            end,
            hashes_with_offsets(View)
        )
    end).

read_handles_zero_length_body_test() ->
    %% A page whose body is <<>>. The codec must encode + verify it,
    %% and `read_record` must short-circuit the zero-length body path.
    EmptyHash = crypto:hash(sha256, <<>>),
    Corpus = #{EmptyHash => <<>>},
    with_sealed_view(Corpus, fun(View, _Dir) ->
        [{H, Off}] = hashes_with_offsets(View),
        ?assertEqual(EmptyHash, H),
        ?assertEqual(
            {ok, <<>>},
            bondy_mst_pack_io:read_record(View, H, Off)
        )
    end).

%% =============================================================================
%% not_found — header decodes but names a different hash
%% =============================================================================

read_returns_not_found_when_hash_mismatch_test() ->
    %% Pass the offset of record A but ask for hash B. The header decode
    %% succeeds, the stored hash is A, A =/= B → `not_found`.
    Corpus = mk_corpus(2),
    with_sealed_view(Corpus, fun(View, _Dir) ->
        [{H1, Off1}, {_H2, _Off2}] = hashes_with_offsets(View),
        WrongHash = h(999),
        ?assertNotEqual(H1, WrongHash),
        ?assertEqual(
            not_found,
            bondy_mst_pack_io:read_record(View, WrongHash, Off1)
        )
    end).

%% =============================================================================
%% pack_io errors — pread runs off the end of the file
%% =============================================================================

read_returns_short_header_when_offset_past_eof_test() ->
    Corpus = mk_corpus(1),
    with_sealed_view(Corpus, fun(View, Dir) ->
        PackPath = bondy_mst_pack_paths:sealed_pack_path(Dir, 1),
        {ok, FileSize} = file:read_file_info(PackPath),
        Size = element(2, FileSize),
        %% Position past the trailer — no record there.
        BogusOffset = Size + 100,
        BogusHash = h(1),
        ?assertEqual(
            {error, {pack_io, 1, short_header}},
            bondy_mst_pack_io:read_record(View, BogusHash, BogusOffset)
        )
    end).

%% =============================================================================
%% crc_mismatch — body bytes corrupted between write and read
%% =============================================================================

read_returns_crc_mismatch_on_body_corruption_test() ->
    %% Flip a single byte in the body of the only record. The header
    %% (with its hash + crc) is intact and decodes; the body's CRC no
    %% longer matches → `{crc_mismatch, _, _}`.
    Corpus = mk_corpus(1),
    [Hash] = maps:keys(Corpus),
    with_sealed_view(Corpus, fun(View, Dir) ->
        _ = prim_file:close(View#sealed_view.pack_fd),
        PackPath = bondy_mst_pack_paths:sealed_pack_path(Dir, 1),
        flip_body_byte(PackPath),
        View1 = reopen(View, Dir),
        try
            [{H, Off}] = hashes_with_offsets(View1),
            ?assertEqual(Hash, H),
            ?assertEqual(
                {error, {crc_mismatch, 1, Hash}},
                bondy_mst_pack_io:read_record(View1, Hash, Off)
            )
        after
            _ = prim_file:close(View1#sealed_view.pack_fd)
        end
    end).

%% =============================================================================
%% Helpers
%% =============================================================================

reopen(#sealed_view{pack_id = PackId, idx = Idx}, Dir) ->
    PackPath = bondy_mst_pack_paths:sealed_pack_path(Dir, PackId),
    {ok, Fd} = prim_file:open(PackPath, [read, raw, binary]),
    #sealed_view{pack_id = PackId, idx = Idx, pack_fd = Fd}.

flip_body_byte(PackPath) ->
    {ok, Bin} = file:read_file(PackPath),
    %% Pack header (48) + record header (40) + 1 byte in to land on the
    %% first body byte.
    HeaderBytes = bondy_mst_pack_codec:header_bytes(),
    RecHdrBytes = bondy_mst_pack_codec:record_header_bytes(),
    Off = HeaderBytes + RecHdrBytes,
    <<Pre:Off/binary, B:8, Post/binary>> = Bin,
    Flipped = <<Pre/binary, (B bxor 16#FF):8, Post/binary>>,
    ok = file:write_file(PackPath, Flipped).
