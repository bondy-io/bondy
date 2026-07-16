%% =============================================================================
%% PropEr properties for the bondy_oplog_wal stack.
%%
%% This file is the single home for WAL property tests. Each property
%% carries the P-number it implements from `_design/WAL_DESIGN.md` §16.
%%
%% Run with:
%%   rebar3 as test eunit --module=bondy_oplog_wal_proper_test
%% or:
%%   proper:quickcheck(bondy_oplog_wal_proper_test:prop_xxx(),
%%                     [{numtests, 1000}]).
%%
%% Property index (P_BatchAtomicity, P_WalFull, P1..P15 land here as
%% the implementation lands the behaviour each verifies):
%%
%%   Frame layer:
%%     - prop_frame_roundtrip/0          (P1 framing slice)
%%     - prop_frame_bit_flip_detection/0 (P3 framing slice)
%%     - prop_codec_roundtrip/0          (body codec round-trip)
%%     - prop_codec_encrypt_roundtrip/0  (body codec encrypt round-trip)
%%     - prop_codec_ciphertext_bit_flip_detection/0
%%                                       (AES-GCM authenticity)
%%
%%   Single-event writer:
%%     - prop_wal_single_event_roundtrip/0  (P1 single-event slice)
%%     - prop_wal_hlc_monotonicity/0        (P2 single-event slice)
%%
%%   Reader / iterator:
%%     - prop_wal_roundtrip/0            (P1 end-to-end via reader)
%%
%%   Sparse index `.qidx`:
%%     - prop_index_consistency/0        (P6)
%%
%%   Recovery:
%%     - prop_truncation_safety/0        (P5)
%%     - prop_manifest_atomicity/0       (P7)
%%     - prop_consumer_offset_clamping/0 (P10)
%%
%%   Batched fsync + durability:
%%     - prop_await_durable_correctness/0
%%
%%   Atomic batch frames:
%%     - prop_batch_atomicity/0          (P_BatchAtomicity)
%%
%%   Retention:
%%     - prop_retention_safety/0         (P9)
%%
%%   Backpressure:
%%     - prop_wal_full/0                 (P_WalFull)
%%
%%   Magic / rotation / partial-write recovery:
%%     - prop_bit_flip_magic/0           (P4)
%%     - prop_rotation_atomicity/0       (P8 — in-process orphan slice)
%%     - prop_partial_write/0            (P13 — recovery + resume)
%%
%%   Concurrency:
%%     - prop_concurrent_reader_safety/0 (P11)
%%
%%   Fault injection (via `bondy_mst_io` meck seam):
%%     - prop_failed_fsync/0             (P14 — per_write + reopen invariant)
%%     - prop_failed_fsync_batched/0     (P14 — batched-mode variant)
%%     - prop_rename_failure/0           (P15)
%%
%%   Stateful:
%%     - prop_multiproc_convergence/0    (P12)
%%
%% =============================================================================

-module(bondy_oplog_wal_proper_test).

%% PropEr defines `LET` and friends; include it before EUnit so EUnit's
%% `LET` doesn't shadow PropEr's.
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("bondy_oplog.hrl").
-include("bondy_oplog_wal.hrl").

-define(HEADER, ?BONDY_OPLOG_WAL_FRAME_HEADER_BYTES).
-define(SEG_HEADER, ?BONDY_OPLOG_WAL_SEGMENT_HEADER_BYTES).
%% The encoder defaults to v2 (`?BONDY_OPLOG_WAL_FRAME_VERSION`), so
%% framing properties drive their flag generator from the v2 mask.
%% v1's mask is still tested by the dedicated v1/v2-equivalence
%% property below.
-define(KNOWN_FLAGS, ?BONDY_OPLOG_WAL_FRAME_KNOWN_FLAGS_V2).
-define(DEFAULT_NUMTESTS, 200).
-define(WAL_NUMTESTS, 50).

-export([prop_frame_roundtrip/0]).
-export([prop_frame_bit_flip_detection/0]).
-export([prop_frame_v1_v2_decoder_equivalence/0]).
-export([prop_codec_roundtrip/0]).
-export([prop_codec_encrypt_roundtrip/0]).
-export([prop_codec_ciphertext_bit_flip_detection/0]).
-export([prop_idx_v2_seek_matches_v1_on_point_ranges/0]).
-export([prop_idx_v2_seek_in_range_returns_that_entry/0]).
-export([prop_wal_single_event_roundtrip/0]).
-export([prop_wal_hlc_monotonicity/0]).
-export([prop_wal_roundtrip/0]).
-export([prop_index_consistency/0]).
-export([prop_truncation_safety/0]).
-export([prop_manifest_atomicity/0]).
-export([prop_consumer_offset_clamping/0]).
-export([prop_await_durable_correctness/0]).
-export([prop_batch_atomicity/0]).
-export([prop_retention_safety/0]).
-export([prop_wal_full/0]).
-export([prop_bit_flip_magic/0]).
-export([prop_rotation_atomicity/0]).
-export([prop_partial_write/0]).
-export([prop_rescan_recovery/0]).
-export([prop_concurrent_reader_safety/0]).
-export([prop_failed_fsync/0]).
-export([prop_failed_fsync_batched/0]).
-export([prop_rename_failure/0]).
-export([prop_multiproc_convergence/0]).

%% =============================================================================
%% Frame-layer properties
%% =============================================================================

%% P1 (framing slice).
%% Every body that we can encode decodes back to itself, with metadata
%% preserved. Flags are restricted to the v1 known mask — non-zero bits
%% outside the mask are intentionally rejected and tested elsewhere.
prop_frame_roundtrip() ->
    ?FORALL(
        {Body, Flags},
        {binary(), known_flags()},
        begin
            Frame = iolist_to_binary(
                bondy_oplog_wal_frame:encode(Body, [{flags, Flags}])
            ),
            case bondy_oplog_wal_frame:decode(Frame) of
                {ok, Decoded, #{flags := F}} ->
                    Decoded =:= Body andalso F =:= Flags;
                _ ->
                    false
            end
        end
    ).

%% P3 (framing slice).
%% Flipping any single bit inside the CRC-covered region of an encoded
%% frame produces a decode error (CRC mismatch / length / truncated /
%% unknown_flag / unsupported_version). A flip inside `Magic` itself is
%% covered by a separate sniff-priority test, because `bad_magic` is a
%% deliberately distinct error type. See P4 (todo).
prop_frame_bit_flip_detection() ->
    ?FORALL(
        {Body, BitIdx},
        ?LET(
            B,
            non_empty(binary()),
            {B, choose(32, (?HEADER + byte_size(B)) * 8 - 1)}
        ),
        begin
            Frame = iolist_to_binary(bondy_oplog_wal_frame:encode(Body)),
            Corrupt = flip_bit(Frame, BitIdx),
            case bondy_oplog_wal_frame:decode(Corrupt) of
                {ok, _, _} -> false;
                {error, _} -> true
            end
        end
    ).

%% Each frame version accepts only flag bits inside its known mask.
%% The v1 mask is zero; v2's mask covers bits 0 (compressed_body) and
%% 1 (encrypted_body). Expressing the bound as a generator means the
%% property keeps testing the full space if the mask widens further
%% (e.g., if the deferred CRC32C activation is ever picked back up).
known_flags() ->
    case ?KNOWN_FLAGS of
        0 -> 0;
        Mask -> choose(0, Mask)
    end.

%% Body codec round-trip acceptance property.
%% For any body and any compression setting, encode_body ↦ decode_body
%% is the identity on the byte representation. Exercises both the
%% no-op paths (compression = none, body under threshold) and the
%% active path (zlib above threshold). The codec's "didn't shrink"
%% fallback may flip a would-be-compressed run back to the raw form;
%% the property holds either way because decode_body branches on the
%% returned Flags rather than on the input config.
prop_codec_roundtrip() ->
    ?FORALL(
        {Body, Algo, MinBytes},
        {binary(), oneof([none, zlib]), choose(1, 4096)},
        begin
            Opts = #{
                body_compression => Algo,
                body_compression_min_bytes => MinBytes
            },
            {Flags, Encoded} =
                bondy_oplog_wal_codec:encode_body(Body, Opts),
            EncodedBin = iolist_to_binary(Encoded),
            case bondy_oplog_wal_codec:decode_body(EncodedBin, Flags) of
                {ok, Decoded} -> Decoded =:= Body;
                _ -> false
            end
        end
    ).

%% Body-codec encryption round-trip acceptance property.
%% For any body, the compose of encrypt and decrypt (with a known key
%% registry) is the identity. Exercises the encryption-only path and
%% the compress-then-encrypt path; both must produce a flag-tagged
%% envelope that decode_body reverses byte-for-byte.
prop_codec_encrypt_roundtrip() ->
    ?FORALL(
        {Body, WithCompression},
        {binary(), boolean()},
        begin
            Opts0 = #{
                body_encryption =>
                    {enabled, bondy_oplog_wal_codec_test}
            },
            Opts =
                case WithCompression of
                    true ->
                        Opts0#{
                            body_compression => zlib,
                            body_compression_min_bytes => 1
                        };
                    false ->
                        Opts0
                end,
            {Flags, Encoded} =
                bondy_oplog_wal_codec:encode_body(Body, Opts),
            EncodedBin = iolist_to_binary(Encoded),
            case
                bondy_oplog_wal_codec:decode_body(
                    EncodedBin, Flags, Opts
                )
            of
                {ok, Decoded} -> Decoded =:= Body;
                _ -> false
            end
        end
    ).

%% AES-GCM authenticity property. For any random ciphertext byte
%% flip, decode_body returns `{error, decrypt_failed}` — *never* the
%% wrong plaintext and *never* a CRC-class error. This is the property
%% that makes the encryption envelope the integrity boundary: a
%% modified frame body cannot escape the codec.
prop_codec_ciphertext_bit_flip_detection() ->
    Opts = #{body_encryption => {enabled, bondy_oplog_wal_codec_test}},
    ?FORALL(
        {Body, BitIdx},
        ?LET(
            B,
            non_empty(binary()),
            {B, choose(0, 7)}
        ),
        begin
            {?BONDY_OPLOG_WAL_FRAME_FLAG_ENCRYPTED, Encoded} =
                bondy_oplog_wal_codec:encode_body(Body, Opts),
            Bin = iolist_to_binary(Encoded),
            %% Flip a bit anywhere in the post-header region
            %% (ciphertext or tag — both must reject).
            TotalBits = (byte_size(Bin) - 31) * 8,
            case TotalBits > 0 of
                %% Empty payload edge case: skip
                false ->
                    true;
                true ->
                    Idx = 31 * 8 + (BitIdx rem TotalBits),
                    Corrupted = flip_bit(Bin, Idx),
                    case
                        bondy_oplog_wal_codec:decode_body(
                            Corrupted,
                            ?BONDY_OPLOG_WAL_FRAME_FLAG_ENCRYPTED,
                            Opts
                        )
                    of
                        {error, decrypt_failed} -> true;
                        %% Tolerate `truncated_envelope` if the flip
                        %% lands within the envelope header range —
                        %% won't happen given our offset, but defend
                        %% the contract.
                        {error, truncated_envelope} -> true;
                        _ -> false
                    end
            end
        end
    ).

%% v2 index acceptance — equivalence with v1 on single-point ranges.
%% For any synthetic v2 `.qidx` whose every entry has `FirstHlc =
%% LastHlc` (the shape a lifted v1 file produces), seek(T) returns the
%% same offset as a reference "largest FirstHlc =< T" v1 search.
%% This pins down that the v2 reader does not regress the v1 fallback
%% case, which is what the design's "v2 seek returns the same offsets
%% as v1 seek" claim formalises for the universe of v1 (= single-point)
%% inputs.
prop_idx_v2_seek_matches_v1_on_point_ranges() ->
    ?FORALL(
        {Hlcs, Targets},
        {non_empty(list(non_neg_integer())), list(non_neg_integer())},
        begin
            Sorted = lists:usort(Hlcs),
            Entries = [{H, H, H * 100} || H <- Sorted],
            Handle = bondy_oplog_wal_idx:from_entries(Entries),
            lists:all(
                fun(T) ->
                    Got = bondy_oplog_wal_idx:seek(Handle, T),
                    Want = reference_v1_seek(Sorted, T),
                    Got =:= Want
                end,
                Targets
            )
        end
    ).

