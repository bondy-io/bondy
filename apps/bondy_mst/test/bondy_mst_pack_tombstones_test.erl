%% =============================================================================
%% EUnit suite for `bondy_mst_pack_tombstones` — the on-disk
%% tombstone file codec + atomic-write helper.
%% =============================================================================

-module(bondy_mst_pack_tombstones_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_mst_pack.hrl").

%% =============================================================================
%% Fixture
%% =============================================================================

mktemp_dir() ->
    Base = filename:join(
        [
            "/tmp",
            io_lib:format(
                "bondy_mst_pack_tombstones_test_~p_~p",
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

set([]) ->
    sets:new([{version, 2}]);
set(Hs) ->
    sets:from_list(Hs, [{version, 2}]).

h(I) ->
    crypto:hash(sha256, <<"t-", I:32>>).

%% =============================================================================
%% Codec round-trip
%% =============================================================================

empty_set_round_trip_test() ->
    S = set([]),
    Bin = bondy_mst_pack_tombstones:encode(S),
    ?assertEqual({ok, S}, bondy_mst_pack_tombstones:decode(Bin)).

single_hash_round_trip_test() ->
    H = h(1),
    S = set([H]),
    Bin = bondy_mst_pack_tombstones:encode(S),
    {ok, Decoded} = bondy_mst_pack_tombstones:decode(Bin),
    ?assertEqual(true, sets:is_element(H, Decoded)),
    ?assertEqual(1, sets:size(Decoded)).

many_hashes_round_trip_test() ->
    Hs = [h(I) || I <- lists:seq(1, 500)],
    S = set(Hs),
    Bin = bondy_mst_pack_tombstones:encode(S),
    {ok, Decoded} = bondy_mst_pack_tombstones:decode(Bin),
    ?assertEqual(500, sets:size(Decoded)),
    lists:foreach(
        fun(H) -> ?assertEqual(true, sets:is_element(H, Decoded)) end,
        Hs
    ).

%% =============================================================================
%% Decode error paths
%% =============================================================================

truncated_header_test() ->
    %% Header is 16 bytes; trailer is 32. Anything < 48 fails on
    %% header check before trailer check.
    ?assertEqual(
        {error, truncated_header},
        bondy_mst_pack_tombstones:decode(<<0:64>>)
    ).

truncated_trailer_test() ->
    %% 20 bytes — past header threshold but cannot hold the 32-byte
    %% trailer.
    ?assertEqual(
        {error, truncated_trailer},
        bondy_mst_pack_tombstones:decode(<<0:160>>)
    ).

bad_magic_test() ->
    Bin0 = bondy_mst_pack_tombstones:encode(set([h(1)])),
    %% Replace magic, then re-seal so the trailer is valid; the
    %% structural error must surface, not integrity_mismatch.
    Bad = reseal(swap_magic(strip_trailer(Bin0), 16#DEADBEEF)),
    ?assertEqual(
        {error, bad_magic},
        bondy_mst_pack_tombstones:decode(Bad)
    ).

bad_version_test() ->
    Bin0 = bondy_mst_pack_tombstones:encode(set([h(1)])),
    Bad = reseal(swap_version(strip_trailer(Bin0), 99)),
    ?assertEqual(
        {error, {bad_version, 99}},
        bondy_mst_pack_tombstones:decode(Bad)
    ).

integrity_mismatch_detects_body_flip_test() ->
    Bin = bondy_mst_pack_tombstones:encode(set([h(1), h(2)])),
    %% Flip a byte deep in the body.
    Mid = byte_size(Bin) div 2,
    Bad = flip_byte(Bin, Mid),
    ?assertEqual(
        {error, integrity_mismatch},
        bondy_mst_pack_tombstones:decode(Bad)
    ).

integrity_mismatch_detects_trailer_flip_test() ->
    Bin = bondy_mst_pack_tombstones:encode(set([h(1)])),
    Bad = flip_byte(Bin, byte_size(Bin) - 1),
    ?assertEqual(
        {error, integrity_mismatch},
        bondy_mst_pack_tombstones:decode(Bad)
    ).

%% =============================================================================
%% File round-trip
%% =============================================================================

write_then_read_round_trip_test() ->
    with_tmp_dir(fun(Dir) ->
        Hs = [h(I) || I <- lists:seq(1, 10)],
        S = set(Hs),
        ok = bondy_mst_pack_tombstones:write(Dir, S),
        {ok, Loaded} = bondy_mst_pack_tombstones:read(Dir),
        lists:foreach(
            fun(H) -> ?assertEqual(true, sets:is_element(H, Loaded)) end,
            Hs
        )
    end).

read_missing_file_returns_enoent_test() ->
    with_tmp_dir(fun(Dir) ->
        ?assertEqual(
            {error, enoent},
            bondy_mst_pack_tombstones:read(Dir)
        )
    end).

write_overwrites_previous_test() ->
    with_tmp_dir(fun(Dir) ->
        ok = bondy_mst_pack_tombstones:write(Dir, set([h(1), h(2), h(3)])),
        ok = bondy_mst_pack_tombstones:write(Dir, set([h(9)])),
        {ok, S} = bondy_mst_pack_tombstones:read(Dir),
        ?assertEqual(1, sets:size(S)),
        ?assertEqual(true, sets:is_element(h(9), S)),
        ?assertEqual(false, sets:is_element(h(1), S))
    end).

write_empty_set_is_readable_test() ->
    with_tmp_dir(fun(Dir) ->
        ok = bondy_mst_pack_tombstones:write(Dir, set([])),
        ?assertMatch({ok, _}, bondy_mst_pack_tombstones:read(Dir)),
        {ok, S} = bondy_mst_pack_tombstones:read(Dir),
        ?assertEqual(0, sets:size(S))
    end).

delete_removes_file_test() ->
    with_tmp_dir(fun(Dir) ->
        ok = bondy_mst_pack_tombstones:write(Dir, set([h(1)])),
        ?assert(filelib:is_regular(bondy_mst_pack_tombstones:path(Dir))),
        ok = bondy_mst_pack_tombstones:delete(Dir),
        ?assertNot(filelib:is_regular(bondy_mst_pack_tombstones:path(Dir))),
        %% Idempotent — second delete is a no-op.
        ok = bondy_mst_pack_tombstones:delete(Dir)
    end).

%% =============================================================================
%% Helpers
%% =============================================================================

strip_trailer(Bin) ->
    BodyLen = byte_size(Bin) - 32,
    binary:part(Bin, 0, BodyLen).

reseal(Body) ->
    <<Body/binary, (crypto:hash(sha256, Body))/binary>>.

swap_magic(<<_:32, Rest/binary>>, NewMagic) ->
    <<NewMagic:32, Rest/binary>>.

swap_version(<<Magic:32, _:8, Rest/binary>>, NewVersion) ->
    <<Magic:32, NewVersion:8, Rest/binary>>.

flip_byte(Bin, Index) ->
    <<Pre:Index/binary, B:8, Post/binary>> = Bin,
    <<Pre/binary, (B bxor 16#FF):8, Post/binary>>.
