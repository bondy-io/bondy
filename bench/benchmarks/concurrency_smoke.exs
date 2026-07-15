Bench.setup()

# Two workloads (a fast op and a slower op) over 3 seconds — used to
# validate the harness end-to-end before running the heavier benches.

Bench.Concurrency.run(
  name: "smoke",
  duration_seconds: 3,
  warmup_ms: 500,
  setup: fn -> :ok end,
  cleanup: fn _ -> :ok end,
  workloads: %{
    fast: %{count: 2, op: fn _ctx -> :erlang.unique_integer() end},
    slow: %{count: 2, op: fn _ctx -> :timer.sleep(1) end}
  }
)
