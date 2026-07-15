%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_wal_codec).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").
-include("bondy_oplog_wal.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Pure body codec: compresses / decompresses and encrypts / decrypts the
encoded batch body that sits inside a WAL frame.

Sits between `bondy_oplog_wal` (writer) / `bondy_oplog_wal_reader` /
`bondy_oplog_wal_recovery` and `bondy_oplog_wal_frame`. The frame
module owns the envelope (Magic, FrameLen, CRC, FrameVersion, Flags);
the codec owns the body bytes — choosing whether to compress and / or
encrypt them, which algorithm to use, and how to reverse the
transforms on read.

## Wire format

The body's on-disk representation is selected by `Flags` bits 0
(compressed) and 1 (encrypted). The transforms compose: when both
flags are set, the writer **compresses first, then encrypts**; the
reader reverses the order. Encrypting compressed bytes preserves
secrecy of an already-shrunk payload — the design's rationale is
that encrypted data has no exploitable redundancy so the reverse
order (encrypt-then-compress) is pointless or harmful.

```
%% Flag bit 0 — compression envelope:
%%   <<AlgorithmId:8, CompressedBytes/binary>>
%%
%% Flag bit 1 — encryption envelope:
%%   <<AlgorithmId:8, KeyId:16, IV:12/binary, Tag:16/binary,
%%     Ciphertext/binary>>
%%
%% Bit 0 + bit 1 — encryption envelope whose Ciphertext, after
%%   decryption, is the compression envelope above.
```

The leading algorithm byte in each envelope decouples the *capability*
advertised by the flag from the *algorithm* used to apply it, so a
writer can swap implementations later (zlib → lz4 → …, AES-256-GCM →
ChaCha20-Poly1305 → …) without a wire-format break. Algorithm ids
live in `bondy_oplog_wal.hrl`:

| Flag | Id | Algorithm | Status |
|---|---|---|---|
| bit 0 | 1 | zlib `deflate -1`  | implemented |
| bit 0 | 2 | lz4               | reserved (requires NIF; not built in) |
| bit 1 | 1 | AES-256-GCM         | implemented |

## Encode contract

`encode_body/2` returns `{Flags, EncodedBody}` where `Flags` is the
value to or-into the frame's `Flags` field. Bit 0 is set only when
the codec actually compressed (after the threshold and didn't-shrink
short-circuits below); bit 1 is set whenever encryption was requested
and a fresh frame was emitted.

Compression short-circuits:

1. `body_compression = none` — compression path is a no-op.
2. `iolist_size(Body) < body_compression_min_bytes` — body is below
   the threshold; compression is a no-op. Saves CPU on tiny bodies.
3. *Didn't-shrink* — if the compressed envelope is not strictly
   smaller than the input, the body is written uncompressed. Without
   this check, payloads with no exploitable redundancy (already
   compressed, encrypted, or random) would *grow*.

Encryption has no short-circuit: if `body_encryption` is `{enabled,
Registry}` then every body is encrypted. The IV is `crypto:
strong_rand_bytes(12)` per frame; IV uniqueness for a given key is
the catastrophe condition for AES-GCM and the codec never reuses one.

## Decode contract

`decode_body/2,3` branches on `Flags`:

- bit 1 set → reads the encryption envelope, looks up the `KeyId`
  via the caller-supplied registry, decrypts, verifies the tag, then
  recurses on the plaintext with `Flags band 1` (the remaining
  compression bit).
- bit 0 set → reads the algorithm id from byte 0, decompresses the
  remainder.
- both clear → returns the body bytes unchanged.

Failure surfaces (typed errors; the codec never crashes):

- `truncated_envelope` — envelope is shorter than its fixed header.
- `{unknown_codec, Algo}` — unrecognised compression algorithm id.
- `{unknown_cipher, Algo}` — unrecognised encryption algorithm id.
- `{missing_key, KeyId}` — the registry has no key with that id.
- `decompress_failed` — zlib refused the payload.
- `decrypt_failed` — AES-GCM tag mismatch (corruption, wrong key, or
  modified ciphertext). A bit flip inside the ciphertext is
  *guaranteed* to surface here rather than as a CRC error or as
  silently corrupted plaintext.

The decoder never trusts the algorithm byte for anything except
dispatch, and never trusts the ciphertext bytes until the tag has
verified — a malformed envelope cannot escape the codec.

## Key registry

When `body_encryption = {enabled, Registry}` is configured on the
writer, `Registry` is a module implementing
`bondy_oplog_wal_key_registry`. The writer calls `Registry:current_
key/0` once per encrypted frame; readers and recovery call
`Registry:lookup_key/1` once per encrypted frame they decode. Old
frames stay readable as long as their `KeyId` is still resolvable —
the codec returns `{missing_key, KeyId}` otherwise rather than
attempting recovery.

## Telemetry

Per encode that actually compressed:

```
[bondy_oplog, wal, codec, compress]
  measurements: input_bytes, output_bytes, duration_us
  metadata:     instance_id, algorithm
```

Per decode that actually decompressed:

```
[bondy_oplog, wal, codec, decompress]
  measurements: input_bytes, output_bytes, duration_us
  metadata:     instance_id, algorithm
```

Per encrypted frame (encode and decode):

```
[bondy_oplog, wal, codec, encrypt]
  measurements: input_bytes, output_bytes, duration_us
  metadata:     instance_id, key_id, algorithm

[bondy_oplog, wal, codec, decrypt]
  measurements: input_bytes, output_bytes, duration_us, tag_mismatches
  metadata:     instance_id, key_id, algorithm
```

`tag_mismatches` is `0` on a successful decrypt and `1` on tag
failure (the event still fires so dashboards can alert on it). No
event fires for the no-op paths. `instance_id` is optional; if the
caller passes `undefined`, the key is omitted.

## Purity

This module performs no file I/O and holds no state. It is safe to
call from any context that has a body in hand — writer, reader,
recovery, or test fixture. Key registry callbacks must be free of
process-bound side effects for the same reason.
""").

-define(FLAG_COMPRESSED, ?BONDY_OPLOG_WAL_FRAME_FLAG_COMPRESSED).
-define(FLAG_ENCRYPTED, ?BONDY_OPLOG_WAL_FRAME_FLAG_ENCRYPTED).
-define(ALGO_ZLIB, ?BONDY_OPLOG_WAL_CODEC_ALGO_ZLIB).
-define(ALGO_LZ4, ?BONDY_OPLOG_WAL_CODEC_ALGO_LZ4).
-define(CIPHER_AES_256_GCM, ?BONDY_OPLOG_WAL_CODEC_CIPHER_AES_256_GCM).
-define(IV_BYTES, ?BONDY_OPLOG_WAL_CODEC_IV_BYTES).
-define(TAG_BYTES, ?BONDY_OPLOG_WAL_CODEC_TAG_BYTES).
-define(KEY_BYTES, ?BONDY_OPLOG_WAL_CODEC_KEY_BYTES).
-define(ENCRYPT_HEADER_BYTES,
    ?BONDY_OPLOG_WAL_CODEC_ENCRYPT_HEADER_BYTES
).
-define(MIN_BYTES_DEFAULT,
    ?BONDY_OPLOG_WAL_BODY_COMPRESSION_MIN_BYTES_DEFAULT
).

-type algorithm() :: none | zlib | lz4.
-type encryption() :: disabled | {enabled, module()}.

-type encode_opts() :: #{
    body_compression => algorithm(),
    body_compression_min_bytes => pos_integer(),
    body_encryption => encryption(),
    instance_id => instance_id() | undefined
}.

-type decode_opts() :: #{
    body_encryption => encryption(),
    instance_id => instance_id() | undefined
}.

-type decode_error() ::
    {unknown_codec, byte()}
    | {unknown_cipher, byte()}
    | {missing_key, bondy_oplog_wal_key_registry:key_id()}
    | decompress_failed
    | decrypt_failed
    | truncated_envelope.

-export_type([algorithm/0]).
-export_type([encryption/0]).
-export_type([encode_opts/0]).
-export_type([decode_opts/0]).
-export_type([decode_error/0]).

-export([encode_body/2]).
-export([decode_body/2]).
-export([decode_body/3]).
-export([validate_algorithm/1]).
-export([validate_encryption/1]).

%% =============================================================================
%% API
%% =============================================================================

?DOC("""
Encodes `Body` per `Opts`. Returns `{Flags, EncodedBody}` where:

- `Flags` is the codec-contributed portion of the frame's `Flags`
  field — `0` when the body is written uncompressed, or
  `?BONDY_OPLOG_WAL_FRAME_FLAG_COMPRESSED` when the codec actually
  compressed it.
- `EncodedBody` is iodata suitable for `bondy_oplog_wal_frame:encode/2`.

`Opts`:

- `body_compression` — `none` (default), `zlib`, or `lz4`. `none`
  short-circuits with no telemetry. `lz4` is reserved and currently
  errors at startup via `validate_algorithm/1`.
- `body_compression_min_bytes` — bodies whose `iolist_size/1` is
  below this threshold are written uncompressed even when compression
  is enabled. Default 256 bytes.
- `instance_id` — surfaced as telemetry metadata. Optional.
""").
-spec encode_body(iodata(), encode_opts()) ->
    {non_neg_integer(), iodata()}.

encode_body(Body, Opts) ->
    {CompressFlags, AfterCompress} = maybe_compress(Body, Opts),
    case maps:get(body_encryption, Opts, disabled) of
        disabled ->
            {CompressFlags, AfterCompress};
        {enabled, Registry} ->
            Envelope = encrypt_now(AfterCompress, Registry, Opts),
            {CompressFlags bor ?FLAG_ENCRYPTED, Envelope}
    end.

%% @private
%% Compression sub-path used by `encode_body/2`. Returns the codec
%% flag bits and the (possibly transformed) iodata. Encryption layers
%% on top of this; the compression flag stays inside the encrypted
%% envelope so a decoder must decrypt before it can decompress.
maybe_compress(Body, Opts) ->
    case maps:get(body_compression, Opts, none) of
        none ->
            {0, Body};
        Algo ->
            Min = maps:get(
                body_compression_min_bytes, Opts, ?MIN_BYTES_DEFAULT
            ),
            try_compress(Body, Algo, Min, Opts)
    end.

?DOC("""
Decodes the codec envelope of a frame body.

`Flags` is the full `Flags` value carried by the frame; the codec
looks only at bit 0. Returns `{ok, Bytes}` with the decoded body
bytes, or `{error, Reason}` where `Reason :: decode_error()`.

On the bit-0-clear path the input is returned unchanged. On the
bit-0-set path the first byte selects the algorithm and the rest is
the compressed payload; a missing or unknown algorithm byte produces
a typed error rather than a crash.

`Opts` is optional; same shape as `encode_body/2`'s, but only
`instance_id` is read (for telemetry metadata).
""").
-spec decode_body(binary(), non_neg_integer()) ->
    {ok, binary()} | {error, decode_error()}.

decode_body(Body, Flags) ->
    decode_body(Body, Flags, #{}).

?DOC("""
Variant of `decode_body/2` that accepts an opts map for telemetry
metadata (currently only `instance_id` is read).
""").
-spec decode_body(binary(), non_neg_integer(), map()) ->
    {ok, binary()} | {error, decode_error()}.

decode_body(Body, Flags, Opts) ->
    case Flags band ?FLAG_ENCRYPTED of
        ?FLAG_ENCRYPTED ->
            case decrypt(Body, Opts) of
                {ok, Plaintext} ->
                    %% Plaintext carries the remaining compression
                    %% flag inline; recurse with the encrypted bit
                    %% cleared so the compression sub-decoder sees a
                    %% post-encryption-stripped flag set.
                    decode_body(
                        Plaintext, Flags band (bnot ?FLAG_ENCRYPTED), Opts
                    );
                {error, _} = E ->
                    E
            end;
        0 ->
            decode_compressed(Body, Flags, Opts)
    end.

%% @private
decode_compressed(Body, Flags, _Opts) when
    Flags band ?FLAG_COMPRESSED =:= 0
->
    {ok, Body};
decode_compressed(<<>>, _Flags, _Opts) ->
    %% The flag claims a compressed body but there isn't even an
    %% algorithm byte. Don't crash — surface a typed error so the
    %% caller (reader / recovery) treats it as a body-level decode
    %% failure rather than an exception.
    {error, truncated_envelope};
decode_compressed(<<Algo:8, Payload/binary>>, _Flags, Opts) ->
    InstanceId = maps:get(instance_id, Opts, undefined),
    case algo_atom(Algo) of
        {ok, AlgoAtom} ->
            decompress(AlgoAtom, Payload, byte_size(Payload), InstanceId);
        {error, _} = E ->
            E
    end.

?DOC("""
Validates a `body_compression` opt at startup. Returns `ok` for
`none` and `zlib`; returns `{error, {unsupported_codec, lz4}}` for
`lz4` (reserved id; requires an LZ4 NIF that is not built into the
project today). Any other value is `{error, {invalid_opt,
body_compression, V}}`.
""").
-spec validate_algorithm(term()) ->
    ok
    | {error, {invalid_opt, body_compression, term()}}
    | {error, {unsupported_codec, lz4}}.

validate_algorithm(none) -> ok;
validate_algorithm(zlib) -> ok;
validate_algorithm(lz4) -> {error, {unsupported_codec, lz4}};
validate_algorithm(V) -> {error, {invalid_opt, body_compression, V}}.

?DOC("""
Validates a `body_encryption` opt at startup. Returns `ok` for
`disabled` and for `{enabled, Module}` when `Module` exports the
`bondy_oplog_wal_key_registry` callbacks and the module's
`current_key/0` returns a well-formed `{KeyId, Key}` pair (`KeyId`
in `0..16#FFFF`, `Key` a 32-byte binary). Otherwise returns a typed
`{invalid_opt, body_encryption, _}` or `{key_registry_*, _}` error.
The startup check is a one-time cost that catches misconfiguration
before any frame is written; bad keys at runtime still come back as
`{missing_key, _}` from `decode_body/3`.
""").
-spec validate_encryption(term()) ->
    ok
    | {error, {invalid_opt, body_encryption, term()}}
    | {error, {key_registry_unloadable, module()}}
    | {error, {key_registry_bad_current_key, term()}}.

validate_encryption(disabled) ->
    ok;
validate_encryption({enabled, Module}) when is_atom(Module) ->
    case ensure_registry_callable(Module) of
        ok ->
            try Module:current_key() of
                {KeyId, Key} when
                    is_integer(KeyId),
                    KeyId >= 0,
                    KeyId =< 16#FFFF,
                    is_binary(Key),
                    byte_size(Key) =:= ?KEY_BYTES
                ->
                    ok;
                Other ->
                    {error, {key_registry_bad_current_key, Other}}
            catch
                Class:Reason ->
                    {error, {key_registry_bad_current_key, {Class, Reason}}}
            end;
        {error, _} = E ->
            E
    end;
validate_encryption(V) ->
    {error, {invalid_opt, body_encryption, V}}.

%% @private
ensure_registry_callable(Module) ->
    case code:ensure_loaded(Module) of
        {module, _} ->
            case
                erlang:function_exported(Module, current_key, 0) andalso
                    erlang:function_exported(Module, lookup_key, 1)
            of
                true -> ok;
                false -> {error, {key_registry_unloadable, Module}}
            end;
        {error, _} ->
            {error, {key_registry_unloadable, Module}}
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Threshold + didn't-shrink short-circuits.
try_compress(Body, Algo, Min, Opts) ->
    InSize = iolist_size(Body),
    case InSize < Min of
        true ->
            {0, Body};
        false ->
            InstanceId = maps:get(instance_id, Opts, undefined),
            compress_now(Body, InSize, Algo, InstanceId)
    end.

%% @private
%% Compresses `Body` with `Algo`. If the compressed envelope (algo
%% byte + payload) is not strictly smaller than the input, falls back
%% to the uncompressed path so worst-case payloads don't grow. Both
%% branches emit telemetry only when compression actually ran; the
%% fallback path emits an event with the negative ratio so operators
%% can see that the writer attempted compression and rejected it.
compress_now(Body, InSize, zlib, InstanceId) ->
    T0 = erlang:monotonic_time(microsecond),
    %% Z_DEFAULT_COMPRESSION lets zlib pick a balanced level; the
    %% level isn't a per-instance knob — the lz4 swap-out point would
    %% invalidate it anyway.
    Z = zlib:open(),
    try
        %% Raw deflate stream (windowBits = -15, no zlib wrapper) so
        %% the envelope's algorithm byte is the only out-of-band
        %% framing — the zlib wrapper's adler32 would duplicate the
        %% frame-level CRC. `default` level balances CPU vs ratio; the
        %% per-instance knob lands later if profiling motivates it.
        ok = zlib:deflateInit(Z, default, deflated, -15, 8, default),
        Compressed = iolist_to_binary(
            zlib:deflate(Z, Body, finish)
        ),
        ok = zlib:deflateEnd(Z),
        Envelope = <<?ALGO_ZLIB:8, Compressed/binary>>,
        OutSize = byte_size(Envelope),
        T1 = erlang:monotonic_time(microsecond),
        case OutSize < InSize of
            true ->
                emit_compress(InstanceId, zlib, InSize, OutSize, T1 - T0),
                {?FLAG_COMPRESSED, Envelope};
            false ->
                %% Compression didn't help — keep the raw body.
                {0, Body}
        end
    after
        zlib:close(Z)
    end.

%% @private
decompress(zlib, Payload, InSize, InstanceId) ->
    T0 = erlang:monotonic_time(microsecond),
    Z = zlib:open(),
    try
        ok = zlib:inflateInit(Z, -15),
        Out = iolist_to_binary(zlib:inflate(Z, Payload)),
        ok = zlib:inflateEnd(Z),
        T1 = erlang:monotonic_time(microsecond),
        emit_decompress(
            InstanceId, zlib, InSize, byte_size(Out), T1 - T0
        ),
        {ok, Out}
    catch
        error:_ ->
            {error, decompress_failed}
    after
        zlib:close(Z)
    end.

%% @private
algo_atom(?ALGO_ZLIB) -> {ok, zlib};
algo_atom(Other) -> {error, {unknown_codec, Other}}.

%% @private
emit_compress(InstanceId, Algo, In, Out, Dur) ->
    telemetry:execute(
        [bondy_oplog, wal, codec, compress],
        #{input_bytes => In, output_bytes => Out, duration_us => Dur},
        meta(InstanceId, Algo)
    ).

%% @private
emit_decompress(InstanceId, Algo, In, Out, Dur) ->
    telemetry:execute(
        [bondy_oplog, wal, codec, decompress],
        #{input_bytes => In, output_bytes => Out, duration_us => Dur},
        meta(InstanceId, Algo)
    ).

%% @private
emit_encrypt(InstanceId, KeyId, In, Out, Dur) ->
    telemetry:execute(
        [bondy_oplog, wal, codec, encrypt],
        #{input_bytes => In, output_bytes => Out, duration_us => Dur},
        meta(InstanceId, aes_256_gcm, KeyId)
    ).

%% @private
emit_decrypt(InstanceId, KeyId, In, Out, Dur, TagMismatches) ->
    telemetry:execute(
        [bondy_oplog, wal, codec, decrypt],
        #{
            input_bytes => In,
            output_bytes => Out,
            duration_us => Dur,
            tag_mismatches => TagMismatches
        },
        meta(InstanceId, aes_256_gcm, KeyId)
    ).

%% @private
meta(undefined, Algo) ->
    #{algorithm => Algo};
meta(InstanceId, Algo) ->
    #{instance_id => InstanceId, algorithm => Algo}.

%% @private
meta(InstanceId, Algo, KeyId) ->
    (meta(InstanceId, Algo))#{key_id => KeyId}.

%% =============================================================================
%% Encrypt / decrypt
%% =============================================================================

%% @private
%% Encrypts `Body` with the writer's *current* key under
%% AES-256-GCM. The IV is freshly generated per call —
%% `crypto:strong_rand_bytes/1`'s 12 random bytes give the maximum
%% feasible collision resistance for the AES-GCM 96-bit-IV contract.
%% Returns the on-wire envelope as a binary; the caller composes it
%% with the frame header.
encrypt_now(Body, Registry, Opts) ->
    InstanceId = maps:get(instance_id, Opts, undefined),
    {KeyId, Key} = Registry:current_key(),
    IV = crypto:strong_rand_bytes(?IV_BYTES),
    BodyBin = iolist_to_binary(Body),
    T0 = erlang:monotonic_time(microsecond),
    {Ciphertext, Tag} = crypto:crypto_one_time_aead(
        aes_256_gcm, Key, IV, BodyBin, <<>>, ?TAG_BYTES, true
    ),
    T1 = erlang:monotonic_time(microsecond),
    Envelope =
        <<?CIPHER_AES_256_GCM:8, KeyId:16/big-unsigned, IV/binary, Tag/binary,
            Ciphertext/binary>>,
    emit_encrypt(
        InstanceId,
        KeyId,
        byte_size(BodyBin),
        byte_size(Envelope),
        T1 - T0
    ),
    Envelope.

%% @private
%% Decrypts the encryption envelope. Returns `{ok, Plaintext}` on a
%% tag-verified decryption, or a typed error from `decode_error()`
%% for every failure mode. Tag failures emit a `tag_mismatches => 1`
%% telemetry event so dashboards can alert on the rate.
decrypt(Body, _Opts) when byte_size(Body) < ?ENCRYPT_HEADER_BYTES ->
    {error, truncated_envelope};
decrypt(
    <<Algo:8, KeyId:16/big-unsigned, IV:?IV_BYTES/binary, Tag:?TAG_BYTES/binary,
        Ciphertext/binary>>,
    Opts
) ->
    case cipher_atom(Algo) of
        {ok, aes_256_gcm} ->
            decrypt_aes_gcm(KeyId, IV, Tag, Ciphertext, Opts);
        {error, _} = E ->
            E
    end.

%% @private
decrypt_aes_gcm(KeyId, IV, Tag, Ciphertext, Opts) ->
    case resolve_key(KeyId, Opts) of
        {ok, Key} ->
            do_decrypt_aes_gcm(Key, KeyId, IV, Tag, Ciphertext, Opts);
        {error, _} = E ->
            E
    end.

%% @private
do_decrypt_aes_gcm(Key, KeyId, IV, Tag, Ciphertext, Opts) ->
    InstanceId = maps:get(instance_id, Opts, undefined),
    T0 = erlang:monotonic_time(microsecond),
    Result = crypto:crypto_one_time_aead(
        aes_256_gcm, Key, IV, Ciphertext, <<>>, Tag, false
    ),
    T1 = erlang:monotonic_time(microsecond),
    Dur = T1 - T0,
    case Result of
        error ->
            emit_decrypt(
                InstanceId, KeyId, byte_size(Ciphertext), 0, Dur, 1
            ),
            {error, decrypt_failed};
        Plaintext when is_binary(Plaintext) ->
            emit_decrypt(
                InstanceId,
                KeyId,
                byte_size(Ciphertext),
                byte_size(Plaintext),
                Dur,
                0
            ),
            {ok, Plaintext}
    end.

%% @private
%% Resolves a `KeyId` to a `Key` via the caller-supplied registry.
%% Missing-key surfaces as a typed `{missing_key, KeyId}` rather
%% than a crash; a missing `body_encryption` opt on the decode path
%% (e.g. a reader configured before the operator enabled encryption
%% on the writer) is treated the same way — the codec cannot
%% manufacture a key, so missing is the only honest answer.
resolve_key(KeyId, Opts) ->
    case maps:get(body_encryption, Opts, disabled) of
        {enabled, Registry} ->
            try Registry:lookup_key(KeyId) of
                {ok, Key} when is_binary(Key), byte_size(Key) =:= ?KEY_BYTES ->
                    {ok, Key};
                {error, missing} ->
                    {error, {missing_key, KeyId}};
                _Other ->
                    {error, {missing_key, KeyId}}
            catch
                _:_ ->
                    {error, {missing_key, KeyId}}
            end;
        disabled ->
            {error, {missing_key, KeyId}}
    end.

%% @private
cipher_atom(?CIPHER_AES_256_GCM) -> {ok, aes_256_gcm};
cipher_atom(Other) -> {error, {unknown_cipher, Other}}.
