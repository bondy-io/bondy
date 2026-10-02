%% =============================================================================
%% Unit tests for `bondy_log_codec` (pure body codec).
%%
%% Groups:
%%
%% 1. Pure encode/decode: no I/O. Covers the no-op paths (algorithm =
%%    none, body under threshold) and the active path (zlib).
%% 2. Wire-format checks: flag bit, algorithm byte, error surfaces.
%% 3. Encryption: AES-256-GCM round-trip, tag-mismatch, missing key,
%%    IV uniqueness, startup validation, compose with compression.
%%
%% The end-to-end tests through the WAL writer + reader live in
%% `bondy_oplog_wal_codec_test`; the property-based round-trip is in
%% `bondy_oplog_wal_proper_test`.
%% =============================================================================

-module(bondy_log_codec_test).

-behaviour(bondy_log_key_registry).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_log.hrl").

-define(FLAG, ?BONDY_LOG_FRAME_FLAG_COMPRESSED).
-define(EFLAG, ?BONDY_LOG_FRAME_FLAG_ENCRYPTED).

%% In-process key registry used by this suite. Static current key
%% derived from `static_key/0`; one extra retired key surfaces via
%% `key_id = 7` for the "old key still resolvable" case.
-export([current_key/0]).
-export([lookup_key/1]).

current_key() ->
    {1, static_key(1)}.

lookup_key(1) -> {ok, static_key(1)};
lookup_key(7) -> {ok, static_key(7)};
lookup_key(_) -> {error, missing}.

static_key(Salt) ->
    crypto:hash(sha256, <<"codec-test-key-", Salt:32>>).

%% =============================================================================
%% Pure codec round-trip
%% =============================================================================

none_passes_body_through_test() ->
    Body = <<"hello, wal">>,
    ?assertEqual(
        {0, Body},
        bondy_log_codec:encode_body(
            Body, #{body_compression => none}
        )
    ).

below_threshold_passes_through_test() ->
    %% A 100-byte body with `min_bytes = 256` is below the threshold;
    %% the codec must short-circuit even though zlib is enabled.
    Body = crypto:strong_rand_bytes(100),
    ?assertEqual(
        {0, Body},
        bondy_log_codec:encode_body(
            Body, #{
                body_compression => zlib,
                body_compression_min_bytes => 256
            }
        )
    ).

compressible_body_actually_compresses_test() ->
    %% A highly redundant body must compress: the codec emits the
    %% compressed flag and the on-disk body is strictly smaller than
    %% the input.
    Body = binary:copy(<<"ABCD">>, 1024),
    {Flags, Encoded} =
        bondy_log_codec:encode_body(
            Body, #{
                body_compression => zlib,
                body_compression_min_bytes => 1
            }
        ),
    ?assertEqual(?FLAG, Flags),
    ?assert(iolist_size(Encoded) < byte_size(Body)),
    %% First byte is the algorithm id (1 = zlib).
    EncodedBin = iolist_to_binary(Encoded),
    <<Algo:8, _/binary>> = EncodedBin,
    ?assertEqual(?BONDY_LOG_CODEC_ALGO_ZLIB, Algo).

incompressible_body_falls_back_to_raw_test() ->
    %% Random bytes don't compress — the codec must refuse the swap
    %% rather than write a body that's larger than the input.
    Body = crypto:strong_rand_bytes(4096),
    {Flags, Encoded} =
        bondy_log_codec:encode_body(
            Body, #{
                body_compression => zlib,
                body_compression_min_bytes => 1
            }
        ),
    ?assertEqual(0, Flags),
    ?assertEqual(Body, Encoded).

roundtrip_compressible_test() ->
    Body = binary:copy(<<"hello, ">>, 2048),
    {Flags, Encoded} =
        bondy_log_codec:encode_body(
            Body, #{
                body_compression => zlib,
                body_compression_min_bytes => 1
            }
        ),
    EncodedBin = iolist_to_binary(Encoded),
    ?assertEqual(
        {ok, Body},
        bondy_log_codec:decode_body(EncodedBin, Flags)
    ).

roundtrip_uncompressed_test() ->
    Body = <<"plain bytes">>,
    {Flags, Encoded} =
        bondy_log_codec:encode_body(
            Body, #{body_compression => none}
        ),
    EncodedBin = iolist_to_binary(Encoded),
    ?assertEqual(
        {ok, Body},
        bondy_log_codec:decode_body(EncodedBin, Flags)
    ).

%% =============================================================================
%% Decode error surfaces
%% =============================================================================

