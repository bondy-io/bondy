defmodule Bench.Concurrency.Report do
  @moduledoc """
  JSON + self-contained HTML reporter for the concurrency harness.

  Writes to `bench/_output/concurrency/<name>/{data.json,index.html}`.
  HTML uses Chart.js from a CDN; the table still renders if offline.
  """

  @chart_js_cdn "https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"

  def write(name, run) do
    dir = Path.join([Bench.output_dir(), "concurrency", name])
    File.mkdir_p!(dir)

    json_path = Path.join(dir, "data.json")
    html_path = Path.join(dir, "index.html")

    File.write!(json_path, Jason.encode!(run, pretty: true))
    File.write!(html_path, render_html(run))

    IO.puts("    report: #{html_path}")
  end

  def print_console(name, stats) do
    IO.puts("\n    ----- #{name} -----")

    rows =
      Enum.map(stats, fn {label, s} ->
        p = s.percentiles_us

        [
          to_string(label),
          fmt_num(s.ops_per_sec),
          fmt_num(s.count),
          fmt_errors(Map.get(s, :errors, 0), Map.get(s, :error_rate, 0.0)),
          fmt_us(p[50]),
          fmt_us(p[90]),
          fmt_us(p[95]),
          fmt_us(p[99]),
          fmt_us(p[99.9])
        ]
      end)

    header = ~w(workload ops/sec total errors p50 p90 p95 p99 p99.9)

    cols =
      [header | rows]
      |> Enum.zip()
      |> Enum.map(fn col_t ->
        col = Tuple.to_list(col_t)
        Enum.map(col, &String.pad_trailing(&1, max_width(col)))
      end)

    cols
    |> Enum.zip()
    |> Enum.map(fn row_t -> row_t |> Tuple.to_list() |> Enum.join("  ") end)
    |> Enum.each(&IO.puts("    " <> &1))
  end

  defp max_width(col), do: Enum.map(col, &String.length/1) |> Enum.max()
  defp fmt_num(n) when is_number(n), do: format_thousands(round(n))
  defp fmt_us(us) when is_number(us), do: :erlang.float_to_binary(us / 1, decimals: 2) <> "µs"
  defp fmt_us(_), do: "-"

  # "5 (1.2%)" when any errors fired, "—" when clean. Highlights cases
  # where the bench is measuring fast-fail churn rather than real work.
  defp fmt_errors(0, _), do: "—"
  defp fmt_errors(n, rate) when is_number(n) and is_number(rate) do
    pct = :erlang.float_to_binary(rate * 100, decimals: 1)
    "#{format_thousands(n)} (#{pct}%)"
  end

  defp format_thousands(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.codepoints()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.join/1)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp render_html(run) do
    labels = run.stats |> Map.keys() |> Enum.sort()

    summary_rows =
      labels
      |> Enum.map(fn label ->
        s = run.stats[label]
        p = s.percentiles_us
        workers = run.workloads[label].worker_count

        """
        <tr>
          <td><code>#{label}</code></td>
          <td>#{workers}</td>
          <td>#{format_thousands(round(s.ops_per_sec))}</td>
          <td>#{format_thousands(s.count)}</td>
          <td>#{fmt_errors(Map.get(s, :errors, 0), Map.get(s, :error_rate, 0.0))}</td>
          <td>#{fmt_us(p[50])}</td>
          <td>#{fmt_us(p[90])}</td>
          <td>#{fmt_us(p[95])}</td>
          <td>#{fmt_us(p[99])}</td>
          <td>#{fmt_us(p[99.9])}</td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    bar_chart_data = chart_throughput_data(run, labels)
    hist_chart_data = chart_histogram_data(run, labels)

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>bondy_mst concurrency · #{run.name}</title>
      <script src="#{@chart_js_cdn}"></script>
      <style>
        body { font: 13px/1.45 -apple-system, sans-serif; max-width: 1100px; margin: 24px auto; padding: 0 16px; color: #1c1f23; }
        h1 { font-size: 18px; margin: 0 0 6px; }
        .meta { color: #666; margin-bottom: 18px; }
        table { border-collapse: collapse; width: 100%; margin-bottom: 22px; }
        th, td { padding: 6px 10px; border-bottom: 1px solid #eaeaea; text-align: left; }
        th { background: #f6f6f6; font-weight: 600; }
        td:nth-child(n+3) { text-align: right; font-variant-numeric: tabular-nums; }
        .chart-wrap { margin: 18px 0; padding: 14px; border: 1px solid #eaeaea; border-radius: 6px; }
        .chart-wrap h3 { margin: 0 0 10px; font-size: 14px; }
      </style>
    </head>
    <body>
      <h1>concurrency · #{run.name}</h1>
      <div class="meta">
        duration #{run.duration_seconds}s · warmup #{run.warmup_ms}ms ·
        total #{format_thousands(run.total_count)} ops ·
        aggregate #{format_thousands(round(run.total_ops_per_sec))} ops/s
      </div>

      <table>
        <thead>
          <tr>
            <th>workload</th>
            <th>workers</th>
            <th>ops/sec</th>
            <th>total</th>
            <th>errors</th>
            <th>p50</th>
            <th>p90</th>
            <th>p95</th>
            <th>p99</th>
            <th>p99.9</th>
          </tr>
        </thead>
        <tbody>
          #{summary_rows}
        </tbody>
      </table>

      <div class="chart-wrap">
        <h3>throughput (ops/sec per workload)</h3>
        <canvas id="bar-chart" height="120"></canvas>
      </div>

      <div class="chart-wrap">
        <h3>latency distribution (count vs. log-bucketed ns)</h3>
        <canvas id="hist-chart" height="160"></canvas>
      </div>

      <script>
        const barCfg = #{Jason.encode!(bar_chart_data)};
        const histCfg = #{Jason.encode!(hist_chart_data)};

        new Chart(document.getElementById("bar-chart"), {
          type: "bar",
          data: barCfg,
          options: {
            indexAxis: "y",
            scales: { x: { type: "logarithmic", title: { text: "ops/sec (log)", display: true } } }
          }
        });

        new Chart(document.getElementById("hist-chart"), {
          type: "line",
          data: histCfg,
          options: {
            scales: {
              x: { title: { text: "latency (ns, log-bucketed midpoint)", display: true }, type: "logarithmic" },
              y: { title: { text: "samples", display: true } }
            },
            elements: { point: { radius: 0 } }
          }
        });
      </script>
    </body>
    </html>
    """
  end

  defp chart_throughput_data(run, labels) do
    %{
      labels: labels,
      datasets: [
        %{
          label: "ops/sec",
          data: Enum.map(labels, &round(run.stats[&1].ops_per_sec)),
          backgroundColor: "rgba(54, 162, 235, 0.55)"
        }
      ]
    }
  end

  defp chart_histogram_data(run, labels) do
    # Reuse the first non-empty workload's bin boundaries as the X axis.
    bins =
      Enum.find_value(labels, fn l -> run.stats[l].histogram end) || []

    xs =
      bins
      |> Enum.map(fn b -> (b.ns_low + b.ns_high) / 2 end)

    datasets =
      Enum.map(labels, fn l ->
        counts = run.stats[l].histogram |> Enum.map(& &1.count)

        %{
          label: to_string(l),
          data: Enum.zip(xs, counts) |> Enum.map(fn {x, y} -> %{x: x, y: y} end),
          fill: false,
          tension: 0.2
        }
      end)

    %{datasets: datasets}
  end
end
