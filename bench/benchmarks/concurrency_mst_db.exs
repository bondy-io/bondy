Bench.setup()

# Concurrency tests against `bondy_mst_db`. The read path claims to be
# lock-free (ETS lookup → projection get → overlay merge), so reader
# scaling should approach linear up to the number of schedulers.
# `write_through/4` mutates the cache + overlay; mixing it with reads
# stresses the read-concurrent ETS contract.
#
# Tune duration via DURATION_S env var (default 10s).

duration_s = String.to_integer(System.get_env("DURATION_S", "10"))

unique_ns = fn prefix ->
  String.to_atom(
    "concbench_db_" <> prefix <> "_" <> Integer.to_string(System.unique_integer([:positive]))
  )
end

encode_lww_frame = fn hlc, value ->
  body = :bondy_oplog_crdt_lww_register.encode_state({:set, value, hlc})
  :bondy_oplog_cell_frame.encode(hlc, body)
end

# Register a single-shard substrate, seed it with N cells, and optionally
# pre-warm a fraction into the cache.
make_ctx = fn prefix, n, cache_warmup_fraction ->
  ns = unique_ns.(prefix)

  {:ok, proj_handle} = Bench.ProjectionEts.open(ns, :primary, 0, %{})
  {:ok, cache_handle} = :bondy_oplog_cache_ets.init(ns, :primary, 0, %{})
  overlay = :bondy_oplog_db_overlay.new()

  config = %{
    shard_count: 1,
    cache_adapter: :bondy_oplog_cache_ets,
    cache_handle: cache_handle,
    projection_adapter: Bench.ProjectionEts.__info__(:module),
    projection_handle: proj_handle,
    overlay: overlay,
    fold_module: :undefined,
    crdt_module: :bondy_oplog_crdt_lww_register,
    owner: self()
  }

  :ok = :bondy_mst_db_registry.register(ns, :primary, 0, config)

  hlc_base = 1_700_000_000_000

  entries =
    for i <- 1..n do
      key = "k:" <> String.pad_leading(Integer.to_string(i), 8, "0")
      hlc = hlc_base + i
      frame = encode_lww_frame.(hlc, "v#{i}")
      {key, frame}
    end

  :ok = Bench.ProjectionEts.put_batch(proj_handle, entries)

  n_warm = trunc(n * cache_warmup_fraction)

  if n_warm > 0 do
    Enum.each(1..n_warm, fn i ->
      key = "k:" <> String.pad_leading(Integer.to_string(i), 8, "0")
      val = {:set, "v#{i}", hlc_base + i}
      :ok = :bondy_oplog_cache_ets.put(cache_handle, key, {val, hlc_base + i})
    end)
  end

  %{
    ns: ns,
    n: n,
    cursor: :atomics.new(1, [{:signed, false}]),
    proj_handle: proj_handle,
    cache_handle: cache_handle,
    overlay: overlay
  }
end

cleanup_ctx = fn %{
                   ns: ns,
                   proj_handle: ph,
                   cache_handle: ch,
                   overlay: ov
                 } ->
  :ok = :bondy_mst_db_registry.unregister(ns, :primary, 0)
  :ok = Bench.ProjectionEts.close(ph)
  :ok = :bondy_oplog_cache_ets.close(ch)
  :ok = :bondy_oplog_db_overlay.delete(ov)
end

next_key = fn %{cursor: cursor, n: n} ->
  i = :atomics.add_get(cursor, 1, 1)
  idx = rem(i - 1, n) + 1
  "k:" <> String.pad_leading(Integer.to_string(idx), 8, "0")
end

read_op = fn ctx -> :bondy_mst_db.read(ctx.ns, :primary, next_key.(ctx)) end

# `write_through` requires an event — synthesise one with a fresh HLC.
write_through_op = fn ctx ->
  key = next_key.(ctx)
  i = :atomics.add_get(ctx.cursor, 1, 1)
  hlc = :bondy_oplog_hlc.encode(1_900_000_000_000 + i, 0)
  ev_key = :bondy_oplog_event.key(hlc, "origin-bench-16", i)
  event = :bondy_oplog_event.new(ev_key, {:set, hlc, "wt-v#{i}"}, :undefined)
  :bondy_mst_db.write_through(ctx.ns, :primary, key, event)
end

run_scenario = fn name, n, warm, workloads ->
  Bench.Concurrency.run(
    name: name,
    duration_seconds: duration_s,
    setup: fn -> make_ctx.(name, n, warm) end,
    cleanup: cleanup_ctx,
    workloads: workloads
  )
end

# ----- Readers-only, hot cache (the optimistic case) -----

run_scenario.("mst_db_readers_1", 10_000, 0.99, %{
  readers: %{count: 1, op: read_op}
})
run_scenario.("mst_db_readers_8", 10_000, 0.99, %{
  readers: %{count: 8, op: read_op}
})
run_scenario.("mst_db_readers_16", 10_000, 0.99, %{
  readers: %{count: 16, op: read_op}
})

# ----- Readers-only, cold cache (each miss goes to projection) -----

run_scenario.("mst_db_readers_cold_8", 10_000, 0.0, %{
  readers: %{count: 8, op: read_op}
})

# ----- Mixed read / write_through -----

run_scenario.("mst_db_mixed_8r_1w", 10_000, 0.99, %{
  readers: %{count: 8, op: read_op},
  writers: %{count: 1, op: write_through_op}
})

run_scenario.("mst_db_mixed_8r_8w", 10_000, 0.99, %{
  readers: %{count: 8, op: read_op},
  writers: %{count: 8, op: write_through_op}
})
