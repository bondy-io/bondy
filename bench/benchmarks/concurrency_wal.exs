Bench.setup()

# Concurrent WAL appenders against a single writer process. With
# `per_write` fsync, the writer is fsync-bound so adding callers only
# grows the queue. With `batched` fsync, the writer can amortise
# multiple appends across one fsync, so throughput should scale until
# the fsync interval saturates.
#
# Tune duration via DURATION_S env var (default 8s).

duration_s = String.to_integer(System.get_env("DURATION_S", "8"))

base_dir = "/tmp/bondy_mst_bench_wal_conc"
File.rm_rf!(base_dir)
File.mkdir_p!(base_dir)

origin = "bench-origin-16b"

mk_event = fn ctx ->
  i = :atomics.add_get(ctx.cursor, 1, 1)
  hlc = :bondy_oplog_hlc.encode(1_700_000_000_000 + i, 0)
  key = :bondy_oplog_event.key(hlc, origin, i)
  :bondy_oplog_event.new(key, {:op, i}, :undefined)
end

open_wal = fn fsync_mode, prefix ->
  dir =
    Path.join(base_dir, prefix <> "-" <> Integer.to_string(System.unique_integer([:positive])))

  File.mkdir_p!(dir)
  instance_id = "bench-" <> Path.basename(dir)

  opts = %{
    dir: String.to_charlist(dir),
    origin: origin,
    fsync_mode: fsync_mode,
    max_segment_bytes: 64 * 1024 * 1024
  }

  {:ok, pid} = :bondy_oplog_wal.open(instance_id, opts)

  %{pid: pid, dir: dir, cursor: :atomics.new(1, [{:signed, false}])}
end

cleanup_wal = fn %{pid: pid, dir: dir} ->
  _ = :bondy_oplog_wal.close(pid)
  File.rm_rf!(dir)
end

append_op = fn ctx ->
  :bondy_oplog_wal.append(ctx.pid, mk_event.(ctx))
end

append_batch16_op = fn ctx ->
  batch = for _ <- 1..16, do: mk_event.(ctx)
  :bondy_oplog_wal.append_batch(ctx.pid, batch)
end

run_scenario = fn name, fsync_mode, prefix, workloads ->
  Bench.Concurrency.run(
    name: name,
    duration_seconds: duration_s,
    setup: fn -> open_wal.(fsync_mode, prefix) end,
    cleanup: cleanup_wal,
    workloads: workloads
  )
end

# ----- per_write fsync, varying writers -----

run_scenario.("wal_perwrite_1", :per_write, "perwrite", %{
  writers: %{count: 1, op: append_op}
})

run_scenario.("wal_perwrite_4", :per_write, "perwrite", %{
  writers: %{count: 4, op: append_op}
})

run_scenario.("wal_perwrite_16", :per_write, "perwrite", %{
  writers: %{count: 16, op: append_op}
})

# ----- batched fsync, varying writers -----

run_scenario.("wal_batched_1", :batched, "batched", %{
  writers: %{count: 1, op: append_op}
})

run_scenario.("wal_batched_4", :batched, "batched", %{
  writers: %{count: 4, op: append_op}
})

run_scenario.("wal_batched_16", :batched, "batched", %{
  writers: %{count: 16, op: append_op}
})

# ----- batched fsync, batch_size=16 — checks whether batched batching
# saturates fsync cadence -----

run_scenario.("wal_batched_batch16_8", :batched, "bbatch", %{
  writers: %{count: 8, op: append_batch16_op}
})

File.rm_rf!(base_dir)