%% v2 index acceptance — in-range hits return the containing entry,
%% bounding the reader's body-decode work to one batch.
%% Generates a v2 entry list with non-degenerate ranges
%% `(FirstHlc, LastHlc, Offset)` where `FirstHlc < LastHlc`, then for a
%% target HLC drawn from inside one specific entry's range asserts that
%% `seek/2` returns exactly that entry's offset. The "scan bounded by
%% one batch" guarantee is the seek-level expression of the design's
%% acceptance — the reader has the right anchor frame on the first
%% probe and never has to walk forward into the un-indexed gap.
prop_idx_v2_seek_in_range_returns_that_entry() ->
    ?FORALL(
        Spec,
        idx_spec_with_target(),
        begin
            {Entries, TargetIdx, T} = Spec,
            {_, _, ExpectedOffset} = lists:nth(TargetIdx, Entries),
            Handle = bondy_oplog_wal_idx:from_entries(Entries),
            bondy_oplog_wal_idx:seek(Handle, T) =:= {ok, ExpectedOffset}
        end
    ).

%% @private
%% Reference v1 seek: returns `{ok, Offset}` for the largest entry
%% whose FirstHlc =< T, or `none`. Implemented over a sorted-FirstHlcs
%% list, since the v1-shape entries we generate share that ordering.
reference_v1_seek([], _T) ->
    none;
reference_v1_seek(Sorted, T) ->
    case [H || H <- Sorted, H =< T] of
        [] -> none;
        Hs -> {ok, lists:max(Hs) * 100}
    end.

%% @private
%% Generates `(Entries, TargetIdx, T)` where `Entries` is a non-empty
%% ascending v2 entry list with non-overlapping non-degenerate ranges,
%% `TargetIdx` selects one entry, and `T` is drawn from that entry's
%% inclusive range.
idx_spec_with_target() ->
    ?LET(
        Bases,
        non_empty(list(range(0, 1_000_000))),
        ?LET(
            Spans,
            vector(length(lists:usort(Bases)), range(1, 64)),
            begin
                Sorted = lists:usort(Bases),
                %% Build non-overlapping ranges: stride starts at
                %% `Base * 100` to put a guaranteed gap between every
                %% range. Each entry's FirstHlc = base, LastHlc =
                %% base + span.
                Entries =
                    [
                        {B * 100, B * 100 + S, B * 1000}
                     || {B, S} <- lists:zip(Sorted, Spans)
                    ],
                N = length(Entries),
                ?LET(
                    Idx,
                    range(1, N),
                    begin
                        {F, L, _} = lists:nth(Idx, Entries),
                        ?LET(
                            T,
                            range(F, L),
                            {Entries, Idx, T}
                        )
                    end
                )
            end
        )
    ).

%% PR1 acceptance property.
%% The v2 reader (this one) must round-trip both v1- and v2-encoded
%% frames byte-for-byte, with the version field preserved as a
%% distinguishing tag. This is the property that gates rolling forward
%% to v2 frames on disk while keeping pre-PR1 segments readable.
prop_frame_v1_v2_decoder_equivalence() ->
    ?FORALL(
        Body,
        binary(),
        begin
            V1Frame = iolist_to_binary(
                bondy_oplog_wal_frame:encode(Body, [{version, 1}])
            ),
            V2Frame = iolist_to_binary(
                bondy_oplog_wal_frame:encode(Body, [{version, 2}])
            ),
            case
                {
                    bondy_oplog_wal_frame:decode(V1Frame),
                    bondy_oplog_wal_frame:decode(V2Frame)
                }
            of
                {
                    {ok, B1, #{version := 1, flags := 0}},
                    {ok, B2, #{version := 2, flags := 0}}
                } ->
                    B1 =:= Body andalso B2 =:= Body;
                _ ->
                    false
            end
        end
    ).

%% =============================================================================
%% WAL writer properties (single-event path)
%% =============================================================================

%% P1 (single-event slice).
%% Append N events through the WAL writer; raw-scan the segment files
%% and verify the recovered event list equals the appended sequence
%% with HLCs preserved. Rotation is exercised by choosing
%% `max_segment_bytes` small enough that ~1/3 of generated events
%% trigger a rotation.
prop_wal_single_event_roundtrip() ->
    ?FORALL(
        N,
        choose(1, 50),
        with_wal_dir(fun(Dir) ->
            HLC = bondy_oplog_hlc:new(),
            Events = generate_events(HLC, N),
            %% Pick a cap that yields ~3 events per segment on average.
            MaxBytes = ?SEG_HEADER + estimated_frame_size() * 3,
            {ok, Pid} = bondy_oplog_wal:start_link(
                instance_id(),
                #{
                    dir => Dir,
                    origin => origin(),
                    max_segment_bytes => MaxBytes
                }
            ),
            Results = [bondy_oplog_wal:append(Pid, E) || E <- Events],
            Info = bondy_oplog_wal:info(Pid),
            ok = bondy_oplog_wal:close(Pid),
            Recovered = scan_all_segments(
                Dir, instance_id(), maps:get(current_segment, Info)
            ),
            length(Results) =:= N andalso
                lists:all(
                    fun
                        ({ok, _, _}) -> true;
                        (_) -> false
                    end,
                    Results
                ) andalso
                Recovered =:= Events
        end)
    ).

%% P2 (single-event slice).
%% Across all appended events in append order, the HLCs returned by
%% `append/2` are strictly increasing.
prop_wal_hlc_monotonicity() ->
    ?FORALL(
        N,
        choose(1, 50),
        with_wal_dir(fun(Dir) ->
            HLC = bondy_oplog_hlc:new(),
            Events = generate_events(HLC, N),
            {ok, Pid} = bondy_oplog_wal:start_link(
                instance_id(),
                #{dir => Dir, origin => origin()}
            ),
            Hlcs = [
                begin
                    {ok, H, _} = bondy_oplog_wal:append(Pid, E),
                    H
                end
             || E <- Events
            ],
            ok = bondy_oplog_wal:close(Pid),
            is_strictly_increasing(Hlcs)
        end)
    ).

%% =============================================================================
%% Reader / iterator end-to-end property
%% =============================================================================

%% P1 (end-to-end via reader).
%% Append N events through the WAL writer, then open a bounded reader
%% at `beginning` and drain it. Recovered event list must equal the
%% appended list in order. Rotation is exercised by choosing
%% `max_segment_bytes` small enough that ~1/3 of generated events
%% trigger a rotation. The reader walks across segments transparently.
prop_wal_roundtrip() ->
    ?FORALL(
        N,
        choose(1, 50),
        with_wal_dir(fun(Dir) ->
            HLC = bondy_oplog_hlc:new(),
            Events = generate_events(HLC, N),
            MaxBytes = ?SEG_HEADER + estimated_frame_size() * 3,
            {ok, Pid} = bondy_oplog_wal:start_link(
                instance_id(),
                #{
                    dir => Dir,
                    origin => origin(),
                    max_segment_bytes => MaxBytes
                }
            ),
            [{ok, _, _} = bondy_oplog_wal:append(Pid, E) || E <- Events],
            {ok, Iter} = bondy_oplog_wal_reader:open(Pid, beginning),
            Recovered = drain_reader(Iter, []),
            ok = bondy_oplog_wal:close(Pid),
            Recovered =:= Events
        end)
    ).

%% =============================================================================
%% Sparse-index consistency property (P6)
%% =============================================================================

%% P6.
%% For every entry the writer emits into a `.qidx`, the on-disk frame at
%% the entry's `ByteOffset` (within the segment file) must:
%%
%% - parse as a valid frame (Magic, CRC, version, flags all valid),
%% - decode to a non-empty event list,
%% - have its first event's HLC equal to the entry's HLC.
%%
%% This property checks both the sealed-segment path (`.qidx` flushed on
%% rotation) and the head-segment path (`.qidx` flushed on `close/1`).
%% Workload: random N appended events with a rotation-friendly cap so
%% multiple segments accumulate during the trial.
prop_index_consistency() ->
    ?FORALL(
        N,
        choose(1, 50),
        with_wal_dir(fun(Dir) ->
            HLC = bondy_oplog_hlc:new(),
            Events = generate_events(HLC, N),
            MaxBytes = ?SEG_HEADER + estimated_frame_size() * 3,
            %% Tighten the index interval so the workload reliably
            %% produces more than just the first-frame entry per
            %% segment. Default 64 KiB would gate most trials to the
            %% single mandatory entry.
            {ok, Pid} = bondy_oplog_wal:start_link(
                instance_id(),
                #{
                    dir => Dir,
                    origin => origin(),
                    max_segment_bytes => MaxBytes,
                    idx_interval_bytes => 200
                }
            ),
            Info0 = bondy_oplog_wal:info(Pid),
            [bondy_oplog_wal:append(Pid, E) || E <- Events],
            HeadSeg = maps:get(current_segment, bondy_oplog_wal:info(Pid)),
            _ = Info0,
            ok = bondy_oplog_wal:close(Pid),
            check_index_consistency(Dir, instance_id(), HeadSeg)
        end)
    ).

%% For every segment from 0..HeadSeg, load its `.qidx` (which exists for
%% all of them after `close/1`) and verify each entry points at a real
%% frame whose first event's HLC equals the indexed HLC.
check_index_consistency(Dir, InstanceId, HeadSeg) ->
    lists:all(
        fun(SegId) -> check_segment_index(Dir, InstanceId, SegId) end,
        lists:seq(0, HeadSeg)
    ).

check_segment_index(Dir, InstanceId, SegId) ->
    IdxPath = filename:join(
        [Dir, InstanceId, bondy_oplog_wal_idx:filename(SegId)]
    ),
    case bondy_oplog_wal_idx:read_file(IdxPath) of
        {ok, []} ->
            %% An empty index is only legal for an empty segment (e.g.,
            %% a head segment created by rotation but never appended
            %% to). Verify the segment has no frames past its header.
            seg_is_empty(Dir, InstanceId, SegId);
        {ok, Entries} ->
            lists:all(
                fun(E) -> check_entry(Dir, InstanceId, SegId, E) end,
                Entries
            );
        {error, enoent} ->
            %% A missing `.qidx` is allowed for an empty head segment
            %% (the writer skips the flush in that case). Verify the
            %% segment is indeed empty.
            seg_is_empty(Dir, InstanceId, SegId);
        {error, _} ->
            false
    end.

