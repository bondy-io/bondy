%% =============================================================================
%% EUnit suite for `bondy_mst_pack_index` — the pure `.idx` codec
%% plus its bloom helper `bondy_mst_pack_pack_bloom`. Covers:
%%
%% 1. Build / open round-trip on small and medium hash sets.
%% 2. Fanout-bounded binary search agrees with a naive linear scan
%%    across every record + a random selection of absent hashes.
%% 3. Bloom round-trip: every inserted element is `member = true`;
%%    the false-positive rate on random absent inputs stays below
%%    a generous bound for the chosen P.
%% 4. The bloom-disabled build path produces an index that still
%%    answers lookups correctly (bloom is opt-in).
%% 5. Edge cases: empty entry list; truncated header / sections.
%% =============================================================================

-module(bondy_mst_pack_index_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_mst_pack.hrl").

%% =============================================================================
%% Constants
%% =============================================================================

magic_is_BDIN_test() ->
    ?assertEqual(16#4244494E, bondy_mst_pack_index:magic()).

version_is_1_test() ->
    ?assertEqual(1, bondy_mst_pack_index:version()).

header_bytes_is_16_test() ->
    ?assertEqual(16, bondy_mst_pack_index:header_bytes()).

fanout_bytes_is_1024_test() ->
    ?assertEqual(1024, bondy_mst_pack_index:fanout_bytes()).

offset_bytes_is_8_test() ->
    ?assertEqual(8, bondy_mst_pack_index:offset_bytes()).

%% =============================================================================
%% Build / open round-trip
%% =============================================================================

empty_index_round_trip_test() ->
    Bin = iolist_to_binary(build_idx([])),
    {ok, T} = bondy_mst_pack_index:open(Bin),
    ?assertEqual(0, bondy_mst_pack_index:record_count(T)),
    %% Empty pack: lookup of any hash must return not_found
    %% without crashing.
    H = crypto:hash(sha256, <<"absent">>),
    ?assertEqual(not_found, bondy_mst_pack_index:lookup(T, H)),
    ?assertEqual([], bondy_mst_pack_index:entries(T)).

single_entry_round_trip_test() ->
    H = crypto:hash(sha256, <<"only">>),
    Bin = iolist_to_binary(build_idx([{H, 4242}])),
    {ok, T} = bondy_mst_pack_index:open(Bin),
    ?assertEqual(1, bondy_mst_pack_index:record_count(T)),
    ?assertEqual({ok, 4242}, bondy_mst_pack_index:lookup(T, H)),
    Other = crypto:hash(sha256, <<"other">>),
    ?assertEqual(not_found, bondy_mst_pack_index:lookup(T, Other)),
    ?assertEqual([{H, 4242}], bondy_mst_pack_index:entries(T)).

many_entries_round_trip_test() ->
    Entries = make_entries(500),
    Bin = iolist_to_binary(build_idx(Entries)),
    {ok, T} = bondy_mst_pack_index:open(Bin),
    ?assertEqual(500, bondy_mst_pack_index:record_count(T)),
    %% Every inserted entry must come back exactly.
    lists:foreach(
        fun({H, O}) ->
            ?assertEqual({ok, O}, bondy_mst_pack_index:lookup(T, H))
        end,
        Entries
    ).

unsorted_input_is_sorted_test() ->
    %% The codec sorts internally; we feed it reverse-sorted
    %% input and verify the index still answers correctly.
    Entries = make_entries(64),
    Reversed = lists:reverse(Entries),
    Bin1 = iolist_to_binary(build_idx(Entries)),
    Bin2 = iolist_to_binary(build_idx(Reversed)),
    ?assertEqual(Bin1, Bin2),
    {ok, T} = bondy_mst_pack_index:open(Bin2),
    lists:foreach(
        fun({H, O}) ->
            ?assertEqual({ok, O}, bondy_mst_pack_index:lookup(T, H))
        end,
        Entries
    ).

duplicate_hash_keeps_first_test() ->
    H = crypto:hash(sha256, <<"dup">>),
    Bin = iolist_to_binary(
        build_idx([{H, 100}, {H, 200}])
    ),
    {ok, T} = bondy_mst_pack_index:open(Bin),
    ?assertEqual(1, bondy_mst_pack_index:record_count(T)),
    ?assertEqual({ok, 100}, bondy_mst_pack_index:lookup(T, H)).

%% =============================================================================
%% Fanout agrees with linear scan
%% =============================================================================

fanout_search_matches_linear_test() ->
    Entries = make_entries(257),
    Sorted = lists:keysort(1, Entries),
    Bin = iolist_to_binary(build_idx(Entries)),
    {ok, T} = bondy_mst_pack_index:open(Bin),
    %% Each present hash returns its offset.
    lists:foreach(
        fun({H, O}) ->
            ?assertEqual(
                {ok, O},
                bondy_mst_pack_index:lookup(T, H),
                {present_lookup, H}
            )
        end,
        Sorted
    ),
    %% A run of absent hashes returns not_found.
    Absent = [
        crypto:hash(sha256, <<"absent-", I:32>>)
     || I <- lists:seq(1, 50)
    ],
    Present = [H || {H, _} <- Sorted],
    lists:foreach(
        fun(H) ->
            case lists:member(H, Present) of
                true ->
                    ok;
                false ->
                    ?assertEqual(
                        not_found,
                        bondy_mst_pack_index:lookup(T, H),
                        {absent_lookup, H}
                    )
            end
        end,
        Absent
    ).

%% =============================================================================
%% Bloom
%% =============================================================================

bloom_no_false_negatives_test() ->
    %% Inserting N hashes; member/2 must return true for every one
    %% of them (no false negatives by Bloom design).
    Hashes = [crypto:hash(sha256, <<I:32>>) || I <- lists:seq(1, 500)],
    BF = bondy_mst_pack_bloom:build(Hashes, #{capacity => 500, p => 0.01}),
    lists:foreach(
        fun(H) ->
            ?assertEqual(true, bondy_mst_pack_bloom:member(H, BF), {h, H})
        end,
        Hashes
    ).

bloom_fpr_within_bound_test() ->
    %% A 500-element filter at p = 0.01 should answer `true` for
    %% ≤ ~5 % of 5000 random absent inputs (generous bound: design
    %% target is 1 %, we accept up to 10 % to be insulated from
    %% small-batch variance).
    Inserted = [crypto:hash(sha256, <<I:32>>) || I <- lists:seq(1, 500)],
    BF = bondy_mst_pack_bloom:build(Inserted, #{capacity => 500, p => 0.01}),
    InsertedSet = sets:from_list(Inserted),
    Trials = 5000,
    FalsePositives = lists:foldl(
        fun(I, Acc) ->
            H = crypto:hash(sha256, <<"absent-", I:32>>),
            case sets:is_element(H, InsertedSet) of
                true ->
                    Acc;
                false ->
                    case bondy_mst_pack_bloom:member(H, BF) of
                        true -> Acc + 1;
                        false -> Acc
                    end
            end
        end,
        0,
        lists:seq(1, Trials)
    ),
    Rate = FalsePositives / Trials,
    ?assert(Rate < 0.10, {fpr_too_high, Rate, FalsePositives, Trials}).

bloom_round_trip_via_to_from_binary_test() ->
    Hashes = [crypto:hash(sha256, <<I:32>>) || I <- lists:seq(1, 200)],
    BF1 = bondy_mst_pack_bloom:build(Hashes, #{capacity => 200, p => 0.01}),
    Bin = bondy_mst_pack_bloom:to_binary(BF1),
    {ok, BF2, <<>>} = bondy_mst_pack_bloom:from_binary(Bin),
    %% Every inserted element survives the round-trip.
    lists:foreach(
        fun(H) -> ?assertEqual(true, bondy_mst_pack_bloom:member(H, BF2)) end,
        Hashes
    ),
    %% Both filters answer identically on a set of absent inputs.
    Absent = [
        crypto:hash(sha256, <<"absent-", I:32>>)
     || I <- lists:seq(1, 200)
    ],
    lists:foreach(
        fun(H) ->
            ?assertEqual(
                bondy_mst_pack_bloom:member(H, BF1),
                bondy_mst_pack_bloom:member(H, BF2)
            )
        end,
        Absent
    ).

bloom_section_present_when_built_default_test() ->
    Entries = make_entries(32),
    Bin = iolist_to_binary(build_idx(Entries)),
    {ok, T} = bondy_mst_pack_index:open(Bin),
    ?assertEqual(true, bondy_mst_pack_index:has_bloom(T)).

bloom_section_absent_when_opted_out_test() ->
    Entries = make_entries(32),
    Bin = iolist_to_binary(
        build_idx(Entries, #{bloom => false})
    ),
    {ok, T} = bondy_mst_pack_index:open(Bin),
    ?assertEqual(false, bondy_mst_pack_index:has_bloom(T)),
    %% Lookup path still works without bloom.
    [{H, O} | _] = Entries,
    ?assertEqual({ok, O}, bondy_mst_pack_index:lookup(T, H)).

%% =============================================================================
%% Edge cases on open
%% =============================================================================

open_truncated_header_test() ->
    Bin = iolist_to_binary(
        build_idx(make_entries(8))
    ),
    Short = binary:part(Bin, 0, 8),
    ?assertEqual(
        {error, truncated_header},
        bondy_mst_pack_index:open(Short)
    ).

open_bad_magic_test() ->
    %% Replace 4-byte magic with garbage. The trailer must be
    %% re-computed so the structural error surfaces instead of
    %% being masked by the integrity check.
    Bin0 = iolist_to_binary(
        build_idx(make_entries(8))
    ),
    Bad = reseal(swap_magic(strip_trailer(Bin0), 16#DEADBEEF)),
    ?assertEqual({error, bad_magic}, bondy_mst_pack_index:open(Bad)).

open_bad_version_test() ->
    Bin0 = iolist_to_binary(
        build_idx(make_entries(8))
    ),
    Bad = reseal(swap_version(strip_trailer(Bin0), 99)),
    ?assertEqual(
        {error, {bad_version, 99}},
        bondy_mst_pack_index:open(Bad)
    ).

%% =============================================================================
%% Hash boundary cases (first byte 0x00 and 0xFF)
%% =============================================================================

fanout_handles_first_byte_zero_test() ->
    Zero = <<0:8, 0:248>>,
    Bin = iolist_to_binary(build_idx([{Zero, 11}])),
    {ok, T} = bondy_mst_pack_index:open(Bin),
    ?assertEqual({ok, 11}, bondy_mst_pack_index:lookup(T, Zero)).

fanout_handles_first_byte_max_test() ->
    Max = <<16#FF:8, 0:248>>,
    Bin = iolist_to_binary(build_idx([{Max, 99}])),
    {ok, T} = bondy_mst_pack_index:open(Bin),
    ?assertEqual({ok, 99}, bondy_mst_pack_index:lookup(T, Max)).

fanout_spans_all_buckets_test() ->
    %% One hash in every bucket so all 256 fanout entries are
    %% non-degenerate. Force the first byte to `I` then pad with
    %% 31 sha256-derived bytes so the rest of the hash is unique.
    Entries = [
        {<<I:8, (binary:part(crypto:hash(sha256, <<I:32>>), 0, 31))/binary>>, I}
     || I <- lists:seq(0, 255)
    ],
    Bin = iolist_to_binary(build_idx(Entries)),
    {ok, T} = bondy_mst_pack_index:open(Bin),
    ?assertEqual(256, bondy_mst_pack_index:record_count(T)),
    lists:foreach(
        fun({H, O}) ->
            ?assertEqual({ok, O}, bondy_mst_pack_index:lookup(T, H))
        end,
        Entries
    ).

%% =============================================================================
%% Trailer integrity
%% =============================================================================

open_truncated_trailer_test() ->
    %% A 20-byte binary has a parseable header but cannot hold the
    %% 32-byte trailer. Open must short-circuit with the dedicated
    %% truncated_trailer error.
    ?assertEqual(
        {error, truncated_trailer},
        bondy_mst_pack_index:open(<<0:160>>)
    ).

trailer_round_trip_test() ->
    Bin = iolist_to_binary(
        build_idx(make_entries(16))
    ),
    {ok, T} = bondy_mst_pack_index:open(Bin),
    ?assertEqual(16, bondy_mst_pack_index:record_count(T)).

trailer_detects_header_flip_test() ->
    %% Flip the high bit of the Flags byte (byte 5) — keeps magic,
    %% version, hash_len intact but invalidates the sha256 trailer.
    Bin = iolist_to_binary(
        build_idx(make_entries(8))
    ),
    Bad = flip_byte(Bin, 5),
    ?assertEqual(
        {error, integrity_mismatch},
        bondy_mst_pack_index:open(Bad)
    ).

trailer_detects_fanout_flip_test() ->
    %% Fanout starts after header + (bloom section size). Flipping a
    %% byte inside the fanout must surface as integrity_mismatch.
    Bin = iolist_to_binary(
        build_idx(make_entries(8))
    ),
    %% The exact offset depends on bloom size — pick a byte in the
    %% middle of the body, anywhere outside the trailer.
    BodyLen = byte_size(Bin) - 32,
    MidBody = BodyLen div 2,
    Bad = flip_byte(Bin, MidBody),
    ?assertEqual(
        {error, integrity_mismatch},
        bondy_mst_pack_index:open(Bad)
    ).

trailer_detects_trailer_flip_test() ->
    %% Flip the last byte of the file — trailer itself differs from
    %% sha256(body) and integrity_mismatch surfaces.
    Bin = iolist_to_binary(
        build_idx(make_entries(8))
    ),
    Bad = flip_byte(Bin, byte_size(Bin) - 1),
    ?assertEqual(
        {error, integrity_mismatch},
        bondy_mst_pack_index:open(Bad)
    ).

trailer_detects_bloom_off_flip_test() ->
    %% Same body shape but with bloom disabled — the fanout-region
    %% offset shifts left, so a flip somewhere reasonable in the
    %% body still has to surface as integrity_mismatch.
    Bin = iolist_to_binary(
        build_idx(make_entries(8), #{bloom => false})
    ),
    Bad = flip_byte(Bin, byte_size(Bin) div 2),
    ?assertEqual(
        {error, integrity_mismatch},
        bondy_mst_pack_index:open(Bad)
    ).

%% =============================================================================
%% Build error contract
%% =============================================================================

build_rejects_short_hash_test() ->
    %% 1-byte hash where `hash_len` default expects 32 — tagged error,
    %% not a raise.
    ?assertEqual(
        {error, {bad_hash_size, 32, 1}},
        bondy_mst_pack_index:build([{<<0:8>>, 0}])
    ).

build_rejects_oversize_hash_test() ->
    %% 33-byte hash against the default 32.
    ?assertEqual(
        {error, {bad_hash_size, 32, 33}},
        bondy_mst_pack_index:build([{<<0:264>>, 0}])
    ).

build_rejects_zero_hash_len_opt_test() ->
    ?assertEqual(
        {error, {bad_hash_len, 0}},
        bondy_mst_pack_index:build([], #{hash_len => 0})
    ).

build_rejects_oversize_hash_len_opt_test() ->
    %% Implementation cap is 64 bytes.
    ?assertEqual(
        {error, {bad_hash_len, 65}},
        bondy_mst_pack_index:build([], #{hash_len => 65})
    ).

build_first_entry_short_hash_test() ->
    %% Even the very first dedup pass surfaces the size error.
    Good = crypto:hash(sha256, <<"k">>),
    ?assertEqual(
        {error, {bad_hash_size, 32, 4}},
        bondy_mst_pack_index:build([{<<1, 2, 3, 4>>, 0}, {Good, 1}])
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

make_entries(N) ->
    [
        {crypto:hash(sha256, <<"k-", I:32>>), I * 17 + 13}
     || I <- lists:seq(1, N)
    ].

%% Strip the 32-byte sha256 trailer; callers mutate the resulting body
%% then `reseal/1` to put a valid trailer back on.
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

%% Test-side shim — unwraps the tagged `{ok, IoData}` so existing
%% round-trip tests keep their pre-tagged shape. Tests use known-good
%% input; an `{error, _}` here is a real bug and should crash the test.
build_idx(Entries) ->
    {ok, IO} = bondy_mst_pack_index:build(Entries),
    IO.

build_idx(Entries, Opts) ->
    {ok, IO} = bondy_mst_pack_index:build(Entries, Opts),
    IO.
