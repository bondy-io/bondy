defmodule Bench.E2E.Hist do
  @moduledoc """
  Log-bucketed atomic histogram, shared by the per-workload op timing
  and the per-stage telemetry capture in `Bench.E2E`.

  Bucket `i` covers `[10^(i/20) ns, 10^((i+1)/20) ns)`. 200 buckets
  span 1ns – 10s with ~12% bucket width — fine for p99 tail estimation
  and cheap enough that telemetry handlers on the hot path stay zero-
  allocation under `:counters` writes.
  """

  @bucket_count 200
  @log_base 20.0

  def new, do: :counters.new(@bucket_count, [:write_concurrency])

  def record(_hist, ns) when not is_integer(ns) or ns <= 0, do: :ok

  def record(hist, ns) do
    idx = bucket_for(ns)
    :counters.add(hist, idx + 1, 1)
  end

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