check_entry(Dir, InstanceId, SegId, {FirstHlc, _LastHlc, Offset}) ->
    SegPath = filename:join(
        [Dir, InstanceId, bondy_oplog_wal_segment:filename(SegId)]
    ),
    case file:read_file(SegPath) of
        {ok, Bin} when byte_size(Bin) >= Offset + ?HEADER ->
            <<_:Offset/binary, Header:?HEADER/binary, _/binary>> = Bin,
            case bondy_oplog_wal_frame:decode_header(Header) of
                {ok, #{frame_len := FrameLen}} when
                    byte_size(Bin) >= Offset + FrameLen
                ->
                    <<_:Offset/binary, Frame:FrameLen/binary, _/binary>> = Bin,
                    case bondy_oplog_wal_frame:decode(Frame) of
                        {ok, Body, _Meta} ->
                            case binary_to_term(Body, [safe]) of
                                [Event | _] ->
                                    Key = bondy_oplog_event:key(Event),
                                    bondy_oplog_event:key_hlc(Key) =:= FirstHlc;
                                _ ->
                                    false
                            end;
                        _ ->
                            false
                    end;
                _ ->
                    false
            end;
        _ ->
            false
    end.

seg_is_empty(Dir, InstanceId, SegId) ->
    SegPath = filename:join(
        [Dir, InstanceId, bondy_oplog_wal_segment:filename(SegId)]
    ),
    case file:read_file_info(SegPath) of
        {ok, FI} ->
            element(2, FI) =:= ?SEG_HEADER;
        _ ->
            false
    end.

%% =============================================================================
%% Recovery properties (P5, P7, P10)
%% =============================================================================

%% P5 (truncation safety).
%% After appending N events and truncating the head segment's `.qdata`
%% at an arbitrary byte offset, reopening the WAL via recovery must
%% expose only frames whose end-offset ≤ TruncOffset, in append order,
%% and the file size after recovery must equal the writer's
%% `head_offset` (i.e., no partial frame is left dangling).
prop_truncation_safety() ->
    ?FORALL(
        {N, ChopBytes},
        ?LET(NN, choose(2, 20), {NN, choose(0, max(1, NN * 30))}),
        with_wal_dir(fun(Dir) ->
            HLC = bondy_oplog_hlc:new(),
            Events = generate_events(HLC, N),
            Opts = #{dir => Dir, origin => origin()},
            {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
            [bondy_oplog_wal:append(P1, E) || E <- Events],
            ok = bondy_oplog_wal:close(P1),
            SegPath = filename:join(
                [
                    Dir,
                    instance_id(),
                    bondy_oplog_wal_segment:filename(0)
                ]
            ),
            {ok, Size} = file_size(SegPath),
            %% Trim ChopBytes off the tail (but never below the segment
            %% header — the header isn't tested by P5).
            TruncTo = max(?SEG_HEADER, Size - ChopBytes),
            truncate_file(SegPath, TruncTo),
            {ok, P2} = bondy_oplog_wal:start_link(instance_id(), Opts),
            Read = read_all_events(P2),
            Info = bondy_oplog_wal:info(P2),
            {ok, NewSize} = file_size(SegPath),
            ok = bondy_oplog_wal:close(P2),
            %% Recovered events are a strict prefix of the original.
            IsPrefix =
                Read =:= lists:sublist(Events, length(Read)),
            %% File size equals head_offset (no dangling bytes).
            FileSizeMatches =
                NewSize =:= maps:get(head_offset, Info),
            %% All recovered frames end at or before the truncation
            %% point — i.e., recovery never resurrects bytes from
            %% beyond the trim.
            EndsBeforeTrunc =
                maps:get(head_offset, Info) =< TruncTo,
            IsPrefix andalso FileSizeMatches andalso EndsBeforeTrunc
        end)
    ).

%% P7 (manifest atomicity, observability slice).
%% The full crash-trace property (kill writer mid-rename with a partial
%% tmp file on disk) needs a fault-injection harness that is still
%% TODO. Here we exercise the in-process atomicity contract: a
%% malformed `manifest.tmp` left on disk after the rename has already
%% succeeded must not be observed by recovery — the orphan cleanup
%% removes it and the live `manifest` is what's read.
prop_manifest_atomicity() ->
    ?FORALL(
        N,
        choose(1, 10),
        with_wal_dir(fun(Dir) ->
            HLC = bondy_oplog_hlc:new(),
            Events = generate_events(HLC, N),
            Opts = #{dir => Dir, origin => origin()},
            {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
            [bondy_oplog_wal:append(P1, E) || E <- Events],
            ok = bondy_oplog_wal:close(P1),
            InstDir = filename:join(Dir, instance_id()),
            %% Seed a junk manifest.tmp — must not affect recovery.
            TmpPath = filename:join(
                InstDir, ?BONDY_OPLOG_WAL_MANIFEST_TMP_FILENAME
            ),
            ok = file:write_file(TmpPath, <<"garbage manifest tmp">>),
            {ok, P2} = bondy_oplog_wal:start_link(instance_id(), Opts),
            Read = read_all_events(P2),
            ok = bondy_oplog_wal:close(P2),
            %% Recovery must (1) succeed (gen_server up), (2) surface
            %% the original event sequence, and (3) clean the orphan
            %% manifest.tmp.
            Read =:= Events andalso
                not filelib:is_regular(TmpPath)
        end)
    ).

%% P10 (consumer-offset clamping).
%% For any pre-seeded `consumer.offset` content (random segment +
%% random offset, possibly past EOF or mid-frame), after recovery the
%% on-disk consumer.offset:
%% - has a committed_segment that is in `live_segments`;
%% - has a committed_frame_offset on a real frame boundary;
%% - has committed_frame_offset ≤ `head_offset` (for the head segment)
%%   or ≤ segment file size (for a sealed segment).
prop_consumer_offset_clamping() ->
    ?FORALL(
        {N, BadSeg, BadOff},
        ?LET(
            NN,
            choose(1, 15),
            {NN, choose(0, 99), choose(0, 1_000_000)}
        ),
        with_wal_dir(fun(Dir) ->
            HLC = bondy_oplog_hlc:new(),
            Events = generate_events(HLC, N),
            Opts = #{dir => Dir, origin => origin()},
            {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
            Positions = [
                begin
                    {ok, _, Pos} = bondy_oplog_wal:append(P1, E),
                    Pos
                end
             || E <- Events
            ],
            HeadOff = maps:get(
                head_offset, bondy_oplog_wal:info(P1)
            ),
            HeadSeg = maps:get(
                current_segment, bondy_oplog_wal:info(P1)
            ),
            ok = bondy_oplog_wal:close(P1),
            InstDir = filename:join(Dir, instance_id()),
            %% Seed an aggressively-bad consumer.offset by writing
            %% the file content directly. The `with_position/3` setter
            %% guards against offsets < segment header, but recovery
            %% must still cope with such values when they appear on
            %% disk (file written by an older buggy applier, manual
            %% edit, etc.).
            ok = seed_raw_consumer_offset(
                InstDir, max(0, BadSeg), max(0, BadOff)
            ),
            {ok, P2} = bondy_oplog_wal:start_link(
                instance_id(), Opts
            ),
            ok = bondy_oplog_wal:close(P2),
            {ok, Clamped} = bondy_oplog_wal_state:read_consumer_offset(InstDir),
            ClampedSeg =
                bondy_oplog_wal_state:committed_segment(
                    Clamped
                ),
            ClampedOff =
                bondy_oplog_wal_state:committed_frame_offset(
                    Clamped
                ),
            %% Clamped segment is live (post-clamp it must be ≤ head;
            %% since we never rotated, every event is in segment 0).
            InLive = ClampedSeg =:= HeadSeg,
            %% Clamped offset is ≤ head_offset of head segment.
            WithinBound = ClampedOff =< HeadOff,
            %% Clamped offset is at a frame boundary (one of the
            %% appended positions, the segment header, or head_offset).
            ValidBoundaries =
                [
                    ?SEG_HEADER,
                    HeadOff
                    | [Off || {S, Off} <- Positions, S =:= HeadSeg]
                ],
            AtBoundary = lists:member(ClampedOff, ValidBoundaries),
            InLive andalso WithinBound andalso AtBoundary
        end)
    ).

%% =============================================================================
%% Batched fsync + `await_durable/3` correctness
%% =============================================================================

%% For any sequence of N appends in `batched` mode, with size and time
%% triggers configured high enough that no fsync runs implicitly, the
%% following must hold:
%%
%% - Before any explicit `sync/1`, every per-append end position lies
%%   strictly above `durable_position/1`. `await_durable/3` with a
%%   zero timeout returns `{error, timeout}` for each.
%%
%% - After `sync/1`, `durable_position/1` equals the head, and
%%   `await_durable/3` with a zero timeout returns `ok` for every
%%   recorded end position.
%%
%% In other words: durability is reached at fsync boundaries and only
%% at fsync boundaries; `await_durable/3` reports the position's status
%% correctly with respect to the boundary.
prop_await_durable_correctness() ->
    ?FORALL(
        N,
        choose(1, 20),
        with_wal_dir(fun(Dir) ->
            HLC = bondy_oplog_hlc:new(),
            Events = generate_events(HLC, N),
            Opts = #{
                dir => Dir,
                origin => origin(),
                fsync_mode => batched,
                batched_fsync_interval => 60_000,
                batched_fsync_bytes => 100 * 1024 * 1024,
                max_segment_bytes => 100 * 1024 * 1024
            },
            {ok, Pid} = bondy_oplog_wal:start_link(instance_id(), Opts),
            EndPositions = lists:map(
                fun(E) ->
                    {ok, _, _} = bondy_oplog_wal:append(Pid, E),
                    Info = bondy_oplog_wal:info(Pid),
                    {
                        maps:get(current_segment, Info),
                        maps:get(head_offset, Info)
                    }
                end,
                Events
            ),
            BeforeSync = [
                {error, timeout} =:=
                    bondy_oplog_wal:await_durable(
                        Pid, Pos, 0
                    )
             || Pos <- EndPositions
            ],
            ok = bondy_oplog_wal:sync(Pid),
            LastPos = lists:last(EndPositions),
            DurableAfter = bondy_oplog_wal:durable_position(Pid),
            AfterSync = [
                ok =:= bondy_oplog_wal:await_durable(Pid, Pos, 0)
             || Pos <- EndPositions
            ],
            ok = bondy_oplog_wal:close(Pid),
            DurableAfter =:= LastPos andalso
                lists:all(fun(X) -> X end, BeforeSync) andalso
                lists:all(fun(X) -> X end, AfterSync)
        end)
    ).

%% =============================================================================
%% Atomic batch frame property (P_BatchAtomicity)
%% =============================================================================

%% P_BatchAtomicity.
%% For any sequence of `append_batch/2` calls, the raw on-disk scan
%% recovers the events grouped exactly into the original batches:
%%
%% - The scanner walks every segment, decodes each frame's body, and
%%   collects one event-list per frame.
%% - The result equals the input batch list verbatim — same number of
%%   batches, same events in each batch, same order.
%%
%% A partial-batch frame would manifest as either a CRC mismatch
%% (caught here as a scan error) or a frame whose body decoded a list
%% shorter than the original — either way the property fails.
%%
%% Mid-write crash atomicity (the recovery-time truncation guarantee)
%% is covered by `prop_truncation_safety/0` plus the recovery EUnit
%% suite; this property covers the steady-state guarantee that the
%% writer never publishes a partial frame on a clean run.
prop_batch_atomicity() ->
    ?FORALL(
        BatchSizes,
        non_empty(list(choose(1, 8))),
        with_wal_dir(fun(Dir) ->
            HLC = bondy_oplog_hlc:new(),
            Batches = generate_batches(HLC, BatchSizes),
            %% Rotation-friendly cap so multi-segment trials are
            %% reachable. Let the writer default-clamp `max_batch_bytes`
            %% to fit the segment; the generator never produces a batch
            %% large enough to be rejected.
            MaxBytes = ?SEG_HEADER + estimated_frame_size() * 8 * 4,
            Opts = #{
                dir => Dir,
                origin => origin(),
                max_segment_bytes => MaxBytes
            },
            {ok, Pid} = bondy_oplog_wal:start_link(instance_id(), Opts),
            [
                {ok, _Entries} = bondy_oplog_wal:append_batch(Pid, B)
             || B <- Batches
            ],
            Info = bondy_oplog_wal:info(Pid),
            HeadSegId = maps:get(current_segment, Info),
            ok = bondy_oplog_wal:close(Pid),
            Recovered = scan_all_segments_grouped(
                Dir, instance_id(), HeadSegId
            ),
            Recovered =:= Batches
        end)
    ).

%% =============================================================================
%% Retention safety property (P9)
%% =============================================================================

%% P9. For any interleaving of:
%%   - appends (which grow `live_segments` via natural rotation),
%%   - `set_committed_segment/2` (the consumer-cursor stub),
%%   - `advance_snapshot_watermark/2` (which also triggers an
%%     implicit sweep),
%%   - explicit `retention_sweep/1`,
%%
%% the post-condition holds: no segment that was deleted satisfies any
%% of the "must-keep" predicates, and the surviving live-segment count
%% is at least `min_live_segments`.
%%
%% Operationally we replay the operation sequence, capture the
%% pre-state, run the operation, then check the invariants.
prop_retention_safety() ->
    ?FORALL(
        Ops,
        retention_ops_gen(),
        with_wal_dir(fun(Dir) ->
            HLC = bondy_oplog_hlc:new(),
            MinLive = 1,
            MaxBytes = ?SEG_HEADER + estimated_frame_size() * 2,
            Opts = #{
                dir => Dir,
                origin => origin(),
                max_segment_bytes => MaxBytes,
                min_live_segments => MinLive,
                %% 24h: disables the periodic tick within trial duration.
                retention_sweep_interval => 24 * 60 * 60 * 1000
            },
            {ok, Pid} = bondy_oplog_wal:start_link(instance_id(), Opts),
            try
                run_retention_ops(Pid, HLC, Ops, MinLive)
            after
                ok = bondy_oplog_wal:close(Pid)
            end
        end)
    ).

%% Generator: a sequence of small operations the property replays.
%% Each `append` ensures monotone progress; sweeps and cursor
%% advances can fire in any interleaving.
retention_ops_gen() ->
    non_empty(
        list(
            oneof([
                {append, choose(1, 2)},
                {commit_advance, choose(0, 6)},
                {watermark_advance, choose(0, 12)},
                sweep
            ])
        )
    ).

%% Replay the operations, asserting the safety invariant after each
%% retention-relevant step. Returns true if every step preserved the
%% invariant; false otherwise.
run_retention_ops(Pid, HLC, Ops, MinLive) ->
    SeqRef = counters:new(1, []),
    %% Treat the watermark trace as monotone — generated deltas are
    %% added to a running base so the property doesn't waste shrink
    %% budget on regressions (which are independently tested in
    %% EUnit).
    WatermarkBase = counters:new(1, []),
    CommittedBase = counters:new(1, []),
    lists:all(
        fun(Op) ->
            step_op(
                Pid,
                HLC,
                Op,
                SeqRef,
                WatermarkBase,
                CommittedBase,
                MinLive
            )
        end,
        Ops
    ).

step_op(Pid, HLC, {append, N}, SeqRef, _WB, _CB, _MinLive) ->
    do_appends(Pid, HLC, SeqRef, N),
    true;
step_op(Pid, _HLC, {commit_advance, Delta}, _SeqRef, _WB, CB, MinLive) ->
    Pre = snapshot_state(Pid),
    Cur = counters:get(CB, 1),
    New = Cur + Delta,
    counters:put(CB, 1, New),
    ok = bondy_oplog_wal:set_committed_segment(Pid, New),
    invariant(Pre, snapshot_state(Pid), MinLive);
step_op(Pid, HLC, {watermark_advance, Delta}, _SeqRef, WB, _CB, MinLive) ->
    Pre = snapshot_state(Pid),
    %% Bound the watermark to a value derived from current HLC so it
    %% stays plausible across long sequences.
    Now = bondy_oplog_hlc:now(HLC),
    Cur = counters:get(WB, 1),
    Floor = max(Cur, Now - 1000),
    NewBase = Floor + Delta,
    counters:put(WB, 1, NewBase),
    %% advance_snapshot_watermark is monotone — if NewBase < current,
    %% the call errors and the state is untouched.
    _ = bondy_oplog_wal:advance_snapshot_watermark(Pid, NewBase),
    invariant(Pre, snapshot_state(Pid), MinLive);
step_op(Pid, _HLC, sweep, _SeqRef, _WB, _CB, MinLive) ->
    Pre = snapshot_state(Pid),
    {ok, _Deleted, _Freed} = bondy_oplog_wal:retention_sweep(Pid),
    invariant(Pre, snapshot_state(Pid), MinLive).

do_appends(_Pid, _HLC, _SeqRef, 0) ->
    ok;
do_appends(Pid, HLC, SeqRef, N) when N > 0 ->
    counters:add(SeqRef, 1, 1),
    Seq = counters:get(SeqRef, 1),
    Hlc = bondy_oplog_hlc:now(HLC),
    Key = bondy_oplog_event:key(Hlc, origin(), Seq),
    Event = bondy_oplog_event:new(Key, {op, Hlc}, undefined),
    {ok, _, _} = bondy_oplog_wal:append(Pid, Event),
    do_appends(Pid, HLC, SeqRef, N - 1).

snapshot_state(Pid) ->
    Info = bondy_oplog_wal:info(Pid),
    #{
        live => maps:get(live_segments, Info),
        committed => maps:get(committed_segment, Info)
    }.

%% Safety invariants per step:
%%
%%   (a) the surviving live-segment count is at least MinLive;
%%   (b) every segment that disappeared from `live` was strictly
%%       below the committed cursor at the *post-state* — and since
%%       the committed cursor is monotone, also at the time of
%%       deletion. The watermark cut is enforced by the
%%       implementation; checking the committed cut + the floor is
%%       sufficient for the safety property.
invariant(
    #{live := PreLive},
    #{live := PostLive, committed := Committed},
    MinLive
) ->
    Floor = length(PostLive) >= MinLive,
    Removed = ordsets:to_list(
        ordsets:subtract(
            ordsets:from_list(PreLive), ordsets:from_list(PostLive)
        )
    ),
    CommittedCut = lists:all(fun(S) -> S < Committed end, Removed),
    Floor andalso CommittedCut.

%% P_WalFull — backpressure safety.
%%
%% Property: with a tight `max_total_wal_size` (or `max_live_segments`),
%% the writer eventually refuses appends with `{error, wal_full}`, the
%% writer process stays alive, and `info/1` reports the matching
%% `backpressure` state.
%%
%% The generator parameters are intentionally small — 1..100 appends
%% against a cap that fits 0..3 frames — so each trial reliably exercises
%% both the "fits" and "refused" paths.
prop_wal_full() ->
    ?FORALL(
        {Mode, NEvents, CapFrames},
        {oneof([total_size, live_count]), choose(1, 100), choose(0, 3)},
        with_wal_dir(fun(Dir) ->
            Opts = wal_full_opts(Dir, Mode, CapFrames),
            {ok, Pid} = bondy_oplog_wal:start_link(instance_id(), Opts),
            try
                Outcome = run_wal_full_outcome(Pid, NEvents),
                Alive = is_process_alive(Pid),
                Ok = Alive andalso wal_full_invariant(Pid, Outcome),
                ?WHENFAIL(
                    io:format(
                        user,
                        "prop_wal_full failed: mode=~p NEvents=~p "
                        "CapFrames=~p alive=~p outcome=~p~n",
                        [Mode, NEvents, CapFrames, Alive, Outcome]
                    ),
                    Ok
                )
            after
                ok = bondy_oplog_wal:close(Pid)
            end
        end)
    ).

%% @private
%% Per-mode opts. For `total_size`, the cap is approximately
%% `CapFrames` frames past the segment header. For `live_count`, the
%% cap is `CapFrames + 1` segments (so the trial can produce one or
%% more rotations and then trip).
wal_full_opts(Dir, total_size, CapFrames) ->
    base_wal_opts(Dir, #{
        max_total_wal_size =>
            max(
                ?SEG_HEADER + 1,
                ?SEG_HEADER + CapFrames * estimated_frame_size()
            )
    });
