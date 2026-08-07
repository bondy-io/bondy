%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_pack_store).

-compile({no_auto_import, [put/2, get/2]}).

-behaviour(bondy_mst_store).

-include_lib("kernel/include/logger.hrl").
-include("bondy_mst.hrl").
-include("bondy_mst_pack.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Persistent `bondy_mst_store` backend backed by an append-only
content-addressed pack-file format (see `bondy_mst_pack_writer` /
`bondy_mst_pack_reader` and the pack-store design notes).

## State model

A pack-store instance owns a directory containing:

- `manifest` — authoritative view of live sealed packs and current
  root (`bondy_mst_pack_manifest`).
- `incoming.pack` — append-only log of recent puts (created lazily
  on first put after open / seal).
- `pack-NNNN.pack` + `pack-NNNN.idx` — sealed immutable packs.

The store state record carries:

- a `bondy_mst_pack_writer` owning `incoming.pack` and the in-memory
  pending hash → offset map,
- a list of `sealed_view` records (one per sealed pack), each holding
  a parsed `.idx` and an open read fd,
- a `free_set` of hashes tombstoned via `free/3` or `delete/2`, kept
  for the next compaction (the actual deletion is performed by
  `gc/2`).

Pages are serialised as `term_to_binary({Level, Low, List},
[deterministic, {minor_version, 2}])` — the same form
`bondy_mst_page:hash/2` hashes over — so `sha256(stored_bytes)`
matches the canonical page hash with no double work.

## Concurrency

The state record is opaque to outside processes: the writer's raw
fd is owned by the calling process and cannot be shared. Callers
must serialise mutations through a single owner process (typically
a gen_server above this module). Read concurrency is also single-
owner for the same reason.

## Error handling

Diverges intentionally from the in-memory `bondy_mst_map_store` /
`bondy_mst_ets_store` siblings: those operate on data structures
that cannot fail at I/O, so they never raise. This backend wraps
real disk and treats unrecoverable I/O failures (manifest write
refused, sealed pack read error, file system gone) as raised
errors of the form `error({Op, Reason})` — e.g. `{set_root, _}`,
`{put, _}`, `{get, _}`, `{gc_open_view, _, _}`. Recoverable
conditions (missing hash, no-op seal, GC epoch unsupported)
return ordinary tagged results.

The `{gc_open_view, _, _}` failure mode is special: it can only
occur *after* the manifest swap has been durably committed, so the
on-disk state already reflects the compaction. We retry the view
open once before raising (most failures here — EMFILE, EAGAIN,
transient EIO — are recoverable, and the just-fsync'd idx is hot
in the OS page cache). On persistent failure we still raise so
the calling process restarts and recovers from the manifest
on next open.

The reasoning matches the codebase's WAL modules: a backend that
cannot persist what the caller asked it to has no honest
return value, and forcing every caller to thread an extra
`{error, _}` branch on top of `bondy_mst_store`'s callback
signatures defeats the abstraction. The owning gen_server is
expected to catch and surface these via its own restart/log path.

## Auto-seal

Two open-time options bound the size of `incoming.pack` between
explicit `seal/1` calls:

- `auto_seal_records` — seal after this many pending records.
  Default: `10_000` (`?BONDY_MST_PACK_DEFAULT_AUTO_SEAL_RECORDS`).
- `auto_seal_bytes`   — seal once `incoming.pack` reaches this byte
  size (including header). Default: `16_000_000`
  (`?BONDY_MST_PACK_DEFAULT_AUTO_SEAL_BYTES`).

Whichever threshold fires first triggers the seal. Either can be
set to `infinity` to disable; both `infinity` reverts to fully
caller-driven seal (the prior default). When a threshold is
crossed during a `put/2`, the store rolls over before returning.
Auto-seal failures are logged at WARNING and do not fail the put;
the page has already been durably appended to `incoming.pack` and
the next put will re-evaluate the thresholds. Bounding incoming
pack size keeps the linear `scan_incoming/3` cost on reopen
proportional to the threshold rather than to the lifetime put
volume.
""").

-record(?MODULE, {
    writer :: bondy_mst_pack_writer:t(),
    %% Invariant: stored in DESCENDING `pack_id` order (newest first).
    %% The read paths (`do_get/2`, `do_has/2`) iterate this list and
    %% short-circuit on the first hit, so newer pages — the most-
    %% recently-written and typically the most-recently-accessed — are
    %% probed first. Every mutation that grows the list (`seal/1`,
    %% `finalise_compaction/6`) funnels through `newest_first/1` to
    %% preserve the invariant. Callers that need ascending order
    %% (`apply_compaction/3` reporting) sort at the use-site rather
    %% than reshuffling the canonical field.
    sealed_views :: [#sealed_view{}],
    free_set :: sets:set(binary()),
    hashing_algorithm :: atom(),
    opts :: map(),
    %% Auto-seal thresholds. After every successful `put/2` the store
    %% checks pending record count and `incoming.pack` byte size; if
    %% either threshold is crossed it rolls over via `seal/1`. Defaults
    %% bound the resume-scan cost on reopen (see `bondy_mst_pack.hrl`);
    %% set either to `infinity` to disable. The check is opportunistic
    %% — a seal failure during auto-seal is logged but does not fail
    %% the put, since the page is already durable in incoming.pack
    %% and the next put will re-evaluate.
    auto_seal_records :: pos_integer() | infinity,
    auto_seal_bytes :: pos_integer() | infinity,
    %% Seal driver. `sync` (default) keeps the historical behaviour: each
    %% `put/2` checks the thresholds and, when crossed, seals inline on the
    %% caller's process. `async` hands sealing to the store's owner (the
    %% `bondy_oplog` instance): `put/2` never seals, and the owner drives
    %% `maybe_roll_for_seal/1` + a worker running `run_seal_job/1` +
    %% `complete_seal/2`, keeping the multi-hundred-ms rewrite off the
    %% critical path. The thresholds mean the same thing in both modes.
    seal_mode = sync :: sync | async,
    %% Tombstones-flush debounce. The `tombstones` file uses the same
    %% tmp+datasync+rename+fsync_dir pattern as the manifest (4 fsyncs
    %% per write). `bondy_mst:put/3` issues one `free/3` per spine
    %% modification — typically ~5 per put on a populated tree — so a
    %% naive per-call write costs ~20 fsyncs per MST put. We keep the
    %% in-memory `free_set` current and persist on the same shape as
    %% the set_root debounce: when `tombstones_unsynced_count` reaches
    %% the records threshold, or the wall-clock floor has elapsed, the
    %% next mutation flushes. Seal / auto-seal / GC / close / explicit
    %% `flush/1` force a flush so the on-disk tombstones never lag the
    %% in-memory set for long.
    tombstones_flush_every_records :: pos_integer() | infinity,
    tombstones_flush_every_ms :: pos_integer() | infinity,
    tombstones_unsynced_count = 0 :: non_neg_integer(),
    last_tombstones_flush_ms :: integer(),
    tombstones_dirty = false :: boolean(),
    %% GC dead-fraction gate. The original policy was "rewrite on any
    %% drop", which is correct but not granular — for very large stores
    %% with sparse churn it rewrites the world on every GC. Setting
    %% this to e.g. 0.5 lets operators accept up to that fraction of
    %% dead pages in a single sealed pack before paying for a full
    %% rewrite. Multi-pack coalescing is unaffected: when there are
    %% 2+ sealed packs, GC always merges them into one (the threshold
    %% only gates the dead-fraction case). Default `0.0` preserves the
    %% pre-PR-PS-6 behaviour. See QA #9 / design §8.1.
    gc_threshold_dead_fraction :: float()
}).

-type t() :: #?MODULE{}.
-type page() :: bondy_mst_page:t().
-type opts() :: opts_map() | [{atom(), term()}].
-type opts_map() :: #{
    dir := file:filename_all(),
    instance_id := binary(),
    atom() => term()
}.

-export_type([t/0]).
-export_type([page/0]).
-export_type([opts/0]).

%% bondy_mst_store callbacks
-export([open/2]).
-export([close/1]).
-export([flush/1]).
-export([capabilities/1]).
-export([copy/3]).
-export([destroy/1]).
-export([delete/2]).
-export([free/3]).
-export([gc/2]).
-export([get/2]).
-export([get_root/1]).
-export([has/2]).
-export([is_present/2]).
-export([page_state/2]).
-export([is_tombstoned/2]).
-export([list/1]).
-export([missing_set/2]).
-export([page_refs/1]).
-export([put/2]).
-export([set_root/2]).

%% Pack-store-specific extensions
-export([seal/1]).
-export([dir/1]).
-export([instance_id/1]).
-export([sealed_pack_ids/1]).
-export([info/1]).

%% Asynchronous seal extensions
-export([maybe_roll_for_seal/1]).
-export([run_seal_job/1]).
-export([seal_job_pack_id/1]).
-export([complete_seal/2]).
-export([seal_in_flight/1]).

-ifdef(TEST).
%% The page codec is the durability contract with the on-disk format; the
%% atom-table hazard it has to survive cannot be reached through the public
%% API (constructing a page with an atom this VM does not know is impossible
%% from inside this VM).
-export([serialise/1]).
-export([deserialise/1]).
-endif.

%% =============================================================================
%% bondy_mst_store CALLBACKS
%% =============================================================================

-spec open(Algo :: atom(), Opts :: opts()) -> t() | no_return().

open(Algo, Opts) when is_atom(Algo), is_list(Opts) ->
    open(Algo, maps:from_list(Opts));
open(sha256, Opts) when is_map(Opts) ->
    Dir = required(dir, Opts),
    InstanceId = required(instance_id, Opts),
    ok = ensure_dir(Dir),
    WriterOpts0 = #{instance_id => InstanceId, hash_algo => sha256},
    WriterOpts1 = forward_opt(sync_every_records, Opts, WriterOpts0),
    WriterOpts2 = forward_opt(sync_every_ms, Opts, WriterOpts1),
    WriterOpts3 = forward_opt(root_flush_every_records, Opts, WriterOpts2),
    WriterOpts = forward_opt(root_flush_every_ms, Opts, WriterOpts3),
    Cfg = #{
        opts => Opts,
        auto_seal_records =>
            validated_auto_seal(auto_seal_records, Opts),
        auto_seal_bytes =>
            validated_auto_seal(auto_seal_bytes, Opts),
        seal_mode => validated_seal_mode(Opts),
        tombstones_flush_every_records =>
            validated_tombstones_flush(tombstones_flush_every_records, Opts),
        tombstones_flush_every_ms =>
            validated_tombstones_flush(tombstones_flush_every_ms, Opts),
        gc_threshold_dead_fraction =>
            validated_gc_threshold(gc_threshold_dead_fraction, Opts),
        now => erlang:monotonic_time(millisecond)
    },
    open_writer(Dir, InstanceId, WriterOpts, Cfg);
open(Algo, _Opts) ->
    error({unsupported_hash_algorithm, Algo}).

%% @private
%% Attempts to open the writer; on `{error, needs_recovery}` runs the
%% recovery pass once and retries. Any other error path raises
%% `{pack_store_open, _}` directly. Telemetry for the recovery event
%% (design §13) is emitted from here so it carries the caller's
%% instance_id even when the writer was unable to materialise one.
open_writer(Dir, InstanceId, WriterOpts, Cfg) ->
    case bondy_mst_pack_writer:open(Dir, WriterOpts) of
        {ok, W} ->
            build_state(W, Dir, Cfg);
        {error, needs_recovery} ->
            recover_and_retry(Dir, InstanceId, WriterOpts, Cfg);
        {error, R} ->
            error({pack_store_open, R})
    end.

%% @private
recover_and_retry(Dir, InstanceId, WriterOpts, Cfg) ->
    StartTs = erlang:monotonic_time(microsecond),
    case bondy_mst_pack_recovery:recover(Dir, InstanceId, sha256) of
        {ok, Outcome} ->
            DurationUs = erlang:monotonic_time(microsecond) - StartTs,
            emit_recovery_ok(InstanceId, Outcome, DurationUs),
            case bondy_mst_pack_writer:open(Dir, WriterOpts) of
                {ok, W} ->
                    build_state(W, Dir, Cfg);
                {error, R} ->
                    error({pack_store_open, {recovery_retry_failed, R}})
            end;
        {error, R} ->
            DurationUs = erlang:monotonic_time(microsecond) - StartTs,
            emit_recovery_failed(InstanceId, R, DurationUs),
            error({pack_store_open, {recovery_failed, R}})
    end.

%% @private
build_state(W, Dir, Cfg) ->
    Manifest = bondy_mst_pack_writer:manifest(W),
    SealedIds = bondy_mst_pack_manifest:sealed_packs(Manifest),
    SealedCtx = bondy_mst_pack_sealed_view:open_ctx_from_writer(W),
    case open_sealed_views(Dir, SealedCtx, SealedIds) of
        {ok, Views} ->
            #?MODULE{
                writer = W,
                sealed_views = newest_first(Views),
                free_set = load_tombstones(Dir),
                hashing_algorithm = sha256,
                opts = maps:get(opts, Cfg),
                auto_seal_records = maps:get(auto_seal_records, Cfg),
                auto_seal_bytes = maps:get(auto_seal_bytes, Cfg),
                seal_mode = maps:get(seal_mode, Cfg),
                tombstones_flush_every_records =
                    maps:get(tombstones_flush_every_records, Cfg),
                tombstones_flush_every_ms =
                    maps:get(tombstones_flush_every_ms, Cfg),
                tombstones_unsynced_count = 0,
                last_tombstones_flush_ms = maps:get(now, Cfg),
                tombstones_dirty = false,
                gc_threshold_dead_fraction =
                    maps:get(gc_threshold_dead_fraction, Cfg)
            };
        {error, R} ->
            _ = bondy_mst_pack_writer:close(W),
            error({pack_store_open, R})
    end.

-spec close(t()) -> ok.

close(#?MODULE{} = T) ->
    %% Force a final tombstones flush so clean shutdown is lossless;
    %% errors are swallowed because there is no caller to return them
    %% to and the next reopen rebuilds the in-memory free_set from
    %% disk anyway.
    _ = do_flush_tombstones(T),
    lists:foreach(
        fun(#sealed_view{pack_fd = Fd}) -> _ = prim_file:close(Fd) end,
        T#?MODULE.sealed_views
    ),
    bondy_mst_pack_writer:close(T#?MODULE.writer),
    ok.

-spec flush(t()) -> {ok, t()} | {error, term()}.

flush(#?MODULE{writer = W} = T) ->
    %% Durability barrier: datasync the incoming pack (pages durable) then
    %% rewrite the manifest with the staged root (pages-before-root, so the
    %% persisted root never references a non-durable page). Idempotent — a
    %% no-op when nothing is staged. The writer's own buffers (tombstones,
    %% free_set) are rebuilt on reopen and are not part of resume, so they
    %% are intentionally left to their own debounce.
    case bondy_mst_pack_writer:flush(W) of
        {ok, W1} ->
            {ok, T#?MODULE{writer = W1}};
        {error, _} = Error ->
            Error
    end.

-spec capabilities(t()) -> map().

capabilities(#?MODULE{}) ->
    #{
        transactions => false,
        read_concurrency => false,
        concurrent_writes => false,
        %% The pack store can seal off the caller's critical path via
        %% `maybe_roll_for_seal/1` + `run_seal_job/1` + `complete_seal/2`.
        %% A consumer reads this capability (via `bondy_mst:capabilities/1`)
        %% to decide whether to drive the asynchronous seal; memory backends
        %% advertise `false` and the seal surface is a no-op for them.
        async_seal => true,
        %% Durable: the pack tree survives an instance/node restart, so a WAL
        %% consumer resumes from its committed offset rather than replaying.
        durable => true,
        %% Sealed packs are read through raw file descriptors bound to the
        %% process that opened them (see the moduledoc). A consumer that may
        %% fold the tree from another process reads this capability to decide
        %% whether the fold must be delegated to the owner; folding elsewhere
        %% raises `not_on_controlling_process`. Memory backends advertise
        %% `false` — their pages are process-independent terms.
        process_bound_reads => true
    }.

-spec get_root(t()) -> binary() | undefined.

get_root(#?MODULE{writer = W}) ->
    bondy_mst_pack_writer:current_root(W).

-spec set_root(t(), binary() | undefined) -> t().

set_root(#?MODULE{writer = W} = T, Root) ->
    case bondy_mst_pack_writer:set_root(W, Root) of
        {ok, W1} ->
            T#?MODULE{writer = W1};
        {error, R} ->
            error({set_root, R})
    end.

-spec get(t(), binary()) -> page() | undefined.

get(#?MODULE{} = T, Hash) when is_binary(Hash) ->
    StartTs = erlang:monotonic_time(microsecond),
    %% Serve any physically-present page. The `free_set` is a GC / enumeration
    %% hint (see `list/1` and `gc/2`), NOT a read mask. Masking reads here was
    %% a second, conflicting source of truth about whether a page is live:
    %% `truncate`/`merge` churn can leave a page tombstoned while it is still
    %% reachable from a live (or a peer's) root, and since physical GC never
    %% runs in this deployment the bytes are still on disk — masking them made
    %% `get`/`missing_set`/`do_diff` report a dangling root for a page that is
    %% actually present (`peer_returned_empty_pages`, replay `function_clause`,
    %% and an endless re-pull). Reachability from the root is the single source
    %% of truth for liveness; the tombstone only gates physical reclamation and
    %% `list/1` enumeration.
    {Page, Source, ByteSize} = do_get(T, Hash),
    emit_get(
        T,
        ByteSize,
        erlang:monotonic_time(microsecond) - StartTs,
        Source
    ),
    Page.

-spec has(t(), binary()) -> boolean().

has(#?MODULE{} = T, Hash) when is_binary(Hash) ->
    %% Physical presence, not the `free_set` mask — see `get/2`.
    do_has(T, Hash).

-doc """
Diagnostic: is the page's content PHYSICALLY present (in pending or a
sealed pack), ignoring the `free_set` tombstone that `has/2` honours? Used
to classify a "missing" page (per `missing_set/2`) as either
tombstone-masked-but-present (data on disk) or genuinely absent (never
written) when diagnosing a dangling root.
""".
-spec is_present(t(), binary()) -> boolean().

is_present(#?MODULE{} = T, Hash) when is_binary(Hash) ->
    do_has(T, Hash).

-doc """
Diagnostic: is the hash currently tombstoned in the `free_set`?
""".
-spec is_tombstoned(t(), binary()) -> boolean().

is_tombstoned(#?MODULE{free_set = FreeSet}, Hash) when is_binary(Hash) ->
    sets:is_element(Hash, FreeSet).

-doc """
Which of the three states a "missing" page is actually in — the accessor that
lets `bondy_oplog_instance:diagnose_root/1` name the layer that lost a page on
a DURABLE shard rather than reporting `unknown`.

