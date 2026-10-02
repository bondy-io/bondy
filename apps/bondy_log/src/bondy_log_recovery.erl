%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_log_recovery).

-include_lib("kernel/include/logger.hrl").
-include_lib("kernel/include/file.hrl").
-include("bondy_log.hrl").

-moduledoc """
Recovery sequencing for a per-instance WAL directory.

Recovery is the procedure the writer runs on open when a manifest
exists. It produces a usable, consistent
in-memory state from on-disk artifacts, applying break-and-truncate to
the head segment if needed and rebuilding lost / stale `.qidx` files.

The recovery contract: **the WAL is the source of truth.** Any frame
that survives recovery is durable; anything beyond the last valid
frame in the head segment is truncated. The consumer resumes from a
clamped `committed_frame_offset` that is guaranteed to be a real
frame boundary.

### Steps

1. **Manifest read & validate.** Refuse to open on instance_id mismatch
   or unsupported schema version.
2. **Orphan cleanup.** Remove `.tmp` files; remove `.qdata` / `.qidx`
   for segment ids outside `live_segments`. Log every deletion.
3. **Per sealed segment** (`live_segments ∖ {current_segment}`):
   open `.qdata` and verify the header identity through the adapter
   (refuse on mismatch). Open `.qidx`; if it is missing or fails to
   parse, rebuild it by walking the segment's frame stream — body-
   decoding only those frames that the writer's accumulator would have
   indexed.
4. **Head segment** (`current_segment`): open RW, validate header,
   scan forward from offset 48 frame-by-frame. The first invalid
   frame (CRC mismatch, bad magic, length out of range, body decode
   failure) marks the end of the durable tail; truncate the file to
   that offset. The accumulator built during the scan becomes the
   writer's `idx_acc`. Position the fd past the last valid frame so
   the writer's next `prim_file:write/2` appends correctly.
5. **Consumer offset.** Read `consumer.offset` (missing = fresh). Clamp:
   the segment must be in `live_segments`; the offset must be ≤ the
   last valid offset of the committed segment; the offset must be at
   a real frame boundary (use the `.qidx` to find the nearest
   preceding entry, then forward-scan).
6. **Return.** The writer installs the recovered state and resumes
   normal operation.
""".

-define(SEG_HEADER_BYTES, ?BONDY_LOG_SEGMENT_HEADER_BYTES).
-define(MAGIC_BYTES, 4).
-define(FRAME_HEADER_BYTES, ?BONDY_LOG_FRAME_HEADER_BYTES).
-define(READ_CHUNK_BYTES, (1024 * 1024)).

%% A frame walk reads its segment a chunk at a time rather than one pread per
%% frame header and another per body. A cached chunk is only valid while
%% nothing writes the file: every walk below runs under `recover/3`, which
%% `bondy_log_wal` calls from its open path before it holds a head fd.
-record(reader, {
    fd :: file:fd(),
    offset = 0 :: non_neg_integer(),
    chunk = <<>> :: binary()
}).

-type recovery_mode() :: strict | rescan.

-type recovery_opts() :: #{
    adapter := module(),
    identity := bondy_log_identity:ctx(),
    body_encryption => bondy_log_codec:encryption(),
    idx_interval_bytes => pos_integer(),
    recovery_mode => recovery_mode(),
    telemetry_prefix => [atom(), ...]
}.

%% What every frame-decoding step needs: the codec's encryption config
%% and telemetry prefix, and the log adapter (with its magic resolved
%% once).
-type decode_ctx() :: #{
    body_encryption := bondy_log_codec:encryption(),
    telemetry_prefix := [atom(), ...],
    adapter := module(),
    frame_magic := bondy_log_frame:magic()
}.

-type recovery_result() :: #{
    manifest := bondy_log_manifest:t(),
    head_fd := file:fd(),
    head_segment_id := non_neg_integer(),
    head_offset := non_neg_integer(),
    first_key := bondy_log_record:key() | undefined,
    last_key := bondy_log_record:key() | undefined,
    append_count := non_neg_integer(),
    %% The largest record seq (`bondy_log_record:max_seq/1`) in the retained WAL: the manifest's
    %% record for the sealed segments, maxed with the head-segment scan.
    max_seq := non_neg_integer(),
    idx_acc := bondy_log_idx:accumulator(),
    consumer_offset := bondy_log_state:consumer_offset(),
    truncated_bytes := non_neg_integer(),
    frames_skipped := non_neg_integer(),
    bytes_skipped := non_neg_integer(),
    %% Bytes the head-segment scan walked: `last_valid_offset` minus
    %% the segment header, plus any bytes that were physically present
    %% and skipped past in `rescan` mode. Excludes the segment-header
    %% (read once and validated) and excludes sealed segments (which
    %% are validated by header check, not by walking their frames).
    scanned_bytes := non_neg_integer(),
    cleaned_orphans := [file:filename_all()]
}.

-export_type([recovery_mode/0]).
-export_type([recovery_opts/0]).
-export_type([recovery_result/0]).

-export([recover/3]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Runs recovery for the WAL directory `Dir` belonging to `InstanceId`.
`Opts` carries:

- `adapter` — the log adapter (`bondy_log_record` + `bondy_log_identity`)
  the log was written with; frames are decoded through it and every
  segment header's identity is verified by it.
- `identity` — the adapter's identity context, as passed to the writer.
- `telemetry_prefix` — the writer's event-name prefix, for the codec's
  decode events; defaults to `[bondy_log]`.
- `idx_interval_bytes` — the sparse-index emit interval the writer
  uses; recovery threads the same value through the head-segment scan
  so the rebuilt accumulator matches what a from-scratch writer would
  have produced.
- `recovery_mode` — `strict` (default writer behaviour) breaks and
  truncates at the first corrupt frame in the head segment; `rescan`
  skips corrupt frames, rewriting the head segment in place to
  contain only the surviving frames.

Returns `{ok, recovery_result()}` on success or `{error, Reason}` for:

- `{manifest, _}` — manifest is missing, unreadable, or fails validation.
- `{instance_id_mismatch, Expected, Found}` — WAL directory was created
  for a different instance.
- `{orphan_segment, _}` — a sealed segment's header doesn't carry this
  log's identity (e.g., backup restored onto the wrong node); the reason
  is the adapter's.
- `{head_segment, SegId, missing_segment}` — the manifest names a head
  segment whose file is absent. Distinct from a corrupt header: absence
  means something removed a segment the manifest still considers live,
  which the WAL's own write ordering cannot produce (`create/4` fsyncs
  the header and the dirent before the manifest names the segment).
- `{head_segment, _}` — head segment header is corrupt or unreadable.
  Under that same write ordering this state is unreachable for a
  manifest-named segment, so it is reported rather than repaired: a
  sub-48-byte file provably holds no frame and could be re-initialised
  without data loss, but doing so silently would erase the evidence that
  an invariant was violated. Detection here is deliberate, matching
  `bondy_log_scrubber`'s stance that repair is operator-driven.
- `{consumer_offset, _}` — `consumer.offset` file is malformed.

