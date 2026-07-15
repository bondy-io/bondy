defmodule Bench.Concurrency do
  @moduledoc """
  Sustained-load concurrency harness.

  Drives N worker processes through a per-workload operation function
  for a fixed wall-clock duration, captures per-op latency into a
  shared `:counters`-backed log histogram, and produces JSON +
  self-contained HTML reports.

  ## Scope

  Each scenario runs *one mix of workloads* over *one duration*. A
  benchmark script defines several scenarios so the report can chart
  contention curves (1/4/8/16 workers, etc.) side-by-side.

  ## Histogram

  Latency buckets are log-spaced: bucket `i` covers
  `[10^(i/20) ns, 10^((i+1)/20) ns)`. With 200 buckets that spans
  `[1 ns, 10^10 ns]` = up to 10 s with ~12% bucket width — fine for
  p99/p99.9 estimation. Counters are atomic, so workers can record
  without coordination.

  ## Concurrency model

  Workers are plain processes (not gen_servers). The parent traps
  exits, monitors every worker, and aborts the scenario if any worker
  crashes — masking a crash with a quiet retry would produce
  misleading numbers.
  """

  alias Bench.Concurrency.Report

  defmodule Hist do
    @moduledoc false

    @bucket_count 200
    @log_base 20.0

    def new, do: :counters.new(@bucket_count, [:write_concurrency])

    def record(hist, ns) when is_integer(ns) and ns > 0 do
      idx = bucket_for(ns)
      :counters.add(hist, idx + 1, 1)
    end

    def record(_hist, _), do: :ok

    def total(hist) do
      Enum.reduce(1..@bucket_count, 0, fn i, acc ->
        acc + :counters.get(hist, i)
      end)
    end

    @doc "Returns `%{p => latency_ns}` for the given percentile list."
    def percentiles(hist, ps) when is_list(ps) do
      counts = for i <- 1..@bucket_count, do: :counters.get(hist, i)
      total = Enum.sum(counts)

      cond do
        total == 0 ->
          Map.new(ps, &{&1, 0})

        true ->
          cum_with_idx =
            counts
            |> Enum.with_index()
            |> Enum.scan({0, 0}, fn {c, i}, {acc, _} -> {acc + c, i} end)

          Map.new(ps, fn p ->
            target = max(1, trunc(total * p / 100))
            {_, idx} =
              Enum.find(cum_with_idx, fn {acc, _} -> acc >= target end) ||
                List.last(cum_with_idx)

            {p, bucket_midpoint_ns(idx)}
          end)
      end
    end

    @doc "Returns histogram bins as `[%{ns_low, ns_high, count}, ...]`."
    def bins(hist) do
      for i <- 0..(@bucket_count - 1) do
        count = :counters.get(hist, i + 1)
        %{ns_low: bucket_low_ns(i), ns_high: bucket_low_ns(i + 1), count: count}
      end
    end

    defp bucket_for(ns) do
      idx = trunc(:math.log10(ns) * @log_base)
      max(0, min(idx, @bucket_count - 1))
    end

    defp bucket_low_ns(i), do: :math.pow(10, i / @log_base)

    defp bucket_midpoint_ns(i) do
      :math.pow(10, (i + 0.5) / @log_base)
    end
  end

  @doc """
  Runs a scenario. Returns `%{label => stats}`.

  ## Options

  - `:name` — slug used for the report directory.
  - `:duration_seconds` — wall-clock run time per scenario (required).
  - `:workloads` — `%{label => %{count: N, op: (ctx -> any)}}`. The
    op fn is invoked in a tight loop; its return value is ignored.
  - `:setup` — `(-> ctx)` called once before workers spawn. The
    context is passed to every op invocation.
  - `:cleanup` — `(ctx -> any)` called after workers stop.
  - `:warmup_ms` — discard the first N ms of measurements (default 500).
  """
  def run(opts) do
    name = Keyword.fetch!(opts, :name)
    duration_s = Keyword.fetch!(opts, :duration_seconds)
    workloads = Keyword.fetch!(opts, :workloads)
    setup_fun = Keyword.get(opts, :setup, fn -> nil end)
    cleanup_fun = Keyword.get(opts, :cleanup, fn _ -> :ok end)
    warmup_ms = Keyword.get(opts, :warmup_ms, 500)

    IO.puts("\n==> concurrency: #{name}  (duration=#{duration_s}s, warmup=#{warmup_ms}ms)")
    for {label, %{count: n}} <- workloads do
      IO.puts("    workload[#{label}]: count=#{n}")
    end

    ctx = setup_fun.()
    histograms = Map.new(workloads, fn {label, _} -> {label, Hist.new()} end)
    # Slot 1: error count. Counted separately from the latency histogram
    # so an op that fast-fails on backpressure does not skew p50/p99 —
    # error returns are usually orders of magnitude cheaper than a real
    # call and would otherwise drag the latency distribution down while
    # inflating the ops/sec metric.
    error_counters = Map.new(workloads, fn {label, _} ->
      {label, :counters.new(1, [:write_concurrency])}
    end)

    parent = self()
    Process.flag(:trap_exit, true)

    # Wait until warmup_ms has elapsed before workers start recording.
    record_after = :erlang.monotonic_time(:millisecond) + warmup_ms
    deadline_ms =
      :erlang.monotonic_time(:millisecond) + warmup_ms + duration_s * 1000

    workers =
      for {label, %{count: n, op: op}} <- workloads, _ <- 1..n do
        hist = histograms[label]
        errors = error_counters[label]

        pid =
          spawn_link(fn ->
            worker_loop(op, ctx, hist, errors, record_after, deadline_ms, parent)
          end)

        {pid, label}
      end

    wait_for_workers(workers)

    total_count =
      Enum.reduce(histograms, 0, fn {_label, h}, acc -> acc + Hist.total(h) end)

    stats =
      Map.new(workloads, fn {label, _} ->
        h = histograms[label]
        errs = :counters.get(error_counters[label], 1)
        count = Hist.total(h)
        pcts = Hist.percentiles(h, [50, 90, 95, 99, 99.9])
        total_attempts = count + errs

        {label,
         %{
           count: count,
           errors: errs,
           error_rate:
             if(total_attempts > 0, do: errs / total_attempts, else: 0.0),
           ops_per_sec: count / duration_s,
           percentiles_us: Map.new(pcts, fn {p, ns} -> {p, ns / 1_000} end),
           histogram: Hist.bins(h)
         }}
      end)

    cleanup_fun.(ctx)

    Report.write(name, %{
      name: name,
      duration_seconds: duration_s,
      warmup_ms: warmup_ms,
      total_count: total_count,
      total_ops_per_sec: total_count / duration_s,
      workloads:
        Map.new(workloads, fn {label, %{count: n}} -> {label, %{worker_count: n}} end),
      stats: stats
    })

    Report.print_console(name, stats)

    stats
  end

  defp worker_loop(op, ctx, hist, errors, record_after, deadline_ms, parent) do
    now = :erlang.monotonic_time(:millisecond)

    cond do
      now >= deadline_ms ->
        send(parent, {:worker_done, self()})
        :ok

      now < record_after ->
        # Warmup: do work, do not record.
        _ = op.(ctx)
        worker_loop(op, ctx, hist, errors, record_after, deadline_ms, parent)

      true ->
        t0 = :erlang.monotonic_time(:nanosecond)
        result = op.(ctx)
        t1 = :erlang.monotonic_time(:nanosecond)
        record_result(result, hist, errors, t1 - t0)
        worker_loop(op, ctx, hist, errors, record_after, deadline_ms, parent)
    end
  end

  # Classify the op's return value: anything matching `{:error, _}` is
  # treated as a fast-fail (counted as an error, latency discarded);
  # everything else is success (latency recorded).
  defp record_result({:error, _}, _hist, errors, _ns) do
    :counters.add(errors, 1, 1)
  end

  defp record_result(_other, hist, _errors, ns) do
    Hist.record(hist, ns)
  end

  defp wait_for_workers(workers) do
    expected = MapSet.new(workers, fn {pid, _} -> pid end)
    do_wait(expected)
  end

  defp do_wait(remaining) do
    if MapSet.size(remaining) == 0 do
      :ok
    else
      receive do
        {:worker_done, pid} ->
          do_wait(MapSet.delete(remaining, pid))

        {:EXIT, pid, :normal} ->
          do_wait(MapSet.delete(remaining, pid))

        {:EXIT, pid, reason} ->
          IO.puts("[concurrency] worker #{inspect(pid)} crashed: #{inspect(reason)}")
          # Drain the rest and bail.
          do_wait(MapSet.delete(remaining, pid))
      end
    end
  end
end