- `absent` — nothing on disk for this hash. Something deleted a page a live
  root references: a store-layer fault.
- `{tombstoned, undefined}` — the bytes ARE on disk but the `free_set` masks
  them from `get/2`, so a walk that called the page missing did not learn that
  from the disk: a consumer / read-path fault. The epoch slot is `undefined`
  because this backend tombstones by set membership and keeps no per-hash
  free time (contrast `bondy_mst_ets_store`, whose `FreedAt` column carries a
  monotonic timestamp).
- `live` — present and unmasked; the miss was transient.
""".
-spec page_state(t(), binary()) ->
    live | {tombstoned, undefined} | absent.

page_state(#?MODULE{} = T, Hash) when is_binary(Hash) ->
    case is_present(T, Hash) of
        false ->
            absent;
        true ->
            case is_tombstoned(T, Hash) of
                true -> {tombstoned, undefined};
                false -> live
            end
    end.

-spec put(t(), page()) -> {binary(), t()}.

put(#?MODULE{writer = W, hashing_algorithm = Algo} = T, Page) ->
    Bytes = serialise(Page),
    PendingBefore = bondy_mst_pack_writer:pending_count(W),
    StartTs = erlang:monotonic_time(microsecond),
    case bondy_mst_pack_writer:append(W, Bytes) of
        {ok, Hash, W1} ->
            %% The writer's content hash IS sha256(serialise(Page)), which
            %% equals bondy_mst_page:hash(Page, Algo) by construction (both
            %% term_to_binary the same `{Level, Low, List}` with identical
            %% opts, then sha256 it), so the on-disk store is content-
            %% addressed for free. Re-deriving it here would repeat one
            %% term_to_binary + one sha256 per page — the dominant CPU of the
            %% MST spine rebuild (mst_install). We assert the equivalence
            %% under TEST and skip the redundant work in release/bench.
            ok = assert_content_hash(Hash, Page, Algo),
            T1 = maybe_persist_free_set(
                T#?MODULE{writer = W1},
                sets:del_element(Hash, T#?MODULE.free_set),
                put
            ),
            T2 = maybe_auto_seal(T1),
            %% ContentHit: the writer dedups against its `pending` map.
            %% If pending_count didn't grow, the page was already in
            %% pending and no new bytes touched incoming.pack. (Pages
            %% already in a sealed pack are NOT a content hit here — the
            %% writer still appends them to incoming.pack.)
            ContentHit =
                bondy_mst_pack_writer:pending_count(W1) =:= PendingBefore,
            emit_put(
                T2,
                byte_size(Bytes),
                erlang:monotonic_time(microsecond) - StartTs,
                ContentHit
            ),
            {Hash, T2};
        {error, R} ->
            error({put, R})
    end.

-spec delete(t(), binary()) -> t().

delete(#?MODULE{} = T, Hash) when is_binary(Hash) ->
    maybe_persist_free_set(
        T,
        sets:add_element(Hash, T#?MODULE.free_set),
        delete
    ).

-spec copy(t(), bondy_mst_store:t(), binary()) -> t().

copy(#?MODULE{} = T, OtherStore, Hash) ->
    case bondy_mst_store:get(OtherStore, Hash) of
        undefined ->
            T;
        Page ->
            Refs = bondy_mst_store:page_refs(OtherStore, Page),
            T1 = lists:foldl(
                fun(Ref, Acc) -> copy(Acc, OtherStore, Ref) end,
                T,
                Refs
            ),
            {_Hash, T2} = put(T1, Page),
            T2
    end.

-spec list(t()) -> [page()].

list(#?MODULE{} = T) ->
    Hashes = enumerate_hashes(T),
    lists:filtermap(
        fun(H) ->
            case do_get(T, H) of
                {undefined, _, _} -> false;
                {Page, _, _} -> {true, Page}
            end
        end,
        Hashes
    ).

-spec free(t(), binary(), page()) -> t().

free(#?MODULE{} = T, Hash, _Page) when is_binary(Hash) ->
    maybe_persist_free_set(
        T,
        sets:add_element(Hash, T#?MODULE.free_set),
        free
    ).

?DOC("""
Pack-rewrite compaction. Given a list of `KeepRoots`, computes the
transitively reachable hash set, intersects it with the set of
non-tombstoned hashes, and rewrites every sealed pack into a single
new sealed pack containing only those entries.