The caller (typically `bondy_log_wal:init/1`) is responsible for
installing the returned state and publishing the head atomics. The
recovery procedure itself does no atomics work.
""".
-spec recover(
    Dir :: file:filename_all(),
    InstanceId :: bondy_log_wal:instance_id(),
    Opts :: recovery_opts()
) -> {ok, recovery_result()} | {error, term()}.

recover(Dir, InstanceId, #{adapter := _, identity := _} = Opts) ->
    case sync_dir(Dir) of
        {error, _} = Error ->
            Error;
        ok ->
            case bondy_log_manifest:read(Dir) of
                {ok, Manifest} ->
                    run_pipeline(Dir, InstanceId, Opts, Manifest);
                {error, Reason} ->
                    {error, {manifest, Reason}}
            end
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Synced before recovery reads the directory, and before the writer
%% appends to a head segment whose directory entry could otherwise still
%% vanish on an unclean restart.
sync_dir(Dir) ->
    case bondy_mst_io:fsync_dir(Dir) of
        ok -> ok;
        {error, Reason} -> {error, {dir_fsync_failed, Dir, Reason}}
    end.

%% @private
%% Top-level orchestration. Each step `case`s on the previous step's
%% return so a single failure short-circuits cleanly without leaving
%% partially-recovered state visible.
run_pipeline(Dir, InstanceId, Opts0, Manifest) ->
    Opts = apply_opt_defaults(Opts0),
    IdxIntervalBytes = maps:get(idx_interval_bytes, Opts),
    BodyEnc = decode_ctx(Opts),
    Adapter = maps:get(adapter, Opts),
    Ctx = maps:get(identity, Opts),
    case validate_manifest(Manifest, InstanceId) of
        ok ->
            CleanedOrphans = cleanup_orphans(Dir, Manifest),
            case
                verify_sealed_segments(
                    Dir,
                    Adapter,
                    Ctx,
                    IdxIntervalBytes,
                    BodyEnc,
                    Manifest
                )
            of
                ok ->
                    case
                        recover_head_segment(
                            Dir, Adapter, Ctx, Opts, Manifest
                        )
                    of
                        {ok, HeadInfo} ->
                            finalize(
                                Dir, Manifest, HeadInfo, CleanedOrphans, BodyEnc
                            );
                        {error, _} = E ->
                            E
                    end;
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

%% @private
%% Fills in defaults for any unspecified key in `recovery_opts()`.
%% Centralised so production callers (the writer) and tests reach the
%% same baseline.
apply_opt_defaults(Opts) ->
    Defaults = #{
        idx_interval_bytes =>
            ?BONDY_LOG_IDX_DEFAULT_INTERVAL_BYTES,
        recovery_mode => strict,
        body_encryption => disabled,
        telemetry_prefix => [bondy_log]
    },
    maps:merge(Defaults, Opts).

%% @private
-spec decode_ctx(recovery_opts()) -> decode_ctx().
decode_ctx(Opts) ->
    Mod = maps:get(adapter, Opts),
    #{
        body_encryption => maps:get(body_encryption, Opts),
        telemetry_prefix => maps:get(telemetry_prefix, Opts),
        adapter => Mod,
        frame_magic => Mod:frame_magic()
    }.

%% @private
%% Validates the manifest **before** any destructive operation. Two
%% invariants:
%%
%% 1. `instance_id` matches the caller — refuses orphan WAL directories.
%% 2. `current_segment` is a member of `live_segments`. If this is
%%    violated, the subsequent `cleanup_orphans/2` would delete the
%%    head segment's `.qdata` (because it appears to be orphaned),
%%    leaving recovery in an unrecoverable state. A hand-edited or
%%    crash-corrupted manifest with an empty / inconsistent
%%    `live_segments` must abort recovery *before* anything is
%%    deleted.
validate_manifest(Manifest, InstanceId) ->
    case bondy_log_manifest:instance_id(Manifest) of
        InstanceId ->
            validate_current_in_live(Manifest);
        Other ->
            {error, {instance_id_mismatch, InstanceId, Other}}
    end.

%% @private
validate_current_in_live(Manifest) ->
    Current = bondy_log_manifest:current_segment(Manifest),
    LiveIds = [
        Id
     || {Id, _} <- bondy_log_manifest:live_segments(Manifest)
    ],
    case lists:member(Current, LiveIds) of
        true ->
            ok;
        false ->
            {error, {manifest, {current_not_in_live, Current, LiveIds}}}
    end.

%% @private
finalize(Dir, Manifest, HeadInfo, CleanedOrphans, Ctx) ->
    case bondy_log_state:read_consumer_offset(Dir) of
        {ok, CO0} ->
            CO = clamp_consumer_offset(CO0, Manifest, HeadInfo, Dir, Ctx),
            ok = persist_clamped_offset_if_changed(Dir, CO0, CO),
            {ok, build_result(Manifest, HeadInfo, CO, CleanedOrphans)};
        {error, Reason} ->
            _ = close_head_fd(HeadInfo),
            {error, {consumer_offset, Reason}}
    end.

%% @private
%% Persists the clamped consumer offset back to disk so recovery is
%% idempotent: a second crash-and-recover cycle observes the clamped
%% value directly, not the original (potentially past-EOF) one. We
%% skip the write when the clamp was a no-op so unused WALs don't pay
%% a per-open fsync.
persist_clamped_offset_if_changed(_Dir, Same, Same) ->
    ok;
persist_clamped_offset_if_changed(Dir, _Before, After) ->
    case bondy_log_state:write_consumer_offset(Dir, After) of
        ok ->
            ok;
        {error, Reason} ->
            ?LOG_WARNING(#{
                description =>
                    "Failed to persist clamped consumer offset during "
                    "recovery; in-memory state is correct but next "
                    "recovery will re-clamp from the stale on-disk file",
                reason => Reason
            }),
            ok
    end.

%% @private
close_head_fd(#{head_fd := Fd}) ->
    _ = prim_file:close(Fd),
    ok.

%% @private
build_result(Manifest, HeadInfo, CO, CleanedOrphans) ->
    #{
        manifest => Manifest,
        head_fd => maps:get(head_fd, HeadInfo),
        head_segment_id => maps:get(segment_id, HeadInfo),
        head_offset => maps:get(last_valid_offset, HeadInfo),
        first_key => maps:get(first_key, HeadInfo),
        last_key => maps:get(last_key, HeadInfo),
        append_count => maps:get(frame_count, HeadInfo),
        max_seq => max(
            bondy_log_manifest:max_seq(Manifest),
            maps:get(max_seq, HeadInfo)
        ),
        idx_acc => maps:get(idx_acc, HeadInfo),
        consumer_offset => CO,
        truncated_bytes => maps:get(truncated_bytes, HeadInfo),
        frames_skipped => maps:get(frames_skipped, HeadInfo, 0),
        bytes_skipped => maps:get(bytes_skipped, HeadInfo, 0),
        scanned_bytes => maps:get(scanned_bytes, HeadInfo, 0),
        cleaned_orphans => CleanedOrphans
    }.

%% -----------------------------------------------------------------------------
%% Orphan cleanup
%% -----------------------------------------------------------------------------

%% @private
%% Walks the WAL directory and removes:
%%
%% - `*.tmp` files (left behind by a crash mid-rename).
%% - `.qdata` files whose segment id is not in `live_segments`. These
%%   are typically the failed-rotation residue: a new segment was
%%   created but `commit_rotation` never landed.
%% - `.qidx` files whose segment id is not in `live_segments`. Same
%%   cause, plus stale indexes from segments since deleted via
%%   retention sweep.
%%
%% Files that are not WAL artifacts (anything that doesn't match the
%% expected naming patterns) are ignored — this is a defensive choice;
%% an operator who left an unrelated file in the WAL directory might
%% be unhappy to find it deleted on every restart.
cleanup_orphans(Dir, Manifest) ->
    LiveIds = [
        Id
     || {Id, _} <- bondy_log_manifest:live_segments(Manifest)
    ],
    case file:list_dir(Dir) of
        {ok, Names} ->
            lists:filtermap(
                fun(Name) ->
                    maybe_delete(Dir, Name, LiveIds)
                end,
                Names
            );
        {error, Reason} ->
            ?LOG_WARNING(#{
                description =>
                    "Failed to list WAL directory during orphan cleanup; "
                    "continuing without cleanup",
                dir => Dir,
                reason => Reason
            }),
            []
    end.

%% @private
maybe_delete(Dir, Name, LiveIds) ->
    case classify_file(Name, LiveIds) of
        keep ->
            false;
        {drop, Reason} ->
            Path = filename:join(Dir, Name),
            case prim_file:delete(Path) of
                ok ->
                    ?LOG_INFO(#{
                        description => "Removed orphan WAL artifact",
                        path => Path,
                        reason => Reason
                    }),
                    {true, Path};
                {error, DErr} ->
                    ?LOG_WARNING(#{
                        description =>
                            "Failed to remove orphan WAL artifact",
                        path => Path,
                        reason => DErr
                    }),
                    false
            end
    end.

%% @private
classify_file(Name, LiveIds) when is_binary(Name) ->
    classify_file(binary_to_list(Name), LiveIds);
classify_file(Name, LiveIds) ->
    case Name of
        ?BONDY_LOG_MANIFEST_FILENAME ->
            keep;
        ?BONDY_LOG_MANIFEST_TMP_FILENAME ->
            {drop, manifest_tmp};
        ?BONDY_LOG_CONSUMER_OFFSET_FILENAME ->
            keep;
        ?BONDY_LOG_CONSUMER_OFFSET_TMP_FILENAME ->
            {drop, consumer_offset_tmp};
        ?BONDY_LOG_SNAPSHOT_WATERMARK_FILENAME ->
            keep;
        ?BONDY_LOG_SNAPSHOT_WATERMARK_TMP_FILENAME ->
            {drop, snapshot_watermark_tmp};
        _ ->
            case lists:suffix(".tmp", Name) of
                true -> {drop, generic_tmp};
                false -> classify_data_file(Name, LiveIds)
            end
    end.

%% @private
classify_data_file(Name, LiveIds) ->
    case parse_segment_id(Name, ".qdata") of
        {ok, Id} ->
            classify_by_membership(Id, LiveIds, orphan_qdata);
        not_a_match ->
            case parse_segment_id(Name, ".qidx") of
                {ok, Id} ->
                    classify_by_membership(Id, LiveIds, orphan_qidx);
                not_a_match ->
                    %% Unknown extension — leave alone.
                    keep
            end
    end.

%% @private
classify_by_membership(Id, LiveIds, Reason) ->
    case lists:member(Id, LiveIds) of
        true -> keep;
        false -> {drop, {Reason, Id}}
    end.

%% @private
%% Parse "000000042.qdata" → {ok, 42}; "000000042.qidx" → {ok, 42};
%% anything else → not_a_match.
parse_segment_id(Name, Suffix) when is_list(Name) ->
    case lists:suffix(Suffix, Name) of
        false ->
            not_a_match;
        true ->
            Prefix = lists:sublist(Name, length(Name) - length(Suffix)),
            try list_to_integer(Prefix) of
                Id when Id >= 0 -> {ok, Id};
                _ -> not_a_match
            catch
                _:_ -> not_a_match
            end
    end.

%% -----------------------------------------------------------------------------
%% Sealed segments
%% -----------------------------------------------------------------------------

%% @private
%% Validates and (if necessary) rebuilds the `.qidx` for every sealed
%% segment in the manifest. The head segment is handled separately by
%% `recover_head_segment/5`.
verify_sealed_segments(
    Dir,
    Adapter,
    Ctx,
    IdxIntervalBytes,
    BodyEnc,
    Manifest
) ->
    Current = bondy_log_manifest:current_segment(Manifest),
    Live = bondy_log_manifest:live_segments(Manifest),
    Sealed = [{Id, FH} || {Id, FH} <- Live, Id =/= Current],
    verify_sealed_loop(
        Sealed, Dir, Adapter, Ctx, IdxIntervalBytes, BodyEnc
    ).

%% @private
verify_sealed_loop([], _Dir, _Adapter, _Ctx, _Interval, _BodyEnc) ->
    ok;
verify_sealed_loop(
    [{SegId, _FH} | Rest],
    Dir,
    Adapter,
    Ctx,
    Interval,
    BodyEnc
) ->
    case
        verify_sealed_segment(
            Dir, SegId, Adapter, Ctx, Interval, BodyEnc
        )
    of
        ok ->
            verify_sealed_loop(
                Rest, Dir, Adapter, Ctx, Interval, BodyEnc
            );
        {error, _} = E ->
            E
    end.

%% @private
verify_sealed_segment(Dir, SegId, Adapter, Ctx, Interval, BodyEnc) ->
    SegPath = filename:join(Dir, bondy_log_segment:filename(SegId)),
    case bondy_log_segment:open(SegPath) of
        {ok, Fd, Header} ->
            Res =
                case bondy_log_segment:verify(Header, Adapter, Ctx) of
                    ok ->
                        ensure_sealed_idx(
                            Dir, SegId, Fd, Interval, BodyEnc
                        );
                    {error, _} = E ->
                        E
                end,
            _ = prim_file:close(Fd),
            Res;
        {error, Reason} ->
            {error, {sealed_segment, SegId, Reason}}
    end.

%% @private
%% Returns `ok` if the on-disk `.qidx` is loadable. Otherwise rebuilds
%% by scanning the segment's frame stream and writes the new file.
ensure_sealed_idx(Dir, SegId, Fd, Interval, BodyEnc) ->
    IdxPath = filename:join(Dir, bondy_log_idx:filename(SegId)),
    case bondy_log_idx:read_file(IdxPath) of
        {ok, _Entries} ->
            ok;
        {error, Reason} ->
            ?LOG_INFO(#{
                description =>
                    "Sealed segment .qidx unavailable; rebuilding",
                segment => SegId,
                reason => Reason
            }),
            rebuild_sealed_idx(IdxPath, Fd, SegId, Interval, BodyEnc)
    end.

%% @private
rebuild_sealed_idx(IdxPath, Fd, SegId, Interval, BodyEnc) ->
    case scan_segment_for_index(Fd, Interval, BodyEnc) of
        {ok, Acc} ->
            Entries = bondy_log_idx:entries(Acc),
            case bondy_log_idx:write_file(IdxPath, Entries) of
                ok ->
                    ?LOG_INFO(#{
                        description =>
                            "Sealed segment .qidx rebuilt",
                        segment => SegId,
                        entries => length(Entries)
                    }),
                    ok;
                {error, Reason} ->
                    {error, {idx_rebuild_write, SegId, Reason}}
            end;
        {error, Reason} ->
            {error, {idx_rebuild_scan, SegId, Reason}}
    end.

%% @private
%% Scans the segment from offset 48 to EOF. For each frame the
%% accumulator decides via `would_index/2` whether the body must be
%% decoded; non-indexed frames are skipped header-only (a single pread
%% of the 16-byte frame header per frame). Sealed segments are trusted
%% (only their segment header is validated on recovery), so skipping
%% CRC verification for non-indexed frames is consistent with the
%% recovery contract.
scan_segment_for_index(Fd, Interval, BodyEnc) ->
    Acc0 = bondy_log_idx:new(Interval),
    scan_loop_for_index(reader(Fd), ?SEG_HEADER_BYTES, Acc0, BodyEnc).

%% @private
scan_loop_for_index(R0, Off, Acc, BodyEnc) ->
    case peek_frame_header(R0, Off, BodyEnc) of
        {{ok, FrameLen}, R1} ->
            case bondy_log_idx:would_index(Acc, FrameLen) of
                true ->
                    case
                        read_and_decode_frame_body(
                            R1, Off, FrameLen, BodyEnc
                        )
                    of
                        {{ok, Body}, R} ->
                            case decode_frame_bounds(Body, BodyEnc) of
                                {ok, FirstKey, LastKey, _MaxSeq} ->
                                    Acc1 =
                                        bondy_log_idx:note_indexed_frame(
                                            Acc, FirstKey, LastKey, Off
                                        ),
                                    scan_loop_for_index(
                                        R, Off + FrameLen, Acc1, BodyEnc
                                    );
                                {error, _} = E ->
                                    E
                            end;
                        {{truncate, Reason}, _R} ->
                            %% Sealed segment body corruption is a real
                            %% recovery error — surface so the operator
                            %% sees it.
                            {error, {sealed_body, Reason}};
                        {{error, _} = E, _R} ->
                            E
                    end;
                false ->
                    Acc1 = bondy_log_idx:note_skipped_frame(
                        Acc, FrameLen
                    ),
                    scan_loop_for_index(
                        R1, Off + FrameLen, Acc1, BodyEnc
                    )
            end;
        {eof, _R} ->
            {ok, Acc};
        {{truncate, Reason}, _R} ->
            {error, {sealed_header, Reason}};
        {{error, _} = E, _R} ->
            E
    end.

%% -----------------------------------------------------------------------------
%% Head segment
%% -----------------------------------------------------------------------------

%% Per-frame record built during the head-segment scan. In `strict`
%% mode `accepted_rev` is unused (we keep the writer's idx accumulator
%% and the file's existing layout). In `rescan` mode we also retain
%% each accepted frame's source-offset+length so we can rewrite the
%% segment in place to drop the corrupt regions.
%%
%% Memory bound for `accepted_rev`: one ~40-byte tuple per accepted
%% frame, retained until compaction (one-shot at recovery startup,
%% then freed). For the default 64 MiB `max_segment_bytes` cap, this
%% is ~2.5 MiB for typical 1 KB frames and ~12 MiB for 200-byte
%% registry-style frames. Both fit comfortably in startup RSS.
%% Operators running with a much larger `max_segment_bytes` should
%% scale the expectation linearly; switch to a streaming rewrite if
%% recovery memory becomes a constraint.
-record(head_scan, {
    mode :: recovery_mode(),
    segment_id :: non_neg_integer(),
    idx_interval :: pos_integer(),
    first_key :: bondy_log_record:key() | undefined,
    last_key :: bondy_log_record:key() | undefined,
    max_seq = 0 :: non_neg_integer(),
    frame_count = 0 :: non_neg_integer(),
    skipped_frames = 0 :: non_neg_integer(),
    skipped_bytes = 0 :: non_neg_integer(),
    %% [{SrcOff, FrameLen, FirstKey, LastKey}], newest-first. Only
    %% populated in rescan.
    accepted_rev = [] :: [
        {
            non_neg_integer(),
            pos_integer(),
            bondy_log_record:key(),
            bondy_log_record:key()
        }
    ],
    idx_acc :: bondy_log_idx:accumulator(),
    %% Decode context inherited from `recovery_opts`: the head-scan calls
    %% `read_and_decode_frame_body/4` once per frame header it accepts,
    %% threading this so the codec can resolve per-frame `KeyId`s via the
    %% operator-supplied registry and the record adapter can decode and
    %% key the batch.
    body_encryption :: decode_ctx()
}).

%% @private
%% Opens the head segment R/W, validates its header, scans forward,
%% and (in rescan mode) rewrites the segment to drop corrupt frames
%% before returning. Returns the recovered state needed to install in
%% the writer.
recover_head_segment(Dir, Adapter, Ctx, Opts, Manifest) ->
    SegId = bondy_log_manifest:current_segment(Manifest),
    SegPath = filename:join(Dir, bondy_log_segment:filename(SegId)),
    case bondy_log_segment:open(SegPath) of
        {ok, Fd, Header} ->
            case bondy_log_segment:verify(Header, Adapter, Ctx) of
                ok ->
                    finalize_head(Fd, SegId, Header, Dir, Opts);
                {error, Reason} ->
                    _ = prim_file:close(Fd),
                    {error, {head_segment, SegId, Reason}}
            end;
        {error, Reason} ->
            {error, {head_segment, SegId, Reason}}
    end.

%% @private
finalize_head(Fd, SegId, Header, Dir, Opts) ->
    IdxInterval = maps:get(idx_interval_bytes, Opts),
    Mode = maps:get(recovery_mode, Opts),
    BodyEnc = decode_ctx(Opts),
    State0 = #head_scan{
        mode = Mode,
        segment_id = SegId,
        idx_interval = IdxInterval,
        idx_acc = bondy_log_idx:new(IdxInterval),
        body_encryption = BodyEnc
    },
    case scan_head_loop(reader(Fd), ?SEG_HEADER_BYTES, State0) of
        {ok, LastValid, S} ->
            maybe_compact_and_finalize(Fd, SegId, Header, Dir, LastValid, S);
        {error, Reason} ->
            _ = prim_file:close(Fd),
            {error, {head_segment, SegId, Reason}}
    end.

%% @private
%% In strict mode, or in rescan mode with zero skips, the layout on
%% disk is already a contiguous run of valid frames — just truncate
%% trailing garbage to `LastValid`. In rescan mode with skips, the
%% file has gaps; rewrite it in place to a contiguous tmp file and
%% atomic-rename.
maybe_compact_and_finalize(Fd, SegId, Header, Dir, LastValid, S) ->
    case S#head_scan.skipped_frames of
        0 ->
            finalize_strict(Fd, SegId, LastValid, S);
        _ ->
            log_rescan_summary(SegId, S),
            compact_and_finalize(Fd, SegId, Header, Dir, S)
    end.

%% @private
finalize_strict(Fd, SegId, LastValid, S) ->
    case truncate_head_if_needed(Fd, LastValid) of
        {ok, TruncatedBytes} ->
            {ok, head_result(Fd, SegId, LastValid, TruncatedBytes, S)};
        {error, Reason} ->
            _ = prim_file:close(Fd),
            {error, {head_segment, SegId, {truncate, Reason}}}
    end.

%% @private
%% Rewrites the head segment to a fresh tmp file containing only the
%% accepted frames, atomic-renames over the original, and reopens the
%% renamed file R/W. The original fd is closed. The idx accumulator
%% is rebuilt with the *new* (compacted) offsets so the writer's
%% on-rotation `.qidx` flush points at the right bytes.
compact_and_finalize(Fd, SegId, Header, Dir, S) ->
    case rewrite_head_compact(Fd, SegId, Header, Dir, S) of
        {ok, NewFd, NewLastValid, NewIdxAcc} ->
            _ = prim_file:close(Fd),
            S1 = S#head_scan{idx_acc = NewIdxAcc},
            %% truncated_bytes is the bytes that disappeared from the
            %% original file — skipped frames plus any trailing garbage.
            TruncatedBytes = S1#head_scan.skipped_bytes,
            {ok, head_result(NewFd, SegId, NewLastValid, TruncatedBytes, S1)};
        {error, Reason} ->
            _ = prim_file:close(Fd),
            {error, {head_segment, SegId, {compact, Reason}}}
    end.

%% @private
head_result(Fd, SegId, LastValid, TruncatedBytes, S) ->
    %% Bytes the head-segment scan walked: the byte range
    %% `[?SEG_HEADER_BYTES, LastValid]` is the run of frames the
    %% scanner accepted (post-compact in rescan mode), and
    %% `skipped_bytes` covers any bytes that were physically present
    %% and walked past during rescan-mode resumption. Trailing
    %% truncation bytes are accounted for separately via
    %% `truncated_bytes` and are not "scanned" in this sense — the
    %% scanner halted before descending into them.
    ScannedBytes =
        max(0, LastValid - ?SEG_HEADER_BYTES) +
            S#head_scan.skipped_bytes,
    #{
        segment_id => SegId,
        head_fd => Fd,
        last_valid_offset => LastValid,
        first_key => S#head_scan.first_key,
        last_key => S#head_scan.last_key,
        max_seq => S#head_scan.max_seq,
        frame_count => S#head_scan.frame_count,
        frames_skipped => S#head_scan.skipped_frames,
        bytes_skipped => S#head_scan.skipped_bytes,
        scanned_bytes => ScannedBytes,
        idx_acc => S#head_scan.idx_acc,
        truncated_bytes => TruncatedBytes
    }.

%% @private
%% Forward scan of the head segment. In strict mode the first decode
%% failure marks the truncation point; in rescan mode each failure is
%% logged, the bytes are counted as skipped, and the scan resumes
%% from the next frame magic (or the end of the corrupted frame, if
%% the header parsed cleanly).
scan_head_loop(R0, Off, S) ->
    case peek_frame_header(R0, Off, S#head_scan.body_encryption) of
        {{ok, FrameLen}, R} ->
            scan_with_header(R, Off, FrameLen, S);
        {eof, _R} ->
            {ok, Off, S};
        {{truncate, Reason}, R} ->
            handle_skip_or_stop(R, Off, undefined, Reason, S);
        {{error, _} = E, _R} ->
            E
    end.

%% @private
scan_with_header(R0, Off, FrameLen, S) ->
    case
        read_and_decode_frame_body(
            R0, Off, FrameLen, S#head_scan.body_encryption
        )
    of
        {{ok, Body}, R} ->
            absorb_frame(R, Off, FrameLen, Body, S);
        {{truncate, Reason}, R} ->
            handle_skip_or_stop(R, Off, FrameLen, Reason, S);
        {{error, _} = E, _R} ->
            E
    end.

%% @private
absorb_frame(R, Off, FrameLen, Body, S) ->
    case decode_frame_bounds(Body, S#head_scan.body_encryption) of
        {ok, FirstKey, LastKey, MaxSeq} ->
            S1 = accept_frame(Off, FrameLen, FirstKey, LastKey, MaxSeq, S),
            scan_head_loop(R, Off + FrameLen, S1);
        {error, Reason} ->
            %% CRC-clean but body isn't a well-formed batch list. Strict
            %% treats this as truncation; rescan logs and skips past
            %% the known FrameLen (the frame's header was valid).
            handle_skip_or_stop(R, Off, FrameLen, {bad_body, Reason}, S)
    end.

%% @private
accept_frame(Off, FrameLen, FirstKey, LastKey, MaxSeq, S) ->
    IdxAcc = bondy_log_idx:note_frame(
        S#head_scan.idx_acc, FirstKey, LastKey, Off, FrameLen
    ),
    AcceptedRev =
        case S#head_scan.mode of
            rescan ->
                [{Off, FrameLen, FirstKey, LastKey} | S#head_scan.accepted_rev];
            strict ->
                S#head_scan.accepted_rev
        end,
    S#head_scan{
        first_key = pick_first_key(S#head_scan.first_key, FirstKey),
        last_key = LastKey,
        max_seq = max_seq_after(S#head_scan.max_seq, MaxSeq),
        frame_count = S#head_scan.frame_count + 1,
        idx_acc = IdxAcc,
        accepted_rev = AcceptedRev
    }.

%% @private
%% Dispatches on the recovery mode. In strict mode any failure stops
%% the scan with `LastValid = Off`. In rescan mode the bytes from Off
%% up to either the next magic (header-level corruption) or the end
%% of the framed-but-corrupt range (body-level corruption) are
%% skipped, logged, and the scan resumes.
%%
%% `FrameLen` is `undefined` when the failure happened at the header
%% level (we don't know how long the corrupt frame is supposed to be).
handle_skip_or_stop(
    _R, Off, _FrameLen, _Reason, #head_scan{mode = strict} = S
) ->
    {ok, Off, S};
handle_skip_or_stop(R, Off, FrameLen, Reason, #head_scan{mode = rescan} = S) ->
    %% Two strategies based on what we know:
    %% - Header parsed cleanly (FrameLen known): the frame body is
    %%   corrupt, but FrameLen is from a CRC-unverified header — we
    %%   cannot trust it absolutely. Probe at `Off + FrameLen` first;
    %%   if there's no magic there, fall back to byte-by-byte scan.
    %% - Header did not parse (FrameLen undefined): scan byte-by-byte
    %%   from Off + 1 for the next magic.
    Resume = next_resume_offset(
        R#reader.fd, Off, FrameLen, magic_bin(S)
    ),
    handle_rescan_resume(R, Off, FrameLen, Reason, Resume, S).

%% @private
handle_rescan_resume(_R, Off, _FrameLen, Reason, eof, S) ->
    %% No more magics; treat everything from Off onwards as skipped
    %% trailing garbage. Stop the scan at Off (the last good offset).
    ?LOG_WARNING(#{
        description => "Rescan recovery: trailing corruption to EOF",
        segment_id => S#head_scan.segment_id,
        skipped_from => Off,
        reason => Reason
    }),
    %% File size minus Off is the skipped trailing region; counted
    %% separately at compact time via `truncated_bytes`. We do not
    %% inflate skipped_bytes with the trailing garbage — that's
    %% truncation, not skip-with-survivors-past-it.
    {ok, Off, S};
handle_rescan_resume(R, Off, FrameLen, Reason, {ok, NextOff}, S) ->
    Skipped = NextOff - Off,
    ?LOG_WARNING(#{
        description => "Rescan recovery: skipping corrupt frame",
        segment_id => S#head_scan.segment_id,
        skipped_from => Off,
        skipped_to => NextOff,
        skipped_bytes => Skipped,
        frame_len_hint => FrameLen,
        reason => Reason
    }),
    S1 = S#head_scan{
        skipped_frames = S#head_scan.skipped_frames + 1,
        skipped_bytes = S#head_scan.skipped_bytes + Skipped
    },
    scan_head_loop(R, NextOff, S1).

%% @private
%% Picks the offset to resume the scan at after a corruption event.
%% Header-level corruption: scan byte-by-byte from Off+1 for the next
%% magic. Body-level corruption: probe at Off+FrameLen first (the
%% common case where only the body is torn but the framing is intact
%% per CRC-unverified header); if no magic there, byte-by-byte scan.
next_resume_offset(Fd, Off, undefined, MagicBin) ->
    find_next_magic(Fd, Off + 1, MagicBin);
next_resume_offset(Fd, Off, FrameLen, MagicBin) ->
    Probe = Off + FrameLen,
    case has_magic_at(Fd, Probe, MagicBin) of
        true -> {ok, Probe};
        false -> find_next_magic(Fd, Off + 1, MagicBin);
        eof -> eof;
        {error, _} = E -> E
    end.

%% @private
magic_bin(#head_scan{body_encryption = #{frame_magic := Magic}}) ->
    <<Magic:32/big-unsigned>>.

%% @private
has_magic_at(Fd, Off, MagicBin) ->
    case prim_file:pread(Fd, Off, ?MAGIC_BYTES) of
        {ok, MagicBin} -> true;
        {ok, _} -> false;
        eof -> eof;
        {error, _} = E -> E
    end.

%% @private
log_rescan_summary(SegId, S) ->
    ?LOG_WARNING(#{
        description => "Rescan recovery completed with skipped frames",
        segment_id => SegId,
        frames_kept => S#head_scan.frame_count,
        frames_skipped => S#head_scan.skipped_frames,
        bytes_skipped => S#head_scan.skipped_bytes
    }).

%% @private
%% Chunked forward scan for the next frame magic byte sequence.
%% Returns `{ok, Off}` of the next magic, or `eof` if the file ends
%% before another magic appears. The chunk overlap is `MAGIC_BYTES - 1
%% = 3` so a magic straddling a chunk boundary is still found.
%%
%% Used only by rescan-mode recovery. Strict mode never calls this.
%% 64 KiB chunks balance syscall count vs. memory: a multi-MiB
%% contiguous corrupt region needs `bytes / chunk` preads to scan.
%% At 16 KiB we paid 4× the syscalls for the same total read; at
%% 256 KiB we'd hold a larger transient binary for no gain on the
%% common case (single torn frame fits in one chunk regardless).
-define(RESCAN_CHUNK_BYTES, (64 * 1024)).

find_next_magic(Fd, FromOff, MagicBin) ->
    find_next_magic_loop(Fd, FromOff, MagicBin).

%% @private
find_next_magic_loop(Fd, Off, MagicBin) ->
    case prim_file:pread(Fd, Off, ?RESCAN_CHUNK_BYTES) of
        {ok, Bin} when byte_size(Bin) < ?MAGIC_BYTES ->
            eof;
        {ok, Bin} ->
            case binary:match(Bin, MagicBin) of
                {Pos, ?MAGIC_BYTES} ->
                    {ok, Off + Pos};
                nomatch ->
                    Advance = byte_size(Bin) - (?MAGIC_BYTES - 1),
                    case Advance > 0 of
                        true ->
                            find_next_magic_loop(
                                Fd, Off + Advance, MagicBin
                            );
                        false ->
                            eof
                    end
            end;
        eof ->
            eof;
        {error, _} = E ->
            E
    end.

%% @private
%% Rewrites the head segment file to a tmp sibling containing only
%% the accepted frames, then atomic-renames over the original. The
%% original fd is left open R/W for the caller to close after the
%% rename; the caller also receives a fresh R/W fd on the renamed
%% file. Atomicity guarantee: if recovery crashes mid-rewrite, the
%% original file is intact and a fresh recovery attempt sees the
%% same corruption + the orphan tmp (which `cleanup_orphans/2` will
%% delete on the next run).
rewrite_head_compact(SrcFd, SegId, Header, Dir, S) ->
    SegName = bondy_log_segment:filename(SegId),
    FinalPath = filename:join(Dir, SegName),
    %% `FinalPath` is a `file:filename_all()` — either a binary or a
    %% list. Build the tmp sibling via iolist so we work for both.
    TmpPath = iolist_to_binary([FinalPath, ".tmp"]),
    %% Delete any leftover tmp from a prior failed compaction so the
    %% `[exclusive]` open below doesn't refuse with `eexist`.
    _ = prim_file:delete(TmpPath),
    case prim_file:open(TmpPath, [read, write, raw, binary, exclusive]) of
        {ok, DstFd} ->
            HeaderBin = bondy_log_segment:encode_header(Header),
            case copy_frames_to_tmp(SrcFd, DstFd, HeaderBin, S) of
                {ok, NewLastValid, NewIdxAcc} ->
                    case
                        finalize_compact_tmp(
                            DstFd, TmpPath, FinalPath, Dir
                        )
                    of
                        {ok, NewFd} ->
                            {ok, NewFd, NewLastValid, NewIdxAcc};
                        {error, _} = E ->
                            _ = prim_file:delete(TmpPath),
                            E
                    end;
                {error, _} = E ->
                    _ = prim_file:close(DstFd),
                    _ = prim_file:delete(TmpPath),
                    E
            end;
        {error, _} = E ->
            E
    end.

%% @private
%% Writes the segment header into the tmp file, then copies each
%% accepted frame from `SrcFd` to `DstFd` in order, rebuilding the
%% idx accumulator with the new (compacted) offsets.
copy_frames_to_tmp(SrcFd, DstFd, HeaderBin, S) ->
    case prim_file:write(DstFd, HeaderBin) of
        ok ->
            Accepted = lists:reverse(S#head_scan.accepted_rev),
            IdxAcc0 = bondy_log_idx:new(S#head_scan.idx_interval),
            copy_loop(SrcFd, DstFd, ?SEG_HEADER_BYTES, Accepted, IdxAcc0);
        {error, _} = E ->
            E
    end.

%% @private
copy_loop(_SrcFd, _DstFd, Pos, [], IdxAcc) ->
    {ok, Pos, IdxAcc};
copy_loop(
    SrcFd,
    DstFd,
    Pos,
    [{SrcOff, FrameLen, FirstKey, LastKey} | Rest],
    IdxAcc
) ->
    case prim_file:pread(SrcFd, SrcOff, FrameLen) of
        {ok, Bin} when byte_size(Bin) =:= FrameLen ->
            case prim_file:write(DstFd, Bin) of
                ok ->
                    IdxAcc1 = bondy_log_idx:note_frame(
                        IdxAcc, FirstKey, LastKey, Pos, FrameLen
                    ),
                    copy_loop(
                        SrcFd, DstFd, Pos + FrameLen, Rest, IdxAcc1
                    );
                {error, _} = E ->
                    E
            end;
        {ok, _Short} ->
            {error, {compact_short_read, SrcOff, FrameLen}};
        eof ->
            {error, {compact_eof, SrcOff, FrameLen}};
        {error, _} = E ->
            E
    end.

%% @private
%% Not `bondy_log_io:write_atomic/3`: the caller owns the fd, and the
%% compacted file must come back open R/W positioned at EOF.
finalize_compact_tmp(DstFd, TmpPath, FinalPath, Dir) ->
    case bondy_mst_io:datasync(DstFd) of
        ok ->
            _ = prim_file:close(DstFd),
            case prim_file:rename(TmpPath, FinalPath) of
                ok ->
                    %% dir-fsync so the rename is durable.
                    case bondy_mst_io:fsync_dir(Dir) of
                        ok -> reopen_compacted(FinalPath);
                        {error, _} = E -> E
                    end;
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            _ = prim_file:close(DstFd),
            E
    end.

%% @private
reopen_compacted(FinalPath) ->
    case prim_file:open(FinalPath, [read, write, raw, binary]) of
        {ok, NewFd} ->
            %% Position at EOF so subsequent writer appends land at
            %% the right offset.
            case prim_file:position(NewFd, eof) of
                {ok, _} ->
                    {ok, NewFd};
                {error, Reason} ->
                    _ = prim_file:close(NewFd),
                    {error, {position, Reason}}
            end;
        {error, _} = E ->
            E
    end.

%% @private
%% Returns the number of bytes trimmed; 0 if the file was already at
%% `LastValid`. After truncation, the file position is at the new EOF,
%% so subsequent `prim_file:write/2` on the writer's fd lands at the
%% right offset.
truncate_head_if_needed(Fd, LastValid) ->
    case prim_file:position(Fd, eof) of
        {ok, Size} when Size =:= LastValid ->
            %% File already ends at the last valid offset. Seek back
            %% there so subsequent writes append in the right place.
            {ok, _} = prim_file:position(Fd, LastValid),
            {ok, 0};
        {ok, Size} when Size > LastValid ->
            {ok, _} = prim_file:position(Fd, LastValid),
            case prim_file:truncate(Fd) of
                ok ->
                    case bondy_mst_io:datasync(Fd) of
                        ok -> {ok, Size - LastValid};
                        {error, _} = E -> E
                    end;
                {error, _} = E ->
                    E
            end;
        {ok, Size} when Size < LastValid ->
            %% Shouldn't happen — the scan can't progress past the
            %% physical EOF. Crash loudly if it does.
            {error, {scan_past_eof, Size, LastValid}};
        {error, _} = E ->
            E
    end.

%% -----------------------------------------------------------------------------
%% Consumer offset clamping
%% -----------------------------------------------------------------------------

%% @private
%% Clamps the consumer offset to a position that is:
%% 1. In a segment that's still in `live_segments`.
%% 2. ≤ `last_valid_offset` of that segment.
%% 3. At a real frame boundary.
%%
%% On any invariant violation, the offset is moved down (never up).
clamp_consumer_offset(CO, Manifest, HeadInfo, Dir, Ctx) ->
    Seg = bondy_log_state:committed_segment(CO),
    Off = bondy_log_state:committed_frame_offset(CO),
    Live = bondy_log_manifest:live_segments(Manifest),
    LiveIds = [Id || {Id, _} <- Live],
    case lists:member(Seg, LiveIds) of
        false ->
            %% Committed segment has been swept. Clamp to the start of
            %% the earliest live segment.
            FirstLive = lists:min(LiveIds),
            bondy_log_state:with_position(
                CO, FirstLive, ?SEG_HEADER_BYTES
            );
        true ->
            clamp_offset_within_segment(CO, Seg, Off, HeadInfo, Dir, Ctx)
    end.

%% @private
clamp_offset_within_segment(CO, Seg, Off, HeadInfo, Dir, Ctx) ->
    HeadSeg = maps:get(segment_id, HeadInfo),
    Bound =
        case Seg of
            HeadSeg ->
                maps:get(last_valid_offset, HeadInfo);
            _ ->
                sealed_segment_size(Dir, Seg)
        end,
    %% Clamp magnitude to ≤ Bound; then clamp to a frame boundary.
    ClampedToBound = min(Off, Bound),
    Aligned = align_to_frame_boundary(
        Dir, Seg, ClampedToBound, HeadInfo, Ctx
    ),
    bondy_log_state:with_position(CO, Seg, Aligned).

%% @private
sealed_segment_size(Dir, Seg) ->
    Path = filename:join(Dir, bondy_log_segment:filename(Seg)),
    case prim_file:read_file_info(Path) of
        {ok, #file_info{size = Size}} ->
            Size;
        _ ->
            %% Defensive: if we can't size the file we conservatively
            %% return the segment header boundary so the clamp lands at
            %% "nothing committed".
            ?SEG_HEADER_BYTES
    end.

%% @private
%% Returns the largest frame-start offset `≤ Target` within the
%% segment. Uses the `.qidx` (or the head segment's in-memory acc) to
%% find a nearby anchor, then forward-scans to find the exact boundary.
%% Returns `?SEG_HEADER_BYTES` if no anchor / scan reaches `Target`.
%%
%% The `.qidx` is keyed by key, but the clamp target is a byte offset.
%% We sweep entries linearly to find the largest entry with
%% `ByteOffset ≤ Target`. The list is small (sub-1k entries), so the
%% linear sweep is fast enough.
align_to_frame_boundary(_Dir, _Seg, Target, _HeadInfo, _Ctx) when
    Target =< ?SEG_HEADER_BYTES
->
    ?SEG_HEADER_BYTES;
align_to_frame_boundary(Dir, Seg, Target, HeadInfo, Ctx) ->
    HeadSeg = maps:get(segment_id, HeadInfo),
    Entries =
        case Seg of
            HeadSeg ->
                bondy_log_idx:entries(
                    maps:get(idx_acc, HeadInfo)
                );
            _ ->
                sealed_idx_entries(Dir, Seg)
        end,
    Anchor = seek_byte_offset(Entries, Target),
    forward_scan_to_boundary(Dir, Seg, Anchor, Target, Ctx).

%% @private
seek_byte_offset(Entries, Target) ->
    lists:foldl(
        fun
            ({_H, Off}, Best) when Off =< Target, Off > Best -> Off;
            (_, Best) -> Best
        end,
        ?SEG_HEADER_BYTES,
        Entries
    ).

%% @private
sealed_idx_entries(Dir, Seg) ->
    Path = filename:join(Dir, bondy_log_idx:filename(Seg)),
    case bondy_log_idx:read_file(Path) of
        {ok, Entries} -> Entries;
        {error, _} -> []
    end.

%% @private
%% Walks frames starting at `Anchor` looking for the largest frame-
%% start offset `≤ Target`. Uses header-only peeks; no CRC verification
%% needed (we just want a boundary; the reader re-CRCs every frame).
forward_scan_to_boundary(Dir, Seg, Anchor, Target, Ctx) ->
    Path = filename:join(Dir, bondy_log_segment:filename(Seg)),
    case prim_file:open(Path, [read, raw, binary]) of
        {ok, Fd} ->
            try
                walk_to_boundary(reader(Fd), Anchor, Target, Anchor, Ctx)
            after
                _ = prim_file:close(Fd)
            end;
        {error, _} ->
            Anchor
    end.

%% @private
walk_to_boundary(R0, Off, Target, Best, Ctx) when Off =< Target ->
    case peek_frame_header(R0, Off, Ctx) of
        {{ok, FrameLen}, R} ->
            Next = Off + FrameLen,
            if
                Next =< Target ->
                    walk_to_boundary(R, Next, Target, Next, Ctx);
                true ->
                    %% The next frame would overshoot Target; current
                    %% frame's start is the largest boundary ≤ Target.
                    Off
            end;
        _ ->
            Best
    end;
walk_to_boundary(_R, _Off, _Target, Best, _Ctx) ->
    Best.

%% -----------------------------------------------------------------------------
%% Frame-level read helpers
%% -----------------------------------------------------------------------------

%% @private
%% Reads just the 16-byte frame header at `Off` and returns the frame
%% length. Does **not** CRC-verify the body — that's
%% `read_and_decode_frame_body/3`'s job. Callers that don't need the
%% body (sealed-segment rebuild for non-indexed frames, the consumer-
%% offset clamp walk) save the body pread + decode.
%%
%% Returns:
%%
%% - `{ok, FrameLen}`: header parsed, magic OK, FrameLen ≥ header size.
%% - `eof`: file ends before a full header is available.
%% - `{truncate, Reason}`: header-level integrity failure (bad magic,
%%   length out of range). The head-segment scan treats this as the
%%   truncation point.
%% - `{error, Reason}`: I/O error (surfaced to the caller).
peek_frame_header(R0, Off, #{frame_magic := Magic}) ->
    {Res, R} = pread(R0, Off, ?FRAME_HEADER_BYTES),
    Out =
        case Res of
            {ok, HeaderBin} when
                byte_size(HeaderBin) =:= ?FRAME_HEADER_BYTES
            ->
                case
                    bondy_log_frame:decode_header(HeaderBin, [{magic, Magic}])
                of
                    {ok, #{frame_len := FrameLen}} -> {ok, FrameLen};
                    {error, Reason} -> {truncate, Reason}
                end;
            {ok, Short} when byte_size(Short) < ?FRAME_HEADER_BYTES ->
                eof;
            eof ->
                eof;
            {error, Reason} ->
                {error, Reason}
        end,
    {Out, R}.

%% @private
%% Serves `Len` bytes at `Off` from the cached chunk, or refills the cache
%% with at least `?READ_CHUNK_BYTES` from `Off`. A short read at EOF returns
%% the bytes there are, which every caller already treats as `eof`.
reader(Fd) ->
    #reader{fd = Fd}.

%% @private
pread(#reader{offset = COff, chunk = Chunk} = R, Off, Len) when
    Off >= COff, Off + Len =< COff + byte_size(Chunk)
->
    {{ok, binary:part(Chunk, Off - COff, Len)}, R};
pread(#reader{fd = Fd} = R, Off, Len) ->
    case prim_file:pread(Fd, Off, max(Len, ?READ_CHUNK_BYTES)) of
        {ok, Chunk} ->
            Bin = binary:part(Chunk, 0, min(Len, byte_size(Chunk))),
            {{ok, Bin}, R#reader{offset = Off, chunk = Chunk}};
        Other ->
            {Other, R}
    end.

%% @private
%% Reads the full frame at `Off`, CRC-verifies it, and runs the codec
%% to recover the inner batch bytes. Returns:
%%
%% - `{ok, Body}`: frame decoded successfully; `Body` is the inner
%%   bytes (the encoded `[Event_1, ..., Event_N]` list). For frames
%%   whose Flags advertise compression the codec inflates them
%%   transparently — callers always see the post-codec body.
%% - `{truncate, Reason}`: CRC mismatch, body short, codec failure, or
%%   any other frame-level decode failure. The head-segment scan
%%   treats this as the truncation point; the sealed-segment rebuild
%%   surfaces it as corruption.
%% - `{error, Reason}`: I/O error.
read_and_decode_frame_body(
    R0,
    Off,
    FrameLen,
    #{
        frame_magic := Magic,
        body_encryption := BodyEnc,
        telemetry_prefix := Prefix
    }
) ->
    {Res, R} = pread(R0, Off, FrameLen),
    Out =
        case Res of
            {ok, Bin} when byte_size(Bin) =:= FrameLen ->
                case bondy_log_frame:decode(Bin, [{magic, Magic}]) of
                    {ok, RawBody, #{flags := Flags}} ->
                        case
                            bondy_log_codec:decode_body(RawBody, Flags, #{
                                body_encryption => BodyEnc,
                                telemetry_prefix => Prefix
                            })
                        of
                            {ok, Body} ->
                                {ok, Body};
                            {error, Reason} ->
                                %% A codec failure on an otherwise valid
                                %% frame is recovery-level corruption —
                                %% map it through the truncation channel so
                                %% the head-scan loop hits its existing
                                %% strict/rescan dispatch.
                                {truncate, {codec, Reason}}
                        end;
                    {error, Reason} ->
                        {truncate, Reason}
                end;
            {ok, _Short} ->
                {truncate, truncated_body};
            eof ->
                {truncate, truncated_body};
            {error, Reason} ->
                {error, Reason}
        end,
    {Out, R}.

%% @private
%% Decodes the first and last records' keys and the batch's largest seq
%% out of an already-CRC-verified body, through the record adapter
%% (`bondy_log_record`). Used by both the head-scan path (to populate
%% `head_scan.first_key` / `last_key` / `max_seq`) and the sealed-segment
%% index rebuild path (`scan_loop_for_index/4`, which ignores the seq —
%% the manifest already records it for sealed segments). The decoded
%% records are not retained — only the two keys and one integer survive —
%% so the cost is bounded by the adapter's decode itself.
%%
%% A body the adapter rejects is `{error, Reason}`; `absorb_frame/5` reads
%% that as `{bad_body, _}` and strict recovery treats it as TRUNCATION,
%% discarding every frame after it. That is why the oplog adapter decodes
%% without `[safe]` — see the oplog adapter.
decode_frame_bounds(Body, #{adapter := Mod}) ->
    case Mod:decode_body(Body) of
        {ok, Records} ->
            {ok, Mod:key(hd(Records)), Mod:key(lists:last(Records)),
                Mod:max_seq(Records)};
        {error, _} = E ->
            E
    end.

%% @private
%% A record kind with no sequence (`Mod:max_seq/1` → `undefined`) leaves
%% the retained maximum where it is.
max_seq_after(Cur, undefined) -> Cur;
max_seq_after(Cur, MaxSeq) -> max(Cur, MaxSeq).

%% @private
pick_first_key(undefined, Key) -> Key;
pick_first_key(Existing, _) -> Existing.
