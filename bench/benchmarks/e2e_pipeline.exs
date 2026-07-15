Bench.setup()

# End-to-end pipeline benchmark.
#
# Provisions a multi-shard `bondy_oplog_core` substrate against
# `Bench.ProjectionEts` (in-memory) and `:bondy_oplog_cache_ets`,
# then starts a `bondy_oplog` instance per shard with the substrate
# wired as the applier's `cell_apply_target`. Writes flow:
#
#     client → :bondy_oplog.append({cell_apply, B, K, Op})
#            → WAL → applier.drain
#            → cell kernel apply_op (op-based CRDT, PR-Z)
#            → ProjectionEts.put_batch
#
# Reads flow through the substrate: cache-fast, projection on miss
# (which populates the cache).
#
# TARGETS (per instance / per shard): 4,000 writes/s on the durable stack
# (leveled projection + pack MST + per_write fsync) and 20,000 writes/s on
# the ephemeral stack (ets projection + ets MST + batched fsync). The
# console summary prints the per-instance applier rate and PASS/BELOW vs
# these targets for `write_only` scenarios.
#
# COMPACTION (COMPACT=true, default): periodic compaction bounds the MST so
# the run is steady-state-production-realistic (without it the MST grows
# unbounded and `mst_install` dominates — an artifact). Use long durations
# (DURATION_S=300..600) to measure sustained throughput. See the compaction
# block near the bottom.
#
# Tune via env: DURATION_S (default 10), WARMUP_MS (default 500),
# SHARDS (default 4), PREPOPULATE (default 10000), WRITERS (default 4),
# READERS (default 8).

duration_s = String.to_integer(System.get_env("DURATION_S", "10"))
warmup_ms = String.to_integer(System.get_env("WARMUP_MS", "500"))
shard_count = String.to_integer(System.get_env("SHARDS", "4"))
prepopulate = String.to_integer(System.get_env("PREPOPULATE", "10000"))
writers = String.to_integer(System.get_env("WRITERS", "4"))
readers = String.to_integer(System.get_env("READERS", "8"))

# MST snapshot-store backend per oplog instance. Default `ets` matches
# the in-memory shape the bench was originally written against. Set
# `MST_BACKEND=pack` to route every shard's MST snapshot through the
# durable `bondy_mst_pack_store` (rooted under `/tmp/bondy_mst_bench_pack_e2e/`)
# — the production wiring when paired with the leveled projection.
mst_backend =
  case System.get_env("MST_BACKEND", "ets") do
    "pack" -> :pack
    _ -> :ets
  end

pack_root = "/tmp/bondy_mst_bench_pack_e2e/#{:os.getpid()}"

# WAL durability mode for the oplog instances the bench starts. Each
# shard's WAL is a separate gen_server with its own fsync cadence;
# `per_write` fsyncs after every batch frame, `batched` lets the WAL
# coalesce multiple frames into one fsync (`batched_fsync_interval` /
# `batched_fsync_bytes` thresholds). `per_write` is the default for
# durability; switch to `batched` to compare against the
# `concurrency_wal` bench's high-throughput numbers.
wal_fsync_mode =
  case System.get_env("WAL_FSYNC", "per_write") do
    "batched" -> :batched
    _ -> :per_write
  end

# Writer batch size. `1` = one event per `append/2` call (the original
# bench shape). Anything > 1 routes the writer through
# `append_many/2`, which lets the WAL coalesce multiple events into a
# single frame and a single fsync — the combination needed to
# approach the `wal_batched_batch16_8` 1.2M events/s number.
batch_size = String.to_integer(System.get_env("BATCH_SIZE", "1"))

# Applier→instance demand cap. Default 16. Set to 2 to demonstrate
# the gate firing aggressively (writer should backpressure quickly);
# set to a very large value to disable the cap and reproduce the
# pre-flow-control behaviour.
max_in_flight = String.to_integer(System.get_env("MAX_IN_FLIGHT", "16"))

# A2 — coarser applier batching. The applier coalesces consecutive WAL
# frames into one batch until this many events accumulate, amortising the
# pack-store spine rebuild + leveled put_batch. `1` reproduces the pre-A2
# one-frame-per-apply behaviour (the A/B baseline arm); the lib default is
# 256.
apply_batch_max_events =
  String.to_integer(System.get_env("APPLY_BATCH_MAX_EVENTS", "256"))