* Integer `Epoch` is currently rejected with a no-op (pages carry no
  epoch on this backend); the metadata reports `reason =>
  epoch_unsupported`.
* If there are no sealed packs to compact, the call is a no-op.
* If no entries would be dropped and there is exactly one sealed
  pack, the call is a no-op (coalescing multiple packs into one is
  still performed even with zero drops, since reducing fd count and
  improving lookup locality is the other point of GC).
* If drops were found but the dead fraction
  (`dropped / (kept + dropped)`) is below the configured
  `gc_threshold_dead_fraction` option (default `0.0`, i.e. always
  rewrite), the call returns `compacted => false, reason =>
  below_threshold` with the actual `kept` / `dropped` counts. The
  threshold only gates single-pack rewrites — when there are 2+
  sealed packs the call always coalesces them.
* Pending pages (still in `incoming.pack`) are not touched; the next
  `seal/1` deposits them. Tombstones whose target is still pending
  are preserved in `free_set`; tombstones whose target was applied
  by compaction are cleared.

On any I/O failure mid-compaction the call logs, leaves the store
in its pre-call state, and reports `compacted => false` with the
error in metadata. The single non-recoverable case — failing to
open a sealed view *after* the manifest swap — raises; the next
reopen recovers via the on-disk manifest.
""").
-spec gc(t(), [binary()] | epoch()) -> {t(), map()}.

gc(#?MODULE{} = T, Epoch) when is_integer(Epoch) ->
    Meta = #{compacted => false, reason => epoch_unsupported},
    emit_gc(T, Meta, 0),
    {T, Meta};
gc(#?MODULE{sealed_views = []} = T, KeepRoots) when is_list(KeepRoots) ->
    Meta = gc_noop_meta(),
    emit_gc(T, Meta, 0),
    {T, Meta};
gc(#?MODULE{} = T, KeepRoots) when is_list(KeepRoots) ->
    OldBytes = sealed_views_bytes(T),
    Dir = bondy_mst_pack_writer:dir(T#?MODULE.writer),
    StartTs = erlang:monotonic_time(microsecond),
    {T1, Meta0} = do_gc(T, KeepRoots),
    DurationUs = erlang:monotonic_time(microsecond) - StartTs,
    %% bytes_freed = old sealed total - new sealed total. Computed
    %% post-call by stat'ing the new pack (if any) and subtracting
    %% from the pre-call sum. The new pack's bytes are still on disk
    %% at this point (finalise_compaction has fsync'd everything).
    NewBytes =
        case maps:get(new_pack, Meta0, undefined) of
            undefined ->
                0;
            PackId ->
                try
                    filelib:file_size(
                        bondy_mst_pack_paths:sealed_pack_path(Dir, PackId)
                    )
                catch
                    _:_ -> 0
                end
        end,
    BytesFreed = max(OldBytes - NewBytes, 0),
    Meta = Meta0#{bytes_freed => BytesFreed},
    emit_gc(T1, Meta, DurationUs),
    {T1, Meta}.

-spec missing_set(t(), binary()) -> sets:set(binary()).

missing_set(#?MODULE{} = T, Root) when is_binary(Root) ->
    do_missing_set(T, Root, sets:new([{version, 2}])).

-spec page_refs(page()) -> [binary()].

page_refs(Page) ->
    bondy_mst_page:refs(Page).

-spec destroy(t()) -> ok.

destroy(#?MODULE{writer = W} = T) ->
    Dir = bondy_mst_pack_writer:dir(W),
    ok = close(T),
    _ = file:del_dir_r(Dir),
    ok.

%% =============================================================================
%% API — extensions
%% =============================================================================

?DOC("""
Seals the current `incoming.pack` into a new sealed `pack-NNNN`
pair and refreshes the sealed-view cache.  Returns `{ok, T1}` for
the post-seal state (regardless of whether a new pack was created
or the call was a no-op against an empty incoming).
""").
-spec seal(t()) -> {ok, t()} | {error, term()}.

seal(#?MODULE{writer = W} = T) ->
    %% Seal is a write barrier — any staged tombstones are flushed
    %% so the on-disk state after seal/1 is fully durable.
    case do_flush_tombstones(T) of
        {ok, T0} ->
            RecordCount = bondy_mst_pack_writer:pending_count(W),
            PackBytes = bondy_mst_pack_writer:incoming_offset(W),
            StartTs = erlang:monotonic_time(microsecond),
            Result = bondy_mst_pack_writer:seal(W),
            DurationUs = erlang:monotonic_time(microsecond) - StartTs,
            case Result of
                {ok, no_op, W1} ->
                    %% No-op seal: nothing to emit; the no_op return
                    %% means there was nothing pending to roll over.
                    {ok, T0#?MODULE{writer = W1}};
                {ok, PackId, W1} ->
                    Dir = bondy_mst_pack_writer:dir(W1),
                    Ctx = bondy_mst_pack_sealed_view:open_ctx_from_writer(W1),
                    case bondy_mst_pack_sealed_view:open(Dir, Ctx, PackId) of
                        {ok, View} ->
                            Views = newest_first([
                                View | T0#?MODULE.sealed_views
                            ]),
                            T1 = T0#?MODULE{writer = W1, sealed_views = Views},
                            emit_seal(
                                T1,
                                RecordCount,
                                PackBytes,
                                DurationUs,
                                PackId
                            ),
                            {ok, T1};
                        {error, _} = E ->
                            E
                    end;
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

?DOC("""
Asynchronous counterpart to the synchronous `seal/1`: if the auto-seal
threshold is crossed and no seal is already in flight, rolls the current
`incoming.pack` aside (cheap — see `bondy_mst_pack_writer:roll_incoming/1`)
and returns the resulting `seal_job()` for a worker to execute off the
caller's critical path.