decode_unknown_algorithm_test() ->
    %% Flag claims compressed, algorithm byte is 99 — unknown.
    Bad = <<99:8, 1, 2, 3>>,
    ?assertEqual(
        {error, {unknown_codec, 99}},
        bondy_log_codec:decode_body(Bad, ?FLAG)
    ).

decode_truncated_envelope_test() ->
    %% Flag is set but the body is empty — there isn't even an
    %% algorithm byte. Must surface as a typed error, not a crash.
    ?assertEqual(
        {error, truncated_envelope},
        bondy_log_codec:decode_body(<<>>, ?FLAG)
    ).

decode_corrupted_compressed_body_test() ->
    %% Valid algorithm byte, garbage payload. Decompression fails;
    %% codec returns `decompress_failed`, not an exception.
    Bad = <<?BONDY_LOG_CODEC_ALGO_ZLIB:8, "not actually zlib">>,
    ?assertEqual(
        {error, decompress_failed},
        bondy_log_codec:decode_body(Bad, ?FLAG)
    ).

%% =============================================================================
%% Startup validation
%% =============================================================================

validate_none_ok_test() ->
    ?assertEqual(ok, bondy_log_codec:validate_algorithm(none)).

validate_zlib_ok_test() ->
    ?assertEqual(ok, bondy_log_codec:validate_algorithm(zlib)).

validate_lz4_unsupported_test() ->
    ?assertEqual(
        {error, {unsupported_codec, lz4}},
        bondy_log_codec:validate_algorithm(lz4)
    ).

validate_invalid_value_test() ->
    ?assertEqual(
        {error, {invalid_opt, body_compression, snappy}},
        bondy_log_codec:validate_algorithm(snappy)
    ).

%% =============================================================================
%% Telemetry surface
%% =============================================================================

telemetry_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(telemetry),
            ok
        end,
        fun(_) -> ok end, [
            {timeout, 5, fun compress_telemetry_emits_with_metadata/0},
            {timeout, 5, fun decompress_telemetry_emits/0},
            {timeout, 5, fun no_event_for_noop/0}
        ]}.

compress_telemetry_emits_with_metadata() ->
    Ref = attach([bondy_log, codec, compress], compress),
    Body = binary:copy(<<"ABCD">>, 1024),
    {?FLAG, _} = bondy_log_codec:encode_body(
        Body, #{
            body_compression => zlib,
            body_compression_min_bytes => 1,
            instance_id => <<"codec-test">>
        }
    ),
    {M, Md} = receive_event(compress, 1000),
    detach(Ref),
    ?assertMatch(#{input_bytes := _, output_bytes := _, duration_us := _}, M),
    ?assertEqual(byte_size(Body), maps:get(input_bytes, M)),
    ?assert(maps:get(output_bytes, M) > 0),
    ?assertEqual(zlib, maps:get(algorithm, Md)),
    ?assertEqual(<<"codec-test">>, maps:get(instance_id, Md)).

decompress_telemetry_emits() ->
    Body = binary:copy(<<"zzz">>, 2048),
    {Flags, Encoded} = bondy_log_codec:encode_body(
        Body, #{
            body_compression => zlib,
            body_compression_min_bytes => 1
        }
    ),
    Ref = attach([bondy_log, codec, decompress], decompress),
    {ok, _} = bondy_log_codec:decode_body(
        iolist_to_binary(Encoded),
        Flags,
        #{instance_id => <<"codec-test">>}
    ),
    {M, Md} = receive_event(decompress, 1000),
    detach(Ref),
    ?assertEqual(byte_size(Body), maps:get(output_bytes, M)),
    ?assertEqual(zlib, maps:get(algorithm, Md)).

no_event_for_noop() ->
    Ref = attach([bondy_log, codec, compress], compress_noop),
    %% Below threshold → no-op.
    {0, _} = bondy_log_codec:encode_body(
        <<"tiny">>, #{
            body_compression => zlib,
            body_compression_min_bytes => 256,
            instance_id => <<"x">>
        }
    ),
    timer:sleep(20),
    detach(Ref),
    ?assertEqual(no_event, drain(compress_noop)).

%% =============================================================================
%% Encryption — pure codec
%% =============================================================================

encryption_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(telemetry),
            ok
        end,
        fun(_) -> ok end, [
            {timeout, 5, fun encrypt_only_roundtrip/0},
            {timeout, 5, fun compress_then_encrypt_roundtrip/0},
            {timeout, 5, fun encrypt_sets_flag_and_envelope_header/0},
            {timeout, 5, fun iv_unique_per_frame/0},
            {timeout, 5, fun tag_mismatch_returns_decrypt_failed/0},
            {timeout, 5, fun missing_key_returns_missing_key/0},
            {timeout, 5, fun unknown_cipher_id_returns_typed_error/0},
            {timeout, 5, fun truncated_encryption_envelope/0},
            {timeout, 5, fun decrypt_without_registry_returns_missing_key/0},
            {timeout, 5, fun validate_encryption_paths/0},
            {timeout, 5, fun encrypt_telemetry_emits/0},
            {timeout, 5, fun decrypt_tag_failure_emits_telemetry/0}
        ]}.