# A4 — instance-side install coalescing. The instance merges up to this
# many queued `install_local_batch` casts into one MST put_batch,
# amortising the spine rebuild. `1` disables it; lib default is 16.
install_coalesce_max =
  String.to_integer(System.get_env("INSTALL_COALESCE_MAX", "16"))

# A3 — applier OldValue frame-cache. When `true`, the applier serves the
# per-event OldValue read from a private write-through cache (a hit skips
# the projection `get/3`, the dominant per-event cost on the durable
# stack). `false` (the A/B baseline arm) reproduces the pre-A3 read path.
# Lib default is false.
oldstate_cache = System.get_env("OLDSTATE_CACHE", "false") in ["1", "true"]

# Fused-writer rollout, Step 5 validation. When `true`, ephemeral (ets MST)
# instances run in `fused` mode: the instance drains its own WAL and installs
# into BOTH the projection and the MST inline, with NO separate applier — the
# H1 collapse that lifts single-shard ephemeral throughput past the
# ~11k/instance applier↔instance install round-trip. Only honoured for ets
# MST profiles (the `fused ⇒ ephemeral` invariant); ignored for pack/leveled.
fused? = System.get_env("FUSED", "false") in ["1", "true"]

# Ephemeral ETS WAL (task #50). When `mem`, a fused ephemeral instance uses the
# in-memory `bondy_oplog_wal_mem` backend instead of the disk WAL: events live
# in an ETS ordered_set and the fused drain reads them the instant they are
# inserted, dropping the WAL-durability LATENCY (the ~42%-util floor that the
# fused writer alone could not clear). Only honoured for a fused ets-MST
# instance (the supervisor gates `mem` on `fused`); ignored otherwise.
wal_backend =
  case System.get_env("WAL_BACKEND", "disk") do
    "mem" -> :mem
    _ -> :disk
  end

IO.puts(
  "[e2e] config: shards=#{shard_count} writers=#{writers} readers=#{readers} " <>
    "fsync=#{wal_fsync_mode} batch_size=#{batch_size} mst=#{mst_backend} " <>
    "apply_batch_max_events=#{apply_batch_max_events} " <>
    "install_coalesce_max=#{install_coalesce_max} " <>
    "oldstate_cache=#{oldstate_cache} fused=#{fused?} wal_backend=#{wal_backend} " <>
    "dirty_io_schedulers=#{:erlang.system_info(:dirty_io_schedulers)}"
)

# Backends to compare. `BACKENDS=ets,leveled` runs each scenario
# twice; `BACKENDS=ets` runs only the in-memory path. `leveled` is
# skipped automatically when the bench profile hasn't been compiled
# yet (so a plain `mix run` on a fresh checkout still works).
# A value in BACKENDS is either a legacy projection-only swap (`ets`,
# `leveled` — honour the global MST_BACKEND / WAL_FSYNC envs, unchanged)
# or a full durability *stack profile* that bundles projection + MST
# snapshot store + WAL fsync mode, so `ephemeral` vs `durable` measures
# the whole stack rather than only the projection adapter:
#
#   ephemeral → ets projection + in-memory (ets) MST + batched fsync.
#               The `durability => ephemeral` table: nothing durable,
#               reconverges from peers, so it carries no per-write fsync
#               cost. This is the "ets-backed ephemeral table".
#   durable   → leveled projection + pack-store MST + per_write fsync.
#               The fully-durable, leveled-backed production stack: the
#               queryable store is leveled, the MST snapshot is the
#               durable pack-store, and every event is fsynced. A durable
#               backend gates the applier on the bootstrap lifecycle, so
#               the per-instance config sets `seed: true` (genesis peer,
#               no cluster to bootstrap from) — see `make_ctx`.
#
# `BACKENDS=ephemeral,durable` runs the head-to-head ephemeral-vs-leveled
# comparison. Legacy `ets` / `leveled` keep projection-only semantics.
profile_for = fn
  :ephemeral ->
    %{label: "ephemeral", projection: :ets, mst: :ets, fsync: :batched}

  :durable ->
    %{label: "durable", projection: :leveled, mst: :pack, fsync: :per_write}

  :ets ->
    %{label: "ets", projection: :ets, mst: mst_backend, fsync: wal_fsync_mode}

  :leveled ->
    %{label: "leveled", projection: :leveled, mst: mst_backend, fsync: wal_fsync_mode}