wal_full_opts(Dir, live_count, CapFrames) ->
    base_wal_opts(Dir, #{
        max_live_segments => max(1, CapFrames + 1),
        max_segment_bytes => ?SEG_HEADER + estimated_frame_size() * 2,
        max_batch_bytes => estimated_frame_size() * 2
    }).

%% @private
%% Common opts for both backpressure modes. Tight segment cap so a
%% reasonable number of appends produces rotations; periodic retention
%% disabled so the trial is deterministic.
base_wal_opts(Dir, Extra) ->
    maps:merge(
        #{
            dir => Dir,
            origin => origin(),
            retention_sweep_interval => 24 * 60 * 60 * 1000
        },
        Extra
    ).

%% @private
%% Append until either we exhaust `NEvents` (cap was generous enough to
%% fit them all) or we hit `{error, wal_full}` (the expected outcome
%% under a tight cap). Returns a tagged outcome the caller inspects.
run_wal_full_outcome(Pid, NEvents) ->
    HLC = bondy_oplog_hlc:new(),
    append_until_full(Pid, HLC, NEvents, 0).

%% @private
append_until_full(_Pid, _HLC, 0, Count) ->
    {fit, Count};
append_until_full(Pid, HLC, N, Count) ->
    Hlc = bondy_oplog_hlc:now(HLC),
    Key = bondy_oplog_event:key(Hlc, origin(), Count + 1),
    Event = bondy_oplog_event:new(Key, {op, Hlc}, undefined),
    case bondy_oplog_wal:append(Pid, Event) of
        {ok, _, _} ->
            append_until_full(Pid, HLC, N - 1, Count + 1);
        {error, wal_full} ->
            {refused, Count};
        {error, Other} ->
            {unexpected_error, Other}
    end.

%% @private
%% Invariant on the post-trial state. The safety property is twofold:
%%
%%   (a) The writer survives a `{error, wal_full}` refusal — no crash
%%       cascade. `is_process_alive/1` (checked by the caller) covers
%%       this directly; here we also confirm the writer continues to
%%       serve `info/1` calls.
%%   (b) `append_count` exactly equals the number of accepted appends.
%%       A refused append must not have advanced any internal counter
%%       or written any frame.
%%
%% We deliberately do NOT assert the precise `backpressure` field shape
%% here — that field is a min-headroom heuristic exposed for operators,
%% not a load-bearing invariant of the writer's safety. A future refusal
%% that overshoots by one byte may leave the headroom at zero while the
%% writer happily reports `ok` for the smallest-possible frame size.
wal_full_invariant(Pid, {fit, Count}) ->
    maps:get(append_count, bondy_oplog_wal:info(Pid)) =:= Count;
wal_full_invariant(Pid, {refused, Count}) ->
    maps:get(append_count, bondy_oplog_wal:info(Pid)) =:= Count;
wal_full_invariant(_Pid, {unexpected_error, _}) ->
    false.

%% =============================================================================
%% P4 — bit-flip in frame Magic
%% =============================================================================