This is the admission-control point for the in-flight=1 cap: while a seal is
in flight (`seal_in_flight/1`), a crossed threshold returns `{defer, T}` —
`incoming.pack` keeps growing and the caller applies backpressure rather
than starting a second concurrent rewrite.

Returns:
- `{rolled, Job, T1}` — rolled; run `Job` via `run_seal_job/1` (in a worker),
  then `complete_seal/2` on this store with `Job`'s pack id.
- `{defer, T1}`       — threshold crossed but a seal is already in flight.
- `{noop, T1}`        — threshold not crossed (or nothing pending to roll).

Unlike `seal/1` this does NOT flush staged tombstones — that write barrier
is deferred to `complete_seal/2`, keeping the roll off the hot path.
""").
-spec maybe_roll_for_seal(t()) ->
    {rolled, bondy_mst_pack_writer:seal_job(), t()}
    | {defer, t()}
    | {noop, t()}.

maybe_roll_for_seal(
    #?MODULE{
        auto_seal_records = infinity,
        auto_seal_bytes = infinity
    } = T
) ->
    {noop, T};
maybe_roll_for_seal(
    #?MODULE{
        writer = W,
        auto_seal_records = RMax,
        auto_seal_bytes = BMax
    } = T
) ->
    Records = bondy_mst_pack_writer:pending_count(W),
    Bytes = bondy_mst_pack_writer:incoming_offset(W),
    case
        threshold_crossed(Records, RMax) orelse threshold_crossed(Bytes, BMax)
    of
        false ->
            {noop, T};
        true ->
            case seal_in_flight(T) of
                true ->
                    {defer, T};
                false ->
                    do_roll_for_seal(T, Records, Bytes)
            end
    end.

%% @private
do_roll_for_seal(#?MODULE{writer = W} = T, Records, Bytes) ->
    StartTs = erlang:monotonic_time(microsecond),
    case bondy_mst_pack_writer:roll_incoming(W) of
        {ok, Job, W1} ->
            DurationUs = erlang:monotonic_time(microsecond) - StartTs,
            T1 = T#?MODULE{writer = W1},
            emit_seal_roll(
                T1, Records, Bytes, DurationUs, maps:get(pack_id, Job)
            ),
            {rolled, Job, T1};
        {no_op, W1} ->
            {noop, T#?MODULE{writer = W1}};
        {error, Reason} ->
            %% The page is already durable in incoming.pack; the next put
            %% re-evaluates. Mirrors the auto-seal failure policy.
            ?LOG_WARNING(#{
                event => mst_pack_store_roll_failed,
                reason => Reason,
                pending_records => Records,
                pending_bytes => Bytes
            }),
            {noop, T}
    end.

?DOC("""
Executes a `seal_job()` produced by `maybe_roll_for_seal/1`. Pure with
respect to store state — it writes the new `pack-NNNN` pair from the job's
in-memory snapshot and touches no live state — so it is safe to run in a
separate worker process while the store keeps serving puts and reads.

Returns `ok` or `{error, _}`. On error the caller must NOT `complete_seal/2`
— the rolled snapshot stays in flight and recovery re-seals it on reopen.
""").
-spec run_seal_job(bondy_mst_pack_writer:seal_job()) -> ok | {error, term()}.

run_seal_job(Job) when is_map(Job) ->
    bondy_mst_pack_writer:run_seal_job(Job).

?DOC("""
The target pack id of a `seal_job()`. Stateless accessor used by the seal
orchestration to know which pack to `complete_seal/2` once the worker
reports the job done.
""").
-spec seal_job_pack_id(bondy_mst_pack_writer:seal_job()) -> pos_integer().

seal_job_pack_id(Job) when is_map(Job) ->
    maps:get(pack_id, Job).

?DOC("""
Finalises the asynchronous seal whose worker has completed `run_seal_job/1`
for `PackId`: commits the manifest, drops the in-flight snapshot, and mounts
the new sealed pack as a sealed view so reads move from the in-flight
snapshot to the durable pack atomically. Flushes any staged tombstones as
the post-seal write barrier (mirroring `seal/1`).

Returns `{ok, T1}` or `{error, _}` (a manifest-commit or view-open failure;
the caller should treat it as fatal — a reopen re-mounts the durable pack).
""").
-spec complete_seal(t(), pos_integer()) -> {ok, t()} | {error, term()}.

complete_seal(#?MODULE{writer = W} = T, PackId) ->
    case bondy_mst_pack_writer:complete_seal(W, PackId) of
        {ok, W1} ->
            Dir = bondy_mst_pack_writer:dir(W1),
            Ctx = bondy_mst_pack_sealed_view:open_ctx_from_writer(W1),
            case bondy_mst_pack_sealed_view:open(Dir, Ctx, PackId) of
                {ok, View} ->
                    Views = newest_first([View | T#?MODULE.sealed_views]),
                    T1 = T#?MODULE{writer = W1, sealed_views = Views},
                    %% Write barrier: the seal is durable, so flush staged
                    %% tombstones. A flush failure is non-fatal — the
                    %% free_set debounce retries — so the seal still
                    %% completes.
                    case do_flush_tombstones(T1) of
                        {ok, T2} -> {ok, T2};
                        {error, _} -> {ok, T1}
                    end;
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

?DOC("""
Whether a seal is currently in flight — a `maybe_roll_for_seal/1` has rolled
but its `complete_seal/2` has not yet run. The in-flight=1 cap reads this to
decide between rolling and deferring.
""").
-spec seal_in_flight(t()) -> boolean().

seal_in_flight(#?MODULE{writer = W}) ->
    bondy_mst_pack_writer:sealing_pack_id(W) =/= undefined.

-spec dir(t()) -> file:filename_all().
dir(#?MODULE{writer = W}) -> bondy_mst_pack_writer:dir(W).

-spec instance_id(t()) -> binary().
instance_id(#?MODULE{writer = W}) -> bondy_mst_pack_writer:instance_id(W).

-spec sealed_pack_ids(t()) -> [non_neg_integer()].
sealed_pack_ids(#?MODULE{sealed_views = Views}) ->
    [V#sealed_view.pack_id || V <- Views].

?DOC("""
Returns a snapshot of the per-instance gauges described in design
§13. Synchronous and cheap (no I/O beyond the manifest cursor and
`filelib:file_size/1` on each sealed pack). Intended to be plugged
into `telemetry_poller` by operators who want gauges emitted on a
schedule; the pack store itself does not emit gauges.