end

profiles =
  System.get_env("BACKENDS", "ets,leveled")
  |> String.split(",", trim: true)
  |> Enum.map(&String.to_atom/1)
  |> Enum.map(profile_for)
  |> Enum.filter(fn p ->
    p.projection != :leveled or Bench.leveled_available?() or
      (IO.puts(
         "[e2e] skipping #{p.label} profile (needs the leveled adapter; " <>
           "run `rebar3 as bench compile`)"
       ) && false)
  end)

IO.puts(
  "[e2e] profiles: " <>
    Enum.map_join(profiles, ", ", fn p ->
      "#{p.label}(proj=#{p.projection},mst=#{p.mst},fsync=#{p.fsync})"
    end)
)

bucket = ""

# Op-based CRDT module the cells are projected through (PR-Z: the fold
# family is retired; every table is a native `bondy_oplog_crdt`). Default
# `lww_register` — the register the original bench used, now its byte-
# identical native twin. Override with `CRDT=g_set` / `pn_counter` to bench
# a different commutative type, or `CRDT=aw_map` for the tier_2 add-wins map.
# The write op (`build_cell_op`) is `{:set, hlc, v}`, which lww_register
# consumes directly; for a different CRDT, adjust `build_cell_op`.
crdt_label = System.get_env("CRDT", "lww_register")

crdt_module =
  case crdt_label do
    "lww_register" -> :bondy_oplog_crdt_lww_register
    "g_set" -> :bondy_oplog_crdt_g_set
    "pn_counter" -> :bondy_oplog_crdt_pn_counter
    "g_counter" -> :bondy_oplog_crdt_g_counter
    "aw_map" -> :bondy_oplog_crdt_aw_map
    other -> String.to_atom("bondy_oplog_crdt_" <> other)
  end

# The oplog INSTANCE needs a `fold_module` LABEL on its start opts so its
# compaction guard (`do_compact_async`) treats it as compaction-eligible —
# production `bondy_db:start_shard_instance/9` pins this. It only gates the
# guard + chooses the compaction path; the applier's per-instance fold
# projection is gated on the REGISTRY `fold_module` (kept `:undefined` here),
# so this adds NO per-event fold work. Worker `crdt_module` stays undefined →
# the projection-backed catalogue (truncate-only) path.
instance_fold_label = String.to_atom(crdt_label)

IO.puts("[e2e] crdt_module=#{crdt_module} (op-based)")

leveled_root = "/tmp/bondy_mst_bench_leveled/#{:os.getpid()}"

# When true, swap `:bondy_oplog_cache_ets` for `Bench.CacheNoop` so
# every read falls through to the projection adapter. Isolates raw
# ETS vs leveled projection-read performance — the default cache
# absorbs ~99.8% of reads with a 10k key space, so without bypass the
# bench measures the cache, not the backend.
bypass_cache? = System.get_env("BYPASS_CACHE", "false") in ["1", "true"]

{cache_adapter, cache_label} =
  if bypass_cache? do
    {Bench.CacheNoop, "_nocache"}
  else
    {:bondy_oplog_cache_ets, ""}
  end

unique_ns = fn prefix ->
  String.to_atom(
    "bench_e2e_" <>
      prefix <> "_" <> Integer.to_string(System.unique_integer([:positive]))
  )
end

unique_prefix = fn prefix ->
  "bench-e2e-" <>
    prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))
end

# Same routing the substrate uses internally.
shard_for = fn key -> :erlang.phash2({bucket, key}, shard_count) end