encrypt_only_roundtrip() ->
    Body = <<"hello, encrypted wal">>,
    Opts = #{body_encryption => {enabled, ?MODULE}},
    {Flags, Encoded} = bondy_log_codec:encode_body(Body, Opts),
    ?assertEqual(?EFLAG, Flags),
    EncodedBin = iolist_to_binary(Encoded),
    ?assertNotEqual(Body, EncodedBin),
    ?assertEqual(
        {ok, Body},
        bondy_log_codec:decode_body(EncodedBin, Flags, Opts)
    ).

compress_then_encrypt_roundtrip() ->
    %% A body large enough that compression is meaningful; we expect
    %% both flag bits to be set and the round-trip to be the identity.
    Body = binary:copy(<<"compressible payload ">>, 256),
    Opts = #{
        body_compression => zlib,
        body_compression_min_bytes => 1,
        body_encryption => {enabled, ?MODULE}
    },
    {Flags, Encoded} = bondy_log_codec:encode_body(Body, Opts),
    ?assertEqual(?FLAG bor ?EFLAG, Flags),
    EncodedBin = iolist_to_binary(Encoded),
    ?assertEqual(
        {ok, Body},
        bondy_log_codec:decode_body(EncodedBin, Flags, Opts)
    ).

encrypt_sets_flag_and_envelope_header() ->
    Body = <<"x">>,
    Opts = #{body_encryption => {enabled, ?MODULE}},
    {Flags, Encoded} = bondy_log_codec:encode_body(Body, Opts),
    ?assertEqual(?EFLAG, Flags),
    EncodedBin = iolist_to_binary(Encoded),
    %% First byte must be the AES-256-GCM cipher id.
    <<Algo:8, KeyId:16/big-unsigned, IV:12/binary, Tag:16/binary,
        _Ciphertext/binary>> = EncodedBin,
    ?assertEqual(?BONDY_LOG_CODEC_CIPHER_AES_256_GCM, Algo),
    ?assertEqual(1, KeyId),
    ?assertEqual(12, byte_size(IV)),
    ?assertEqual(16, byte_size(Tag)).

iv_unique_per_frame() ->
    %% Two encryptions of the same body must produce different IVs.
    %% This is the GCM catastrophe condition; the test guards against
    %% an accidental change to a deterministic IV source.
    Body = <<"identical body">>,
    Opts = #{body_encryption => {enabled, ?MODULE}},
    {?EFLAG, E1} = bondy_log_codec:encode_body(Body, Opts),
    {?EFLAG, E2} = bondy_log_codec:encode_body(Body, Opts),
    B1 = iolist_to_binary(E1),
    B2 = iolist_to_binary(E2),
    <<_:3/binary, IV1:12/binary, _Tag1:16/binary, _/binary>> = B1,
    <<_:3/binary, IV2:12/binary, _Tag2:16/binary, _/binary>> = B2,
    ?assertNotEqual(IV1, IV2).