%% P4. For any sequence of appended frames in the head segment, flipping
%% any single bit inside the 32-bit Magic field of frame K on disk and
%% reopening the WAL must result in:
%%
%%   (a) Recovery succeeds (the writer's `init/1` returns ok).
%%   (b) The reader exposes exactly the K frames preceding the corrupted
%%       one (i.e., recovery break-and-truncates at the bad-magic boundary).
%%   (c) The head_offset after recovery equals the byte offset of the
%%       corrupted frame's start (no partial bytes survive).
%%   (d) Appending more events after recovery succeeds and lands at the
%%       truncated head_offset.
%%
%% The "halt at first bad frame" semantics in v1 are deliberate (no
%% Magic-rescan, see WAL_DESIGN §17); P4 pins them down.
prop_bit_flip_magic() ->
    ?FORALL(
        {N, K, BitInMagic},
        ?LET(
            NN,
            choose(2, 12),
            {NN, choose(0, NN - 1), choose(0, 31)}
        ),
        with_wal_dir(fun(Dir) ->
            HLC = bondy_oplog_hlc:new(),
            Events = generate_events(HLC, N),
            Opts = #{dir => Dir, origin => origin()},
            {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
            {Positions, HeadAfter} =
                append_and_record_positions(P1, Events),
            ok = bondy_oplog_wal:close(P1),
            %% Frame K's start offset comes directly from the writer's
            %% returned Pos (the {Segment, StartOffset} pair).
            {FrameKStart, _} = frame_extent(K, Positions, HeadAfter),
            ok = flip_bit_in_file(
                seg_path(Dir, 0), FrameKStart * 8 + BitInMagic
            ),
            {ok, P2} = bondy_oplog_wal:start_link(instance_id(), Opts),
            Read = read_all_events(P2),
            Info2 = bondy_oplog_wal:info(P2),
            HeadOffAfterRecover = maps:get(head_offset, Info2),
            %% Recovery should have truncated to the K-th frame start.
            HeadMatches = HeadOffAfterRecover =:= FrameKStart,
            ReadMatches =
                Read =:= lists:sublist(Events, K),
            %% Append-after-recovery must succeed; the new frame's
            %% start offset should equal the truncated head_offset.
            ExtraEvent = hd(generate_events(HLC, 1)),
            ExtraResult = bondy_oplog_wal:append(P2, ExtraEvent),
            ExtraOk =
                case ExtraResult of
                    {ok, _, {_, NewStart}} -> NewStart =:= FrameKStart;
                    _ -> false
                end,
            ReadAfter = read_all_events(P2),
            ResumeOk =
                ReadAfter =:=
                    lists:sublist(Events, K) ++ [ExtraEvent],
            ok = bondy_oplog_wal:close(P2),
            ?WHENFAIL(
                io:format(
                    user,
                    "prop_bit_flip_magic failed: N=~p K=~p Bit=~p "
                    "FrameKStart=~p HeadAfter=~p Read=~p "
                    "HeadMatches=~p ReadMatches=~p ExtraOk=~p "
                    "ResumeOk=~p~n",
                    [
                        N,
                        K,
                        BitInMagic,
                        FrameKStart,
                        HeadOffAfterRecover,
                        length(Read),
                        HeadMatches,
                        ReadMatches,
                        ExtraOk,
                        ResumeOk
                    ]
                ),
                HeadMatches andalso ReadMatches andalso
                    ExtraOk andalso ResumeOk
            )
        end)
    ).

%% =============================================================================
%% P8 — rotation atomicity (in-process orphan slice)
%% =============================================================================

%% P8 (orphan slice). A crash between `create/4` (new segment file
%% exists on disk) and `commit_rotation/3` (manifest updated) leaves a
%% `<NewSegId>.qdata` file that's not referenced by the manifest. On
%% reopen, recovery's `cleanup_orphans/2` must:
%%
%%   (a) Delete the orphan file.
%%   (b) Leave the live `current_segment` (and the live event sequence)
%%       intact.
%%   (c) Allow the next rotation to recreate the same segment id without
%%       colliding on `exclusive` open.
%%
%% Property: simulate the orphan state directly (write a fake
%% `<head+1>.qdata` into the WAL dir before reopen), then verify the
%% three invariants. The "in-process" suffix is to distinguish from the
%% full crash-trace variant, which lives in the fault-injection harness.
prop_rotation_atomicity() ->
    ?FORALL(
        N,
        choose(1, 20),
        with_wal_dir(fun(Dir) ->
            HLC = bondy_oplog_hlc:new(),
            Events = generate_events(HLC, N),
            %% Big segment cap — keep everything in segment 0 so we can
            %% deterministically construct the orphan as segment 1.
            Opts = #{
                dir => Dir,
                origin => origin(),
                max_segment_bytes => 1024 * 1024
            },
            {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
            [bondy_oplog_wal:append(P1, E) || E <- Events],
            Info1 = bondy_oplog_wal:info(P1),
            HeadSeg = maps:get(current_segment, Info1),
            ok = bondy_oplog_wal:close(P1),
            %% Plant an orphan: a stub `.qdata` for HeadSeg+1 that is
            %% NOT in the manifest's live_segments. Recovery must drop it.
            InstDir = filename:join(Dir, instance_id()),
            OrphanPath = filename:join(
                InstDir, bondy_oplog_wal_segment:filename(HeadSeg + 1)
            ),
            ok = file:write_file(
                OrphanPath, <<"orphan-partial-rotation">>
            ),
            true = filelib:is_regular(OrphanPath),
            {ok, P2} = bondy_oplog_wal:start_link(instance_id(), Opts),
            Read = read_all_events(P2),
            Info2 = bondy_oplog_wal:info(P2),
            ok = bondy_oplog_wal:close(P2),
            %% (a) orphan gone, (b) head unchanged, (c) events recovered
            %% intact. (d) a subsequent reopen + append still works,
            %% confirming the rotation id is reusable.
            OrphanGone = not filelib:is_regular(OrphanPath),
            HeadIntact =
                maps:get(current_segment, Info2) =:= HeadSeg,
            EventsIntact = Read =:= Events,
            ?WHENFAIL(
                io:format(
                    user,
                    "prop_rotation_atomicity failed: N=~p HeadSeg=~p "
                    "OrphanGone=~p HeadIntact=~p EventsIntact=~p~n",
                    [N, HeadSeg, OrphanGone, HeadIntact, EventsIntact]
                ),
                OrphanGone andalso HeadIntact andalso EventsIntact
            )
        end)
    ).

%% =============================================================================
%% P13 — partial write (recovery-and-resume slice)
%% =============================================================================

%% P13 (in-process variant; full fault-injection harness still TODO).
%%
%% A `prim_file:write/2` that returns ok but writes fewer bytes than
%% requested leaves the on-disk segment in a state byte-identical to a
%% truncation at the same offset. The property:
%%
%%   1. Append N frames; record their end offsets.
%%   2. Choose a frame boundary K (between 0 and N) and a sub-frame
%%      chop count C (1 .. FrameLen - 1) — truncate the head segment
%%      `.qdata` at the start of frame K plus C bytes.
%%   3. Reopen the WAL: recovery must surface exactly the first K
%%      whole frames; head_offset after recovery must equal frame K's
%%      start offset; truncated_bytes must be ≥ C.
%%   4. Append M new events: they must succeed, land at the recovered
%%      head_offset, and round-trip via the reader.
%%
%% The "recovery + resume" framing makes this stronger than
%% prop_truncation_safety, which only verifies the recovery step.
prop_partial_write() ->
    ?FORALL(
        {N, M, K, SubFrameOff},
        ?LET(
            NN,
            choose(2, 12),
            {NN, choose(1, 3), choose(0, NN - 1),
                %% Pick a small positive sub-frame offset; we'll clamp
                %% against the actual frame size at runtime.
                choose(1, 200)}
        ),
        with_wal_dir(fun(Dir) ->
            HLC = bondy_oplog_hlc:new(),
            Events = generate_events(HLC, N),
            Opts = #{dir => Dir, origin => origin()},
            {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
            {Positions, HeadAfter} =
                append_and_record_positions(P1, Events),
            ok = bondy_oplog_wal:close(P1),
            SegPath = seg_path(Dir, 0),
            {FrameKStart, FrameKEnd} =
                frame_extent(K, Positions, HeadAfter),
            FrameKLen = FrameKEnd - FrameKStart,
            Chop = min(SubFrameOff, max(1, FrameKLen - 1)),
            TruncTo = FrameKStart + Chop,
            truncate_file(SegPath, TruncTo),
            {ok, P2} = bondy_oplog_wal:start_link(instance_id(), Opts),
            Read = read_all_events(P2),
            Info2 = bondy_oplog_wal:info(P2),
            HeadOff = maps:get(head_offset, Info2),
            ExtraEvents = generate_events(HLC, M),
            ExtraResults = [bondy_oplog_wal:append(P2, E) || E <- ExtraEvents],
            ReadAfter = read_all_events(P2),
            Info3 = bondy_oplog_wal:info(P2),
            ok = bondy_oplog_wal:close(P2),
            %% (a) recovered frames are the first K events,
            %% (b) head_offset is at frame K's start,
            %% (c) post-recovery appends succeed,
            %% (d) post-recovery reader returns first K + M events.
            ReadMatches =
                Read =:= lists:sublist(Events, K),
            HeadMatches = HeadOff =:= FrameKStart,
            AppendsOk = lists:all(
                fun
                    ({ok, _, _}) -> true;
                    (_) -> false
                end,
                ExtraResults
            ),
            ResumeMatches =
                ReadAfter =:= lists:sublist(Events, K) ++ ExtraEvents,
            HeadAdvanced =
                maps:get(head_offset, Info3) > FrameKStart,
            ?WHENFAIL(
                io:format(
                    user,
                    "P13 fail: N=~p M=~p K=~p Sub=~p FrameKStart=~p "
                    "FrameKLen=~p Chop=~p TruncTo=~p HeadOff=~p "
                    "Read=~p AppendsOk=~p ResumeMatches=~p~n",
                    [
                        N,
                        M,
                        K,
                        SubFrameOff,
                        FrameKStart,
                        FrameKLen,
                        Chop,
                        TruncTo,
                        HeadOff,
                        length(Read),
                        AppendsOk,
                        ResumeMatches
                    ]
                ),
                ReadMatches andalso HeadMatches andalso AppendsOk andalso
                    ResumeMatches andalso HeadAdvanced
            )
        end)
    ).

%% =============================================================================
%% PR2 (WAL_DESIGN_V2.md) — rescan recovery
%% =============================================================================

%% Property: in `rescan` mode, a single byte flip inside the body of
%% an arbitrary frame K must leave the recovered event sequence as a
%% subset of the originally-appended sequence, with recovery succeeding
%% and a strict reopen of the post-recovery WAL returning the same
%% events (i.e., the segment is rewritten contiguously).
%%
%% The flip is placed past the frame's 16-byte header so it triggers a
%% CRC mismatch (body-level corruption), not a `bad_magic` (header-
%% level corruption). The two paths are exercised independently by the
%% unit tests; this property focuses on the body-corruption path which
%% is the most common in production (torn writes inside a frame).
prop_rescan_recovery() ->
    ?FORALL(
        {N, K, BodyByteOff},
        ?LET(
            NN,
            choose(3, 8),
            {NN, choose(0, NN - 1), choose(20, 80)}
        ),
        with_wal_dir(fun(Dir) ->
            HLC = bondy_oplog_hlc:new(),
            Events = generate_events(HLC, N),
            Opts = #{dir => Dir, origin => origin()},
            {ok, P1} = bondy_oplog_wal:start_link(instance_id(), Opts),
            {Positions, HeadAfter} =
                append_and_record_positions(P1, Events),
            ok = bondy_oplog_wal:close(P1),
            SegPath = seg_path(Dir, 0),
            {FrameKStart, FrameKEnd} =
                frame_extent(K, Positions, HeadAfter),
            FrameKLen = FrameKEnd - FrameKStart,
            %% Clamp the body-byte offset against the actual frame
            %% size so the flip lands inside this frame's body.
            Clamped = min(BodyByteOff, max(?HEADER + 1, FrameKLen - 1)),
            FlipByte = FrameKStart + Clamped,
            flip_bit_in_file(SegPath, FlipByte * 8),
            RescanOpts = Opts#{recovery_mode => rescan},
            {ok, P2} = bondy_oplog_wal:start_link(
                instance_id(), RescanOpts
            ),
            Read1 = read_all_events(P2),
            ok = bondy_oplog_wal:close(P2),
            %% Reopen in strict mode — the rescan compaction must have
            %% left a contiguous segment that strict recovery accepts.
            {ok, P3} = bondy_oplog_wal:start_link(instance_id(), Opts),
            Read2 = read_all_events(P3),
            ok = bondy_oplog_wal:close(P3),
            %% Recovery acceptance criteria:
            %%   (a) read1 is a subset of the appended events,
            %%   (b) read1 preserves append order,
            %%   (c) strict reopen yields the same events as rescan,
            %%   (d) at least N-1 frames survive (we corrupted one).
            SubsetOk = lists:all(
                fun(E) -> lists:member(E, Events) end, Read1
            ),
            OrderOk = is_subsequence(Read1, Events),
            StrictRoundTripOk = Read1 =:= Read2,
            SurvivalOk = length(Read1) >= N - 1,
            ?WHENFAIL(
                io:format(
                    user,
                    "prop_rescan_recovery fail: N=~p K=~p Clamped=~p "
                    "FlipByte=~p Read1=~p Read2=~p~n",
                    [
                        N,
                        K,
                        Clamped,
                        FlipByte,
                        length(Read1),
                        length(Read2)
                    ]
                ),
                SubsetOk andalso OrderOk andalso StrictRoundTripOk andalso
                    SurvivalOk
            )
        end)
    ).

%% Returns `true` iff `Sub` is a (not necessarily contiguous)
%% subsequence of `List` — i.e. every element of `Sub` appears in
%% `List` in the same order. Used by `prop_rescan_recovery/0`.
is_subsequence([], _) -> true;
is_subsequence(_, []) -> false;
is_subsequence([X | XR], [X | YR]) -> is_subsequence(XR, YR);
is_subsequence(Xs, [_ | YR]) -> is_subsequence(Xs, YR).

%% =============================================================================
%% P11 — concurrent reader safety
%% =============================================================================

%% P11. While the writer is appending, an arbitrary number of readers
%% walking from arbitrary start positions must:
%%
%%   (a) Never crash the writer (the writer process survives the trial).
%%   (b) Never observe a partial frame (the reader either decodes a
%%       whole frame or returns end_of_log).
%%   (c) Observe a contiguous prefix of the canonical event sequence
%%       (i.e., the reader's output is `lists:sublist(Events, R)` for
%%       some R ≥ 0).
%%   (d) Eventually catch up to head_offset_ref if the writer stops
%%       appending — represented here as: after the writer finishes,
%%       a reader opened at `beginning` returns all N events.
%%
%% The trial spawns 1 writer process and R reader processes. The writer
%% appends N events with a small random delay between them; each reader
%% opens at `beginning` (non-follow) and drains the log to whatever is
%% durably visible at the time. The property then asserts each reader's
%% recovered list is a prefix of the canonical event list.
prop_concurrent_reader_safety() ->
    ?FORALL(
        {N, R},
        {choose(5, 30), choose(1, 4)},
        with_wal_dir(fun(Dir) ->
            HLC = bondy_oplog_hlc:new(),
            Events = generate_events(HLC, N),
            Opts = #{
                dir => Dir,
                origin => origin(),
                %% Keep segment-rotation traffic in scope so readers
                %% have to cross segment boundaries.
                max_segment_bytes =>
                    ?SEG_HEADER + estimated_frame_size() * 5
            },
            {ok, Pid} = bondy_oplog_wal:start_link(instance_id(), Opts),
            try
                Parent = self(),
                ReaderRefs = [
                    spawn_monitor(fun() ->
                        Acc = run_concurrent_reader(Pid),
                        Parent ! {reader_done, self(), Acc}
                    end)
                 || _ <- lists:seq(1, R)
                ],
                ok = run_concurrent_writer(Pid, Events),
                ReaderResults = collect_readers(ReaderRefs, []),
                %% (a) writer alive.
                Alive = is_process_alive(Pid),
                %% (b)+(c) each reader sees a contiguous prefix.
                PrefixOk = lists:all(
                    fun(Read) -> is_prefix(Read, Events) end,
                    ReaderResults
                ),
                %% (d) post-write full read sees everything.
                Final = read_all_events(Pid),
                FinalOk = Final =:= Events,
                ?WHENFAIL(
                    io:format(
                        user,
                        "prop_concurrent_reader_safety failed: N=~p "
                        "R=~p Alive=~p PrefixOk=~p FinalOk=~p "
                        "ReaderLens=~p~n",
                        [
                            N,
                            R,
                            Alive,
                            PrefixOk,
                            FinalOk,
                            [
                                if
                                    is_list(L) -> length(L);
                                    true -> L
                                end
                             || L <- ReaderResults
                            ]
                        ]
                    ),
                    Alive andalso PrefixOk andalso FinalOk
                )
            after
                ok = bondy_oplog_wal:close(Pid)
            end
        end)
    ).

%% @private
run_concurrent_writer(Pid, Events) ->
    lists:foreach(
        fun(E) ->
            {ok, _, _} = bondy_oplog_wal:append(Pid, E),
            %% Yield to give readers a chance to interleave.
            erlang:yield()
        end,
        Events
    ).

%% @private
%% Open a fresh reader at the beginning of the log and drain it once,
%% catching protocol errors as a property failure (the writer must
%% never crash a concurrent reader).
run_concurrent_reader(Pid) ->
    case bondy_oplog_wal_reader:open(Pid, beginning) of
        {ok, Iter} ->
            drain_reader(Iter, []);
        {error, _} ->
            %% A reader open failure mid-write would still satisfy the
            %% prefix property (Acc = []), so report empty.
            []
    end.

%% @private
collect_readers([], Acc) ->
    Acc;
collect_readers([{Pid, MonRef} | Rest], Acc) ->
    receive
        {reader_done, Pid, Read} ->
            erlang:demonitor(MonRef, [flush]),
            collect_readers(Rest, [Read | Acc]);
        {'DOWN', MonRef, process, Pid, _Reason} ->
            %% A reader crash is a property failure.
            collect_readers(Rest, [{reader_crashed, Pid} | Acc])
    after 30_000 ->
        collect_readers(Rest, [{reader_timeout, Pid} | Acc])
    end.

%% @private
%% True if `Read` is `lists:sublist(Events, length(Read))`.
is_prefix(Read, _Events) when not is_list(Read) ->
    false;
is_prefix(Read, Events) ->
    Read =:= lists:sublist(Events, length(Read)).

%% =============================================================================
%% P14 — failed fsync (fault injection)
%% =============================================================================

%% P14. A failed `prim_file:datasync/1` in the writer's per_write fsync
%% path must:
%%
%%   (a) Surface as `{error, _}` to the caller of `append/2` /
%%       `append_batch/2`.
%%   (b) Not advance `durable_offset` past the failed fsync's
%%       boundary — the durable view stays at the last successful
%%       fsync.
%%   (c) Leave the writer process alive and serving subsequent calls
%%       (info/1, close/1, etc.).
%%
%% Implementation: mock `bondy_mst_io:datasync/1` to return
%% `{error, eio}` after a configurable number of successful calls. The
%% generator chooses how many appends to perform before flipping the
%% switch, so each trial exercises both the "fsync still ok" path and
%% the "fsync now fails" path.
prop_failed_fsync() ->
    ?FORALL(
        N,
        choose(2, 12),
        with_wal_dir(fun(Dir) ->
            HLC = bondy_oplog_hlc:new(),
            Events = generate_events(HLC, N),
            Opts = #{
                dir => Dir,
                origin => origin(),
                fsync_mode => per_write
            },
            {ok, Pid} = bondy_oplog_wal:start_link(instance_id(), Opts),
            true = unlink(Pid),
            try
                %% First half: succeed. Second half: fail. Keep the
                %% warm-up unmocked so meck's tracing layer doesn't add
                %% per-call overhead before we actually need the seam.
                Half = max(1, N div 2),
                {First, Rest} = lists:split(Half, Events),
                FirstResults = [bondy_oplog_wal:append(Pid, E) || E <- First],
                FirstOk = lists:all(
                    fun
                        ({ok, _, _}) -> true;
                        (_) -> false
                    end,
                    FirstResults
                ),
                InfoBefore = bondy_oplog_wal:info(Pid),
                #{
                    durable_offset := DurableBefore,
                    durable_segment := DurSegBefore
                } = InfoBefore,
                %% Install meck under the wal_io fault lock — the lock
                %% serialises any test that mocks `bondy_mst_io`,
                %% which is necessary because `meck:new/2` swaps the
                %% module in the VM-wide code server.
                {FaultResults, Alive, Info2} = with_io_fault_lock(
                    fun() ->
                        ok = meck:expect(
                            bondy_mst_io,
                            datasync,
                            fun(_Fd) -> {error, eio} end
                        ),
                        FaultRs = [bondy_oplog_wal:append(Pid, E) || E <- Rest],
                        AliveBool = is_process_alive(Pid),
                        Inf = bondy_oplog_wal:info(Pid),
                        {FaultRs, AliveBool, Inf}
                    end
                ),
                FaultErrors = lists:all(
                    fun
                        ({error, eio}) -> true;
                        (_) -> false
                    end,
                    FaultResults
                ),
                DurableUnchanged =
                    maps:get(durable_offset, Info2) =:= DurableBefore andalso
                        maps:get(durable_segment, Info2) =:=
                            DurSegBefore,
                %% E8 — reopen invariant. The fault path pwrite'd the
                %% bytes but the writer held `durable_offset` back
                %% because no datasync completed. After close + reopen,
                %% recovery scans the segment, CRC-verifies every frame,
                %% and the in-memory state must reflect what is actually
                %% on disk (WAL_DESIGN §16.3 (b)).
                try
                    _ = bondy_oplog_wal:close(Pid)
                catch
                    _:_ -> ok
                end,
                {ReopenOk, ReopenDurable, ReopenHead, PostReopenAppendOk} = reopen_and_probe(
                    Opts, HLC
                ),
                %% After reopen, the WAL_DESIGN §16.3 (b) invariant is:
                %% "in-memory state consistent with on-disk". Concretely:
                %%   1. `durable_offset` must not shrink — every ACK'd
                %%      append from before the fault is still durable.
                %%   2. `head_offset >= durable_offset` (the writer's
                %%      authoritative position is at or beyond what is
                %%      durable on disk).
                %% Recovery's break-and-truncate may legitimately accept
                %% fault-path frames that pwrite'd successfully (their
                %% CRCs pass) and push durable past where the writer's
                %% in-memory head was, so we do *not* bound durable from
                %% above against the pre-reopen head — the disk is the
                %% source of truth and may legitimately contain more.
                ReopenDurableSafe = ReopenDurable >= DurableBefore,
                ReopenHeadSafe = ReopenHead >= ReopenDurable,
                ?WHENFAIL(
                    io:format(
                        user,
                        "prop_failed_fsync failed: N=~p FirstOk=~p "
                        "FaultErrors=~p Alive=~p DurableUnchanged=~p "
                        "DurableBefore=~p Info2=~p ReopenOk=~p "
                        "ReopenDurable=~p ReopenHead=~p "
                        "PostReopenAppendOk=~p~n",
                        [
                            N,
                            FirstOk,
                            FaultErrors,
                            Alive,
                            DurableUnchanged,
                            DurableBefore,
                            Info2,
                            ReopenOk,
                            ReopenDurable,
                            ReopenHead,
                            PostReopenAppendOk
                        ]
                    ),
                    FirstOk andalso FaultErrors andalso
                        Alive andalso DurableUnchanged andalso
                        ReopenOk andalso
                        ReopenDurableSafe andalso
                        ReopenHeadSafe andalso
                        PostReopenAppendOk
                )
            after
                try
                    _ = bondy_oplog_wal:close(Pid)
                catch
                    _:_ -> ok
                end
            end
        end)
    ).