# Per-shard projection handle/bookie/etc. for a given backend.
# Returns `{adapter_module, projection_handle, bookie_or_nil}`. The
# bookie pid is held in ctx so cleanup can shut it down.
open_projection = fn
  :ets, ns, shard ->
    {:ok, ph} = Bench.ProjectionEts.open(ns, :primary, shard, %{})
    {Bench.ProjectionEts, ph, nil}

  :leveled, ns, shard ->
    # Per-shard leveled Bookie. Each bookie owns its own
    # journal/ledger files under leveled_root/<scenario>/<shard>.
    # Small per-shard cache + journal to keep the bench
    # initialisation snappy; the goal is to measure steady-state, not
    # cold-start.
    dir =
      Path.join([leveled_root, Atom.to_string(ns), Integer.to_string(shard)])

    File.mkdir_p!(dir)

    {:ok, bookie} =
      :leveled_bookie.book_start([
        {:root_path, String.to_charlist(dir)},
        {:max_journalsize, 1_000_000_000},
        {:cache_size, 2_000},
        {:sync_strategy, :none},
        # head_only=with_lookup required by bondy_db_projection_leveled
        # (PR-PS-15b). Enables book_mput (atomic batched writes) and
        # book_headonly (ledger-only point reads).
        {:head_only, :with_lookup}
      ])

    {:ok, ph} =
      Bench.ProjectionLeveled.open(ns, :primary, shard, %{bookie: bookie})

    {Bench.ProjectionLeveled, ph, bookie}
end

close_projection = fn
  Bench.ProjectionEts, ph, _ ->
    Bench.ProjectionEts.close(ph)

  Bench.ProjectionLeveled, ph, bookie ->
    Bench.ProjectionLeveled.close(ph)
    # `book_close/1` flushes the ledger cache + closes journal cleanly.
    # Used in production by riak_kv; safe to call at scenario teardown.
    _ = :leveled_bookie.book_close(bookie)
    :ok
end

