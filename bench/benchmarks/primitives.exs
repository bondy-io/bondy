Bench.setup()

# Substrate read-path primitives — HLC, cell-frame codec, db_overlay.
# These run on every read; a microsecond here is a microsecond
# everywhere.

# ----- HLC -----

hlc_a = :bondy_oplog_hlc.new(0)

hlc_scenarios = %{
  "hlc / now (uncontended)" =>
    fn _ -> :bondy_oplog_hlc.now(hlc_a) end,
  "hlc / peek" =>
    fn _ -> :bondy_oplog_hlc.peek(hlc_a) end,
  "hlc / update (peer ahead)" =>
    fn _ ->
      peer = :bondy_oplog_hlc.encode(:erlang.system_time(:millisecond) + 10_000, 0)
      :bondy_oplog_hlc.update(hlc_a, peer)
    end,
  "hlc / encode" =>
    fn _ -> :bondy_oplog_hlc.encode(1_700_000_000_000, 5) end,
  "hlc / decode" =>
    fn _ -> :bondy_oplog_hlc.decode(0x000001A1A2A3A4A5) end
}

Benchee.run(hlc_scenarios, [inputs: %{"hlc" => :ok}] ++ Bench.benchee_opts("primitives_hlc"))

# ----- Cell frame codec -----

cell_inputs = %{
  "body=64B"  => :crypto.strong_rand_bytes(64),
  "body=1KB"  => :crypto.strong_rand_bytes(1024),
  "body=64KB" => :crypto.strong_rand_bytes(64 * 1024)
}

cell_scenarios = %{
  "cell_frame / encode" =>
    fn body -> :bondy_oplog_cell_frame.encode(1_700_000_000_000, body) end,
  "cell_frame / decode" =>
    {fn frame -> :bondy_oplog_cell_frame.decode(frame) end,
     before_scenario: fn body -> :bondy_oplog_cell_frame.encode(1_700_000_000_000, body) end},
  "cell_frame / encoded_size" =>
    fn body -> :bondy_oplog_cell_frame.encoded_size(byte_size(body)) end
}

Benchee.run(
  cell_scenarios,
  [inputs: cell_inputs] ++ Bench.benchee_opts("primitives_cell_frame")
)

# ----- db_overlay -----
#
# Overlay holds events accepted into the WAL but not yet projected.
# `events_for/3` is the per-read scan that merges with the projection.

# Build an overlay populated with N events spread across M cell keys.
build_overlay = fn n_events, n_cells ->
  tab = :bondy_oplog_db_overlay.new()
  origin = "origin-aaaa-bbbb"

  for i <- 1..n_events do
    cell = "cell:#{rem(i, n_cells)}"
    hlc = :bondy_oplog_hlc.encode(1_700_000_000_000 + i, 0)
    key = :bondy_oplog_event.key(hlc, origin, i)
    ev = :bondy_oplog_event.new(key, {:op, i}, :undefined)
    :bondy_oplog_db_overlay.insert(tab, cell, ev)
  end

  tab
end

overlay_inputs = %{
  "1k events / 100 cells" => {1_000, 100},
  "10k events / 100 cells" => {10_000, 100},
  "10k events / 1k cells"  => {10_000, 1_000}
}

overlay_scenarios = %{
  "overlay / insert" =>
    {fn {tab, i} ->
       hlc = :bondy_oplog_hlc.encode(1_900_000_000_000 + i, 0)
       key = :bondy_oplog_event.key(hlc, "origin", i)
       ev = :bondy_oplog_event.new(key, :op, :undefined)
       :bondy_oplog_db_overlay.insert(tab, "cell:hot", ev)
     end,
     before_each: fn {tab, _info} -> {tab, System.unique_integer([:positive])} end,
     before_scenario: fn {n_events, n_cells} -> {build_overlay.(n_events, n_cells), nil} end,
     after_scenario: fn {tab, _} -> :bondy_oplog_db_overlay.delete(tab) end},
  "overlay / events_for (hot cell, after_hlc=0)" =>
    {fn tab -> :bondy_oplog_db_overlay.events_for(tab, "cell:1", 0) end,
     before_scenario: fn {n_events, n_cells} -> build_overlay.(n_events, n_cells) end,
     after_scenario: fn tab -> :bondy_oplog_db_overlay.delete(tab) end},
  "overlay / range (10 cells, after_hlc=0)" =>
    {fn tab -> :bondy_oplog_db_overlay.range(tab, "cell:0", "cell:9", 0) end,
     before_scenario: fn {n_events, n_cells} -> build_overlay.(n_events, n_cells) end,
     after_scenario: fn tab -> :bondy_oplog_db_overlay.delete(tab) end}
}

Benchee.run(
  overlay_scenarios,
  [inputs: overlay_inputs] ++ Bench.benchee_opts("primitives_overlay")
)