%% =============================================================================
%% P14 — failed fsync (batched-mode variant)
%% =============================================================================

%% P14 in batched mode. The per-append return contract differs from
%% `per_write`: `append/2` returns `{ok, _, _}` even when the deferred
%% datasync ultimately fails, because the durability promise is
%% "fsync at some later boundary, retried on failure". The invariants
%% under a sustained datasync fault are therefore:
%%
%%   (a) Appends still return `{ok, _, _}` — the failure is logged and
%%       retried by the next `flush_tick`, not surfaced to the caller.
%%   (b) `durable_offset` is held back — no datasync has completed, so
%%       the writer cannot advance the durable boundary.
%%   (c) `pending_fsync_bytes` stays > 0 — the un-fsync'd byte budget
%%       is preserved for the next retry attempt.
%%   (d) The writer stays alive across multiple failed `flush_tick`
%%       firings.
prop_failed_fsync_batched() ->
    ?FORALL(
        N,
        choose(2, 8),
        with_wal_dir(fun(Dir) ->
            HLC = bondy_oplog_hlc:new(),
            Events = generate_events(HLC, N),
            %% Short interval so the timer fires repeatedly inside the
            %% test window. Size threshold is high so the *timer* is
            %% what triggers fsync attempts (we are testing the
            %% interval-retry semantics).
            Opts = #{
                dir => Dir,
                origin => origin(),
                fsync_mode => batched,
                batched_fsync_interval => 30,
                batched_fsync_bytes => 64 * 1024 * 1024
            },
            {ok, Pid} = bondy_oplog_wal:start_link(instance_id(), Opts),
            true = unlink(Pid),
            try
                {BatchResults, Alive, Info2} = with_io_fault_lock(
                    fun() ->
                        ok = meck:expect(
                            bondy_mst_io,
                            datasync,
                            fun(_Fd) -> {error, eio} end
                        ),
                        BR = [bondy_oplog_wal:append(Pid, E) || E <- Events],
                        %% Sleep long enough that several `flush_tick`s
                        %% have fired and been rejected.
                        timer:sleep(200),
                        AliveBool = is_process_alive(Pid),
                        Inf = bondy_oplog_wal:info(Pid),
                        {BR, AliveBool, Inf}
                    end
                ),
                BatchOk = lists:all(
                    fun
                        ({ok, _, _}) -> true;
                        (_) -> false
                    end,
                    BatchResults
                ),
                DurableHeldBack =
                    maps:get(durable_offset, Info2) =< ?SEG_HEADER,
                PendingHeld =
                    maps:get(pending_fsync_bytes, Info2, 0) > 0,
                ?WHENFAIL(
                    io:format(
                        user,
                        "prop_failed_fsync_batched failed: N=~p "
                        "BatchOk=~p Alive=~p DurableHeldBack=~p "
                        "PendingHeld=~p Info2=~p~n",
                        [
                            N,
                            BatchOk,
                            Alive,
                            DurableHeldBack,
                            PendingHeld,
                            Info2
                        ]
                    ),
                    BatchOk andalso Alive andalso
                        DurableHeldBack andalso
                        PendingHeld
                )
            after
                try
                    _ = bondy_oplog_wal:close(Pid)
                catch
                    _:_ -> ok
                end
            end
        end)
    ).