# Provision N shards: projection + cache + overlay + registry +
# oplog instance, each instance's applier targets its shard.
make_ctx = fn prefix, profile ->
  ns = unique_ns.(prefix)
  inst_prefix = unique_prefix.(prefix)

  shards =
    for shard <- 0..(shard_count - 1), into: %{} do
      {adapter, ph, bookie} = open_projection.(profile.projection, ns, shard)
      {:ok, ch} = cache_adapter.init(ns, :primary, shard, %{})
      ov = :bondy_oplog_db_overlay.new()

      config = %{
        shard_count: shard_count,
        cache_adapter: cache_adapter,
        cache_handle: ch,
        projection_adapter: adapter,
        projection_handle: ph,
        overlay: ov,
        # The op-based kernel: `crdt_module` drives the cell projection
        # (`bondy_oplog_cell_kernel:from_modules/2` selects `{crdt, _}`).
        # `fold_module` is unset (the fold path is retired).
        fold_module: :undefined,
        crdt_module: crdt_module,
        owner: self()
      }

      :ok = :bondy_oplog_core_registry.register(ns, :primary, shard, config)

      instance_id = inst_prefix <> "-" <> Integer.to_string(shard)

      # MST backend per oplog instance. For `pack`, every shard gets
      # its own subdir under `pack_root` so a parallel scenario does
      # not collide with another. The pack-store backend reads
      # `storage_path` via the same path strategy other persistent
      # backends use; `dir` is derived per-instance internally.
      mst_opts =
        case profile.mst do
          :pack ->
            File.mkdir_p!(pack_root)
            # A durable backend (storage_path set) puts the instance in
            # the `pre_bootstrap` lifecycle — the applier refuses to drain
            # the WAL until it bootstraps from a peer. This bench has no
            # cluster, so each shard is a genesis peer: `seed: true` skips
            # the bootstrap gate (matches
            # test/bondy_db_pack_leveled_e2e_test.erl). The in-memory ets
            # path has no storage_path and so no gate.
            base = %{
              backend: :bondy_mst_pack_store,
              storage_path: pack_root,
              seed: true
            }

            # Optional seal-threshold overrides (P2 seal-stall sweep). The
            # pack store reads these from `backend_options` (see
            # bondy_oplog_instance:backend_opts/3) — top-level keys are NOT
            # forwarded. `auto_seal_bytes` (default 16MB) is usually the
            # binding threshold, not `auto_seal_records` (default 10k).
            seal =
              [auto_seal_records: "AUTO_SEAL_RECORDS", auto_seal_bytes: "AUTO_SEAL_BYTES"]
              |> Enum.map(fn {k, env} -> {k, System.get_env(env)} end)
              |> Enum.reject(fn {_k, v} -> is_nil(v) end)
              |> Map.new(fn {k, v} -> {k, String.to_integer(v)} end)

            # Seal driver: `SEAL_MODE=async` moves the pack-store seal off the
            # instance's commit critical path (bondy_oplog_instance drives
            # `maybe_roll_for_seal` + a monitored worker), the overload-collapse
            # fix. Default (`sync`) seals inline on `put` as before. Lets the
            # writer sweep A/B sync-collapse vs async-plateau.
            seal =
              case System.get_env("SEAL_MODE") do
                "async" -> Map.put(seal, :seal_mode, :async)
                "sync" -> Map.put(seal, :seal_mode, :sync)
                _ -> seal
              end

            if map_size(seal) == 0,
              do: base,
              else: Map.put(base, :backend_options, seal)

          :ets ->
            %{}
        end

      # Fused mode is honoured only for the in-memory (ets) MST — the
      # `fused ⇒ ephemeral` invariant. The supervisor reads this `fused`
      # flag to omit the applier child; the instance drains + installs
      # inline. `applier.cell_apply_target` is still passed (the fused
      # instance builds its cell_apply_ctx from it).
      instance_fused? = fused? and profile.mst == :ets

      # The in-memory WAL backend is gated on fused (the supervisor only
      # dispatches the mem reader on the fused drain). A non-fused or
      # non-ephemeral instance keeps the disk WAL.
      instance_wal_backend = if instance_fused?, do: wal_backend, else: :disk

      {:ok, _sup} =
        :bondy_oplog.start_instance(
          instance_id,
          Map.merge(mst_opts, %{
            fused: instance_fused?,
            wal_backend: instance_wal_backend,
            # The cell projection runs through the registry entry's
            # `crdt_module` (cell_apply_target → cell_apply_ctx). The
            # per-instance fold projection is unused by this bench.
            #
            # `fold_module` LABEL marks the instance compaction-eligible
            # (matches production `bondy_db:start_shard_instance/9`); without
            # it `do_compact_async` returns `{error, no_crdt_module}` and the
            # MST grows unbounded. It does NOT enable the per-instance fold
            # projection (that's gated on the registry fold_module, undefined).
            fold_module: instance_fold_label,
            fsync_mode: profile.fsync,
            max_install_in_flight: max_in_flight,
            install_coalesce_max: install_coalesce_max,
            applier: %{
              cell_apply_target: {ns, :primary, shard},
              apply_batch_max_events: apply_batch_max_events,
              oldstate_cache: oldstate_cache
            }
          })
        )

      {shard,
       %{
         instance_id: instance_id,
         projection_adapter: adapter,
         projection: ph,
         bookie: bookie,
         cache: ch,
         overlay: ov
       }}
    end

  %{
    ns: ns,
    bucket: bucket,
    profile: profile,
    shards: shards,
    instance_prefix: inst_prefix,
    n_keys: prepopulate,
    write_cursor: :atomics.new(1, [{:signed, false}]),
    read_cursor: :atomics.new(1, [{:signed, false}])
  }
end

# Per-shard contiguous key block — used by both `populate` and the
# bench-time ops. Each writer/reader worker hashes its `self()` to
# pick a shard once and stays there for the run, so its calls all hit
# the same WAL → one frame per `append_many`, one fsync.
shard_key = fn shard, offset ->
  pad =
    offset
    |> Integer.to_string()
    |> String.pad_leading(8, "0")

  "s" <> Integer.to_string(shard) <> ":k:" <> pad
end

worker_shard = fn ctx -> :erlang.phash2(self(), map_size(ctx.shards)) end

keys_per_shard = max(div(prepopulate, shard_count), 1)

