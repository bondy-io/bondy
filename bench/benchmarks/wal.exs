Bench.setup()

# Write-Ahead-Log benchmarks. Highly disk-dependent — read with
# context (FS, SSD model, fsync flush behaviour). Each scenario gets
# its own directory under /tmp/bench-wal-<unique> and cleans it up.

base_dir = "/tmp/bondy_mst_bench_wal"
File.rm_rf!(base_dir)
File.mkdir_p!(base_dir)

# Origin is a fixed 16-byte binary.
origin = "bench-origin-16b"

mk_event = fn n ->
  hlc = :bondy_oplog_hlc.encode(1_700_000_000_000 + n, 0)
  key = :bondy_oplog_event.key(hlc, origin, n)
  :bondy_oplog_event.new(key, {:op, n}, :undefined)
end

unique_dir = fn prefix ->
  Path.join(base_dir, prefix <> "-" <> Integer.to_string(System.unique_integer([:positive])))
end

open_wal = fn fsync_mode, prefix ->
  dir = unique_dir.(prefix)
  File.mkdir_p!(dir)
  instance_id = "bench-" <> Path.basename(dir)

  opts = %{
    dir: String.to_charlist(dir),
    origin: origin,
    fsync_mode: fsync_mode,
    max_segment_bytes: 64 * 1024 * 1024
  }

  {:ok, pid} = :bondy_oplog_wal.open(instance_id, opts)

  cleanup = fn ->
    _ = :bondy_oplog_wal.close(pid)
    File.rm_rf!(dir)
  end

  {pid, cleanup}
end

# A counter so each call uses a distinct sequence number.
counter = :atomics.new(1, [{:signed, false}])

next_event = fn ->
  i = :atomics.add_get(counter, 1, 1)
  mk_event.(i)
end

# ----- Append latency, per_write fsync -----

per_write_scenarios = %{
  "wal / append (per_write fsync)" =>
    {fn pid -> :bondy_oplog_wal.append(pid, next_event.()) end,
     before_scenario: fn _ -> open_wal.(:per_write, "perwrite") end,
     after_scenario: fn {_pid, cleanup} -> cleanup.() end},
  "wal / append_batch=16 (per_write fsync)" =>
    {fn pid ->
       batch = for _ <- 1..16, do: next_event.()
       :bondy_oplog_wal.append_batch(pid, batch)
     end,
     before_scenario: fn _ -> open_wal.(:per_write, "perwrite-batch") end,
     after_scenario: fn {_pid, cleanup} -> cleanup.() end}
}

# Benchee passes the input (the {pid, cleanup} tuple) to the scenario
# fn, but the scenarios above only want the pid. Wrap them:
unwrap = fn f ->
  fn {pid, _cleanup} -> f.(pid) end
end

per_write_scenarios =
  Map.new(per_write_scenarios, fn {name, {f, opts}} ->
    {name, {unwrap.(f), opts}}
  end)

Benchee.run(
  per_write_scenarios,
  [inputs: %{"per_write fsync" => :ok}] ++ Bench.benchee_opts("wal_per_write")
)

# ----- Append latency, batched fsync (50 ms / 1 MiB triggers) -----

batched_scenarios = %{
  "wal / append (batched fsync)" =>
    {unwrap.(fn pid -> :bondy_oplog_wal.append(pid, next_event.()) end),
     before_scenario: fn _ -> open_wal.(:batched, "batched") end,
     after_scenario: fn {_pid, cleanup} -> cleanup.() end},
  "wal / append_batch=16 (batched fsync)" =>
    {unwrap.(fn pid ->
       batch = for _ <- 1..16, do: next_event.()
       :bondy_oplog_wal.append_batch(pid, batch)
     end),
     before_scenario: fn _ -> open_wal.(:batched, "batched-batch") end,
     after_scenario: fn {_pid, cleanup} -> cleanup.() end},
  "wal / sync (after appends, batched)" =>
    {unwrap.(fn pid ->
       _ = :bondy_oplog_wal.append(pid, next_event.())
       :bondy_oplog_wal.sync(pid)
     end),
     before_scenario: fn _ -> open_wal.(:batched, "batched-sync") end,
     after_scenario: fn {_pid, cleanup} -> cleanup.() end}
}

Benchee.run(
  batched_scenarios,
  [inputs: %{"batched fsync" => :ok}] ++ Bench.benchee_opts("wal_batched")
)

# ----- Meta ops -----

meta_scenarios = %{
  "wal / info" =>
    {unwrap.(fn pid -> :bondy_oplog_wal.info(pid) end),
     before_scenario: fn _ ->
       {pid, cleanup} = open_wal.(:per_write, "info")
       # Warm with some events so info has something to report.
       Enum.each(1..100, fn _ -> :bondy_oplog_wal.append(pid, next_event.()) end)
       {pid, cleanup}
     end,
     after_scenario: fn {_pid, cleanup} -> cleanup.() end},
  "wal / durable_position" =>
    {unwrap.(fn pid -> :bondy_oplog_wal.durable_position(pid) end),
     before_scenario: fn _ ->
       {pid, cleanup} = open_wal.(:per_write, "durpos")
       Enum.each(1..100, fn _ -> :bondy_oplog_wal.append(pid, next_event.()) end)
       {pid, cleanup}
     end,
     after_scenario: fn {_pid, cleanup} -> cleanup.() end}
}

Benchee.run(
  meta_scenarios,
  [inputs: %{"meta" => :ok}] ++ Bench.benchee_opts("wal_meta")
)

File.rm_rf!(base_dir)
