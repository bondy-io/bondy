defmodule Bench.E2E.Report do
  @moduledoc """
  JSON + self-contained ECharts dashboard for the E2E benchmark.

  One HTML per scenario under `bench/_output/e2e_pipeline/<name>/
  index.html`. Each page is offline-safe modulo the CDN script tag for
  ECharts; data is embedded directly so the dashboard renders without
  a server.

  The dashboard surfaces the *pipeline* — apply → WAL → applier →
  projection → cache → read — through five linked views:

  - **Sankey** of event flows: how many ops moved between sinks.
  - **Sunburst (sundial)** of latency by stage × percentile band.
  - **Heatmap** of per-shard counts per stage.
  - **Polar bar** (latency rose) with p99 per stage.
  - **Throughput bar** + per-stage **latency histogram** strip.
  """

  @echarts_cdn "https://cdn.jsdelivr.net/npm/echarts@5.5.0/dist/echarts.min.js"

  # Stages we surface in the Sankey/per-stage views, in pipeline order.
  @write_stages [:wal_append, :wal_fsync, :applier_applied, :applier_published]
  @read_stages [:db_core_read, :db_core_range, :db_core_range_all]

  # ----- console summary -----

  def print_console(run) do
    IO.puts("\n    ----- e2e/#{run.name} -----")

    IO.puts(
      "    duration #{run.duration_seconds}s · " <>
        "drain #{Map.get(run, :drain_ms, 0)} ms"
    )

    IO.puts("    total ops (workers): #{fmt_int(run.total_ops)}")

    applier_ops_per_sec = Map.get(run, :applier_ops_per_sec, 0.0)

    IO.puts(
      "    applier ops/s (end-to-end): " <>
        "#{fmt_int(round(applier_ops_per_sec))}"
    )

    # Per-instance (per-shard) write throughput vs the targets: 4,000/s on
    # the durable (leveled) stack, 20,000/s on the ephemeral (ets) stack.
    # The applier counter is the end-to-end applied-event rate; dividing by
    # the shard count gives per-instance throughput. Only meaningful for
    # write-bearing scenarios, so the target check is gated on the name.
    shard_count = max(Map.get(run, :shard_count, 1), 1)
    per_instance = applier_ops_per_sec / shard_count

    IO.puts(
      "    applier ops/s per instance: " <>
        "#{fmt_int(round(per_instance))} (#{shard_count} instance(s))"
    )

    case write_target(run.name) do
      nil ->
        :ok

      {target, profile} ->
        verdict = if per_instance >= target, do: "PASS ✓", else: "BELOW ✗"

        IO.puts(
          "    target (#{profile}): #{fmt_int(target)} writes/s/instance — " <>
            "#{verdict} (#{fmt_int(round(per_instance))})"
        )
    end

    case Map.get(run, :memory) do
      nil ->
        :ok

      %{peak_mb: peak, end_mb: end_mb, delta_mb: delta} ->
        IO.puts(
          "    memory (BEAM, MiB): peak=#{peak} end=#{end_mb} " <>
            "Δ=#{if delta >= 0, do: "+", else: ""}#{delta}"
        )
    end

    IO.puts("    workloads:")

    for {label, s} <- Enum.sort(run.ops) do
      p = s.percentiles_us

      IO.puts(
        "      #{pad(label, 24)} ops/s=#{fmt_int(round(s.ops_per_sec))} " <>
          "p50=#{fmt_us(p[50])} p99=#{fmt_us(p[99])}"
      )
    end

    IO.puts("    stages:")

    for {key, s} <- Enum.sort(run.stages) do
      p = s.percentiles_us

      base =
        "      #{pad(key, 24)} count=#{fmt_int(s.count)} " <>
          "batches=#{fmt_int(s.batches)} " <>
          "p50=#{fmt_us(p[50])} p99=#{fmt_us(p[99])}"

      extra =
        cond do
          s.hits + s.misses > 0 ->
            " hits=#{fmt_int(s.hits)} misses=#{fmt_int(s.misses)}"

          true ->
            ""
        end

      IO.puts(base <> extra)
    end

    :ok
  end

  # Per-instance write-throughput target for a scenario, by profile label
  # in the run name. Only `write_only` scenarios (the canonical pure-write
  # measurement the targets refer to) get a verdict. Durable/leveled stack
  # targets 4,000 writes/s/instance; ephemeral/ets stack targets 20,000.
  defp write_target(name) do
    cond do
      not String.starts_with?(name, "write_only") -> nil
      String.contains?(name, "durable") -> {4_000, "durable / leveled"}
      String.contains?(name, "leveled") -> {4_000, "durable / leveled"}
      String.contains?(name, "ephemeral") -> {20_000, "ephemeral / ets"}
      String.contains?(name, "ets") -> {20_000, "ephemeral / ets"}
      true -> nil
    end
  end

  defp pad(x, n), do: String.pad_trailing(to_string(x), n)
  defp fmt_int(n) when is_integer(n), do: format_thousands(n)
  defp fmt_int(_), do: "-"
  defp fmt_us(nil), do: "-"
  defp fmt_us(us) when is_number(us), do: :erlang.float_to_binary(us / 1, decimals: 2) <> "µs"

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

  # ----- main writers -----

  def write(subdir, run) do
    dir = Path.join([Bench.output_dir(), subdir, run.name])
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "data.json"), Jason.encode!(run, pretty: true))

    File.write!(Path.join(dir, "index.html"), render(run))

    IO.puts("    report: #{Path.join(dir, "index.html")}")
  end

  def write_index(subdir, runs) do
    dir = Path.join([Bench.output_dir(), subdir])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "index.html"), render_index(runs))
    IO.puts("\nindex: #{Path.join(dir, "index.html")}")
  end

  # ----- HTML render -----

  defp render(run) do
    sankey = build_sankey(run)
    sunburst = build_sunburst(run)
    heatmap = build_heatmap(run)
    polar = build_polar(run)
    throughput = build_throughput(run)
    hists = build_histograms(run)
    ops_table = build_ops_table(run)
    stages_table = build_stages_table(run)

    applier_ops_per_sec = Map.get(run, :applier_ops_per_sec, 0.0)
    drain_ms = Map.get(run, :drain_ms, 0)

    payload = %{
      name: run.name,
      duration_s: run.duration_seconds,
      drain_ms: drain_ms,
      shard_count: run.shard_count,
      total_ops: run.total_ops,
      total_ops_per_sec: run.total_ops / run.duration_seconds,
      applier_ops_per_sec: applier_ops_per_sec,
      ops_table: ops_table,
      stages_table: stages_table,
      sankey: sankey,
      sunburst: sunburst,
      heatmap: heatmap,
      polar: polar,
      throughput: throughput,
      hists: hists
    }

    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>bondy_mst e2e · #{run.name}</title>
      <script src="#{@echarts_cdn}"></script>
      <style>
        :root {
          --bg: #0f1419;
          --panel: #161b22;
          --border: #21262d;
          --text: #c9d1d9;
          --muted: #8b949e;
          --accent: #58a6ff;
          --warm: #f78166;
        }
        * { box-sizing: border-box; }
        body {
          margin: 0; padding: 28px;
          background: var(--bg); color: var(--text);
          font: 13px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        }
        h1 { margin: 0 0 4px; font-size: 22px; font-weight: 600; }
        .meta { color: var(--muted); margin-bottom: 22px; }
        .meta b { color: var(--text); font-weight: 600; }
        .grid {
          display: grid;
          grid-template-columns: 1fr 1fr;
          gap: 16px;
        }
        .panel {
          background: var(--panel);
          border: 1px solid var(--border);
          border-radius: 8px;
          padding: 14px 16px 16px;
        }
        .panel.wide { grid-column: 1 / -1; }
        .panel h3 {
          margin: 0 0 4px; font-size: 13px; font-weight: 600;
          color: var(--text); letter-spacing: 0.02em;
        }
        .panel .sub {
          color: var(--muted); font-size: 11px; margin-bottom: 8px;
        }
        .chart { width: 100%; height: 380px; }
        .chart.tall { height: 460px; }
        .chart.short { height: 220px; }
        table { width: 100%; border-collapse: collapse; font-size: 12px; }
        th, td { padding: 5px 8px; border-bottom: 1px solid var(--border); text-align: left; }
        th { color: var(--muted); font-weight: 600; }
        td:nth-child(n+2) { text-align: right; font-variant-numeric: tabular-nums; }
        code { color: var(--accent); }
        .legend { color: var(--muted); font-size: 11px; margin-top: 4px; }
      </style>
    </head>
    <body>
      <h1>e2e · #{run.name}</h1>
      <div class="meta">
        duration <b>#{run.duration_seconds}s</b> ·
        drain <b>#{drain_ms} ms</b> ·
        shards <b>#{run.shard_count}</b> ·
        worker ops <b>#{fmt_int(run.total_ops)}</b> ·
        worker rate <b>#{fmt_int(round(run.total_ops / run.duration_seconds))} ops/s</b> ·
        applier rate <b>#{fmt_int(round(applier_ops_per_sec))} ops/s</b>
      </div>

      <div class="grid">
        <div class="panel wide">
          <h3>Pipeline flow</h3>
          <div class="sub">
            events flowing between sinks across the substrate's
            apply → WAL → applier → projection / read → cache
            paths. Edge width = event count over the run.
          </div>
          <div id="sankey" class="chart tall"></div>
        </div>

        <div class="panel">
          <h3>Latency sundial</h3>
          <div class="sub">
            sunburst over (pipeline → stage → percentile). Outer ring
            shows where the tail latency lives.
          </div>
          <div id="sunburst" class="chart"></div>
        </div>

        <div class="panel">
          <h3>Latency rose</h3>
          <div class="sub">
            polar bars: angle = stage, length = p99 (µs, log).
          </div>
          <div id="polar" class="chart"></div>
        </div>

        <div class="panel wide">
          <h3>Per-shard distribution</h3>
          <div class="sub">
            event count per (stage × shard). Surfaces routing skew —
            ideal is a roughly uniform row across shards.
          </div>
          <div id="heatmap" class="chart"></div>
        </div>

        <div class="panel">
          <h3>Workload throughput</h3>
          <div class="sub">ops/sec per workload</div>
          <div id="throughput" class="chart"></div>
        </div>

        <div class="panel">
          <h3>Per-stage event count</h3>
          <div class="sub">stage counts (log scale)</div>
          <div id="stage-bar" class="chart"></div>
        </div>

        <div class="panel wide">
          <h3>Latency histograms</h3>
          <div class="sub">
            log-bucketed latency distribution per stage and workload.
          </div>
          <div id="hists" class="chart tall"></div>
        </div>

        <div class="panel">
          <h3>Workloads</h3>
          #{ops_table_html(ops_table)}
        </div>

        <div class="panel">
          <h3>Pipeline stages</h3>
          #{stages_table_html(stages_table)}
        </div>
      </div>

      <script>
        const D = #{Jason.encode!(payload)};

        function init(id, opt) {
          const el = document.getElementById(id);
          if (!el) return;
          const chart = echarts.init(el, "dark");
          chart.setOption(opt);
          window.addEventListener("resize", () => chart.resize());
        }

        // -------- Sankey --------
        init("sankey", {
          backgroundColor: "transparent",
          tooltip: { trigger: "item", triggerOn: "mousemove" },
          series: [{
            type: "sankey",
            layout: "none",
            emphasis: { focus: "adjacency" },
            lineStyle: { color: "gradient", curveness: 0.5 },
            label: { color: "#c9d1d9", fontSize: 11 },
            data: D.sankey.nodes,
            links: D.sankey.links
          }]
        });

        // -------- Sunburst --------
        init("sunburst", {
          backgroundColor: "transparent",
          series: [{
            type: "sunburst",
            radius: ["12%", "92%"],
            data: D.sunburst,
            label: { color: "#c9d1d9", fontSize: 10 },
            levels: [
              {},
              { itemStyle: { borderWidth: 2, borderColor: "#0f1419" },
                label: { rotate: "tangential" } },
              { itemStyle: { borderWidth: 1, borderColor: "#0f1419" },
                label: { align: "right" } },
              { itemStyle: { borderWidth: 1, borderColor: "#0f1419" },
                label: { position: "outside", padding: 2 } }
            ]
          }]
        });

        // -------- Heatmap --------
        init("heatmap", {
          backgroundColor: "transparent",
          tooltip: { position: "top" },
          grid: { left: 110, right: 30, top: 20, bottom: 50 },
          xAxis: { type: "category", data: D.heatmap.x,
                   axisLabel: { color: "#c9d1d9", rotate: 25 } },
          yAxis: { type: "category", data: D.heatmap.y,
                   axisLabel: { color: "#c9d1d9" } },
          visualMap: {
            min: 0, max: D.heatmap.max,
            calculable: true, orient: "horizontal",
            left: "center", bottom: 10,
            inRange: { color: ["#0f1419", "#58a6ff", "#f78166"] },
            textStyle: { color: "#c9d1d9" }
          },
          series: [{
            type: "heatmap",
            data: D.heatmap.data,
            label: { show: true, color: "#0f1419", fontSize: 10 }
          }]
        });

        // -------- Polar bar (latency rose) --------
        init("polar", {
          backgroundColor: "transparent",
          tooltip: {},
          polar: {},
          angleAxis: {
            type: "category", data: D.polar.stages,
            axisLabel: { color: "#c9d1d9", fontSize: 10 }
          },
          radiusAxis: {
            type: "log", logBase: 10,
            min: 1,
            axisLabel: { color: "#8b949e" }
          },
          series: [{
            type: "bar",
            coordinateSystem: "polar",
            data: D.polar.values,
            itemStyle: {
              color: function(p) {
                const colors = ["#58a6ff","#79c0ff","#a5d6ff","#f78166","#ffa657","#d2a8ff"];
                return colors[p.dataIndex % colors.length];
              }
            },
            label: { show: false }
          }]
        });

        // -------- Workload throughput --------
        init("throughput", {
          backgroundColor: "transparent",
          tooltip: { trigger: "axis" },
          grid: { left: 90, right: 30, top: 20, bottom: 40 },
          yAxis: { type: "category", data: D.throughput.workloads,
                   axisLabel: { color: "#c9d1d9" } },
          xAxis: { type: "value", name: "ops/s",
                   axisLabel: { color: "#8b949e" } },
          series: [{
            type: "bar", data: D.throughput.values,
            itemStyle: { color: "#58a6ff" },
            label: { show: true, position: "right", color: "#c9d1d9",
                     formatter: p => p.value.toLocaleString() }
          }]
        });

        // -------- Per-stage event count --------
        init("stage-bar", {
          backgroundColor: "transparent",
          tooltip: { trigger: "axis" },
          grid: { left: 100, right: 30, top: 20, bottom: 40 },
          yAxis: { type: "category", data: D.polar.stages,
                   axisLabel: { color: "#c9d1d9" } },
          xAxis: { type: "log", name: "events",
                   axisLabel: { color: "#8b949e" }, min: 1 },
          series: [{
            type: "bar", data: D.polar.counts,
            itemStyle: { color: "#f78166" },
            label: { show: true, position: "right", color: "#c9d1d9",
                     formatter: p => p.value.toLocaleString() }
          }]
        });

        // -------- Histograms (multi-series log-bucketed) --------
        init("hists", {
          backgroundColor: "transparent",
          tooltip: { trigger: "axis" },
          legend: { data: D.hists.series.map(s => s.name),
                    textStyle: { color: "#c9d1d9" },
                    top: 10 },
          grid: { left: 60, right: 30, top: 48, bottom: 50 },
          xAxis: { type: "log", name: "ns (log midpoint)",
                   nameTextStyle: { color: "#8b949e" },
                   axisLabel: { color: "#8b949e" } },
          yAxis: { type: "value", name: "samples",
                   nameTextStyle: { color: "#8b949e" },
                   axisLabel: { color: "#8b949e" } },
          series: D.hists.series.map(s => ({
            name: s.name, type: "line", smooth: true, symbol: "none",
            data: s.points
          }))
        });
      </script>
    </body>
    </html>
    """
  end

  defp ops_table_html(ops_table) do
    rows =
      Enum.map_join(ops_table, "\n", fn r ->
        """
        <tr><td><code>#{r.label}</code></td>
            <td>#{r.workers}</td>
            <td>#{fmt_int(round(r.ops_per_sec))}</td>
            <td>#{fmt_int(r.count)}</td>
            <td>#{fmt_us(r.p50)}</td>
            <td>#{fmt_us(r.p99)}</td>
            <td>#{fmt_us(r.p999)}</td></tr>
        """
      end)

    """
    <table>
      <thead><tr>
        <th>workload</th><th>workers</th><th>ops/s</th><th>total</th>
        <th>p50</th><th>p99</th><th>p99.9</th>
      </tr></thead>
      <tbody>#{rows}</tbody>
    </table>
    """
  end

  defp stages_table_html(stages_table) do
    rows =
      Enum.map_join(stages_table, "\n", fn r ->
        """
        <tr><td><code>#{r.label}</code></td>
            <td>#{fmt_int(r.count)}</td>
            <td>#{if r.hits + r.misses > 0, do: fmt_int(r.hits) <> " / " <> fmt_int(r.misses), else: "—"}</td>
            <td>#{fmt_us(r.p50)}</td>
            <td>#{fmt_us(r.p99)}</td></tr>
        """
      end)

    """
    <table>
      <thead><tr>
        <th>stage</th><th>count</th><th>hits / misses</th>
        <th>p50</th><th>p99</th>
      </tr></thead>
      <tbody>#{rows}</tbody>
    </table>
    """
  end

  # ----- chart data builders -----

  defp build_sankey(run) do
    s = run.stages

    # Edge weights come from telemetry. Each `apply/4` triggers exactly
    # one `wal.append`, one `applier.cell_apply` and one
    # `projection.put`; each `read/4` triggers exactly one
    # `db_core.read`. Workload-label heuristics would miss the mixed
    # scenario, so we count from the substrate instead.
    wal_append = s[:wal_append].count
    wal_fsync = s[:wal_fsync].count
    db_read = s[:db_core_read].count
    db_range = s[:db_core_range].count + s[:db_core_range_all].count
    cache_hits = s[:db_core_read].hits
    cache_misses = s[:db_core_read].misses

    nodes =
      [
        %{name: "client.apply"},
        %{name: "wal.append"},
        %{name: "wal.fsync"},
        %{name: "applier.cell_apply"},
        %{name: "projection.put"},
        %{name: "client.read"},
        %{name: "db_core.read"},
        %{name: "cache.hit"},
        %{name: "cache.miss"},
        %{name: "projection.read"}
      ]
      |> maybe_add_range_nodes(db_range)

    links =
      [
        link("client.apply", "wal.append", wal_append),
        link("wal.append", "wal.fsync", wal_fsync),
        link("wal.append", "applier.cell_apply", wal_append),
        link("applier.cell_apply", "projection.put", wal_append),
        link("client.read", "db_core.read", db_read),
        link("db_core.read", "cache.hit", cache_hits),
        link("db_core.read", "cache.miss", cache_misses),
        link("cache.miss", "projection.read", cache_misses)
      ]
      |> maybe_add_range_links(db_range)
      |> Enum.reject(fn l -> l.value <= 0 end)

    # ECharts requires every node referenced by a link to exist; drop
    # any node that doesn't appear in the final link set.
    referenced =
      MapSet.new(
        Enum.flat_map(links, fn l -> [l.source, l.target] end)
      )

    %{nodes: Enum.filter(nodes, fn n -> n.name in referenced end), links: links}
  end

  defp link(a, b, v), do: %{source: a, target: b, value: v}

  defp maybe_add_range_nodes(nodes, 0), do: nodes
  defp maybe_add_range_nodes(nodes, _), do: nodes ++ [%{name: "client.range"}]

  defp maybe_add_range_links(links, 0), do: links

  defp maybe_add_range_links(links, db_range) do
    # Ranges stream through projection.read on every shard scanned.
    links ++ [link("client.range", "projection.read", db_range)]
  end

  defp build_sunburst(run) do
    # Three rings: pipeline (write/read), stage, percentile band.
    write_children =
      for k <- @write_stages, run.stages[k].count > 0 do
        stage_to_sunburst_node(k, run.stages[k])
      end

    read_children =
      for k <- @read_stages, run.stages[k].count > 0 do
        stage_to_sunburst_node(k, run.stages[k])
      end

    [
      %{
        name: "write path",
        itemStyle: %{color: "#58a6ff"},
        children: write_children
      },
      %{
        name: "read path",
        itemStyle: %{color: "#f78166"},
        children: read_children
      }
    ]
  end

  defp stage_to_sunburst_node(key, s) do
    p = s.percentiles_us

    %{
      name: to_string(key),
      value: s.count,
      children: [
        %{name: "p50 #{fmt_us(p[50])}", value: max(p[50] || 0, 1)},
        %{name: "p90 #{fmt_us(p[90])}", value: max((p[90] || 0) - (p[50] || 0), 1)},
        %{name: "p99 #{fmt_us(p[99])}", value: max((p[99] || 0) - (p[90] || 0), 1)}
      ]
    }
  end

  defp build_heatmap(run) do
    stage_keys = Enum.filter(@write_stages ++ @read_stages, fn k ->
      run.stages[k].count > 0
    end)

    stage_labels = Enum.map(stage_keys, &to_string/1)
    shards = 0..(run.shard_count - 1) |> Enum.to_list()

    {data, mx} =
      Enum.reduce(stage_keys, {[], 0}, fn key, {acc, m} ->
        per_shard = run.stages[key].per_shard
        x_idx = Enum.find_index(stage_keys, &(&1 == key))

        {rows, new_max} =
          Enum.reduce(shards, {[], m}, fn shard, {ax, mx} ->
            v = Map.get(per_shard, shard, 0)
            {[[x_idx, shard, v] | ax], max(mx, v)}
          end)

        {acc ++ rows, new_max}
      end)

    %{
      x: stage_labels,
      y: Enum.map(shards, &"shard #{&1}"),
      data: data,
      max: max(mx, 1)
    }
  end

  defp build_polar(run) do
    stage_keys =
      Enum.filter(@write_stages ++ @read_stages, fn k -> run.stages[k].count > 0 end)

    %{
      stages: Enum.map(stage_keys, &to_string/1),
      values:
        Enum.map(stage_keys, fn k ->
          max(run.stages[k].percentiles_us[99] || 0, 1)
        end),
      counts: Enum.map(stage_keys, fn k -> run.stages[k].count end)
    }
  end

  defp build_throughput(run) do
    ordered = Enum.sort_by(run.ops, fn {l, _} -> to_string(l) end)

    %{
      workloads: Enum.map(ordered, fn {l, _} -> to_string(l) end),
      values: Enum.map(ordered, fn {_, s} -> round(s.ops_per_sec) end)
    }
  end

  defp build_histograms(run) do
    # Two groups of series: per-workload op latency + per-stage telemetry latency.
    op_series =
      for {label, s} <- run.ops do
        %{name: "op/#{label}", points: hist_points(s.histogram)}
      end

    stage_series =
      for {key, s} <- run.stages, s.count > 0 do
        %{name: "stage/#{key}", points: hist_points(s.histogram)}
      end

    %{series: op_series ++ stage_series}
  end

  defp hist_points(bins) do
    bins
    |> Enum.map(fn b ->
      mid = (b.ns_low + b.ns_high) / 2
      [mid, b.count]
    end)
    |> Enum.filter(fn [_, c] -> c > 0 end)
  end

  defp build_ops_table(run) do
    for {label, s} <- Enum.sort(run.ops) do
      %{
        label: to_string(label),
        workers: s.workers,
        ops_per_sec: s.ops_per_sec,
        count: s.count,
        p50: s.percentiles_us[50],
        p99: s.percentiles_us[99],
        p999: s.percentiles_us[99.9]
      }
    end
  end

  defp build_stages_table(run) do
    for {key, s} <- Enum.sort(run.stages) do
      %{
        label: to_string(key),
        count: s.count,
        hits: s.hits,
        misses: s.misses,
        p50: s.percentiles_us[50],
        p99: s.percentiles_us[99]
      }
    end
  end

  # ----- index page over multiple scenarios -----

  defp render_index(runs) do
    rows =
      Enum.map_join(runs, "\n", fn r ->
        applier = Map.get(r, :applier_ops_per_sec, 0.0)
        drain = Map.get(r, :drain_ms, 0)

        """
        <tr>
          <td><a href="#{r.name}/index.html"><code>#{r.name}</code></a></td>
          <td>#{r.duration_seconds}s</td>
          <td>#{drain} ms</td>
          <td>#{r.shard_count}</td>
          <td>#{format_thousands(r.total_ops)}</td>
          <td>#{format_thousands(round(r.total_ops / r.duration_seconds))}</td>
          <td>#{format_thousands(round(applier))}</td>
        </tr>
        """
      end)

    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>bondy_mst · e2e pipeline</title>
      <style>
        body { background: #0f1419; color: #c9d1d9;
               font: 14px/1.5 -apple-system, sans-serif;
               max-width: 980px; margin: 32px auto; padding: 0 16px; }
        h1 { font-size: 22px; margin: 0 0 12px; }
        table { border-collapse: collapse; width: 100%; margin-top: 12px; }
        th, td { padding: 8px 10px; border-bottom: 1px solid #21262d; text-align: left; }
        th { color: #8b949e; font-weight: 600; }
        td:nth-child(n+2) { text-align: right; font-variant-numeric: tabular-nums; }
        a { color: #58a6ff; text-decoration: none; }
        a:hover { text-decoration: underline; }
        .legend { color:#8b949e; font-size: 12px; margin-top: 8px; }
      </style>
    </head>
    <body>
      <h1>e2e pipeline · dashboards</h1>
      <p style="color:#8b949e">
        Each row links to a self-contained ECharts dashboard with Sankey,
        sundial, heatmap and latency views for the named scenario.
      </p>
      <table>
        <thead><tr>
          <th>scenario</th><th>duration</th><th>drain</th><th>shards</th>
          <th>worker ops</th><th>worker ops/s</th><th>applier ops/s</th>
        </tr></thead>
        <tbody>#{rows}</tbody>
      </table>
      <p class="legend">
        <b>worker ops/s</b>: rate at which workers issued ops (append /
        read / mixed). <b>applier ops/s</b>: events the per-instance
        applier fully processed end-to-end, including drain.
      </p>
    </body>
    </html>
    """
  end
end