# Pre-populate every shard's owned keyspace so reads have data and
# writes do read-modify-write against the same cells (not pure
# inserts). Each shard gets `keys_per_shard` cells with keys shaped
# like `"s<shard>:k:<padded-offset>"` so the bench-time ops can
# regenerate them without hashing.
populate = fn ctx, n ->
  hlc_base = :erlang.system_time(:nanosecond)
  per_shard = max(div(n, map_size(ctx.shards)), 1)

  Enum.each(ctx.shards, fn {shard, %{instance_id: id}} ->
    Enum.each(1..per_shard, fn offset ->
      key = shard_key.(shard, offset)
      hlc = hlc_base + shard * per_shard + offset
      event = {:set, hlc, "v" <> Integer.to_string(offset)}
      _ = :bondy_oplog.append(id, {:cell_apply, ctx.bucket, key, event})
    end)
  end)

  Enum.each(ctx.shards, fn {_s, %{instance_id: id}} ->
    :ok = :bondy_oplog.await_apply(id, 60_000)
  end)
end

cleanup = fn ctx ->
  Enum.each(ctx.shards, fn {shard,
                            %{
                              instance_id: id,
                              projection_adapter: adapter,
                              projection: ph,
                              bookie: bookie,
                              cache: ch,
                              overlay: ov
                            }} ->
    # Stop the oplog instance first so no further appends reach the
    # applier while we tear down its sinks. Then close the cache /
    # projection / leveled bookie, then drop the overlay ETS table.
    _ = :bondy_oplog.stop_instance(id)
    _ = :bondy_oplog_core_registry.unregister(ctx.ns, :primary, shard)
    _ = close_projection.(adapter, ph, bookie)
    _ = cache_adapter.close(ch)
    _ = :bondy_oplog_db_overlay.delete(ov)
  end)

  pid = :os.getpid()

  case File.ls("/tmp/bondy_oplog_wal/#{pid}") do
    {:ok, names} ->
      Enum.each(names, fn n ->
        if String.starts_with?(n, ctx.instance_prefix) do
          _ = File.rm_rf("/tmp/bondy_oplog_wal/#{pid}/#{n}")
        end
      end)

    _ ->
      :ok
  end

  # Drop leveled per-NS dirs. The bookie has closed by now; remove the
  # files so the 5 GB cap in feedback_cleanup_tmp_after_tests is not
  # tripped across repeated bench runs.
  if ctx.profile.projection == :leveled do
    _ =
      File.rm_rf(
        Path.join(leveled_root, Atom.to_string(ctx.ns))
      )
  end

  # Drop the pack-store dirs for this scenario. The bondy_mst app is
  # still running, but every oplog instance using this NS has been
  # stopped above; the on-disk manifests + sealed packs are safe to
  # rm. Same /tmp budget concern as the leveled cleanup above.
  if ctx.profile.mst == :pack do
    _ = File.rm_rf(pack_root)
  end
end

# ----- ops -----
#
# Writes are fire-and-forget: `append/2` enqueues into the WAL and
# returns once the frame is durable; the per-instance applier drains
# the WAL asynchronously into the projection. The pipeline-drain
# barrier (`barrier_fun`) runs after the workers stop and before stats
# collection, so every appended event has been applied by the time
# the `applier_applied` telemetry counter is read.

build_cell_op = fn ctx, key ->
  hlc = :erlang.system_time(:nanosecond)
  event = {:set, hlc, "v" <> Integer.to_string(hlc)}
  {:cell_apply, ctx.bucket, key, event}
end

# LATENCY_SAMPLING=on wraps each single-event append with the exact
# write→readable sampling sequence `bondy_db:apply/4` adds when the
# feature is enabled (two `monotonic_time` reads + one `bondy_metrics`
# histogram observe via `bondy_oplog_latency:record/2`), using the real
# per-shard instance_id. Run the same scenario `off` then `on` for the
# A/B. The bench's native write path is `bondy_oplog:append` (it bypasses
# the bondy_db facade), so this is the only way to exercise the hook here.
# Only the single-event (batch_size<=1) path is instrumented — the A/B
# uses batch=1. Default off keeps existing runs byte-identical.
latency_sampling? = System.get_env("LATENCY_SAMPLING", "off") in ["1", "true", "on"]
_ = if latency_sampling?, do: :bondy_oplog_latency.set_enabled(true)

