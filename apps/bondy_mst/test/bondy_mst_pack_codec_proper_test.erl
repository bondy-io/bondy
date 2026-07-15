%% =============================================================================
%% PropEr properties for the MST pack-store wire codecs:
%%
%%   - prop_pack_header_roundtrip/0          — encode∘decode = id over
%%                                              every well-formed header.
%%   - prop_record_roundtrip/0               — record header + body round-
%%                                              trip; the verified body
%%                                              equals the input.
%%   - prop_record_body_bit_flip_detection/0 — flipping any bit inside the
%%                                              body surfaces as a crc_
%%                                              mismatch, never as a silent
%%                                              successful decode.
%%   - prop_trailer_bit_flip_detection/0     — flipping any bit in the
%%                                              pack body or trailer
%%                                              surfaces as a trailer_
%%                                              mismatch.
%%   - prop_idx_roundtrip/0                  — build∘open over arbitrary
%%                                              {Hash, Offset} sets:
%%                                              every entry round-trips
%%                                              via lookup/2.
%%   - prop_bloom_no_false_negatives/0       — for any set of inputs, the
%%                                              parsed-from-binary filter
%%                                              answers `true` for every
%%                                              inserted element.
%%
%% Run:
%%   rebar3 as test proper --module=bondy_mst_pack_codec_proper_test
%% =============================================================================

-module(bondy_mst_pack_codec_proper_test).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("bondy_mst_pack.hrl").

-export([prop_pack_header_roundtrip/0]).
-export([prop_record_roundtrip/0]).
-export([prop_record_body_bit_flip_detection/0]).
-export([prop_trailer_bit_flip_detection/0]).
-export([prop_idx_roundtrip/0]).
-export([prop_bloom_no_false_negatives/0]).

%% =============================================================================
%% EUnit driver — invoked by `rebar3 eunit`. Keeps numtests modest
%% so the eunit suite stays fast; full-fuzz runs use `rebar3 proper`
%% with the higher `numtests` from `rebar.config`.
%% =============================================================================

proper_pack_codec_test_() ->
    Opts = [{numtests, 50}, {to_file, user}],
    [
        {timeout, 30,
            ?_assert(proper:quickcheck(prop_pack_header_roundtrip(), Opts))},
        {timeout, 30,
            ?_assert(proper:quickcheck(prop_record_roundtrip(), Opts))},
        {timeout, 30,
            ?_assert(
                proper:quickcheck(prop_record_body_bit_flip_detection(), Opts)
            )},
        {timeout, 30,
            ?_assert(
                proper:quickcheck(prop_trailer_bit_flip_detection(), Opts)
            )},
        {timeout, 30, ?_assert(proper:quickcheck(prop_idx_roundtrip(), Opts))},
        {timeout, 30,
            ?_assert(proper:quickcheck(prop_bloom_no_false_negatives(), Opts))}
    ].

%% =============================================================================
%% Properties — pack codec
%% =============================================================================

prop_pack_header_roundtrip() ->
    ?FORALL(
        H,
        header_gen(),
        begin
            Bin = bondy_mst_pack_codec:encode_pack_header(H),
            case bondy_mst_pack_codec:decode_pack_header(Bin) of
                {ok, H} ->
                    true;
                Other ->
                    io:format("decode mismatch: ~p~n", [Other]),
                    false
            end
        end
    ).

prop_record_roundtrip() ->
    ?FORALL(
        Page,
        binary(),
        begin
            Hash = crypto:hash(sha256, Page),
            Bin = iolist_to_binary(
                bondy_mst_pack_codec:encode_record(Hash, Page)
            ),
            {ok, Header} = bondy_mst_pack_codec:decode_record_header(Bin),
            Body = binary:part(Bin, 40, byte_size(Page)),
            Hash =:= maps:get(hash, Header) andalso
                byte_size(Page) =:= maps:get(page_len, Header) andalso
                ok =:= bondy_mst_pack_codec:verify_record(Header, Body) andalso
                Body =:= Page
        end
    ).

prop_record_body_bit_flip_detection() ->
    ?FORALL(
        {Page, BitIdx},
        ?LET(
            B,
            non_empty(binary()),
            {B, choose(0, byte_size(B) * 8 - 1)}
        ),
        begin
            Hash = crypto:hash(sha256, Page),
            Bin = iolist_to_binary(
                bondy_mst_pack_codec:encode_record(Hash, Page)
            ),
            {ok, Header} = bondy_mst_pack_codec:decode_record_header(Bin),
            BadBody = flip_bit(Page, BitIdx),
            case bondy_mst_pack_codec:verify_record(Header, BadBody) of
                {error, {crc_mismatch, _, _}} -> true;
                _ -> false
            end
        end
    ).