tag_mismatch_returns_decrypt_failed() ->
    %% Flip one bit in the ciphertext region — GCM tag must reject.
    Body = <<"payload to corrupt">>,
    Opts = #{body_encryption => {enabled, ?MODULE}},
    {?EFLAG, Encoded} = bondy_log_codec:encode_body(Body, Opts),
    Bin = iolist_to_binary(Encoded),
    %% Bit-flip the first ciphertext byte at offset 31.
    <<Pre:31/binary, B, Post/binary>> = Bin,
    Corrupted = <<Pre/binary, (B bxor 16#01), Post/binary>>,
    ?assertEqual(
        {error, decrypt_failed},
        bondy_log_codec:decode_body(
            Corrupted, ?EFLAG, Opts
        )
    ).

missing_key_returns_missing_key() ->
    %% Forge an envelope with KeyId=42 (not present in the stub
    %% registry) — the codec must surface `{missing_key, 42}`.
    IV = crypto:strong_rand_bytes(12),
    Tag = <<0:128>>,
    Body = <<"unreachable">>,
    Forged =
        <<?BONDY_LOG_CODEC_CIPHER_AES_256_GCM:8, 42:16/big-unsigned, IV/binary,
            Tag/binary, Body/binary>>,
    Opts = #{body_encryption => {enabled, ?MODULE}},
    ?assertEqual(
        {error, {missing_key, 42}},
        bondy_log_codec:decode_body(Forged, ?EFLAG, Opts)
    ).

unknown_cipher_id_returns_typed_error() ->
    Forged = <<99:8, 0:16, 0:96, 0:128, "data">>,
    ?assertEqual(
        {error, {unknown_cipher, 99}},
        bondy_log_codec:decode_body(
            Forged,
            ?EFLAG,
            #{body_encryption => {enabled, ?MODULE}}
        )
    ).

truncated_encryption_envelope() ->
    %% Less than 31 bytes — there isn't even a full envelope header.
    ?assertEqual(
        {error, truncated_envelope},
        bondy_log_codec:decode_body(
            <<1, 0, 0>>,
            ?EFLAG,
            #{body_encryption => {enabled, ?MODULE}}
        )
    ).

decrypt_without_registry_returns_missing_key() ->
    %% Encrypt with the stub registry, attempt to decrypt with the
    %% registry omitted from the opts. The codec must not crash and
    %% must not return arbitrary bytes; `missing_key` is the only
    %% honest answer when there's nowhere to resolve the id.
    Body = <<"secret">>,
    Opts = #{body_encryption => {enabled, ?MODULE}},
    {?EFLAG, Encoded} = bondy_log_codec:encode_body(Body, Opts),
    EncodedBin = iolist_to_binary(Encoded),
    ?assertMatch(
        {error, {missing_key, _}},
        bondy_log_codec:decode_body(EncodedBin, ?EFLAG, #{})
    ).

validate_encryption_paths() ->
    ?assertEqual(
        ok,
        bondy_log_codec:validate_encryption(disabled)
    ),
    ?assertEqual(
        ok,
        bondy_log_codec:validate_encryption(
            {enabled, ?MODULE}
        )
    ),
    ?assertMatch(
        {error, {key_registry_unloadable, _}},
        bondy_log_codec:validate_encryption(
            {enabled, no_such_module_anywhere}
        )
    ),
    ?assertMatch(
        {error, {invalid_opt, body_encryption, _}},
        bondy_log_codec:validate_encryption(
            {bogus, ?MODULE}
        )
    ).

encrypt_telemetry_emits() ->
    Ref = attach([bondy_log, codec, encrypt], encrypt),
    Body = <<"payload">>,
    Opts = #{
        body_encryption => {enabled, ?MODULE},
        instance_id => <<"codec-test">>
    },
    {?EFLAG, _} = bondy_log_codec:encode_body(Body, Opts),
    {M, Md} = receive_event(encrypt, 1000),
    detach(Ref),
    ?assertEqual(byte_size(Body), maps:get(input_bytes, M)),
    ?assert(maps:get(output_bytes, M) > byte_size(Body)),
    ?assertEqual(aes_256_gcm, maps:get(algorithm, Md)),
    ?assertEqual(1, maps:get(key_id, Md)),
    ?assertEqual(<<"codec-test">>, maps:get(instance_id, Md)).

decrypt_tag_failure_emits_telemetry() ->
    Body = <<"oops">>,
    Opts = #{
        body_encryption => {enabled, ?MODULE},
        instance_id => <<"codec-test">>
    },
    {?EFLAG, Encoded} = bondy_log_codec:encode_body(Body, Opts),
    Bin = iolist_to_binary(Encoded),
    <<Pre:31/binary, B, Post/binary>> = Bin,
    Corrupted = <<Pre/binary, (B bxor 16#01), Post/binary>>,
    Ref = attach([bondy_log, codec, decrypt], decrypt),
    {error, decrypt_failed} =
        bondy_log_codec:decode_body(Corrupted, ?EFLAG, Opts),
    {M, _Md} = receive_event(decrypt, 1000),
    detach(Ref),
    ?assertEqual(1, maps:get(tag_mismatches, M)).

%% =============================================================================
%% Helpers
%% =============================================================================

attach(EventName, Tag) ->
    Self = self(),
    Ref = make_ref(),
    HandlerId = {?MODULE, Tag, Ref},
    ok = telemetry:attach(
        HandlerId,
        EventName,
        fun(_E, M, Md, _Cfg) -> Self ! {codec_event, Tag, M, Md} end,
        []
    ),
    HandlerId.

detach(HandlerId) ->
    telemetry:detach(HandlerId).

receive_event(Tag, TimeoutMs) ->
    receive
        {codec_event, Tag, M, Md} -> {M, Md}
    after TimeoutMs ->
        erlang:error({telemetry_event_not_received, Tag})
    end.

drain(Tag) ->
    receive
        {codec_event, Tag, _, _} -> got_event
    after 0 -> no_event
    end.