Fields:
- `instance_id`           — opaque identifier set at `open/2`
- `live_pack_count`       — number of sealed packs currently mounted
- `pending_record_count`  — pending pages in `incoming.pack`
- `bytes_total`           — sum of sealed-pack file sizes (sealed
                            packs only; `incoming.pack` excluded)
- `current_root_hash`     — current MST root, or `undefined`
""").
-spec info(t()) -> map().
info(#?MODULE{} = T) ->
    #{
        instance_id => instance_id(T),
        live_pack_count => length(T#?MODULE.sealed_views),
        pending_record_count =>
            bondy_mst_pack_writer:pending_count(T#?MODULE.writer),
        %% Total bytes resident in the writer's pending map (= the
        %% on-disk `incoming.pack` byte size, since the pending map
        %% mirrors the on-disk record layout including pack header,
        %% per-record headers, CRC, and body). Used by operators
        %% sizing per-instance memory budgets and by the QA #15
        %% memory-audit bench.
        pending_bytes =>
            bondy_mst_pack_writer:incoming_offset(T#?MODULE.writer),
        bytes_total => sealed_views_bytes(T),
        current_root_hash => get_root(T)
    }.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
required(K, M) ->
    case maps:find(K, M) of
        {ok, V} -> V;
        error -> error({missing_opt, K})
    end.

%% @private
forward_opt(K, Src, Dst) ->
    case maps:find(K, Src) of
        {ok, V} -> Dst#{K => V};
        error -> Dst
    end.

%% @private
%% Validates and returns an auto-seal threshold from `Opts`. Defaults to
%% the value in `bondy_mst_pack.hrl` (`?BONDY_MST_PACK_DEFAULT_AUTO_SEAL_*`);
%% `infinity` explicitly disables the threshold. A positive integer
%% enables the threshold; any other value is rejected with
%% `error({invalid_opt, K, V})` to fail fast at open time rather than
%% silently disabling the threshold.
validated_auto_seal(K, Opts) ->
    case maps:get(K, Opts, default_for(K)) of
        infinity -> infinity;
        N when is_integer(N), N > 0 -> N;
        Bad -> error({invalid_opt, K, Bad})
    end.

%% @private
%% Same shape as `validated_auto_seal/2` — `infinity` disables, a
%% positive integer enables, any other value is rejected.
validated_tombstones_flush(K, Opts) ->
    case maps:get(K, Opts, default_for(K)) of
        infinity -> infinity;
        N when is_integer(N), N > 0 -> N;
        Bad -> error({invalid_opt, K, Bad})
    end.

%% @private
%% Validates the seal driver. `sync` (default) seals inline on `put/2`;
%% `async` defers sealing to the store owner via `maybe_roll_for_seal/1`.
validated_seal_mode(Opts) ->
    case maps:get(seal_mode, Opts, sync) of
        sync -> sync;
        async -> async;
        Bad -> error({invalid_opt, seal_mode, Bad})
    end.

%% @private
%% Validates the GC dead-fraction threshold. Accepts a float in
%% `[0.0, 1.0]` (integer `0` and `1` are aliased to the float forms).
%% Any other value is rejected with `{invalid_opt, K, V}` so a typo
%% surfaces at open time rather than as silent GC-policy drift.
validated_gc_threshold(K, Opts) ->
    case maps:get(K, Opts, default_for(K)) of
        0 -> 0.0;
        1 -> 1.0;
        F when is_float(F), F >= 0.0, F =< 1.0 -> F;
        Bad -> error({invalid_opt, K, Bad})
    end.

%% @private
default_for(auto_seal_records) ->
    ?BONDY_MST_PACK_DEFAULT_AUTO_SEAL_RECORDS;
default_for(auto_seal_bytes) ->
    ?BONDY_MST_PACK_DEFAULT_AUTO_SEAL_BYTES;
default_for(tombstones_flush_every_records) ->
    ?BONDY_MST_PACK_DEFAULT_TOMBSTONES_FLUSH_EVERY_RECORDS;
default_for(tombstones_flush_every_ms) ->
    ?BONDY_MST_PACK_DEFAULT_TOMBSTONES_FLUSH_EVERY_MS;
default_for(gc_threshold_dead_fraction) ->
    ?BONDY_MST_PACK_DEFAULT_GC_THRESHOLD_DEAD_FRACTION.

%% @private
ensure_dir(Dir) ->
    case filelib:ensure_path(Dir) of
        ok -> ok;
        {error, R} -> error({ensure_dir, Dir, R})
    end.

%% @private
%% Reads `tombstones` at `Dir`. Missing file → empty set (the
%% normal case for a fresh instance). Corrupt or unreadable file
%% is logged at WARNING and treated as empty so a single bad
%% tombstone file does not stop the store from opening — the
%% effect is that previously-deleted hashes become queryable
%% until the next compaction reclaims them.
load_tombstones(Dir) ->
    case bondy_mst_pack_tombstones:read(Dir) of
        {ok, Set} ->
            Set;
        {error, enoent} ->
            sets:new([{version, 2}]);
        {error, Reason} ->
            ?LOG_WARNING(#{
                event => mst_pack_store_tombstones_unreadable,
                dir => Dir,
                reason => Reason
            }),
            sets:new([{version, 2}])
    end.

%% @private
%% Auto-seal: triggers a seal when either threshold is crossed.
%%
%% A failure here is logged but does NOT propagate — the page that just
%% went into `incoming.pack` is already durable, and crossing the
%% threshold is "we should roll over now", not "we cannot accept
%% further writes". The next put will re-evaluate and retry the seal.
%% This matches the opportunistic tone of the durability batching in
%% the writer.
%%
%% Both thresholds default to `infinity`; in that case the function
%% short-circuits to avoid even the inspection calls.
maybe_auto_seal(#?MODULE{seal_mode = async} = T) ->
    %% The store owner drives sealing via `maybe_roll_for_seal/1`; never
    %% seal inline on the put path.
    T;
maybe_auto_seal(
    #?MODULE{
        auto_seal_records = infinity,
        auto_seal_bytes = infinity
    } = T
) ->
    T;
maybe_auto_seal(
    #?MODULE{
        writer = W,
        auto_seal_records = RMax,
        auto_seal_bytes = BMax
    } = T
) ->
    Records = bondy_mst_pack_writer:pending_count(W),
    Bytes = bondy_mst_pack_writer:incoming_offset(W),
    case
        threshold_crossed(Records, RMax) orelse
            threshold_crossed(Bytes, BMax)
    of
        false ->
            T;
        true ->
            case seal(T) of
                {ok, T1} ->
                    T1;
                {error, Reason} ->
                    ?LOG_WARNING(#{
                        event => mst_pack_store_auto_seal_failed,
                        reason => Reason,
                        pending_records => Records,
                        pending_bytes => Bytes
                    }),
                    T
            end
    end.

%% @private
threshold_crossed(_, infinity) -> false;
threshold_crossed(V, Max) -> V >= Max.

%% @private
%% Updates the in-memory `free_set` and decides whether to persist
%% the change to disk. Size equality with the prior set means a
%% no-op (re-tombstoning an already-tombstoned hash, or
%% un-tombstoning a hash that wasn't tombstoned — both common from
%% the MST's page-revision loop). Otherwise the staged set replaces
%% the in-memory one and the debounce policy
%% (`tombstones_flush_every_records` / `tombstones_flush_every_ms`)
%% decides whether to fsync the tombstones file now or piggy-back
%% on the next seal / GC / explicit flush. Crash semantics match
%% the set_root debounce: in-memory is authoritative; on reopen
%% the WAL applier re-derives any unflushed tombstones from its
%% own watermark.
maybe_persist_free_set(#?MODULE{free_set = Old} = T, New, Op) ->
    case sets:size(New) =:= sets:size(Old) of
        true ->
            T;
        false ->
            T1 = T#?MODULE{
                free_set = New,
                tombstones_unsynced_count =
                    T#?MODULE.tombstones_unsynced_count + 1,
                tombstones_dirty = true
            },
            case tombstones_flush_due(T1) of
                true ->
                    case do_flush_tombstones(T1) of
                        {ok, T2} -> T2;
                        {error, R} -> error({Op, {tombstones, R}})
                    end;
                false ->
                    T1
            end
    end.

%% @private
%% Mirrors `bondy_mst_pack_writer:root_flush_due/1`. Threshold-based
%% (records first, wall-clock second); both `infinity` disables
%% on-put flushing entirely — seal / GC / close / explicit flush
%% are then the only persistence drivers.
tombstones_flush_due(#?MODULE{tombstones_dirty = false}) ->
    false;
tombstones_flush_due(#?MODULE{
    tombstones_unsynced_count = N,
    tombstones_flush_every_records = K
}) when
    is_integer(K), N >= K
->
    true;
tombstones_flush_due(#?MODULE{tombstones_flush_every_ms = infinity}) ->
    false;
tombstones_flush_due(#?MODULE{
    last_tombstones_flush_ms = Last,
    tombstones_flush_every_ms = TMs
}) ->
    erlang:monotonic_time(millisecond) - Last >= TMs.

%% @private
%% Forces a tombstones file rewrite if there is a pending change.
%% Idempotent — no-op if `tombstones_dirty = false`.
do_flush_tombstones(#?MODULE{tombstones_dirty = false} = T) ->
    {ok, T};
do_flush_tombstones(#?MODULE{writer = W, free_set = FreeSet} = T) ->
    Dir = bondy_mst_pack_writer:dir(W),
    case bondy_mst_pack_tombstones:write(Dir, FreeSet) of
        ok ->
            {ok, reset_tombstones_flush_counters(T)};
        {error, _} = E ->
            E
    end.

%% @private
reset_tombstones_flush_counters(#?MODULE{} = T) ->
    T#?MODULE{
        tombstones_unsynced_count = 0,
        last_tombstones_flush_ms = erlang:monotonic_time(millisecond),
        tombstones_dirty = false
    }.

%% @private
open_sealed_views(_Dir, _Ctx, []) ->
    {ok, []};
open_sealed_views(Dir, Ctx, [Id | Rest]) ->
    case bondy_mst_pack_sealed_view:open(Dir, Ctx, Id) of
        {ok, V} ->
            case open_sealed_views(Dir, Ctx, Rest) of
                {ok, Vs} ->
                    {ok, [V | Vs]};
                {error, _} = E ->
                    _ = prim_file:close(V#sealed_view.pack_fd),
                    E
            end;
        {error, _} = E ->
            E
    end.

%% @private
newest_first(Views) ->
    lists:reverse(lists:keysort(#sealed_view.pack_id, Views)).

%% @private
%% Returns `{Page | undefined, Source, ByteSize}` so callers can both
%% deserialise and emit telemetry from one walk. `Source` ∈ `pending |
%% {sealed_pack, PackId} | cold_miss`; `ByteSize` is the wire size of
%% the record that was read (0 on a miss).
do_get(#?MODULE{writer = W, sealed_views = Views}, Hash) ->
    case bondy_mst_pack_writer:pending_read(W, Hash) of
        {ok, Bytes} ->
            {deserialise(Bytes), pending, byte_size(Bytes)};
        not_found ->
            get_from_sealed(Views, Hash);
        {error, R} ->
            error({get, R})
    end.

%% @private
get_from_sealed([], _Hash) ->
    {undefined, cold_miss, 0};
get_from_sealed([V | Rest], Hash) ->
    case bondy_mst_pack_index:lookup(V#sealed_view.idx, Hash) of
        not_found ->
            get_from_sealed(Rest, Hash);
        {ok, Offset} ->
            case bondy_mst_pack_io:read_record(V, Hash, Offset) of
                {ok, Bytes} ->
                    {
                        deserialise(Bytes),
                        {sealed_pack, V#sealed_view.pack_id},
                        byte_size(Bytes)
                    };
                not_found ->
                    get_from_sealed(Rest, Hash);
                {error, R} ->
                    error({get, R})
            end
    end.

%% @private
do_has(#?MODULE{writer = W, sealed_views = Views}, Hash) ->
    %% `member/2` unions the active pending set with any in-flight seal
    %% snapshot, so a rolled page stays visible while it is being sealed.
    bondy_mst_pack_writer:member(W, Hash) orelse
        lists:any(
            fun(#sealed_view{idx = Idx}) ->
                bondy_mst_pack_index:lookup(Idx, Hash) =/= not_found
            end,
            Views
        ).

%% @private
%% Enumerate every hash known to the store: pending first, then
%% every sealed view in newest-first order. Hashes are de-duplicated;
%% `free_set` members are excluded.
enumerate_hashes(#?MODULE{
    writer = W,
    sealed_views = Views,
    free_set = FreeSet
}) ->
    Pending = bondy_mst_pack_writer:pending_hashes(W),
    Seen0 = lists:foldl(
        fun(H, M) ->
            case sets:is_element(H, FreeSet) of
                true -> M;
                false -> M#{H => true}
            end
        end,
        #{},
        Pending
    ),
    Seen = lists:foldl(
        fun(#sealed_view{idx = Idx}, M) ->
            lists:foldl(
                fun({H, _}, A) ->
                    case sets:is_element(H, FreeSet) of
                        true -> A;
                        false -> A#{H => true}
                    end
                end,
                M,
                bondy_mst_pack_index:entries(Idx)
            )
        end,
        Seen0,
        Views
    ),
    maps:keys(Seen).

%% @private
do_missing_set(T, Hash, Acc) ->
    case get(T, Hash) of
        undefined ->
            sets:add_element(Hash, Acc);
        Page ->
            lists:foldl(
                fun(Ref, A) -> do_missing_set(T, Ref, A) end,
                Acc,
                page_refs(Page)
            )
    end.

%% @private
%% Page serialisation: only the hash-bearing subset `{Level, Low,
%% List}` is written — `freed_at` is per-replica metadata that
%% `bondy_mst_page:hash/2` deliberately excludes, so persisting it
%% would break content-addressing across replicas.
serialise(Page) ->
    Level = bondy_mst_page:level(Page),
    Low = bondy_mst_page:low(Page),
    List = bondy_mst_page:list(Page),
    erlang:term_to_binary(
        {Level, Low, List},
        [deterministic, {minor_version, 2}]
    ).

%% @private
%% Deliberately NOT `[safe]`. These bytes were produced by `serialise/1` on
%% THIS node and read back from this node's own pack files, so `[safe]` buys
%% no protection here: the atoms a page carries were already materialised in
%% this VM when the page was built or when a peer's page was decoded off the
%% wire. That wire boundary is where the `C-2` `[safe]` decodes live
%% (`bondy_oplog_cell_kernel`, the `bondy_oplog_crdt_*` modules) and it is the
%% one that matters.
%%
%% What `[safe]` did buy was a boot-time brick. It resolves atoms against the
%% VM's atom table AT READ TIME, and on a cold start that table is a moving
%% target — modules load lazily, and `bondy_oplog_instance:init/1` folds the
%% store early. A page holding any atom whose defining module has not been
%% loaded yet (a value that arrived from a peer on a newer version, or simply
%% a module not reached this early in boot) fails `binary_to_term` with
%% `badarg`. The fold dies, the instance dies, and the node cannot open a
%% store it had written perfectly well. `binary_to_term/1` still raises
%% `badarg` on genuinely malformed bytes, so corruption detection is unchanged.
deserialise(Bytes) ->
    {Level, Low, List} = erlang:binary_to_term(Bytes),
    bondy_mst_page:new(Level, Low, List).

%% @private
%% Content-addressing invariant: the writer's content hash (sha256 of the
%% serialised page body) must equal the canonical `bondy_mst_page:hash/2`.
%% This holds by construction — both serialise `{Level, Low, List}` with the
%% same `term_to_binary` opts and sha256 the result — so release/bench builds
%% trust the writer's hash and skip the recompute. Under TEST we re-derive and
%% assert it, exercising the invariant across the full pack-store test suite.
-ifdef(TEST).
assert_content_hash(Hash, Page, Algo) ->
    Hash = bondy_mst_page:hash(Page, Algo),
    ok.
-else.
assert_content_hash(_Hash, _Page, _Algo) ->
    ok.
-endif.

%% =============================================================================
%% PRIVATE — gc
%% =============================================================================

%% @private
gc_noop_meta() ->
    #{
        compacted => false,
        retired => [],
        new_pack => undefined,
        kept => 0,
        dropped => 0
    }.

%% @private
%% Meta for the threshold-skip path: GC found drops but decided not to
%% rewrite because the dead fraction is below `gc_threshold_dead_fraction`.
%% Reports the actual `Kept` / `Dropped` so operators can see the gap
%% between the observed state and the configured threshold.
gc_threshold_skip_meta(Kept, Dropped) ->
    #{
        compacted => false,
        reason => below_threshold,
        retired => [],
        new_pack => undefined,
        kept => Kept,
        dropped => Dropped
    }.

%% @private
do_gc(#?MODULE{} = T, KeepRoots) ->
    Reachable = reachable_set(T, KeepRoots),
    {KeptHashes, Dropped} = partition_sealed(T, Reachable),
    Kept = length(KeptHashes),
    case should_compact(T, Kept, Dropped) of
        false when Dropped > 0 ->
            %% Drops were found but the dead fraction is below the
            %% configured threshold — surface that in the meta so
            %% operators can see what GC observed without rewriting.
            {T, gc_threshold_skip_meta(Kept, Dropped)};
        false ->
            {T, gc_noop_meta()};
        true ->
            apply_compaction(T, KeptHashes, Dropped)
    end.

%% @private
%% Transitive page-ref walk starting from `KeepRoots`. Missing refs
%% (root or transitive) are silently skipped — the resulting set is
%% the largest subset of the store's hashes reachable from the given
%% roots given the current page contents.
reachable_set(T, KeepRoots) ->
    lists:foldl(
        fun(R, Acc) -> walk_reachable(T, R, Acc) end,
        sets:new([{version, 2}]),
        KeepRoots
    ).

%% @private
walk_reachable(_T, undefined, Acc) ->
    Acc;
walk_reachable(T, Hash, Acc) when is_binary(Hash) ->
    case sets:is_element(Hash, Acc) of
        true ->
            Acc;
        false ->
            case do_get(T, Hash) of
                {undefined, _, _} ->
                    Acc;
                {Page, _, _} ->
                    Acc1 = sets:add_element(Hash, Acc),
                    lists:foldl(
                        fun(Ref, A) -> walk_reachable(T, Ref, A) end,
                        Acc1,
                        bondy_mst_page:refs(Page)
                    )
            end
    end.

%% @private
%% Walk every sealed entry once. Newest-first dedup: if the same hash
%% appears in multiple sealed packs (legal because content is
%% identical), it's accounted for exactly once.
partition_sealed(#?MODULE{sealed_views = Views}, Reachable) ->
    Init = {[], 0, sets:new([{version, 2}])},
    {Kept, Dropped, _Seen} = lists:foldl(
        fun(#sealed_view{idx = Idx}, Acc) ->
            lists:foldl(
                fun({H, _Off}, {K, D, S}) ->
                    case sets:is_element(H, S) of
                        true ->
                            {K, D, S};
                        false ->
                            S1 = sets:add_element(H, S),
                            %% REACHABILITY ALONE decides. The `free_set` is
                            %% deliberately NOT a second kill criterion here,
                            %% for the same reason `get/2` refuses to treat it
                            %% as a read mask: reachability from the keep-roots
                            %% is the single source of truth for liveness, and
                            %% a tombstone is only a hint that a page is
                            %% PROBABLY garbage.
                            %%
                            %% Adding `andalso not tombstoned` (the previous
                            %% shape) could only ever change the outcome for a
                            %% page that is REACHABLE FROM A LIVE ROOT yet
                            %% carries a tombstone — and it would delete that
                            %% page from disk permanently. Such a page is
                            %% exactly what a stray `free/3` produces; one such
                            %% bug (a merge freeing a donor hash in the
                            %% receiver's store) was live in this tree until
                            %% 2026-08-07. It costs nothing to be conservative:
                            %% a genuinely dead page is unreachable and gets
                            %% dropped by this same test, so keeping
                            %% reachable-but-tombstoned pages delays no
                            %% reclamation — they are collected on the next
                            %% cycle once they actually fall out of the tree.
                            Keep = sets:is_element(H, Reachable),
                            case Keep of
                                true -> {[H | K], D, S1};
                                false -> {K, D + 1, S1}
                            end
                    end
                end,
                Acc,
                bondy_mst_pack_index:entries(Idx)
            )
        end,
        Init,
        Views
    ),
    {lists:sort(Kept), Dropped}.

%% @private
%% Decide whether to rewrite the sealed set.
%%
%% Multi-pack always wins: when there are 2+ sealed packs the call
%% coalesces them into one regardless of the dead-fraction.
%% Single-pack with zero drops is always a no-op.
%% Single-pack with drops fires only when the dead fraction
%% (`Dropped / (Kept + Dropped)`) meets `gc_threshold_dead_fraction`.
should_compact(#?MODULE{sealed_views = Views}, _Kept, 0) ->
    length(Views) > 1;
should_compact(
    #?MODULE{
        sealed_views = Views,
        gc_threshold_dead_fraction = TR
    },
    Kept,
    Dropped
) ->
    length(Views) > 1 orelse (Dropped / (Kept + Dropped)) >= TR.

%% @private
%% A reader closure that, given a hash, returns the bytes stored in
%% whichever sealed view holds it. Used by `bondy_mst_pack_writer:
%% create_sealed_pack/6` to stream the compacted pack record-by-record.
sealed_reader(Views) ->
    fun(Hash) -> read_sealed_bytes(Views, Hash) end.

%% @private
read_sealed_bytes([], Hash) ->
    {error, {gc_missing_sealed, Hash}};
read_sealed_bytes([V | Rest], Hash) ->
    case bondy_mst_pack_index:lookup(V#sealed_view.idx, Hash) of
        not_found ->
            read_sealed_bytes(Rest, Hash);
        {ok, Off} ->
            case bondy_mst_pack_io:read_record(V, Hash, Off) of
                {ok, Body} ->
                    {ok, Body};
                not_found ->
                    %% bloom false positive that survived binary search —
                    %% try the next pack
                    read_sealed_bytes(Rest, Hash);
                {error, _} = E ->
                    E
            end
    end.

%% @private
apply_compaction(T, KeptHashes, Dropped) ->
    #?MODULE{writer = W, sealed_views = Views} = T,
    Dir = bondy_mst_pack_writer:dir(W),
    IH = bondy_mst_pack_writer:instance_hash(W),
    Algo = bondy_mst_pack_writer:hash_algo(W),
    %% `sealed_views` is newest-first (see record-field invariant);
    %% sort here to surface retired ids in ascending order for the
    %% `compaction_meta()` map — `remove_sealed_packs/2` itself does
    %% not require sorted input.
    OldIds = lists:sort([V#sealed_view.pack_id || V <- Views]),
    NewPackId = lists:max(OldIds) + 1,
    case
        write_compacted_pack(
            Dir,
            IH,
            Algo,
            NewPackId,
            KeptHashes,
            sealed_reader(Views)
        )
    of
        ok ->
            commit_compaction(
                T,
                Dir,
                OldIds,
                NewPackId,
                KeptHashes,
                Dropped
            );
        {error, R} ->
            ?LOG_ERROR(#{
                event => mst_pack_store_gc_write_failed,
                pack_id => NewPackId,
                reason => R
            }),
            {T, #{compacted => false, error => R}}
    end.

%% @private
write_compacted_pack(_Dir, _IH, _Algo, _NewPackId, [], _Reader) ->
    %% Empty kept set — no new pack to write, just retire the old ones.
    ok;
write_compacted_pack(Dir, IH, Algo, NewPackId, Hashes, Reader) ->
    bondy_mst_pack_seal:create_sealed_pack(
        Dir, IH, Algo, NewPackId, Hashes, Reader
    ).

%% @private
commit_compaction(T, Dir, OldIds, NewPackId, KeptHashes, Dropped) ->
    W0 = T#?MODULE.writer,
    M0 = bondy_mst_pack_writer:manifest(W0),
    M1 = bondy_mst_pack_manifest:remove_sealed_packs(M0, OldIds),
    M2 =
        case KeptHashes of
            [] -> M1;
            _ -> bondy_mst_pack_manifest:add_sealed_pack(M1, NewPackId)
        end,
    M3 = bondy_mst_pack_manifest:with_last_compacted_at(
        M2, erlang:system_time(millisecond)
    ),
    case bondy_mst_pack_manifest:write(Dir, M3) of
        ok ->
            finalise_compaction(T, M3, OldIds, NewPackId, KeptHashes, Dropped);
        {error, R} ->
            %% Roll back: delete the just-written sealed pack (if any).
            case KeptHashes of
                [] ->
                    ok;
                _ ->
                    bondy_mst_pack_seal:delete_sealed_pack_files(
                        Dir,
                        NewPackId
                    )
            end,
            ?LOG_ERROR(#{
                event => mst_pack_store_gc_manifest_swap_failed,
                reason => R
            }),
            {T, #{compacted => false, error => R}}
    end.

%% @private
%% Manifest is durable; the rest is bookkeeping. Opening the just-
%% written sealed view is the last step. The failure window is narrow,
%% but the typical failure modes — EMFILE, EAGAIN, transient EIO — are
%% recoverable. We retry once before raising: the idx was just fsync'd,
%% so it is hot in the OS page cache and the retry is essentially free.
%% If the second attempt also fails the on-disk state is still correct
%% and the next reopen rebuilds the in-memory view from the manifest.
finalise_compaction(T, M, OldIds, NewPackId, KeptHashes, Dropped) ->
    OldViews = T#?MODULE.sealed_views,
    W1 = bondy_mst_pack_writer:set_manifest(T#?MODULE.writer, M),
    Dir = bondy_mst_pack_writer:dir(W1),
    lists:foreach(
        fun(#sealed_view{pack_fd = Fd}) -> _ = prim_file:close(Fd) end,
        OldViews
    ),
    NewViews =
        case KeptHashes of
            [] ->
                [];
            _ ->
                open_new_view_or_raise(
                    Dir,
                    bondy_mst_pack_sealed_view:open_ctx_from_writer(W1),
                    NewPackId
                )
        end,
    lists:foreach(
        fun(Id) -> bondy_mst_pack_seal:delete_sealed_pack_files(Dir, Id) end,
        OldIds
    ),
    %% GC just rewrote the manifest and the sealed packs; ride the
    %% tombstones rewrite along so the on-disk state is internally
    %% consistent post-compaction (matches the per-PR architectural
    %% rule that GC commit yields fully durable state).
    Pruned = prune_applied_tombstones(W1, T#?MODULE.free_set),
    T0 = T#?MODULE{
        writer = W1,
        sealed_views = NewViews,
        free_set = Pruned,
        tombstones_dirty = true
    },
    T1 =
        case do_flush_tombstones(T0) of
            {ok, FlushedT} ->
                FlushedT;
            {error, Reason} ->
                error({gc, {tombstones, Reason}})
        end,
    Meta = #{
        compacted => true,
        retired => OldIds,
        new_pack =>
            case KeptHashes of
                [] -> undefined;
                _ -> NewPackId
            end,
        kept => length(KeptHashes),
        dropped => Dropped,
        last_compacted_at => bondy_mst_pack_manifest:last_compacted_at(M)
    },
    {T1, Meta}.

%% @private
%% Opens the just-written sealed view with a single retry on failure.
%% The first attempt failure is logged at WARNING for observability;
%% the second attempt failure logs at ERROR and raises so the calling
%% process restarts and recovers from the manifest. We surface the
%% second reason (not the first) in the raise so the caller's logs
%% point at the persistent fault rather than the transient one.
open_new_view_or_raise(Dir, Ctx, PackId) ->
    case bondy_mst_pack_sealed_view:open(Dir, Ctx, PackId) of
        {ok, V} ->
            [V];
        {error, R1} ->
            ?LOG_WARNING(#{
                event => mst_pack_store_gc_open_view_retry,
                pack_id => PackId,
                reason => R1
            }),
            case bondy_mst_pack_sealed_view:open(Dir, Ctx, PackId) of
                {ok, V} ->
                    [V];
                {error, R2} ->
                    ?LOG_ERROR(#{
                        event => mst_pack_store_gc_open_view_failed,
                        pack_id => PackId,
                        first_reason => R1,
                        second_reason => R2
                    }),
                    error({gc_open_view, PackId, R2})
            end
    end.

%% @private
%% A tombstone on a hash that lived only in sealed packs has now been
%% applied — the entry isn't in the new pack. Drop those.  Tombstones
%% targeting hashes still in `incoming.pack` (pending) stay alive; the
%% next seal will fold them into a future compaction.
prune_applied_tombstones(W, FreeSet) ->
    Pending = bondy_mst_pack_writer:pending_hashes(W),
    PendingSet = sets:from_list(Pending, [{version, 2}]),
    sets:filter(
        fun(H) -> sets:is_element(H, PendingSet) end,
        FreeSet
    ).

%% =============================================================================
%% PRIVATE — telemetry
%% =============================================================================

%% @private
%% Sum of `filelib:file_size/1` over every sealed pack file. Used by
%% `info/1` (`bytes_total` gauge) and by `gc/2` (pre-call snapshot for
%% the `bytes_freed` measurement). Best-effort: a missing/locked file
%% contributes 0 rather than aborting — these are observability
%% measurements, not invariants.
sealed_views_bytes(#?MODULE{writer = W, sealed_views = Views}) ->
    Dir = bondy_mst_pack_writer:dir(W),
    lists:foldl(
        fun(#sealed_view{pack_id = Id}, Acc) ->
            Path = bondy_mst_pack_paths:sealed_pack_path(Dir, Id),
            Acc + safe_file_size(Path)
        end,
        0,
        Views
    ).

%% @private
safe_file_size(Path) ->
    try filelib:file_size(Path) of
        N when is_integer(N), N >= 0 -> N;
        _ -> 0
    catch
        _:_ -> 0
    end.

%% @private
emit_put(T, PageBytes, DurationUs, ContentHit) ->
    telemetry:execute(
        [bondy_mst, page_store, put],
        #{
            page_bytes => PageBytes,
            duration_us => DurationUs,
            content_hit => ContentHit
        },
        #{instance_id => instance_id(T)}
    ).

%% @private
emit_get(T, PageBytes, DurationUs, Source) ->
    telemetry:execute(
        [bondy_mst, page_store, get],
        #{
            page_bytes => PageBytes,
            duration_us => DurationUs,
            source => Source
        },
        #{instance_id => instance_id(T)}
    ).

%% @private
emit_seal(T, RecordCount, PackBytes, DurationUs, NewPackId) ->
    telemetry:execute(
        [bondy_mst, page_store, seal_incoming],
        #{
            record_count => RecordCount,
            pack_bytes => PackBytes,
            duration_us => DurationUs
        },
        #{instance_id => instance_id(T), new_pack_id => NewPackId}
    ).

%% @private
%% The cheap, synchronous half of an asynchronous seal: the cost of rolling
%% `incoming.pack` aside (datasync + close + rename + manifest commit), as
%% opposed to the worker's `seal_incoming` rewrite. `duration_us` here should
%% stay in the sub-millisecond range — a regression signals the roll is no
%% longer cheap and the collapse fix is compromised.
emit_seal_roll(T, RecordCount, PackBytes, DurationUs, NewPackId) ->
    telemetry:execute(
        [bondy_mst, page_store, seal_roll],
        #{
            record_count => RecordCount,
            pack_bytes => PackBytes,
            duration_us => DurationUs
        },
        #{instance_id => instance_id(T), new_pack_id => NewPackId}
    ).

%% @private
%% `Meta` is the compaction result map (`do_gc/2`'s second tuple
%% element, post `bytes_freed` enrichment). Converts to telemetry
%% measurements + metadata. The `reason` metadata carries the
%% compaction outcome: `compacted` (rewrote packs), `noop` (nothing
%% to do), or `epoch_unsupported` (integer epoch passed).
emit_gc(T, Meta, DurationUs) ->
    PacksRetired = length(maps:get(retired, Meta, [])),
    PacksCreated =
        case maps:get(new_pack, Meta, undefined) of
            undefined -> 0;
            _ -> 1
        end,
    Reason =
        case Meta of
            #{reason := R} -> R;
            #{compacted := true} -> compacted;
            _ -> noop
        end,
    telemetry:execute(
        [bondy_mst, page_store, gc],
        #{
            pages_kept => maps:get(kept, Meta, 0),
            pages_dropped => maps:get(dropped, Meta, 0),
            packs_retired => PacksRetired,
            packs_created => PacksCreated,
            bytes_freed => maps:get(bytes_freed, Meta, 0),
            duration_us => DurationUs
        },
        #{instance_id => instance_id(T), reason => Reason}
    ).

%% @private
%% Recovery succeeded. `Outcome` is the map returned by
%% `bondy_mst_pack_recovery:recover/3`; we forward the count fields as
%% measurements and the action / state fields as metadata. Emitted
%% even when `actions` is empty (defensive no-op recoveries) so the
%% subscriber can count "open invoked recovery" regardless of outcome.
emit_recovery_ok(InstanceId, Outcome, DurationUs) ->
    telemetry:execute(
        [bondy_mst, page_store, recovery],
        #{
            duration_us => DurationUs,
            bytes_truncated => maps:get(bytes_truncated, Outcome),
            records_recovered => maps:get(records_recovered, Outcome)
        },
        #{
            instance_id => InstanceId,
            result => ok,
            actions => maps:get(actions, Outcome),
            incoming_state_before =>
                maps:get(incoming_state_before, Outcome),
            incoming_state_after =>
                maps:get(incoming_state_after, Outcome)
        }
    ).

%% @private
%% Recovery failed. State_before/after are not known here (the failure
%% may have been a manifest-read error before the reconciliation began);
%% the subscriber gets `unknown` and the failing reason in `result`.
emit_recovery_failed(InstanceId, Reason, DurationUs) ->
    telemetry:execute(
        [bondy_mst, page_store, recovery],
        #{
            duration_us => DurationUs,
            bytes_truncated => 0,
            records_recovered => 0
        },
        #{
            instance_id => InstanceId,
            result => {error, Reason},
            actions => [],
            incoming_state_before => unknown,
            incoming_state_after => unknown
        }
    ).
