%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_pack_writer).

-include_lib("kernel/include/logger.hrl").
-include("bondy_mst.hrl").
-include("bondy_mst_pack.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Pack-store writer: owns the open `incoming.pack` fd, the in-memory
pending hash index, and the seal flow that rotates the incoming
pack into a numbered sealed pack with its companion `.idx`.

See the pack-store design notes §3 (pack format)
and §5 (seal flow).

## Purity boundary

The pure codec modules (`bondy_mst_pack_codec`,
`bondy_mst_pack_index`, `bondy_mst_pack_manifest`) own the
on-disk wire format and pure record arithmetic. This module is
the *first* place that performs sustained file I/O against an
instance directory: it opens `incoming.pack`, appends records,
and on `seal/1` writes the immutable `pack-NNNN.pack` /
`pack-NNNN.idx` files and atomically updates the manifest.

## Lifecycle

```
open(Dir, #{instance_id := Id})
    → reads or creates manifest
    → opens / creates incoming.pack
    → if manifest says incoming_pack=present, scans incoming.pack
      to rebuild the pending hash → offset map
    → returns writer state

append(W, Page)
    → Hash = sha256(Page)
    → if Hash already in pending, no-op (idempotent)
    → else encode record, write to incoming.pack, advance offset,
      datasync the fd (durability of in-progress writes is
      controlled by the caller; for now we datasync per record)

seal(W)
    → Read every record body out of incoming.pack into memory
      (one pread per pending entry)
    → Sort by hash, dedup
    → Write `pack-NNNN.pack.tmp` (header, sorted records, trailer)
      and `pack-NNNN.idx.tmp`
    → fsync both, rename to final names, fsync dir
    → Update manifest atomically (sealed_packs += [N],
      incoming_pack := absent)
    → Unlink incoming.pack (the next append re-creates it)

close(W) → close incoming.pack fd; manifest unchanged
```

## Crash safety

The seal flow follows the §5 ordering: every new file is durable
before the manifest swap, so a crash mid-seal cannot leave a
manifest pointing at a pack that isn't on disk. The reverse —
orphan `.pack`/`.idx` files on disk that aren't in the manifest,
left by a crash between rename and manifest swap (seal) or between
manifest swap and unlink (GC) — is cleaned by the orphan scanner
in `do_open/4` before the writer surfaces `{ok, t()}`. Any
`*.tmp` rename artefacts are deleted at the same point.

Per-append durability is governed by the batching policy
(`sync_every_records` / `sync_every_ms`, see `open_opts()`).
Defaults (see `bondy_mst_pack.hrl`): `sync_every_records = 32`,
`sync_every_ms = 200`. The pack store sits beneath a WAL that is
the authoritative source of truth, so per-record fsync is
unnecessary in the common case — the WAL applier re-derives any
unsynced pages on recovery. Callers that need stricter durability
(e.g. when the pack store is the source of truth) set
`sync_every_records = 1`.

## What this module does NOT do

- Multi-writer arbitration (caller must serialise — the gen_server
  wrapper does so by owning the single writer instance).
- Recovery / truncation of partially-written records (deferred).
- Compaction / GC across sealed packs (separate module).
- Cross-pack read lookup (that's `bondy_mst_pack_reader`).
""").

-record(?MODULE, {
    dir :: file:filename_all(),
    instance_id :: binary(),
    hash_algo :: atom(),
    instance_hash :: non_neg_integer(),
    manifest :: bondy_mst_pack_manifest:t(),
    incoming_fd :: file:fd() | undefined,
    incoming_offset :: non_neg_integer(),
    %% Hash => {Offset, PageLen, Body}. Offset is the byte offset of
    %% the record header in incoming.pack; PageLen is the body length;
    %% Body is the page bytes kept resident so the MST traversal
    %% (which re-reads pages via `pending_read/2` immediately after
    %% writing them) doesn't have to syscall back to disk. Caps memory
    %% at the auto-seal threshold (~16 MB by default).
    pending :: #{binary() => {non_neg_integer(), non_neg_integer(), binary()}},
    %% In-flight asynchronous seal (at most one — see `roll_incoming/1`). Holds
    %% the rolled, frozen snapshot whose pages are NOT yet in a sealed pack:
    %% `{SealingPath, BodyMap, PackId}` where BodyMap is `Hash => Body`. Reads
    %% (`pending_lookup/2`, `pending_read/2`) consult `pending` then this
    %% snapshot so every page stays visible while the worker rewrites it. The
    %% file is kept on disk (frozen) purely for crash recovery; the worker seals
    %% from BodyMap, not the file. `complete_seal/2` clears it.
    sealing = undefined ::
        undefined
        | {
            file:filename_all(),
            #{binary() => binary()},
            non_neg_integer()
        },
    next_pack_id :: pos_integer(),
    %% Durability policy. After each successful append, the writer
    %% datasyncs when EITHER `unsynced_count >= sync_every_records`
    %% OR `monotonic_ms - last_sync_ms >= sync_every_ms`. The
    %% T-based threshold is opportunistic — it only fires when an
    %% append happens; callers wanting a true wall-clock guarantee
    %% should run their own timer that calls `flush/1`.
    sync_every_records :: pos_integer(),
    sync_every_ms :: pos_integer() | infinity,
    unsynced_count = 0 :: non_neg_integer(),
    last_sync_ms :: integer(),
    %% Root-flush debounce. `set_root/2` rewrites the manifest, which
    %% costs tmp+datasync+rename+fsync_dir (4 fsyncs) — ~40-200 ms per
    %% call on macOS APFS. Without debouncing the MST applier (one
    %% set_root per drain batch) serialises on this fsync chain.
    %% Same shape as the append batching above: flush when EITHER
    %% `root_unsynced_count >= root_flush_every_records` OR
    %% `monotonic_ms - last_root_flush_ms >= root_flush_every_ms`,
    %% checked on each `set_root/2` call. Seal paths reset these
    %% counters because they already rewrite the manifest with the
    %% current in-memory root. `close/1` and `flush/1` force a flush
    %% so clean shutdown is lossless.
    root_flush_every_records :: pos_integer() | infinity,
    root_flush_every_ms :: pos_integer() | infinity,
    root_unsynced_count = 0 :: non_neg_integer(),
    last_root_flush_ms :: integer(),
    root_dirty = false :: boolean()
}).

-type t() :: #?MODULE{}.

-type open_opts() :: #{
    instance_id := binary(),
    hash_algo => atom(),
    sync_every_records => pos_integer(),
    sync_every_ms => pos_integer() | infinity,
    root_flush_every_records => pos_integer() | infinity,
    root_flush_every_ms => pos_integer() | infinity
}.

-type open_error() ::
    {missing_field, atom()}
    | {manifest, term()}
    | {incoming, term()}
    | {pending_scan, term()}
    | {orphan_cleanup, term()}
    | needs_recovery
    | {instance_id_mismatch, binary(), binary()}
    | {hash_algo_mismatch, atom(), atom()}.

-type append_error() ::
    {write, term()}
    | {sync, term()}.

-type seal_error() ::
    {seal, term()}
    | {idx_build, bondy_mst_pack_index:build_error()}
    | {manifest, term()}.

-type seal_job() :: #{
    dir := file:filename_all(),
    instance_hash := non_neg_integer(),
    hash_algo := atom(),
    pack_id := pos_integer(),
    bodies := #{binary() => binary()}
}.

-export_type([t/0]).
-export_type([open_opts/0]).
-export_type([open_error/0]).
-export_type([append_error/0]).
-export_type([seal_error/0]).
-export_type([seal_job/0]).

%% Lifecycle
-export([open/2]).
-export([close/1]).

%% Mutation
-export([append/2]).
-export([flush/1]).
-export([seal/1]).
-export([set_root/2]).
-export([set_manifest/2]).

%% Asynchronous seal
-export([roll_incoming/1]).
-export([run_seal_job/1]).
-export([complete_seal/2]).

%% Inspection
-export([dir/1]).
-export([manifest/1]).
-export([instance_id/1]).
-export([instance_hash/1]).
-export([hash_algo/1]).
-export([derive_instance_hash/1]).
-export([pending_count/1]).
-export([pending_hashes/1]).
-export([pending_lookup/2]).
-export([pending_read/2]).
-export([member/2]).
-export([sealing_pack_id/1]).
-export([current_root/1]).
-export([incoming_offset/1]).
-export([next_pack_id/1]).
-export([unsynced_count/1]).

%% =============================================================================
%% API — lifecycle
%% =============================================================================

?DOC("""
Opens (or creates) a pack-store instance at `Dir`.

`Opts` must carry `instance_id` (a non-empty binary). `hash_algo`
defaults to `sha256`. On first open in an empty directory, a
fresh manifest is written. On reopen, the existing manifest is
loaded and validated against the supplied options.

If the manifest declares `incoming_pack = present` and the file
exists, the writer scans it to rebuild the pending hash→offset
map. Any decode error in the scan returns `{error, needs_recovery}`;
the dedicated recovery path (next phase) is responsible for
truncating partial records.
""").
-spec open(file:filename_all(), open_opts()) ->
    {ok, t()} | {error, open_error()}.

open(Dir, Opts) when is_list(Dir) orelse is_binary(Dir), is_map(Opts) ->
    case maps:find(instance_id, Opts) of
        {ok, InstanceId} when
            is_binary(InstanceId), byte_size(InstanceId) > 0
        ->
            HashAlgo = maps:get(hash_algo, Opts, sha256),
            Policy = #{
                sync_every_records =>
                    maps:get(
                        sync_every_records,
                        Opts,
                        ?BONDY_MST_PACK_DEFAULT_SYNC_EVERY_RECORDS
                    ),
                sync_every_ms =>
                    maps:get(
                        sync_every_ms,
                        Opts,
                        ?BONDY_MST_PACK_DEFAULT_SYNC_EVERY_MS
                    ),
                root_flush_every_records =>
                    maps:get(
                        root_flush_every_records,
                        Opts,
                        ?BONDY_MST_PACK_DEFAULT_ROOT_FLUSH_EVERY_RECORDS
                    ),
                root_flush_every_ms =>
                    maps:get(
                        root_flush_every_ms,
                        Opts,
                        ?BONDY_MST_PACK_DEFAULT_ROOT_FLUSH_EVERY_MS
                    )
            },
            do_open(Dir, InstanceId, HashAlgo, Policy);
        _ ->
            {error, {missing_field, instance_id}}
    end.

?DOC("""
Closes the incoming.pack fd. The on-disk manifest and any sealed
packs are untouched. Idempotent: calling `close/1` on an already-
closed writer is a no-op.
""").
-spec close(t()) -> ok.

close(#?MODULE{incoming_fd = undefined} = W) ->
    _ = flush_pending_root(W),
    ok;
close(#?MODULE{incoming_fd = Fd} = W) ->
    _ = flush(W),
    _ = prim_file:close(Fd),
    ok.

%% =============================================================================
%% API — mutation
%% =============================================================================

?DOC("""
Appends a page to the incoming pack. Returns `{ok, Hash, W1}`.

The hash is derived from `Page` using the writer's configured
algorithm (currently always sha256). If the same hash is already
pending in the in-memory index, the call is a no-op — the file
is not touched and the returned state is byte-for-byte identical.

CRC + record bytes are written to the OS page cache, then a
`datasync` is issued only when the batching policy's threshold is
crossed (`sync_every_records` or `sync_every_ms`, configured at
`open/2`). Defaults batch ~32 appends or 200 ms (see
`bondy_mst_pack.hrl`). Callers needing per-record durability set
`sync_every_records = 1`; callers needing an explicit boundary
drive `flush/1` directly.

A failure surfaces as `{error, {write, Reason}}` (record write) or
`{error, {sync, Reason}}` (deferred datasync triggered by this
append); the in-memory pending map is not updated. The on-disk
byte cursor may have moved if the failure occurred partway
through; recovery on reopen will detect and truncate any partial
trailing record.
""").
-spec append(t(), Page :: binary()) ->
    {ok, Hash :: binary(), t()} | {error, append_error()}.

append(#?MODULE{} = W, Page) when is_binary(Page) ->
    Hash = compute_hash(W#?MODULE.hash_algo, Page),
    case maps:is_key(Hash, W#?MODULE.pending) of
        true ->
            {ok, Hash, W};
        false ->
            case ensure_incoming_open(W) of
                {ok, W1} ->
                    do_append(W1, Hash, Page);
                {error, _} = E ->
                    E
            end
    end.

?DOC("""
Forces a `datasync` of the incoming pack fd if there are any unsynced
records buffered, AND a manifest rewrite if a `set_root/2` is
pending. Idempotent: returns `{ok, W}` without touching disk when
both buffers are clean (or the incoming pack hasn't been created
yet — in which case only the manifest flush runs).

The batching policy normally takes care of durability automatically;
this exists for callers that need an explicit boundary — e.g. before
a snapshot, before close, or in response to an external durability
request.
""").
-spec flush(t()) -> {ok, t()} | {error, term()}.

flush(#?MODULE{} = W) ->
    case flush_incoming(W) of
        {ok, W1} -> flush_pending_root(W1);
        {error, _} = E -> E
    end.

%% @private
flush_incoming(#?MODULE{unsynced_count = 0} = W) -> {ok, W};
flush_incoming(#?MODULE{incoming_fd = undefined} = W) -> {ok, W};
flush_incoming(#?MODULE{} = W) -> do_sync(W).

%% @private
flush_pending_root(#?MODULE{root_dirty = false} = W) -> {ok, W};
flush_pending_root(#?MODULE{} = W) -> do_flush_root(W).

?DOC("""
Seals the incoming pack into a numbered sealed pack.

If the pending set is empty, returns `{ok, no_op, W}` without
touching disk — there's nothing to seal. The manifest's
`incoming_pack` flag is reconciled to `absent` if it was lingering
`present`. (Deferred: empty-seal might still want to remove the
incoming.pack file if it has only a header.)

Otherwise, the four-step seal:

1. Read all record bodies back from incoming.pack via pread.
2. Sort by hash, dedup adjacent duplicates (keep first), write
   `pack-NNNN.pack.tmp` (header + records + trailer) and
   `pack-NNNN.idx.tmp`.
3. fsync both files, rename to final, fsync directory.
4. Atomically swap the manifest to include `pack-NNNN` and clear
   `incoming_pack`.  Then delete `incoming.pack`.

Returns `{ok, PackId, W1}` on success or a typed `{error, _}` if
any step fails. Failure at step 1–3 leaves the manifest unchanged
and any `.tmp` orphans visible for recovery. Failure at step 4
(post-manifest-swap) leaves a stale `incoming.pack` on disk that
the recovery scanner removes on next open.
""").
-spec seal(t()) ->
    {ok, no_op, t()}
    | {ok, PackId :: pos_integer(), t()}
    | {error, seal_error()}.

seal(#?MODULE{pending = P} = W) when map_size(P) =:= 0 ->
    case bondy_mst_pack_manifest:incoming_pack(W#?MODULE.manifest) of
        absent when W#?MODULE.root_dirty ->
            %% No pending records to seal, but a staged root is unflushed.
            %% Piggy-back the root flush onto a no-op seal.
            case do_flush_root(W) of
                {ok, W1} -> {ok, no_op, W1};
                {error, R} -> {error, {manifest, R}}
            end;
        absent ->
            {ok, no_op, W};
        present ->
            %% Pending is empty but manifest says present — reconcile.
            %% The in-memory manifest also carries any staged root, so the
            %% write below covers both reconciliation and root debounce.
            M1 = bondy_mst_pack_manifest:with_incoming_pack(
                W#?MODULE.manifest, absent
            ),
            case bondy_mst_pack_manifest:write(W#?MODULE.dir, M1) of
                ok ->
                    {ok, no_op,
                        reset_root_flush_counters(
                            W#?MODULE{manifest = M1}
                        )};
                {error, R} ->
                    {error, {manifest, R}}
            end
    end;
seal(#?MODULE{} = W) ->
    do_seal(W).

?DOC("""
Stages `Root` as the manifest's `current_root`. The in-memory
manifest is always updated so subsequent `manifest/1` /
`current_root/1` reads see the new root immediately.

The on-disk manifest is rewritten only when the debounce policy
fires — either `root_unsynced_count >= root_flush_every_records`
or `monotonic_ms - last_root_flush_ms >= root_flush_every_ms`.
Each rewrite costs tmp+datasync+rename+fsync_dir (4 fsyncs) so
debouncing turns a per-batch hot spot into amortised cost.

Crash semantics: the on-disk `current_root` may lag the in-memory
root by up to the debounce window. The pack store sits beneath a
WAL that is the authoritative source of truth, so on reopen the
applier replays unapplied WAL records and the on-disk root
catches up. Callers that need stricter durability either lower
the thresholds, call `flush/1` after `set_root/2`, or open the
writer with `root_flush_every_records = 1` (per-call fsync).

`close/1` and `flush/1` always force a final manifest write if a
root flush is pending so clean shutdown is lossless.

Returns `{ok, W1}` (the manifest write either succeeded or was
debounced) or `{error, _}` if the debounced write was due *and*
failed — in the latter case the writer's in-memory root still
reflects the new value and the dirty bit stays set so the next
flush attempt will retry.
""").
-spec set_root(t(), Root :: binary() | undefined) ->
    {ok, t()} | {error, term()}.

set_root(#?MODULE{} = W, Root) when is_binary(Root); Root =:= undefined ->
    M1 = bondy_mst_pack_manifest:with_current_root(W#?MODULE.manifest, Root),
    W1 = W#?MODULE{
        manifest = M1,
        root_unsynced_count = W#?MODULE.root_unsynced_count + 1,
        root_dirty = true
    },
    case root_flush_due(W1) of
        true -> do_flush_root(W1);
        false -> {ok, W1}
    end.

?DOC("""
Refreshes the writer's cached manifest and `next_pack_id` after an
out-of-band manifest swap (e.g., compaction in `bondy_mst_pack_store:gc/2`).

The caller is responsible for having already persisted `M` to disk; this
just updates the in-memory copies.
""").
-spec set_manifest(t(), bondy_mst_pack_manifest:t()) -> t().

set_manifest(#?MODULE{} = W, M) ->
    %% The caller persisted M to disk already; the new on-disk state
    %% supersedes any staged set_root call, so the root-flush
    %% bookkeeping resets.
    reset_root_flush_counters(W#?MODULE{
        manifest = M,
        next_pack_id = next_pack_id_from(M)
    }).

%% =============================================================================
%% API — asynchronous seal
%% =============================================================================

?DOC("""
Rolls the active `incoming.pack` aside so it can be sealed *off* the
caller's critical path, and returns a self-contained `seal_job()` for a
worker to execute.

This is the cheap, synchronous half of an asynchronous seal (the expensive
rewrite is `run_seal_job/1`). It:

1. Datasyncs the active `incoming.pack` so every pending record is durable.
2. Closes the incoming fd and renames `incoming.pack` →
   `incoming-sealing-<PackId>.pack`. The rename keeps the rolled pages
   durable on disk under a stable name — the worker seals from the
   in-memory snapshot, but the file is the crash-recovery source until the
   sealed pack commits.
3. Commits the roll by writing the manifest with `incoming_pack = absent`
   (this is the roll's linearisation point), and resets the writer to a
   fresh empty incoming state (the next `append/2` lazily recreates
   `incoming.pack`). `next_pack_id` advances past the rolled id.

The rolled snapshot is held in the writer's `sealing` field so reads
(`pending_read/2`, `member/2`, `pending_hashes/1`) keep serving the rolled
pages until `complete_seal/2` finalises the sealed pack.

Returns:

- `{ok, Job, W1}` — rolled; run `Job` via `run_seal_job/1`, then
  `complete_seal/2` with `Job`'s pack id.
- `{no_op, W}` — nothing pending to seal.
- `{error, seal_in_flight}` — a previous seal has not yet completed (the
  in-flight=1 cap; the caller defers).
- `{error, _}` — an I/O failure during the roll.
""").
-spec roll_incoming(t()) ->
    {ok, seal_job(), t()} | {no_op, t()} | {error, term()}.

roll_incoming(#?MODULE{pending = P} = W) when map_size(P) =:= 0 ->
    {no_op, W};
roll_incoming(#?MODULE{sealing = S}) when S =/= undefined ->
    {error, seal_in_flight};
roll_incoming(#?MODULE{} = W0) ->
    case flush_incoming(W0) of
        {ok, W1} -> do_roll_incoming(W1);
        {error, _} = E -> E
    end.

?DOC("""
Executes a `seal_job()` produced by `roll_incoming/1`: writes the sorted,
indexed `pack-<PackId>.pack` + `.idx` pair from the job's in-memory body
snapshot, datasyncs, and renames them into place.

Pure with respect to writer state — it reads nothing from the live writer
and mutates no shared state, so it is safe to run in a separate worker
process while the instance keeps appending. The manifest swap that makes
the sealed pack authoritative is `complete_seal/2`, run back on the
instance after this returns.

Returns `ok` or `{error, _}`; on error the instance does NOT
`complete_seal/2` — the rolled snapshot stays in `sealing`, the frozen
`incoming-sealing-<PackId>.pack` stays on disk, and recovery re-seals it
on the next open.
""").
-spec run_seal_job(seal_job()) -> ok | {error, term()}.

run_seal_job(#{
    dir := Dir,
    instance_hash := IH,
    hash_algo := HashAlgo,
    pack_id := PackId,
    bodies := Bodies
}) ->
    Hashes = lists:sort(maps:keys(Bodies)),
    Reader = body_reader(Bodies),
    case
        bondy_mst_pack_seal:create_sealed_pack(
            Dir, IH, HashAlgo, PackId, Hashes, Reader
        )
    of
        ok -> ok;
        {error, R} -> {error, {seal, R}}
    end.

?DOC("""
Finalises the asynchronous seal whose worker has just completed
`run_seal_job/1`. Adds `PackId` to the manifest's `sealed_packs` and clears
the in-flight `sealing` snapshot, then deletes the now-superseded
`incoming-sealing-<PackId>.pack`.

Unlike the synchronous `seal/1`, this does NOT touch the manifest's
`incoming_pack` flag: a fresh `incoming.pack` may already be live (declared
`present`) from appends that arrived after the roll. The manifest write
here is the seal's linearisation point — pre-write the sealed pack is
invisible; post-write it is durable and authoritative, and the store opens
it as a sealed view.

`PackId` must equal the in-flight seal's id (`sealing_pack_id/1`); a
mismatch or a missing in-flight seal is an error.
""").
-spec complete_seal(t(), pos_integer()) -> {ok, t()} | {error, term()}.

complete_seal(#?MODULE{sealing = undefined}, _PackId) ->
    {error, no_seal_in_flight};
complete_seal(
    #?MODULE{sealing = {Path, _Bodies, PackId}, dir = Dir, manifest = M} = W,
    PackId
) ->
    case persist_sealed_pack(Dir, M, PackId) of
        {ok, M1} ->
            _ = prim_file:delete(Path),
            _ = bondy_mst_io:fsync_dir(Dir),
            W1 = reset_root_flush_counters(W#?MODULE{
                manifest = M1,
                sealing = undefined
            }),
            {ok, W1};
        {error, R} ->
            {error, {manifest, R}}
    end;
complete_seal(#?MODULE{sealing = {_Path, _Bodies, Other}}, PackId) ->
    {error, {seal_id_mismatch, Other, PackId}}.

%% =============================================================================
%% API — inspection
%% =============================================================================

-spec dir(t()) -> file:filename_all().
dir(#?MODULE{dir = D}) -> D.

-spec manifest(t()) -> bondy_mst_pack_manifest:t().
manifest(#?MODULE{manifest = M}) -> M.

-spec instance_id(t()) -> binary().
instance_id(#?MODULE{instance_id = Id}) -> Id.

-spec instance_hash(t()) -> non_neg_integer().
instance_hash(#?MODULE{instance_hash = IH}) -> IH.

-spec hash_algo(t()) -> atom().
hash_algo(#?MODULE{hash_algo = A}) -> A.

-spec pending_count(t()) -> non_neg_integer().
pending_count(#?MODULE{pending = P}) -> map_size(P).

?DOC("""
Every hash resident in the writer: the active `pending` set unioned with
any in-flight `sealing` snapshot (see `roll_incoming/1`). The union is
load-bearing — while a seal is in flight the rolled pages live only in the
`sealing` snapshot, and omitting them here would make `enumerate_hashes` /
AAE diff see a store that is momentarily missing pages the root references.
""").
-spec pending_hashes(t()) -> [binary()].
pending_hashes(#?MODULE{pending = P, sealing = undefined}) ->
    lists:sort(maps:keys(P));
pending_hashes(#?MODULE{pending = P, sealing = {_Path, Bodies, _PackId}}) ->
    lists:sort(maps:keys(maps:merge(Bodies, P))).

?DOC("""
Returns the on-disk record offset of `Hash` in `incoming.pack`,
or `not_found`. Used by an in-process reader (the gen_server)
to resolve a recent put without opening a separate reader.

Scoped to the *active* `incoming.pack` only: it does NOT consult an
in-flight `sealing` snapshot (those pages no longer live in
`incoming.pack`). Callers needing presence across the full resident set —
active pending plus any in-flight seal — use `member/2`; callers needing
the body use `pending_read/2`.
""").
-spec pending_lookup(t(), binary()) ->
    {ok, {non_neg_integer(), non_neg_integer()}} | not_found.

pending_lookup(#?MODULE{pending = P}, Hash) ->
    case maps:find(Hash, P) of
        {ok, {Offset, Len, _Body}} -> {ok, {Offset, Len}};
        error -> not_found
    end.

?DOC("""
Whether `Hash` is resident in the writer — present in the active `pending`
set OR in an in-flight `sealing` snapshot. This is the membership predicate
the store's `has/2` uses so a page stays visible throughout an asynchronous
seal.
""").
-spec member(t(), binary()) -> boolean().

member(#?MODULE{pending = P, sealing = S}, Hash) ->
    maps:is_key(Hash, P) orelse sealing_has(S, Hash).

?DOC("""
The pack id of the seal currently in flight (set by `roll_incoming/1`,
cleared by `complete_seal/2`), or `undefined` when no seal is in flight.
The store reads this to enforce the in-flight=1 cap — it defers a roll
while a seal is pending rather than starting a second concurrent rewrite.
""").
-spec sealing_pack_id(t()) -> non_neg_integer() | undefined.

sealing_pack_id(#?MODULE{sealing = undefined}) -> undefined;
sealing_pack_id(#?MODULE{sealing = {_Path, _Bodies, PackId}}) -> PackId.

?DOC("""
Reads the page body associated with `Hash` from `incoming.pack` via
the writer's own fd. Returns `{ok, Body}` for a present hash, where
`Body` is the bytes that were passed to `append/2` (so callers can
deserialise back to their domain object), `not_found` for an absent
hash, or `{error, _}` on I/O.
""").
-spec pending_read(t(), binary()) ->
    {ok, binary()} | not_found | {error, term()}.

pending_read(#?MODULE{pending = P, sealing = S}, Hash) ->
    case maps:find(Hash, P) of
        {ok, {_Offset, _Len, Body}} ->
            {ok, Body};
        error ->
            sealing_read(S, Hash)
    end.

%% @private
sealing_has(undefined, _Hash) ->
    false;
sealing_has({_Path, Bodies, _PackId}, Hash) ->
    maps:is_key(Hash, Bodies).

%% @private
sealing_read(undefined, _Hash) ->
    not_found;
sealing_read({_Path, Bodies, _PackId}, Hash) ->
    case maps:find(Hash, Bodies) of
        {ok, Body} -> {ok, Body};
        error -> not_found
    end.

-spec current_root(t()) -> binary() | undefined.
current_root(#?MODULE{manifest = M}) ->
    bondy_mst_pack_manifest:current_root(M).

-spec incoming_offset(t()) -> non_neg_integer().
incoming_offset(#?MODULE{incoming_offset = Off}) -> Off.

-spec next_pack_id(t()) -> pos_integer().
next_pack_id(#?MODULE{next_pack_id = N}) -> N.

?DOC("""
Number of records that have been written to `incoming.pack` but not
yet `datasync`'d to disk. Decreases to 0 after each successful sync
(either from the batching policy or an explicit `flush/1`).
""").
-spec unsynced_count(t()) -> non_neg_integer().
unsynced_count(#?MODULE{unsynced_count = N}) -> N.

%% =============================================================================
%% PRIVATE — open
%% =============================================================================

%% @private
do_open(Dir, InstanceId, HashAlgo, Policy) ->
    case ensure_dir(Dir) of
        ok ->
            case load_or_create_manifest(Dir, InstanceId, HashAlgo) of
                {ok, Manifest} ->
                    case validate_manifest(Manifest, InstanceId, HashAlgo) of
                        ok ->
                            case cleanup_orphan_packs(Dir, Manifest) of
                                ok ->
                                    open_after_recovery(
                                        Dir,
                                        InstanceId,
                                        HashAlgo,
                                        Manifest,
                                        Policy
                                    );
                                {error, R} ->
                                    {error, {orphan_cleanup, R}}
                            end;
                        {error, _} = E ->
                            E
                    end;
                {error, R} ->
                    {error, {manifest, R}}
            end;
        {error, R} ->
            {error, {manifest, R}}
    end.

%% @private
%% Recover any asynchronous seal interrupted by a crash, then open the live
%% incoming pack. A crash between `roll_incoming/1` and `complete_seal/2`
%% leaves an `incoming-sealing-<id>.pack` on disk whose pages are not yet in
%% a sealed pack. `reconcile_sealing/4` finalises each such file (re-sealing
%% uncommitted ones, deleting already-committed ones) and reconciles the
%% manifest before the regular incoming open proceeds.
open_after_recovery(Dir, InstanceId, HashAlgo, Manifest, Policy) ->
    case reconcile_sealing(Dir, InstanceId, HashAlgo, Manifest) of
        {ok, Manifest1} ->
            open_incoming(Dir, InstanceId, HashAlgo, Manifest1, Policy);
        {error, _} = E ->
            E
    end.

%% @private
%% Finalise every `incoming-sealing-<id>.pack` left on disk by a crash mid
%% asynchronous-seal, then reconcile the manifest's `incoming_pack` flag.
%% Per file:
%%   - id already in `sealed_packs` -> the seal had committed; the pages are
%%     in `pack-<id>`, so the frozen file is an orphan -> delete it.
%%   - otherwise -> re-seal it synchronously into `pack-<id>` and add the id
%%     to the manifest, so the rolled pages become durable in a sealed pack
%%     with no reliance on WAL replay. An unreadable frozen file is
%%     discarded (the WAL applier re-derives its pages).
%% If an uncommitted roll was recovered and `incoming.pack` is gone (the
%% roll renamed it away but its manifest commit never landed), the manifest
%% is flipped to `incoming_pack = absent` so the subsequent incoming open
%% sees a consistent state instead of `needs_recovery`.
reconcile_sealing(Dir, InstanceId, HashAlgo, Manifest0) ->
    InstanceHash = derive_instance_hash(InstanceId),
    Files = bondy_mst_pack_paths:list_incoming_sealing(Dir),
    case
        fold_recover_sealing(
            Dir, InstanceHash, HashAlgo, Manifest0, Files, false
        )
    of
        {ok, Manifest1, Recovered} ->
            maybe_clear_incoming_flag(Dir, Manifest1, Recovered);
        {error, _} = E ->
            E
    end.

%% @private
fold_recover_sealing(_Dir, _IH, _Algo, M, [], Recovered) ->
    {ok, M, Recovered};
fold_recover_sealing(Dir, IH, Algo, M, [{PackId, Path} | Rest], Recovered) ->
    case recover_one_sealing(Dir, IH, Algo, M, PackId, Path) of
        {ok, M1, Did} ->
            fold_recover_sealing(Dir, IH, Algo, M1, Rest, Recovered orelse Did);
        {error, _} = E ->
            E
    end.

%% @private
recover_one_sealing(Dir, IH, Algo, M, PackId, Path) ->
    case lists:member(PackId, bondy_mst_pack_manifest:sealed_packs(M)) of
        true ->
            %% Seal committed before the crash; pages are in pack-<id>.
            _ = prim_file:delete(Path),
            {ok, M, false};
        false ->
            reseal_recovered(Dir, IH, Algo, M, PackId, Path)
    end.

%% @private
reseal_recovered(Dir, IH, Algo, M, PackId, Path) ->
    case scan_sealing_file(Path, IH, Algo) of
        {ok, Bodies} when map_size(Bodies) > 0 ->
            Hashes = lists:sort(maps:keys(Bodies)),
            Reader = body_reader(Bodies),
            case
                bondy_mst_pack_seal:create_sealed_pack(
                    Dir, IH, Algo, PackId, Hashes, Reader
                )
            of
                ok ->
                    case persist_sealed_pack(Dir, M, PackId) of
                        {ok, M1} ->
                            _ = prim_file:delete(Path),
                            _ = bondy_mst_io:fsync_dir(Dir),
                            {ok, M1, true};
                        {error, R} ->
                            {error, {manifest, R}}
                    end;
                {error, R} ->
                    {error, {recover_seal, R}}
            end;
        {ok, _Empty} ->
            %% Header-only frozen file — nothing to seal; drop it.
            _ = prim_file:delete(Path),
            {ok, M, true};
        {error, _} ->
            %% Unreadable/corrupt frozen pack — discard; the WAL applier
            %% re-derives its pages on replay.
            _ = prim_file:delete(Path),
            {ok, M, true}
    end.

%% @private
%% Scan a frozen `incoming-sealing` file into a `Hash => Body` map, reusing
%% the same header + per-record CRC/hash validation as the live incoming
%% scan.
scan_sealing_file(Path, IH, Algo) ->
    case prim_file:open(Path, [read, raw, binary]) of
        {ok, Fd} ->
            try scan_incoming(Fd, IH, Algo) of
                {ok, _EndOffset, Pending} ->
                    {ok, bodies_from_pending(Pending)};
                {error, _} = E ->
                    E
            after
                _ = prim_file:close(Fd)
            end;
        {error, _} = E ->
            E
    end.

%% @private
maybe_clear_incoming_flag(Dir, M, true) ->
    case bondy_mst_pack_manifest:incoming_pack(M) of
        present ->
            Path = bondy_mst_pack_paths:incoming_pack_path(Dir),
            case filelib:is_regular(Path) of
                false ->
                    M1 = bondy_mst_pack_manifest:with_incoming_pack(M, absent),
                    case bondy_mst_pack_manifest:write(Dir, M1) of
                        ok -> {ok, M1};
                        {error, R} -> {error, {manifest, R}}
                    end;
                true ->
                    {ok, M}
            end;
        absent ->
            {ok, M}
    end;
maybe_clear_incoming_flag(_Dir, M, false) ->
    {ok, M}.

%% @private
ensure_dir(Dir) ->
    case filelib:ensure_path(Dir) of
        ok -> ok;
        {error, _} = E -> E
    end.

%% @private
load_or_create_manifest(Dir, InstanceId, HashAlgo) ->
    case bondy_mst_pack_manifest:read(Dir) of
        {ok, M} ->
            {ok, M};
        {error, enoent} ->
            M = bondy_mst_pack_manifest:new(InstanceId, HashAlgo),
            case bondy_mst_pack_manifest:write(Dir, M) of
                ok -> {ok, M};
                {error, _} = E -> E
            end;
        {error, _} = E ->
            %% Already classified as `{unreadable, Path, Reason}` by
            %% `bondy_mst_pack_manifest:read/1`. An unreadable manifest must
            %% NOT fall through to the `enoent` branch above and be replaced
            %% with a fresh one: the directory may still hold sealed packs
            %% that the replacement would orphan.
            E
    end.

%% @private
validate_manifest(M, InstanceId, HashAlgo) ->
    case bondy_mst_pack_manifest:instance_id(M) of
        InstanceId ->
            case bondy_mst_pack_manifest:hash_algo(M) of
                HashAlgo ->
                    ok;
                Other ->
                    {error, {hash_algo_mismatch, Other, HashAlgo}}
            end;
        Other ->
            {error, {instance_id_mismatch, Other, InstanceId}}
    end.

?DOC("""
Computes the `instance_hash` carried in the pack header from the
human-readable `InstanceId`. Centralised so the writer, the sealed-
view opener, and any future tooling that needs to recognise a foreign
pack all hash the same way.
""").
-spec derive_instance_hash(binary()) -> non_neg_integer().

derive_instance_hash(InstanceId) when is_binary(InstanceId) ->
    erlang:phash2(InstanceId, 1 bsl 32).

%% @private
open_incoming(Dir, InstanceId, HashAlgo, Manifest, Policy) ->
    InstanceHash = derive_instance_hash(InstanceId),
    Path = bondy_mst_pack_paths:incoming_pack_path(Dir),
    Declared = bondy_mst_pack_manifest:incoming_pack(Manifest),
    Exists = filelib:is_regular(Path),
    case {Declared, Exists} of
        {absent, false} ->
            %% Defer creating incoming.pack until the first append.
            %% Keeps `open/close` cycles idempotent: the on-disk state
            %% matches the manifest's declared state at all times.
            {ok,
                fresh_state(
                    Dir,
                    InstanceId,
                    HashAlgo,
                    InstanceHash,
                    Manifest,
                    Policy
                )};
        {present, true} ->
            resume_incoming(
                Dir,
                Path,
                InstanceId,
                HashAlgo,
                InstanceHash,
                Manifest,
                Policy
            );
        {absent, true} ->
            %% Orphan from a previous crash; recovery's job.
            {error, needs_recovery};
        {present, false} ->
            {error, needs_recovery}
    end.

%% @private
fresh_state(Dir, InstanceId, HashAlgo, InstanceHash, Manifest, Policy) ->
    Now = erlang:monotonic_time(millisecond),
    #?MODULE{
        dir = Dir,
        instance_id = InstanceId,
        hash_algo = HashAlgo,
        instance_hash = InstanceHash,
        manifest = Manifest,
        incoming_fd = undefined,
        incoming_offset = 0,
        pending = #{},
        next_pack_id = next_pack_id_from(Manifest),
        sync_every_records = maps:get(sync_every_records, Policy),
        sync_every_ms = maps:get(sync_every_ms, Policy),
        unsynced_count = 0,
        last_sync_ms = Now,
        root_flush_every_records = maps:get(root_flush_every_records, Policy),
        root_flush_every_ms = maps:get(root_flush_every_ms, Policy),
        root_unsynced_count = 0,
        last_root_flush_ms = Now,
        root_dirty = false
    }.

%% @private
%% Lazily creates incoming.pack on the writer's first append. Writes
%% the header, flips the manifest's incoming_pack flag to `present`,
%% and atomically swaps the manifest so the on-disk state matches the
%% in-memory state. A crash between creating the file and flipping the
%% manifest leaves an orphan that the recovery scanner removes.
ensure_incoming_open(#?MODULE{incoming_fd = Fd} = W) when Fd =/= undefined ->
    {ok, W};
ensure_incoming_open(#?MODULE{} = W) ->
    Path = bondy_mst_pack_paths:incoming_pack_path(W#?MODULE.dir),
    Header = bondy_mst_pack_codec:encode_pack_header(#{
        version => bondy_mst_pack_codec:version(),
        flags => 0,
        pack_id => 0,
        instance_hash => W#?MODULE.instance_hash,
        hash_algo => W#?MODULE.hash_algo,
        created_at => erlang:system_time(millisecond),
        record_count => 0
    }),
    case prim_file:open(Path, [read, write, raw, binary, exclusive]) of
        {ok, Fd} ->
            case prim_file:write(Fd, Header) of
                ok ->
                    case bondy_mst_io:datasync(Fd) of
                        ok ->
                            _ = bondy_mst_io:fsync_dir(W#?MODULE.dir),
                            flip_manifest_to_present(W, Fd, byte_size(Header));
                        {error, R} ->
                            _ = prim_file:close(Fd),
                            {error, {write, R}}
                    end;
                {error, R} ->
                    _ = prim_file:close(Fd),
                    {error, {write, R}}
            end;
        {error, R} ->
            {error, {write, R}}
    end.

%% @private
flip_manifest_to_present(W, Fd, HeaderSize) ->
    M = bondy_mst_pack_manifest:with_incoming_pack(W#?MODULE.manifest, present),
    case bondy_mst_pack_manifest:write(W#?MODULE.dir, M) of
        ok ->
            %% The header write was just datasync'd in ensure_incoming_open;
            %% rebase the T-timer so it counts from now rather than from
            %% `open/2` (which may have been many ms earlier and would
            %% spuriously trip a tight `sync_every_ms` on the first append).
            %% The manifest write above also covered any staged root.
            {ok,
                reset_root_flush_counters(W#?MODULE{
                    manifest = M,
                    incoming_fd = Fd,
                    incoming_offset = HeaderSize,
                    last_sync_ms = erlang:monotonic_time(millisecond)
                })};
        {error, R} ->
            _ = prim_file:close(Fd),
            _ = prim_file:delete(
                bondy_mst_pack_paths:incoming_pack_path(
                    W#?MODULE.dir
                )
            ),
            {error, {manifest, R}}
    end.

%% @private
resume_incoming(
    Dir,
    Path,
    InstanceId,
    HashAlgo,
    InstanceHash,
    Manifest,
    Policy
) ->
    case prim_file:open(Path, [read, write, raw, binary]) of
        {ok, Fd} ->
            case scan_incoming(Fd, InstanceHash, HashAlgo) of
                {ok, EndOffset, Pending} ->
                    %% `scan_incoming` uses `pread` exclusively, which
                    %% does not move the fd's file pointer — so without
                    %% an explicit seek, the next `prim_file:write` in
                    %% `do_append` would write at offset 0 (where the
                    %% header lives) instead of at `EndOffset`,
                    %% clobbering the header. Plant the pointer at
                    %% EndOffset so subsequent writes append correctly.
                    case prim_file:position(Fd, EndOffset) of
                        {ok, EndOffset} -> ok;
                        {error, R} -> error({resume_seek, R})
                    end,
                    Now = erlang:monotonic_time(millisecond),
                    {ok, #?MODULE{
                        dir = Dir,
                        instance_id = InstanceId,
                        hash_algo = HashAlgo,
                        instance_hash = InstanceHash,
                        manifest = Manifest,
                        incoming_fd = Fd,
                        incoming_offset = EndOffset,
                        pending = Pending,
                        next_pack_id = next_pack_id_from(Manifest),
                        sync_every_records =
                            maps:get(sync_every_records, Policy),
                        sync_every_ms =
                            maps:get(sync_every_ms, Policy),
                        unsynced_count = 0,
                        last_sync_ms = Now,
                        root_flush_every_records =
                            maps:get(root_flush_every_records, Policy),
                        root_flush_every_ms =
                            maps:get(root_flush_every_ms, Policy),
                        root_unsynced_count = 0,
                        last_root_flush_ms = Now,
                        root_dirty = false
                    }};
                {error, R} ->
                    _ = prim_file:close(Fd),
                    {error, R}
            end;
        {error, R} ->
            {error, {incoming, R}}
    end.

%% @private
%% Scan an existing incoming.pack — parse header, walk records until EOF
%% or a decode error. Any decode error short of EOF aborts with
%% `needs_recovery`; the recovery phase will truncate.
scan_incoming(Fd, ExpectedInstanceHash, ExpectedAlgo) ->
    HeaderBytes = bondy_mst_pack_codec:header_bytes(),
    case prim_file:pread(Fd, 0, HeaderBytes) of
        {ok, HBin} when byte_size(HBin) =:= HeaderBytes ->
            case bondy_mst_pack_codec:decode_pack_header(HBin) of
                {ok, #{instance_hash := IH, hash_algo := A}} when
                    IH =:= ExpectedInstanceHash, A =:= ExpectedAlgo
                ->
                    scan_records(Fd, HeaderBytes, #{});
                {ok, _} ->
                    %% Header decoded cleanly but the instance or hash
                    %% algo do not match — this is not our incoming
                    %% pack. Recovery would erase it; refuse to open.
                    {error, {pending_scan, header_mismatch}};
                {error, _} ->
                    %% Magic or version corrupt. The file is from us
                    %% (manifest declares it present) but the bytes are
                    %% unreadable. Route through the recovery path so
                    %% it can reset the file + manifest.
                    {error, needs_recovery}
            end;
        {ok, _Short} ->
            {error, needs_recovery};
        eof ->
            {error, needs_recovery};
        {error, R} ->
            {error, {incoming, R}}
    end.

%% @private
scan_records(Fd, Offset, Pending) ->
    HdrBytes = bondy_mst_pack_codec:record_header_bytes(),
    case prim_file:pread(Fd, Offset, HdrBytes) of
        eof ->
            {ok, Offset, Pending};
        {ok, <<>>} ->
            {ok, Offset, Pending};
        {ok, Bin} when byte_size(Bin) < HdrBytes ->
            {error, needs_recovery};
        {ok, Bin} ->
            case bondy_mst_pack_codec:decode_record_header(Bin) of
                {ok, #{hash := H, page_len := L} = Header} ->
                    BodyOffset = Offset + HdrBytes,
                    case verify_scanned_body(Fd, BodyOffset, L, Header, H) of
                        {ok, Body} ->
                            scan_records(
                                Fd,
                                BodyOffset + L,
                                Pending#{H => {Offset, L, Body}}
                            );
                        {error, _} = E ->
                            E
                    end;
                {error, _} ->
                    {error, needs_recovery}
            end;
        {error, R} ->
            {error, {incoming, R}}
    end.

%% @private
%% Reading a record body during resume verifies both the per-record CRC
%% AND that the record's stored hash matches sha256(body). The two
%% checks together catch the case where a record was fully written but
%% an on-disk bit-flip silently corrupted the body — the seal path
%% would otherwise re-encode the corrupted body under the original
%% hash, producing a content-address-violating sealed pack.
%%
%% Treats any failure as `needs_recovery`; the dedicated recovery path
%% will decide whether to truncate or rebuild.
verify_scanned_body(_Fd, _BodyOffset, 0, Header, Hash) ->
    %% Zero-length body — pread returns `eof`, so verify against <<>>.
    case bondy_mst_pack_codec:verify_record(Header, <<>>) of
        ok ->
            case crypto:hash(sha256, <<>>) of
                Hash -> {ok, <<>>};
                _ -> {error, needs_recovery}
            end;
        {error, _} ->
            {error, needs_recovery}
    end;
verify_scanned_body(Fd, BodyOffset, L, Header, Hash) ->
    case prim_file:pread(Fd, BodyOffset, L) of
        {ok, Body} when byte_size(Body) =:= L ->
            case bondy_mst_pack_codec:verify_record(Header, Body) of
                ok ->
                    case crypto:hash(sha256, Body) of
                        Hash -> {ok, Body};
                        _ -> {error, needs_recovery}
                    end;
                {error, _} ->
                    {error, needs_recovery}
            end;
        _ ->
            {error, needs_recovery}
    end.

%% @private
next_pack_id_from(Manifest) ->
    Highest =
        case bondy_mst_pack_manifest:sealed_packs(Manifest) of
            [] -> bondy_mst_pack_manifest:deleted_through(Manifest);
            L -> lists:max(L)
        end,
    Highest + 1.

%% @private
%% Orphan sealed-pack scanner (design doc §10.1, step 2).
%%
%% A crash between the sealed `.pack`/`.idx` rename-into-place (seal
%% step 3) and the manifest swap (seal step 4) leaves on-disk files
%% the manifest does not reference. The same shape arises post-GC
%% when retired packs are deleted: a crash between the manifest swap
%% and the unlink leaves the now-retired files behind.
%%
%% On every open we enumerate `pack-NNNN.{pack,idx}` and any
%% `*.tmp` siblings, then delete:
%%
%%   - `pack-NNNN.pack` / `pack-NNNN.idx` whose `NNNN` is not in
%%     the manifest's `sealed_packs` — they are orphans from one of
%%     the crash windows above.
%%   - any `*.tmp` rename artefacts — these only exist mid-seal, are
%%     never the source of truth once a crash interrupts the rename,
%%     and would otherwise accumulate.
%%
%% Cleanup is best-effort: individual deletion failures are logged
%% and skipped; the open continues. Only a `list_dir` failure
%% aborts the open (`{error, {orphan_cleanup, R}}`), because we
%% cannot safely proceed without knowing what is on disk.
cleanup_orphan_packs(Dir, Manifest) ->
    case prim_file:list_dir(Dir) of
        {ok, Names} ->
            Sealed = sets:from_list(
                bondy_mst_pack_manifest:sealed_packs(Manifest),
                [{version, 2}]
            ),
            lists:foreach(
                fun(Name) -> maybe_delete_orphan(Dir, Name, Sealed) end,
                Names
            ),
            ok;
        {error, R} ->
            {error, R}
    end.

%% @private
maybe_delete_orphan(Dir, Name, Sealed) ->
    case parse_pack_basename(Name) of
        {pack, Id} ->
            maybe_delete_sealed_orphan(Dir, Name, Id, Sealed, "pack");
        {idx, Id} ->
            maybe_delete_sealed_orphan(Dir, Name, Id, Sealed, "idx");
        {pack_tmp, _Id} ->
            force_delete_orphan(Dir, Name, "pack.tmp");
        {idx_tmp, _Id} ->
            force_delete_orphan(Dir, Name, "idx.tmp");
        not_pack ->
            ok
    end.

%% @private
maybe_delete_sealed_orphan(Dir, Name, Id, Sealed, Kind) ->
    case sets:is_element(Id, Sealed) of
        true ->
            ok;
        false ->
            force_delete_orphan(Dir, Name, Kind)
    end.

%% @private
force_delete_orphan(Dir, Name, Kind) ->
    Path = filename:join(Dir, Name),
    case prim_file:delete(Path) of
        ok ->
            ?LOG_NOTICE(#{
                event => mst_pack_store_orphan_deleted,
                kind => Kind,
                path => Path
            }),
            ok;
        {error, enoent} ->
            ok;
        {error, R} ->
            ?LOG_WARNING(#{
                event => mst_pack_store_orphan_delete_failed,
                kind => Kind,
                path => Path,
                reason => R
            }),
            ok
    end.

%% @private
%% Parse a directory entry into its pack-store classification.
%% Anything not matching `pack-<digits>.(pack|idx)(.tmp)?` is left
%% alone (manifest files, root file, future filenames, etc).
parse_pack_basename("pack-" ++ Rest) ->
    case split_digits(Rest) of
        {[], _} ->
            not_pack;
        {Digits, ".pack"} ->
            {pack, list_to_integer(Digits)};
        {Digits, ".idx"} ->
            {idx, list_to_integer(Digits)};
        {Digits, ".pack.tmp"} ->
            {pack_tmp, list_to_integer(Digits)};
        {Digits, ".idx.tmp"} ->
            {idx_tmp, list_to_integer(Digits)};
        _ ->
            not_pack
    end;
parse_pack_basename(_) ->
    not_pack.

%% @private
split_digits(S) ->
    lists:splitwith(fun(C) -> C >= $0 andalso C =< $9 end, S).

%% =============================================================================
%% PRIVATE — append
%% =============================================================================

%% @private
%% Append is split into (a) write the record, (b) optionally datasync per
%% the writer's batching policy. The write itself goes into the OS page
%% cache and is immediately visible to subsequent preads on the same fd;
%% durability against a kernel/power crash requires the datasync.
do_append(#?MODULE{incoming_fd = Fd, incoming_offset = Off} = W, Hash, Page) ->
    Record = bondy_mst_pack_codec:encode_record(Hash, Page),
    case prim_file:write(Fd, Record) of
        ok ->
            HdrBytes = bondy_mst_pack_codec:record_header_bytes(),
            NewOff = Off + HdrBytes + byte_size(Page),
            Pending = (W#?MODULE.pending)#{
                Hash => {Off, byte_size(Page), Page}
            },
            W1 = W#?MODULE{
                incoming_offset = NewOff,
                pending = Pending,
                unsynced_count = W#?MODULE.unsynced_count + 1
            },
            case maybe_sync_after_append(W1) of
                {ok, W2} -> {ok, Hash, W2};
                {error, _} = E -> E
            end;
        {error, R} ->
            {error, {write, R}}
    end.

%% @private
maybe_sync_after_append(
    #?MODULE{
        unsynced_count = N,
        sync_every_records = K
    } = W
) when N >= K ->
    do_sync(W);
maybe_sync_after_append(#?MODULE{sync_every_ms = infinity} = W) ->
    {ok, W};
maybe_sync_after_append(
    #?MODULE{
        last_sync_ms = Last,
        sync_every_ms = T
    } = W
) ->
    Now = erlang:monotonic_time(millisecond),
    case Now - Last >= T of
        true -> do_sync(W);
        false -> {ok, W}
    end.

%% @private
do_sync(#?MODULE{incoming_fd = Fd} = W) ->
    case bondy_mst_io:datasync(Fd) of
        ok ->
            {ok, W#?MODULE{
                unsynced_count = 0,
                last_sync_ms = erlang:monotonic_time(millisecond)
            }};
        {error, R} ->
            {error, {sync, R}}
    end.

%% =============================================================================
%% PRIVATE — root flush debounce
%% =============================================================================

%% @private
%% Decide whether the staged in-memory `current_root` needs to be
%% rewritten to the on-disk manifest now. Mirrors
%% `maybe_sync_after_append/1`: count-based threshold wins, then
%% wall-clock threshold (opportunistically — only checked on
%% `set_root/2` calls). Both `infinity` means "never flush via
%% set_root" — the next seal / explicit `flush/1` / `close/1`
%% carries it.
root_flush_due(#?MODULE{root_dirty = false}) ->
    false;
root_flush_due(#?MODULE{
    root_unsynced_count = N,
    root_flush_every_records = K
}) when
    is_integer(K), N >= K
->
    true;
root_flush_due(#?MODULE{root_flush_every_ms = infinity}) ->
    false;
root_flush_due(#?MODULE{
    last_root_flush_ms = Last,
    root_flush_every_ms = T
}) ->
    erlang:monotonic_time(millisecond) - Last >= T.

%% @private
%% Atomic manifest rewrite + counter reset. The writer's `manifest`
%% field already holds the staged root, so we just persist it.
%%
%% Pages-before-root: a content-addressed root is only crash-safe if every
%% page it references is already durable. `incoming.pack` is datasync'd on
%% the append path's own batching schedule (`sync_every_records` /
%% `sync_every_ms`), so a staged root reached via the `set_root/2` debounce
%% could otherwise be persisted AHEAD of the pages it points at. A crash in
%% that window loses the unsynced tail of `incoming.pack` (recovery
%% truncates the trailing records) while the manifest root survives,
%% leaving a root that references pages present on no replica — the AAE
%% `peer_returned_empty_pages` / dangling-page data-loss signature. So sync
%% incoming first, matching the ordering `flush/1` already enforces.
do_flush_root(#?MODULE{} = W0) ->
    case flush_incoming(W0) of
        {ok, #?MODULE{dir = Dir, manifest = M} = W} ->
            case bondy_mst_pack_manifest:write(Dir, M) of
                ok ->
                    {ok, reset_root_flush_counters(W)};
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

%% @private
%% Called whenever the manifest has just been written to disk
%% (set_root flush, seal, GC swap). Symmetric to `do_sync/1`'s
%% counter reset.
reset_root_flush_counters(#?MODULE{} = W) ->
    W#?MODULE{
        root_unsynced_count = 0,
        last_root_flush_ms = erlang:monotonic_time(millisecond),
        root_dirty = false
    }.

%% =============================================================================
%% PRIVATE — seal
%% =============================================================================

%% @private
do_seal(
    #?MODULE{
        dir = Dir,
        instance_hash = IH,
        hash_algo = HashAlgo,
        manifest = M,
        incoming_fd = Fd,
        pending = Pending,
        next_pack_id = PackId
    } = W
) ->
    Hashes = lists:sort(maps:keys(Pending)),
    Reader = pending_reader(Fd, Pending),
    case
        bondy_mst_pack_seal:create_sealed_pack(
            Dir, IH, HashAlgo, PackId, Hashes, Reader
        )
    of
        ok ->
            commit_seal(Dir, M, PackId, W);
        {error, R} ->
            {error, {seal, R}}
    end.

%% @private
%% A reader closure over the writer's incoming.pack fd + in-memory
%% pending map. The streaming sealed-pack writer calls this once per
%% hash in sorted order; we pread the body without materialising the
%% rest of the pending set.
pending_reader(Fd, Pending) ->
    fun(Hash) -> read_pending_body(Fd, Pending, Hash) end.

%% @private
%% Bodies are resident in the pending map so the seal stream can
%% return them directly without pread'ing back from `incoming.pack`.
%% Fd is kept in the signature for symmetry / future fallback.
read_pending_body(_Fd, Pending, Hash) ->
    case maps:find(Hash, Pending) of
        {ok, {_Offset, _Len, Body}} ->
            {ok, Body};
        error ->
            {error, {missing_pending, Hash}}
    end.

%% @private
%% Step 4 of seal: the sealed `pack-NNNN` pair is already renamed into
%% place by `bondy_mst_pack_seal:create_sealed_pack/6`; here we
%% delegate to the same module's `commit_manifest/3` for the atomic
%% swap (sealed_packs += [PackId], incoming_pack := absent), then
%% close + unlink the now-superseded incoming.pack.
commit_seal(Dir, M, PackId, W) ->
    case bondy_mst_pack_seal:commit_manifest(Dir, M, PackId) of
        {ok, M1} ->
            close_and_unlink_incoming(W#?MODULE.incoming_fd, Dir),
            reopen_fresh_incoming(W, M1, PackId);
        {error, _} = E ->
            E
    end.

%% @private
close_and_unlink_incoming(undefined, Dir) ->
    _ = prim_file:delete(bondy_mst_pack_paths:incoming_pack_path(Dir)),
    _ = bondy_mst_io:fsync_dir(Dir),
    ok;
close_and_unlink_incoming(Fd, Dir) ->
    _ = prim_file:close(Fd),
    _ = prim_file:delete(bondy_mst_pack_paths:incoming_pack_path(Dir)),
    _ = bondy_mst_io:fsync_dir(Dir),
    ok.

%% @private
%% After a successful seal the writer resets to a fresh state with no
%% open incoming fd; the next append will lazily create incoming.pack
%% and flip the manifest. This keeps the on-disk state consistent with
%% the manifest at every observable point.
reopen_fresh_incoming(W, M1, PackId) ->
    Fresh = fresh_state(
        W#?MODULE.dir,
        W#?MODULE.instance_id,
        W#?MODULE.hash_algo,
        W#?MODULE.instance_hash,
        M1,
        #{
            sync_every_records => W#?MODULE.sync_every_records,
            sync_every_ms => W#?MODULE.sync_every_ms,
            root_flush_every_records => W#?MODULE.root_flush_every_records,
            root_flush_every_ms => W#?MODULE.root_flush_every_ms
        }
    ),
    {ok, PackId, Fresh#?MODULE{next_pack_id = PackId + 1}}.

%% @private
%% The roll of `roll_incoming/1`, run after the pending records are
%% datasync'd. Closes + renames the frozen incoming pack, commits the roll
%% via the manifest, and resets the writer to a fresh incoming state holding
%% the rolled snapshot in `sealing`.
do_roll_incoming(
    #?MODULE{
        dir = Dir,
        instance_hash = IH,
        hash_algo = HashAlgo,
        incoming_fd = Fd,
        pending = Pending,
        next_pack_id = PackId,
        manifest = M
    } = W
) ->
    ok = close_incoming_fd(Fd),
    IncomingPath = bondy_mst_pack_paths:incoming_pack_path(Dir),
    SealingPath = bondy_mst_pack_paths:incoming_sealing_path(Dir, PackId),
    case bondy_mst_io:rename(IncomingPath, SealingPath) of
        ok ->
            _ = bondy_mst_io:fsync_dir(Dir),
            %% Commit point of the roll: incoming_pack := absent. The frozen
            %% sealing file is now the recovery source until the seal
            %% commits. The in-memory manifest already carries any staged
            %% root, and every page it references is durable (datasync'd
            %% then renamed above), so persisting it here is pages-before-
            %% root safe.
            M1 = bondy_mst_pack_manifest:with_incoming_pack(M, absent),
            case bondy_mst_pack_manifest:write(Dir, M1) of
                ok ->
                    Bodies = bodies_from_pending(Pending),
                    Job = #{
                        dir => Dir,
                        instance_hash => IH,
                        hash_algo => HashAlgo,
                        pack_id => PackId,
                        bodies => Bodies
                    },
                    W1 = reset_root_flush_counters(W#?MODULE{
                        manifest = M1,
                        incoming_fd = undefined,
                        incoming_offset = 0,
                        pending = #{},
                        sealing = {SealingPath, Bodies, PackId},
                        next_pack_id = PackId + 1,
                        unsynced_count = 0,
                        last_sync_ms = erlang:monotonic_time(millisecond)
                    }),
                    {ok, Job, W1};
                {error, R} ->
                    {error, {manifest, R}}
            end;
        {error, R} ->
            {error, {rename_sealing, R}}
    end.

%% @private
%% Adds `PackId` to the manifest's `sealed_packs` and persists it WITHOUT
%% touching the `incoming_pack` flag (a fresh incoming pack may already be
%% live). Shared by `complete_seal/2` and the recovery re-seal path.
persist_sealed_pack(Dir, M, PackId) ->
    M1 = bondy_mst_pack_manifest:add_sealed_pack(M, PackId),
    case bondy_mst_pack_manifest:write(Dir, M1) of
        ok -> {ok, M1};
        {error, R} -> {error, R}
    end.

%% @private
%% Projects the writer's `pending` map (`Hash => {Offset, Len, Body}`) to
%% the `Hash => Body` snapshot a seal job carries.
bodies_from_pending(Pending) ->
    maps:map(fun(_Hash, {_Off, _Len, Body}) -> Body end, Pending).

%% @private
%% A `bondy_mst_pack_seal:reader/0` closure over an in-memory body snapshot.
body_reader(Bodies) ->
    fun(Hash) ->
        case maps:find(Hash, Bodies) of
            {ok, Body} -> {ok, Body};
            error -> {error, {missing_pending, Hash}}
        end
    end.

%% @private
close_incoming_fd(undefined) ->
    ok;
close_incoming_fd(Fd) ->
    _ = prim_file:close(Fd),
    ok.

%% =============================================================================
%% PRIVATE — misc
%% =============================================================================

%% @private
compute_hash(sha256, Page) -> crypto:hash(sha256, Page).