write_op =
  cond do
    batch_size <= 1 and latency_sampling? ->
      fn ctx ->
        shard = worker_shard.(ctx)
        i = :atomics.add_get(ctx.write_cursor, 1, 1)
        offset = rem(i - 1, keys_per_shard) + 1
        key = shard_key.(shard, offset)
        instance_id = ctx.shards[shard].instance_id
        t0 = :erlang.monotonic_time(:microsecond)
        r = :bondy_oplog.append(instance_id, build_cell_op.(ctx, key))
        _ =
          :bondy_oplog_latency.record(
            instance_id,
            :erlang.monotonic_time(:microsecond) - t0
          )
        r
      end

    batch_size <= 1 ->
      fn ctx ->
        shard = worker_shard.(ctx)
        i = :atomics.add_get(ctx.write_cursor, 1, 1)
        offset = rem(i - 1, keys_per_shard) + 1
        key = shard_key.(shard, offset)
        instance_id = ctx.shards[shard].instance_id
        :bondy_oplog.append(instance_id, build_cell_op.(ctx, key))
      end

    true ->
    fn ctx ->
      shard = worker_shard.(ctx)
      base = :atomics.add_get(ctx.write_cursor, 1, batch_size)
      first_offset = base - batch_size + 1

      items =
        for n <- 0..(batch_size - 1) do
          offset = rem(first_offset - 1 + n, keys_per_shard) + 1
          {build_cell_op.(ctx, shard_key.(shard, offset)), :undefined}
        end

      instance_id = ctx.shards[shard].instance_id
      :bondy_oplog.append_many(instance_id, items)
    end
  end

read_op = fn ctx ->
  shard = worker_shard.(ctx)
  i = :atomics.add_get(ctx.read_cursor, 1, 1)
  offset = rem(i - 1, keys_per_shard) + 1
  key = shard_key.(shard, offset)
  :bondy_oplog_core.read(ctx.ns, :primary, ctx.bucket, key)
end

mixed_op = fn ctx ->
  Enum.each(1..7, fn _ -> _ = read_op.(ctx) end)
  Enum.each(1..3, fn _ -> _ = write_op.(ctx) end)
  :ok
end

# Drain every shard's applier — used as `barrier_fun`. Each shard is
# awaited sequentially since `await_apply` is now event-driven
# (instance pid call, not 5 ms-poll loop) and the shard count is
# small.
drain_shards = fn ctx ->
  Enum.each(ctx.shards, fn {_shard, %{instance_id: id}} ->
    :ok = :bondy_oplog.await_apply(id, 120_000)
  end)
end

# ----- scenario runner -----
#
# `Bench.E2E.run/1` attaches telemetry handlers using the namespace
# and instance_prefix the run is filtered by. Those values only exist
# after `make_ctx` runs. We materialise the context up-front, pass
# it through to the harness's `setup`, and bind workload ops to a
# captured `ctx` so workers don't have to re-resolve it.

run_scenario = fn base_name, profile, workload_specs ->
  name = "#{base_name}_#{profile.label}#{cache_label}"
  ctx = make_ctx.(name, profile)
  populate.(ctx, prepopulate)

  workloads =
    Map.new(workload_specs, fn {label, %{count: c, op: op}} ->
      {label, %{count: c, op: fn _ignored -> op.(ctx) end}}
    end)

  Bench.E2E.run(
    name: name,
    duration_seconds: duration_s,
    warmup_ms: warmup_ms,
    shard_count: shard_count,
    instance_prefix: ctx.instance_prefix,
    namespace: ctx.ns,
    setup: fn -> ctx end,
    cleanup: cleanup,
    workloads: workloads,
    barrier: drain_shards
  )
end

# ----- scenarios -----
#
# Each base scenario is run once per backend. The scenario name is
# suffixed with `_<backend>` so the index page lists e.g.
# `write_only_w4_ets` and `write_only_w4_leveled` side-by-side.