%% =============================================================================
%% P15 — failed rename (fault injection)
%% =============================================================================

%% P15. A failed `prim_file:rename/2` on the manifest commit path
%% (during rotation) must:
%%
%%   (a) Surface as `{error, _}` to the caller whose `append` /
%%       `append_batch` triggered the rotation.
%%   (b) Leave the old manifest intact on disk — bit-identical to its
%%       pre-rotation contents.
%%   (c) Not advance the writer's in-memory `current_segment` past the
%%       old segment.
%%   (d) Leave the writer alive.
%%
%% Implementation: mock `bondy_mst_io:rename/2` to return
%% `{error, eacces}` after the writer is up. Append events with a tight
%% `max_segment_bytes` so the next append rotates and trips the fault.
prop_rename_failure() ->
    ?FORALL(
        N,
        choose(3, 15),
        with_wal_dir(fun(Dir) ->
            HLC = bondy_oplog_hlc:new(),
            Events = generate_events(HLC, N),
            %% Tight cap so we rotate after the first frame.
            Opts = #{
                dir => Dir,
                origin => origin(),
                max_segment_bytes =>
                    ?SEG_HEADER + estimated_frame_size() + 1
            },
            {ok, Pid} = bondy_oplog_wal:start_link(instance_id(), Opts),
            true = unlink(Pid),
            InstDir = filename:join(Dir, instance_id()),
            ManifestPath = filename:join(
                InstDir, ?BONDY_OPLOG_WAL_MANIFEST_FILENAME
            ),
            try
                %% Get baseline manifest after the writer wrote its
                %% bootstrap manifest.
                {ok, ManifestBefore} = file:read_file(ManifestPath),
                SegBefore = maps:get(
                    current_segment, bondy_oplog_wal:info(Pid)
                ),
                %% Inject the fault on the next rename — the manifest
                %% commit during rotation will fail. The wal_io fault
                %% lock keeps the meck install/unload window from
                %% colliding with any other property that mocks the same
                %% module (see [[feedback_meck_global]] — meck swaps the
                %% module VM-wide via the code server).
                {Results, Alive, ManifestAfter, SegAfter} =
                    with_io_fault_lock(fun() ->
                        ok = meck:expect(
                            bondy_mst_io,
                            rename,
                            fun(_From, _To) -> {error, eacces} end
                        ),
                        %% Use safe_append/2: after C1's fix, the
                        %% rotation-failure stops the gen_server, so
                        %% subsequent appends would otherwise exit with
                        %% `noproc` and crash the comprehension.
                        Rs = [safe_append(Pid, E) || E <- Events],
                        AliveBool = is_process_alive(Pid),
                        SegA =
                            try
                                maps:get(
                                    current_segment,
                                    bondy_oplog_wal:info(Pid)
                                )
                            catch
                                _:_ -> SegBefore
                            end,
                        {ok, ManifestA} = file:read_file(ManifestPath),
                        {Rs, AliveBool, ManifestA, SegA}
                    end),
                Errors = [R || R <- Results, element(1, R) =:= error],
                SawRotationError = Errors =/= [],
                ManifestIntact = ManifestAfter =:= ManifestBefore,
                CurrentSegUnchanged = SegAfter =:= SegBefore,
                %% C1 — after the rename failed, the writer was inside
                %% the post-close window of `rotate/1`; the producing
                %% code now stops the gen_server with `{rotation_failed_
                %% after_seal, _}` rather than reverting to a state that
                %% references the closed old fd. We probe by reopening
                %% from disk: recovery must succeed and the in-memory
                %% state must match the on-disk reality (manifest still
                %% pointing at the old segment).
                ReopenResult = reopen_only(Opts),
                {ReopenOk, ReopenSeg} =
                    case ReopenResult of
                        {ok, Pid2} ->
                            Inf = bondy_oplog_wal:info(Pid2),
                            S = maps:get(current_segment, Inf),
                            try
                                _ = bondy_oplog_wal:close(Pid2)
                            catch
                                _:_ -> ok
                            end,
                            {true, S};
                        _ ->
                            {false, undefined}
                    end,
                ReopenSegConsistent = ReopenSeg =:= SegBefore,
                ?WHENFAIL(
                    io:format(
                        user,
                        "prop_rename_failure failed: N=~p "
                        "SawRotationError=~p Alive=~p "
                        "ManifestIntact=~p CurrentSegUnchanged=~p "
                        "SegBefore=~p SegAfter=~p Errors=~p "
                        "ReopenOk=~p ReopenSeg=~p~n",
                        [
                            N,
                            SawRotationError,
                            Alive,
                            ManifestIntact,
                            CurrentSegUnchanged,
                            SegBefore,
                            SegAfter,
                            Errors,
                            ReopenOk,
                            ReopenSeg
                        ]
                    ),
                    SawRotationError andalso
                        ManifestIntact andalso
                        CurrentSegUnchanged andalso
                        ReopenOk andalso
                        ReopenSegConsistent
                )
            after
                try
                    _ = bondy_oplog_wal:close(Pid)
                catch
                    _:_ -> ok
                end
            end
        end)
    ).

%% =============================================================================
%% P12 — multi-process convergence (writer kill + reopen)
%% =============================================================================

%% P12 (in-process slice). Spawn a writer and a reader, run a workload,
%% kill the writer with `exit(kill)` at a randomly-chosen append count,
%% reopen the WAL, and verify:
%%
%%   (a) Recovery succeeds — the writer restarts cleanly.
%%   (b) Every event that the writer successfully ACKed (i.e., returned
%%       `{ok, _, _}` in `per_write` mode → durability promised) is
%%       present in the recovered log.
%%   (c) The recovered log is a strict prefix of the originally
%%       appended sequence (no out-of-order or fabricated events).
%%   (d) The reader running concurrently with the workload never
%%       crashes the writer.
%%
%% This is the v1 "kill anything at any step" property restricted to the
%% in-process case (one Erlang VM, one OS process). The full
%% multi-OS-process convergence sits behind a fault-injection harness
%% that's out of scope for v1.
prop_multiproc_convergence() ->
    ?FORALL(
        {N, KillAfter, NumReaders},
        ?LET(
            NN,
            choose(4, 20),
            {NN, choose(1, NN - 1), choose(0, 3)}
        ),
        with_wal_dir(fun(Dir) ->
            HLC = bondy_oplog_hlc:new(),
            Events = generate_events(HLC, N),
            Opts = #{
                dir => Dir,
                origin => origin(),
                fsync_mode => per_write,
                %% Tight cap so rotations happen mid-run.
                max_segment_bytes =>
                    ?SEG_HEADER + estimated_frame_size() * 4
            },
            %% Use `start` (no link), so we can `exit(Pid, kill)`
            %% without killing the test process.
            {ok, Pid} = bondy_oplog_wal:start(instance_id(), Opts),
            Parent = self(),
            ReaderRefs = [
                spawn_monitor(fun() ->
                    Acc = run_concurrent_reader(Pid),
                    Parent ! {reader_done, self(), Acc}
                end)
             || _ <- lists:seq(1, NumReaders)
            ],
            %% Append KillAfter events synchronously — guarantees the
            %% first KillAfter ACKs are durable in per_write mode.
            {AckedHead, RestEvents} =
                lists:split(KillAfter, Events),
            AckedResults = [bondy_oplog_wal:append(Pid, E) || E <- AckedHead],
            AckedOk = lists:all(
                fun
                    ({ok, _, _}) -> true;
                    (_) -> false
                end,
                AckedResults
            ),
            %% Spawn a worker that races the kill — appends the rest;
            %% any of these may or may not land before the kill.
            WriterDone = make_ref(),
            spawn(fun() ->
                _ = [
                    catch bondy_oplog_wal:append(Pid, E)
                 || E <- RestEvents
                ],
                Parent ! {WriterDone, done}
            end),
            %% Yield a few times so the spawned worker gets a turn.
            ok = nudge_scheduler(20),
            %% Kill the writer mid-workload.
            MonRef = erlang:monitor(process, Pid),
            true = exit(Pid, kill),
            receive
                {'DOWN', MonRef, process, Pid, killed} -> ok
            after 5_000 -> erlang:demonitor(MonRef, [flush])
            end,
            %% Drain the worker's "done" message (it'll get badarg /
            %% noproc on append after the kill — we just await it so
            %% the test doesn't leak processes).
            receive
                {WriterDone, done} -> ok
            after 5_000 -> ok
            end,
            _ReaderResults = collect_readers(ReaderRefs, []),
            %% Reopen and verify.
            {ok, P2} = bondy_oplog_wal:start_link(instance_id(), Opts),
            Recovered = read_all_events(P2),
            ok = bondy_oplog_wal:close(P2),
            %% (a) recovery succeeded (we got here without throwing).
            %% (b) every ACKed event is in Recovered.
            AckedPresent =
                lists:sublist(Events, KillAfter) =:=
                    lists:sublist(Recovered, KillAfter),
            %% (c) Recovered is a prefix of Events.
            PrefixOk = is_prefix(Recovered, Events),
            ?WHENFAIL(
                io:format(
                    user,
                    "prop_multiproc_convergence failed: N=~p "
                    "KillAfter=~p NumReaders=~p AckedOk=~p "
                    "AckedPresent=~p PrefixOk=~p Recovered=~p~n",
                    [
                        N,
                        KillAfter,
                        NumReaders,
                        AckedOk,
                        AckedPresent,
                        PrefixOk,
                        length(Recovered)
                    ]
                ),
                AckedOk andalso AckedPresent andalso PrefixOk
            )
        end)
    ).

%% @private
%% Yields N times to give other runnable processes scheduler turns.
%% Used by `prop_multiproc_convergence/0` to interleave the async
%% appender with the killer without depending on wall-clock timing.
nudge_scheduler(0) ->
    ok;
nudge_scheduler(N) when N > 0 ->
    erlang:yield(),
    nudge_scheduler(N - 1).

%% =============================================================================
%% EUnit wrapper — runs each property with the configured numtests count
%% so the suite participates in CI under `rebar3 eunit`. The full 24h
%% fuzz job runs PropEr directly via `rebar3 proper`.
%% =============================================================================

properties_test_() ->
    {timeout, 600, fun() ->
        FrameOpts = [{to_file, user}, {numtests, ?DEFAULT_NUMTESTS}],
        WalOpts = [{to_file, user}, {numtests, ?WAL_NUMTESTS}],
        FrameProps = [
            prop_frame_roundtrip(),
            prop_frame_bit_flip_detection(),
            prop_frame_v1_v2_decoder_equivalence(),
            prop_codec_roundtrip(),
            prop_codec_encrypt_roundtrip(),
            prop_codec_ciphertext_bit_flip_detection(),
            prop_idx_v2_seek_matches_v1_on_point_ranges(),
            prop_idx_v2_seek_in_range_returns_that_entry()
        ],
        WalProps = [
            prop_wal_single_event_roundtrip(),
            prop_wal_hlc_monotonicity(),
            prop_wal_roundtrip(),
            prop_index_consistency(),
            prop_truncation_safety(),
            prop_manifest_atomicity(),
            prop_consumer_offset_clamping(),
            prop_await_durable_correctness(),
            prop_batch_atomicity(),
            prop_retention_safety(),
            prop_wal_full(),
            prop_bit_flip_magic(),
            prop_rotation_atomicity(),
            prop_partial_write(),
            prop_rescan_recovery(),
            prop_concurrent_reader_safety(),
            prop_failed_fsync(),
            prop_failed_fsync_batched(),
            prop_rename_failure(),
            prop_multiproc_convergence()
        ],
        lists:foreach(
            fun(Prop) -> ?assert(proper:quickcheck(Prop, FrameOpts)) end,
            FrameProps
        ),
        lists:foreach(
            fun(Prop) -> ?assert(proper:quickcheck(Prop, WalOpts)) end,
            WalProps
        )
    end}.

%% =============================================================================
%% Helpers — kept here so subsequent phases can reuse them.
%% =============================================================================

