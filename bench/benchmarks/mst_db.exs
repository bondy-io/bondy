Bench.setup()

# `bondy_mst_db` substrate — the production read path. Each scenario
# registers a single-shard namespace, populates it through the
# projection adapter (the test-only ETS variant), warms or cools the
# cache as required, and times the public API.

# ----- Helpers -----

unique = fn prefix ->
  String.to_atom(prefix <> Integer.to_string(System.unique_integer([:positive])))
end

# Encode a fold state into a projection frame for direct seeding.
encode_lww_frame = fn hlc, value ->
  body =
    :bondy_oplog_crdt_lww_register.encode_state({:set, value, hlc})

  :bondy_oplog_cell_frame.encode(hlc, body)
end

# Register one shard for {ns, primary, 0} backed by the test projection
# adapter and the production ETS cache adapter. Returns the ns atom
# (so the caller can issue reads) plus a cleanup function.
register_shard = fn ns, opts ->
  {:ok, proj_handle} = Bench.ProjectionEts.open(ns, :primary, 0, %{})
  {:ok, cache_handle} = :bondy_oplog_cache_ets.init(ns, :primary, 0, %{})
  overlay = :bondy_oplog_db_overlay.new()
  fold_mod = Map.get(opts, :fold_module, :bondy_oplog_fold_lww_register)
  shard_count = Map.get(opts, :shard_count, 1)

  proj_mod = Bench.ProjectionEts.__info__(:module)

  config = %{
    shard_count: shard_count,
    cache_adapter: :bondy_oplog_cache_ets,
    cache_handle: cache_handle,
    projection_adapter: proj_mod,
    projection_handle: proj_handle,
    overlay: overlay,
    fold_module: fold_mod,
    owner: self()
  }

  :ok = :bondy_mst_db_registry.register(ns, :primary, 0, config)

  cleanup = fn ->
    :ok = :bondy_mst_db_registry.unregister(ns, :primary, 0)
    :ok = Bench.ProjectionEts.close(proj_handle)
    :ok = :bondy_oplog_cache_ets.close(cache_handle)
    :ok = :bondy_oplog_db_overlay.delete(overlay)
  end

  {ns, proj_handle, cache_handle, overlay, cleanup}
end

# Seed N cells into the projection, optionally pre-warming a fraction
# of them into the cache.
seed = fn proj_handle, cache_handle, n, cache_warmup_fraction ->
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
      :ok = :bondy_oplog_cache_ets.put(cache_handle, key, {{:set, "v#{i}", hlc_base + i}, hlc_base + i})
    end)
  end

  :ok
end

# Round-robin key generator from a counter; keeps reads spread.
make_key_picker = fn n ->
  cursor = :atomics.new(1, [{:signed, false}])

  fn ->
    idx = :atomics.add_get(cursor, 1, 1)
    i = rem(idx - 1, n) + 1
    "k:" <> String.pad_leading(Integer.to_string(i), 8, "0")
  end
end

# ----- Inputs: (N keys, cache hit-rate target) -----

inputs = %{
  "10k / cache=cold (0%)"  => {10_000, 0.0},
  "10k / cache=warm (50%)" => {10_000, 0.5},
  "10k / cache=hot (99%)"  => {10_000, 0.99}
}

# ----- Scenarios -----

scenarios = %{
  "mst_db / read" =>
    {fn %{ns: ns, pick: pick} -> :bondy_mst_db.read(ns, :primary, pick.()) end,
     before_scenario: fn {n, warm} ->
       ns = unique.("mst_db_read_")
       {^ns, proj, cache, _ov, cleanup} = register_shard.(ns, %{})
       :ok = seed.(proj, cache, n, warm)
       %{ns: ns, pick: make_key_picker.(n), cleanup: cleanup}
     end,
     after_scenario: fn %{cleanup: cleanup} -> cleanup.() end},
  "mst_db / read_batch (size=16)" =>
    {fn %{ns: ns, pick: pick} ->
       reads = for _ <- 1..16, do: {ns, :primary, pick.()}
       :bondy_mst_db.read_batch(reads, %{})
     end,
     before_scenario: fn {n, warm} ->
       ns = unique.("mst_db_batch_")
       {^ns, proj, cache, _ov, cleanup} = register_shard.(ns, %{})
       :ok = seed.(proj, cache, n, warm)
       %{ns: ns, pick: make_key_picker.(n), cleanup: cleanup}
     end,
     after_scenario: fn %{cleanup: cleanup} -> cleanup.() end},
  "mst_db / range (limit=64)" =>
    {fn %{ns: ns} ->
       :bondy_mst_db.range(ns, :primary, {"k:00000100", "k:00000200"}, %{limit: 64})
     end,
     before_scenario: fn {n, warm} ->
       ns = unique.("mst_db_range_")
       {^ns, proj, cache, _ov, cleanup} = register_shard.(ns, %{})
       :ok = seed.(proj, cache, n, warm)
       %{ns: ns, cleanup: cleanup}
     end,
     after_scenario: fn %{cleanup: cleanup} -> cleanup.() end},
  "mst_db / ensure_fresh (1 ns, infinity)" =>
    {fn %{ns: ns} -> :bondy_mst_db.ensure_fresh([ns], :infinity) end,
     before_scenario: fn {n, warm} ->
       ns = unique.("mst_db_fresh_")
       {^ns, proj, cache, _ov, cleanup} = register_shard.(ns, %{})
       :ok = seed.(proj, cache, n, warm)
       %{ns: ns, cleanup: cleanup}
     end,
     after_scenario: fn %{cleanup: cleanup} -> cleanup.() end}
}

Benchee.run(scenarios, [inputs: inputs] ++ Bench.benchee_opts("mst_db"))