scenarios = [
  {"write_only_w#{writers}", %{
    "writer" => %{count: writers, op: write_op}
  }},
  {"read_only_w#{readers}", %{
    "reader" => %{count: readers, op: read_op}
  }},
  # Single-worker-doing-both shape — realistic for a client whose
  # business logic is read-then-write on one connection.
  {"mixed_70r_30w_w#{writers + readers}", %{
    "mixed" => %{count: writers + readers, op: mixed_op}
  }},
  # Concurrent R/W with dedicated worker pools — isolates "do reads
  # affect writes?". Readers and writers are separate processes
  # against the same shards.
  {"concurrent_rw_r#{readers}w#{writers}", %{
    "reader" => %{count: readers, op: read_op},
    "writer" => %{count: writers, op: write_op}
  }}
]

# Optional SCENARIOS env filter — comma-separated name prefixes.
# `SCENARIOS=write_only` keeps just write_only. `SCENARIOS=write_only,mixed`
# keeps both. Empty / unset = all four scenarios (default behaviour).
# Used by the applier-pipeline-residual stability runs that want to
# isolate one scenario for long-duration variance assessment.
scenarios =
  case System.get_env("SCENARIOS") do
    nil ->
      scenarios

    "" ->
      scenarios

    csv ->
      prefixes =
        csv
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      filtered =
        Enum.filter(scenarios, fn {base_name, _} ->
          Enum.any?(prefixes, fn p -> String.starts_with?(base_name, p) end)
        end)

      if filtered == [] do
        raise "SCENARIOS=#{csv} matched no scenarios (available: " <>
                Enum.map_join(scenarios, ", ", fn {n, _} -> n end) <> ")"
      end

      filtered
  end

# ----- compaction (production-realistic MST bounding) -----
#
# Without compaction the MST grows unbounded over the run and `mst_install`
# (the spine rebuild) comes to dominate throughput — a bench artifact, not a
# production limit (production compacts to bound the MST). `COMPACT=true`
# (default) periodically advances each shard's stability frontier via a
# self-peer ack, then compacts — keeping the MST small like a steady-state
# production node. The gc_scheduler's built-in `default_trigger` compacts
# but CANNOT advance the frontier in a single-node bench (no peer acks a
# root), so it truncates nothing; the explicit self-peer here is what makes
# compaction effective. `COMPACT_INTERVAL_MS` tunes the cadence (smaller =
# smaller MST + faster installs + more compaction overhead).
compact? = System.get_env("COMPACT", "true") in ["1", "true"]

compact_interval_ms =
  String.to_integer(System.get_env("COMPACT_INTERVAL_MS", "1000"))

if compact? do
  compact_trigger = fn instance_id ->
    try do
      # Read the live root via the instance pid + gen_server `root_hash` — NO
      # `await_apply` overlay barrier (which, like `bondy_oplog.compact`'s
      # former barrier, blocks 5s under sustained writes and stalls compaction).
      # The frontier only needs a recently published root, not a
      # read-your-writes one. (`bondy_oplog_instance.root_hash/1` with a BINARY
      # reads the registry mst field, which is transiently :undefined; the pid
      # form reads the instance's live state.)
      case :bondy_oplog_registry.instance_pid(instance_id) do
        :undefined ->
          :ok

        pid ->
          case :bondy_oplog_instance.root_hash(pid) do
            :undefined ->
              :ok

            root ->
              :bondy_oplog_peer_state.record_sync_complete(
                {:peer, :bench_compact},
                instance_id,
                root
              )

              :bondy_oplog_peer_state.sync()
              _ = :bondy_oplog.compact(instance_id)
              :ok
          end
      end
    catch
      _kind, _reason -> :ok
    end
  end

  :ok = :bondy_oplog_gc_scheduler.set_trigger(compact_trigger)
  :ok = :bondy_oplog_gc_scheduler.set_interval_ms(compact_interval_ms)

  IO.puts(
    "[e2e] compaction ENABLED (self-peer frontier, interval=#{compact_interval_ms}ms)"
  )
else
  :ok = :bondy_oplog_gc_scheduler.set_trigger(:undefined)
  IO.puts("[e2e] compaction DISABLED (MST grows unbounded — install-bound)")
end

runs =
  for profile <- profiles,
      {base_name, specs} <- scenarios,
      do: run_scenario.(base_name, profile, specs)

Bench.E2E.write_index(runs)

IO.puts("\n[e2e] open bench/_output/e2e_pipeline/index.html for the dashboards.")