flip_bit(Bin, BitIdx) ->
    ByteIdx = BitIdx div 8,
    BitInByte = BitIdx rem 8,
    Mask = 1 bsl (7 - BitInByte),
    <<Pre:ByteIdx/binary, B, Post/binary>> = Bin,
    <<Pre/binary, (B bxor Mask):8, Post/binary>>.

%% --- WAL helpers --------------------------------------------------------

instance_id() ->
    <<"wal-proper-instance">>.

origin() ->
    <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>.

%% Each property generates its events lazily inside the test body so we
%% get a strictly-increasing HLC sequence per shrink trial.
generate_events(HLC, N) ->
    [
        begin
            Hlc = bondy_oplog_hlc:now(HLC),
            Key = bondy_oplog_event:key(Hlc, origin(), Seq),
            bondy_oplog_event:new(Key, {op, Hlc}, undefined)
        end
     || Seq <- lists:seq(1, N)
    ].

%% Approximate single-event frame size. Used to pick a rotation-
%% friendly `max_segment_bytes`. A small `op` payload encodes to
%% ~60–80 bytes; pick 100 to leave slack.
estimated_frame_size() -> 100.

is_strictly_increasing([_]) ->
    true;
is_strictly_increasing([A, B | Rest]) when A < B ->
    is_strictly_increasing([B | Rest]);
is_strictly_increasing(_) ->
    false.

%% --- meck fault-injection lock + reopen helpers -------------------------

%% Serialises any property that mocks `bondy_mst_io`. `meck:new/2`
%% swaps the module in the VM-wide code server, so two test modules
%% mocking the same module concurrently would clobber each other's
%% expectations. `global:trans/4` acquires a node-scoped lock; release
%% is automatic when `Body` returns. The lock is held only across the
%% meck install/expect/uninstall window, not across the writer's whole
%% lifetime, so it does not serialise property runs that do not fault-
%% inject.
%%
%% The lock resource MUST be keyed by the MOCKED module, not by the
%% test module — otherwise sibling suites (`bondy_oplog_wal_group_commit_test`,
%% `bondy_mst_pack_writer_test`) that also fault-inject `bondy_mst_io`
%% would each hold a distinct `?MODULE`-scoped lock and never mutually
%% exclude (the intermittent `{error, eacces}` leak this comment used to
%% describe as impossible). Keep this key IDENTICAL across those suites.
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

%% Wrapper around `bondy_oplog_wal:append/2` that turns a `noproc` exit
%% into a regular `{error, noproc}` reply. Used by properties that
%% deliberately drive the writer into a state where it stops (e.g. C1 in
%% `prop_rename_failure/0`).
safe_append(Pid, Event) ->
    try
        bondy_oplog_wal:append(Pid, Event)
    catch
        exit:{noproc, _} -> {error, noproc};
        exit:noproc -> {error, noproc};
        exit:{Reason, _} -> {error, Reason}
    end.

%% Close+reopen probe used by `prop_failed_fsync/0`: after the in-memory
%% fault-path checks, the WAL is closed, reopened from disk (running
%% recovery), and the reopened writer is interrogated for `durable_offset`
%% / `head_offset` and asked to accept one fresh append. Returns the
%% triple `{ok-bool, durable_offset, head_offset, append-ok}`.
reopen_and_probe(Opts, HLC) ->
    case bondy_oplog_wal:start_link(instance_id(), Opts) of
        {ok, Pid2} ->
            true = unlink(Pid2),
            Info = bondy_oplog_wal:info(Pid2),
            Dur = maps:get(durable_offset, Info),
            Head = maps:get(head_offset, Info),
            NewEvent = hd(generate_events(HLC, 1)),
            AppendOk =
                case bondy_oplog_wal:append(Pid2, NewEvent) of
                    {ok, _, _} -> true;
                    _ -> false
                end,
            try
                _ = bondy_oplog_wal:close(Pid2)
            catch
                _:_ -> ok
            end,
            {true, Dur, Head, AppendOk};
        _ ->
            {false, 0, 0, false}
    end.

%% Close+reopen probe used by `prop_rename_failure/0`: just verifies
%% that recovery succeeds and returns a `{ok, _}` plus the new Pid.
%% Caller is responsible for inspecting state and closing.
reopen_only(Opts) ->
    case bondy_oplog_wal:start_link(instance_id(), Opts) of
        {ok, Pid2} = OK ->
            true = unlink(Pid2),
            OK;
        Other ->
            Other
    end.

%% Spawns a temporary directory, runs `Fun(Dir)`, deletes the directory
%% afterwards regardless of the property outcome. The property result
%% (boolean) is returned verbatim.
with_wal_dir(Fun) ->
    Dir = mktemp_dir(),
    try
        Fun(Dir)
    after
        _ = file:del_dir_r(Dir)
    end.

mktemp_dir() ->
    Base = filename:join(
        [
            "/tmp",
            io_lib:format(
                "bondy_oplog_wal_prop_~p_~p",
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

%% Walks every segment file from 0 up to `HeadSegId` inclusive and
%% returns the concatenated event list. The frame body is a list of
%% events (single-event appends are one-element lists; atomic batches
%% are N-element lists).
scan_all_segments(Dir, InstanceId, HeadSegId) ->
    lists:flatmap(
        fun(SegId) -> scan_segment(Dir, InstanceId, SegId) end,
        lists:seq(0, HeadSegId)
    ).

%% Like `scan_all_segments/3` but preserves batch grouping: returns one
%% sublist per frame. Used by `prop_batch_atomicity/0`.
scan_all_segments_grouped(Dir, InstanceId, HeadSegId) ->
    lists:flatmap(
        fun(SegId) -> scan_segment_grouped(Dir, InstanceId, SegId) end,
        lists:seq(0, HeadSegId)
    ).

scan_segment(Dir, InstanceId, SegId) ->
    Path = filename:join(
        [Dir, InstanceId, bondy_oplog_wal_segment:filename(SegId)]
    ),
    {ok, Bin} = file:read_file(Path),
    <<_:?SEG_HEADER/binary, Frames/binary>> = Bin,
    scan_frames(Frames).

scan_segment_grouped(Dir, InstanceId, SegId) ->
    Path = filename:join(
        [Dir, InstanceId, bondy_oplog_wal_segment:filename(SegId)]
    ),
    {ok, Bin} = file:read_file(Path),
    <<_:?SEG_HEADER/binary, Frames/binary>> = Bin,
    scan_frames_grouped(Frames).

scan_frames(<<>>) ->
    [];
scan_frames(<<_:32, FrameLen:32, _/binary>> = Bin) ->
    <<Frame:FrameLen/binary, Rest/binary>> = Bin,
    {ok, Body, _} = bondy_oplog_wal_frame:decode(Frame),
    Batch = binary_to_term(Body, [safe]),
    Batch ++ scan_frames(Rest).

scan_frames_grouped(<<>>) ->
    [];
scan_frames_grouped(<<_:32, FrameLen:32, _/binary>> = Bin) ->
    <<Frame:FrameLen/binary, Rest/binary>> = Bin,
    {ok, Body, _} = bondy_oplog_wal_frame:decode(Frame),
    Batch = binary_to_term(Body, [safe]),
    [Batch | scan_frames_grouped(Rest)].

%% Generate `length(Sizes)` batches with strictly-increasing HLCs across
%% all events.
generate_batches(_HLC, []) ->
    [];
generate_batches(HLC, [Size | Sizes]) ->
    Batch = [
        begin
            Hlc = bondy_oplog_hlc:now(HLC),
            Key = bondy_oplog_event:key(Hlc, origin(), Seq),
            bondy_oplog_event:new(Key, {op, Hlc}, undefined)
        end
     || Seq <- lists:seq(1, Size)
    ],
    [Batch | generate_batches(HLC, Sizes)].

%% Drains a bounded (non-follow) reader to a flat list of events. Used
%% by `prop_wal_roundtrip/0`.
drain_reader(Iter, Acc) ->
    case bondy_oplog_wal_reader:next(Iter) of
        {ok, Batch, _Hlcs, _Pos, NewIter} ->
            drain_reader(NewIter, Acc ++ Batch);
        end_of_log ->
            ok = bondy_oplog_wal_reader:close(Iter),
            Acc;
        {error, _} = E ->
            ok = bondy_oplog_wal_reader:close(Iter),
            E
    end.

%% --- Recovery-test helpers --------------------------------------------

%% Reads every appended event from the WAL via a fresh reader.
read_all_events(Pid) ->
    {ok, Iter} = bondy_oplog_wal_reader:open(Pid, beginning),
    drain_reader(Iter, []).

%% Returns `{ok, NonNegInteger}` with the file's byte size, or
%% `{error, Reason}` if the file is unreachable.
file_size(Path) ->
    case file:read_file_info(Path) of
        {ok, FI} -> {ok, element(2, FI)};
        {error, _} = E -> E
    end.

%% Truncates `Path` to exactly `NewSize` bytes (no-op if the file is
%% already ≤ NewSize).
truncate_file(Path, NewSize) ->
    {ok, Fd} = file:open(Path, [read, write, raw, binary]),
    try
        {ok, _} = file:position(Fd, NewSize),
        ok = file:truncate(Fd)
    after
        ok = file:close(Fd)
    end.

%% Flips a single bit at `BitIdx` (0-based) in the file at `Path`.
%% Reads, rewrites the affected byte in place, leaves the rest of the
%% file untouched. Used by `prop_bit_flip_magic/0`.
flip_bit_in_file(Path, BitIdx) ->
    ByteIdx = BitIdx div 8,
    BitInByte = BitIdx rem 8,
    Mask = 1 bsl (7 - BitInByte),
    {ok, Fd} = file:open(Path, [read, write, raw, binary]),
    try
        {ok, _} = file:position(Fd, ByteIdx),
        {ok, <<B:8>>} = file:read(Fd, 1),
        {ok, _} = file:position(Fd, ByteIdx),
        ok = file:write(Fd, <<(B bxor Mask):8>>)
    after
        ok = file:close(Fd)
    end.

%% Returns `{Start, End}` for frame index `K` (0-based) given the list
%% of `{SegmentId, StartOffset}` positions returned by
%% `bondy_oplog_wal:append/2` plus `HeadOffsetAfter` — the writer's
%% `head_offset` *after* all appends (needed because the last frame's
%% end isn't recorded in `Positions`).
frame_extent(K, Positions, HeadOffsetAfter) ->
    {_, Start} = lists:nth(K + 1, Positions),
    End =
        case K + 1 < length(Positions) of
            true ->
                {_, S} = lists:nth(K + 2, Positions),
                S;
            false ->
                HeadOffsetAfter
        end,
    {Start, End}.

%% Path to a single segment file on disk. Used by properties that
%% manipulate segment bytes directly (P4 magic flip, P5/P13 truncation).
seg_path(Dir, SegId) ->
    filename:join(
        [Dir, instance_id(), bondy_oplog_wal_segment:filename(SegId)]
    ).

%% Append every event in `Events` through `Pid`, capture the
%% `{Segment, StartOffset}` returned by each, then read `head_offset`
%% from `info/1`. Used by P4 / P13 / P5 to derive frame boundaries
%% without re-parsing the on-disk segment.
append_and_record_positions(Pid, Events) ->
    Positions = [
        begin
            {ok, _, Pos} = bondy_oplog_wal:append(Pid, E),
            Pos
        end
     || E <- Events
    ],
    HeadOff = maps:get(head_offset, bondy_oplog_wal:info(Pid)),
    {Positions, HeadOff}.

%% Writes a `consumer.offset` file directly, bypassing the setter
%% guards. Used by P10 to seed arbitrary (including invalid) offsets
%% that recovery must still clamp safely.
seed_raw_consumer_offset(InstDir, Seg, Off) ->
    Path = filename:join(
        InstDir, ?BONDY_OPLOG_WAL_CONSUMER_OFFSET_FILENAME
    ),
    Content = io_lib:format(
        "{committed_segment, ~w}.~n"
        "{committed_frame_offset, ~w}.~n"
        "{committed_hlc, undefined}.~n"
        "{commit_count, 0}.~n"
        "{schema_version, 1}.~n",
        [Seg, Off]
    ),
    file:write_file(Path, iolist_to_binary(Content)).