prop_trailer_bit_flip_detection() ->
    ?FORALL(
        {Body, BitIdx},
        ?LET(
            B,
            non_empty(binary()),
            {B, choose(0, byte_size(B) * 8 - 1)}
        ),
        begin
            Trailer = bondy_mst_pack_codec:compute_trailer(Body),
            BadBody = flip_bit(Body, BitIdx),
            case bondy_mst_pack_codec:verify_trailer(BadBody, Trailer) of
                {error, {trailer_mismatch, _, _}} -> true;
                _ -> false
            end
        end
    ).

%% =============================================================================
%% Properties — index codec
%% =============================================================================

prop_idx_roundtrip() ->
    ?FORALL(
        Entries,
        entries_gen(),
        begin
            {ok, IO} = bondy_mst_pack_index:build(Entries),
            Bin = iolist_to_binary(IO),
            {ok, T} = bondy_mst_pack_index:open(Bin),
            %% After dedup, every distinct hash in the input is
            %% retrievable; the offset matches the first occurrence
            %% by `lists:keysort` stability.
            Expected = collapse_first(Entries),
            lists:all(
                fun({H, O}) ->
                    {ok, O} =:= bondy_mst_pack_index:lookup(T, H)
                end,
                Expected
            )
        end
    ).

prop_bloom_no_false_negatives() ->
    ?FORALL(
        Hashes,
        ?LET(
            N,
            choose(0, 200),
            vector(N, binary(32))
        ),
        begin
            case Hashes of
                [] ->
                    %% Capacity must be > 0; empty input is a degenerate
                    %% case the caller's build/2 in the index module
                    %% skips. We mirror that here.
                    true;
                _ ->
                    BF = bondy_mst_pack_bloom:build(
                        Hashes,
                        #{capacity => length(Hashes), p => 0.01}
                    ),
                    Bin = bondy_mst_pack_bloom:to_binary(BF),
                    {ok, Parsed, <<>>} = bondy_mst_pack_bloom:from_binary(Bin),
                    lists:all(
                        fun(H) -> bondy_mst_pack_bloom:member(H, Parsed) end,
                        Hashes
                    )
            end
        end
    ).

%% =============================================================================
%% Generators
%% =============================================================================

header_gen() ->
    ?LET(
        {PackId, InstanceHash, CreatedAt, RecordCount},
        {
            non_neg_integer(),
            non_neg_integer(),
            non_neg_integer(),
            non_neg_integer()
        },
        #{
            version => 1,
            flags => 0,
            pack_id => PackId rem (1 bsl 64),
            instance_hash => InstanceHash rem (1 bsl 32),
            hash_algo => sha256,
            created_at => CreatedAt rem (1 bsl 64),
            record_count => RecordCount rem (1 bsl 32)
        }
    ).

entries_gen() ->
    ?LET(
        N,
        choose(0, 80),
        vector(N, {binary(32), choose(0, 1 bsl 30)})
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

flip_bit(Bin, BitIdx) ->
    ByteIdx = BitIdx div 8,
    Mask = 1 bsl (BitIdx rem 8),
    <<Head:ByteIdx/binary, Byte:8, Rest/binary>> = Bin,
    <<Head/binary, (Byte bxor Mask):8, Rest/binary>>.

%% @private
%% Mirror of `bondy_mst_pack_index:dedup_sorted/2`'s semantics
%% (sorted by hash, dedup adjacent-on-equal-hash keeping first).
collapse_first(Entries) ->
    Sorted = lists:keysort(1, Entries),
    collapse_first_loop(Sorted, []).

collapse_first_loop([], Acc) ->
    lists:reverse(Acc);
collapse_first_loop([{H, _} | Rest], [{H, _} | _] = Acc) ->
    %% Same hash as the last kept entry — skip.
    collapse_first_loop(skip_same_hash(H, Rest), Acc);
collapse_first_loop([{H, O} | Rest], Acc) ->
    collapse_first_loop(skip_same_hash(H, Rest), [{H, O} | Acc]).

skip_same_hash(_, []) -> [];
skip_same_hash(H, [{H, _} | Rest]) -> skip_same_hash(H, Rest);
skip_same_hash(_, Rest) -> Rest.
