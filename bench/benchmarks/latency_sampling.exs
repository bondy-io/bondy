Bench.setup()

# Microbench for the write→readable latency sampling hot path
# (`bondy_oplog_latency`). This isolates the *exact* per-write cost the
# feature adds on the `bondy_db:apply/4` path, so it is not drowned by the
# synchronous `await_apply` that dominates a real write:
#
#   - DISABLED: one `persistent_term` read (`enabled/0`) → skip everything.
#   - ENABLED:  `enabled/0` + two `monotonic_time` reads + one wait-free
#               `bondy_metrics` histogram observe (`record/2`).
#
# The numbers here, divided into the per-write time budget at the bench's
# real throughput, give the % overhead deterministically (no A/B noise).

# The bench may not have started the full app sup tree; ensure the two
# servers the hot path touches are alive (idempotent).
ensure_up = fn mod ->
  case mod.start_link() do
    {:ok, _} -> :ok
    {:error, {:already_started, _}} -> :ok
  end
end

ensure_up.(:bondy_metrics)
ensure_up.(:bondy_oplog_latency)

:ok = :bondy_oplog_latency.set_enabled(true)

# Per-instance histogram label (first touch allocates the counters array;
# warm it so we measure steady-state observe cost, not allocation).
label = "bench-latency-inst-0"
_ = :bondy_oplog_latency.record(label, 100)

scenarios = %{
  # The cost the hot path pays when sampling is DISABLED.
  "gate only — enabled/0 (disabled-path cost)" =>
    fn _ -> :bondy_oplog_latency.enabled() end,

  # The two clock reads that bracket a sampled write.
  "2x monotonic_time(:microsecond)" =>
    fn _ ->
      t0 = :erlang.monotonic_time(:microsecond)
      :erlang.monotonic_time(:microsecond) - t0
    end,

  # The histogram observe (ETS lookup + 3 counters:add).
  "record/2 — histogram observe" =>
    fn id -> :bondy_oplog_latency.record(id, 137) end,

  # The full added cost per write when sampling is ENABLED:
  # gate + two clock reads + observe. (The real write would happen
  # between t0 and record; excluded here to isolate the overhead.)
  "full per-write sample — gate + 2x mono + record (enabled-path cost)" =>
    fn id ->
      if :bondy_oplog_latency.enabled() do
        t0 = :erlang.monotonic_time(:microsecond)
        :bondy_oplog_latency.record(id, :erlang.monotonic_time(:microsecond) - t0)
      end
    end
}

Benchee.run(
  scenarios,
  [inputs: %{"per-instance histogram" => label}] ++
    Bench.benchee_opts("latency_sampling")
)
