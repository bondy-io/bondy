%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_pack_sealed_view).

-include_lib("kernel/include/logger.hrl").
-include("bondy_mst.hrl").
-include("bondy_mst_pack.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Shared sealed-pack opener with self-healing `.idx` rebuild.

Both `bondy_mst_pack_store` (read+write) and
`bondy_mst_pack_reader` (read-only) materialise sealed views by
pairing a parsed `.idx` (in memory) with an open fd against the
`.pack` file. The plain open path is identical between them; the
rebuild dispatch on a missing or corrupt `.idx` is also identical.
This module owns both, plus the `idx_rebuild` telemetry event.

## Open contract

`open/3` takes the instance `Dir`, a `ctx()` map identifying the
instance, and the `PackId`. Returns `{ok, #sealed_view{}}` or a
typed `{error, _}`. A missing or corrupt `.idx` is routed through
`bondy_mst_pack_idx_rebuild:rebuild/4`; on success the sealed view
is opened from the freshly-rebuilt file and an
`[bondy_mst, page_store, idx_rebuild]` telemetry event with
`result => ok` is emitted. On rebuild failure the original open
error bubbles up and a `result => {error, _}` telemetry event is
emitted.

Non-rebuildable failure modes (FS errors other than `enoent` on
the `.idx`, or any `.pack` file error) bubble up unchanged — the
`.pack` itself is the system's long-term store and a corrupt sealed
pack is genuine data loss that operators must triage.

## ctx() shape

```erlang
#{instance_id   := binary(),
  instance_hash := non_neg_integer(),
  hash_algo     := atom()}
```

`open_ctx_from_writer/1` constructs this from an open
`bondy_mst_pack_writer`. `open_ctx_from_manifest/1` constructs it
from a parsed manifest — used by the reader, which has no writer.
The two helpers must agree on the `instance_hash` derivation; both
delegate to `bondy_mst_pack_writer` so a future change to the
hashing scheme stays in one place.
""").

-export([open/3]).
-export([open_ctx_from_writer/1]).
-export([open_ctx_from_manifest/1]).

-export_type([ctx/0]).
-export_type([open_error/0]).

-type ctx() :: #{
    instance_id := binary(),
    instance_hash := non_neg_integer(),
    hash_algo := atom()
}.

-type open_error() ::
    {sealed_idx, non_neg_integer(), term()}
    | {sealed_pack, non_neg_integer(), term()}.

%% =============================================================================
%% PUBLIC
%% =============================================================================

-spec open(Dir :: file:filename_all(), ctx(), PackId :: non_neg_integer()) ->
    {ok, #sealed_view{}} | {error, open_error()}.

open(Dir, Ctx, PackId) ->
    case attempt_open(Dir, PackId) of
        {ok, V} ->
            {ok, V};
        {error, {sealed_idx, PackId, Cause}} = E ->
            case is_rebuildable_idx_failure(Cause) of
                true -> maybe_rebuild_and_reopen(Dir, Ctx, PackId, Cause, E);
                false -> E
            end;
        {error, _} = E ->
            E
    end.

-spec open_ctx_from_writer(bondy_mst_pack_writer:t()) -> ctx().

open_ctx_from_writer(W) ->
    #{
        instance_id => bondy_mst_pack_writer:instance_id(W),
        instance_hash => bondy_mst_pack_writer:instance_hash(W),
        hash_algo => bondy_mst_pack_writer:hash_algo(W)
    }.

-spec open_ctx_from_manifest(bondy_mst_pack_manifest:t()) -> ctx().

open_ctx_from_manifest(M) ->
    InstanceId = bondy_mst_pack_manifest:instance_id(M),
    #{
        instance_id => InstanceId,
        %% Centralised in the writer so a future change to the
        %% derivation lives in one place.
        instance_hash => bondy_mst_pack_writer:derive_instance_hash(InstanceId),
        hash_algo => bondy_mst_pack_manifest:hash_algo(M)
    }.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
attempt_open(Dir, PackId) ->
    IdxPath = bondy_mst_pack_paths:sealed_idx_path(Dir, PackId),
    PackPath = bondy_mst_pack_paths:sealed_pack_path(Dir, PackId),
    case prim_file:read_file(IdxPath) of
        {ok, IdxBin} ->
            case bondy_mst_pack_index:open(IdxBin) of
                {ok, Idx} ->
                    case prim_file:open(PackPath, [read, raw, binary]) of
                        {ok, Fd} ->
                            {ok, #sealed_view{
                                pack_id = PackId, idx = Idx, pack_fd = Fd
                            }};
                        {error, R} ->
                            {error, {sealed_pack, PackId, R}}
                    end;
                {error, R} ->
                    {error, {sealed_idx, PackId, R}}
            end;
        {error, R} ->
            {error, {sealed_idx, PackId, R}}
    end.

%% @private
%% `enoent` is the only FS error we route to rebuild — every other
%% FS error (eacces, emfile, eio, …) would also fail the rebuild
%% write, so retrying is just two failure messages instead of one.
%% Everything else in this list is a `bondy_mst_pack_index:open/1`
%% decode error; the .pack is authoritative, so any of them is
%% recoverable by re-deriving the index from a fresh scan.
is_rebuildable_idx_failure(enoent) -> true;
is_rebuildable_idx_failure(truncated_header) -> true;
is_rebuildable_idx_failure(truncated_trailer) -> true;
is_rebuildable_idx_failure(integrity_mismatch) -> true;
is_rebuildable_idx_failure(bad_magic) -> true;
is_rebuildable_idx_failure({bad_version, _}) -> true;
is_rebuildable_idx_failure({bad_hash_len, _}) -> true;
is_rebuildable_idx_failure(truncated_fanout) -> true;
is_rebuildable_idx_failure(truncated_hashes) -> true;
is_rebuildable_idx_failure(truncated_offsets) -> true;
is_rebuildable_idx_failure({fanout_inconsistent, _}) -> true;
is_rebuildable_idx_failure({bloom, _}) -> true;
is_rebuildable_idx_failure(_) -> false.

%% @private
maybe_rebuild_and_reopen(Dir, Ctx, PackId, Cause, OriginalErr) ->
    InstanceId = maps:get(instance_id, Ctx),
    InstanceHash = maps:get(instance_hash, Ctx),
    HashAlgo = maps:get(hash_algo, Ctx),
    Trigger = idx_failure_trigger(Cause),
    StartTs = erlang:monotonic_time(microsecond),
    case
        bondy_mst_pack_idx_rebuild:rebuild(
            Dir, PackId, InstanceHash, HashAlgo
        )
    of
        {ok, Outcome} ->
            DurationUs = erlang:monotonic_time(microsecond) - StartTs,
            emit_ok(InstanceId, PackId, Trigger, Outcome, DurationUs),
            attempt_open(Dir, PackId);
        {error, R} ->
            DurationUs = erlang:monotonic_time(microsecond) - StartTs,
            emit_failed(InstanceId, PackId, Trigger, R, DurationUs),
            OriginalErr
    end.

%% @private
%% Telemetry metadata wants a single atom for the trigger; collapse
%% the codec's tagged variants (`{bad_version, _}` → `bad_version`)
%% so subscribers can pattern-match without unpacking the payload.
idx_failure_trigger(Atom) when is_atom(Atom) -> Atom;
idx_failure_trigger({Tag, _}) when is_atom(Tag) -> Tag;
idx_failure_trigger(_) -> unknown.

%% @private
emit_ok(InstanceId, PackId, Trigger, Outcome, DurationUs) ->
    telemetry:execute(
        [bondy_mst, page_store, idx_rebuild],
        #{
            duration_us => DurationUs,
            records_recovered => maps:get(records_recovered, Outcome),
            pack_bytes => maps:get(pack_bytes, Outcome),
            idx_bytes => maps:get(idx_bytes, Outcome)
        },
        #{
            instance_id => InstanceId,
            pack_id => PackId,
            result => ok,
            trigger => Trigger
        }
    ).

%% @private
emit_failed(InstanceId, PackId, Trigger, Reason, DurationUs) ->
    telemetry:execute(
        [bondy_mst, page_store, idx_rebuild],
        #{
            duration_us => DurationUs,
            records_recovered => 0,
            pack_bytes => 0,
            idx_bytes => 0
        },
        #{
            instance_id => InstanceId,
            pack_id => PackId,
            result => {error, Reason},
            trigger => Trigger
        }
    ).
