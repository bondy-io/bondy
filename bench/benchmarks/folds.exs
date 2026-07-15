Bench.setup()

# CRDT primitives — the hottest per-event functions in the system, now the
# native operation-based `bondy_oplog_crdt` modules (PR-Z retired the
# state-based fold family). Measures the eager write step `apply_op/3`, the
# group interpreter `interpret_cog/2` (the Strong-Eventual-Consistency
# primitive run on read overlays + compaction), and the state codec.
#
# (Filename kept as `folds.exs` so the `bench-folds` recipe still resolves;
# the content is the CRDT catalogue, not the retired folds.)

# Logical part is 16-bit, so use the physical part to spread events.
hlc = fn n -> :bondy_oplog_hlc.encode(1_700_000_000_000 + n, 0) end

# An event dot `{Hlc, Origin, Seq}` — what `apply_op/3` reads for HLC, and
# (counters) per-Origin Seq dedup.
key = fn h, origin, seq -> :bondy_oplog_event.key(h, origin, seq) end
ev = fn h, origin, seq, op -> :bondy_oplog_event.new(key.(h, origin, seq), op, %{}) end

lww = :bondy_oplog_crdt_lww_register
gset = :bondy_oplog_crdt_g_set
pnc = :bondy_oplog_crdt_pn_counter
awm = :bondy_oplog_crdt_aw_map

# A pre-built lww state with 1k absorbed writes (for the codec + a realistic
# apply_op-onto-warm-state shape).
lww_warm =
  Enum.reduce(1..1000, lww.init(), fn n, s ->
    lww.apply_op(s, {:set, hlc.(n), "v#{n}"}, key.(hlc.(n), "node-a", n))
  end)

# A pre-built g_set / aw_map with 1k entries for the COG (group-interpret)
# and apply-onto-warm benches.
gset_warm =
  Enum.reduce(1..1000, gset.init(), fn n, s ->
    gset.apply_op(s, {:add, "e#{n}"}, key.(hlc.(n), "node-a", n))
  end)

# 1k events for the interpret_cog (group fold) bench — the SEC primitive.
lww_events = for n <- 1..1000, do: ev.(hlc.(n), "node-a", n, {:set, hlc.(n), "v#{n}"})

# A precomputed dot/op for the hot single-op benches (so the bench measures
# apply_op, not term construction).
k_new = key.(hlc.(100_000), "node-b", 1)
k_old = key.(hlc.(5), "node-b", 1)

apply_scenarios = %{
  # lww_register — the most common cell type.
  "lww / apply_op (newer wins, warm)" =>
    fn _ -> lww.apply_op(lww_warm, {:set, hlc.(2_000), "new"}, k_new) end,
  "lww / apply_op (older rejected)" =>
    fn _ -> lww.apply_op(lww_warm, {:set, hlc.(5), "old"}, k_old) end,
  # g_set — grow-only set membership.
  "g_set / apply_op (add new, set=1k)" =>
    {fn {s, i} -> gset.apply_op(s, {:add, "new-#{i}"}, k_new) end,
     before_each: fn s -> {s, System.unique_integer([:positive])} end,
     before_scenario: fn _ -> gset_warm end},
  # pn_counter — per-Origin {count, maxseq}; a fresh dot each call.
  "pn_counter / apply_op (inc, fresh dot)" =>
    {fn {s, i} -> pnc.apply_op(s, {:inc, 1}, key.(hlc.(i), "node-a", i)) end,
     before_each: fn s -> {s, System.unique_integer([:positive])} end,
     before_scenario: fn _ -> pnc.init() end},
  # aw_map (tier_2) — observed-remove map; apply_op/4 with a causal context.
  "aw_map / apply_op (put, tier_2)" =>
    {fn {s, i} ->
       ctx = awm.context_of(s)
       awm.apply_op(s, {:put, "k#{rem(i, 100)}", "v#{i}"}, key.(hlc.(i), "node-a", i), ctx)
     end,
     before_each: fn s -> {s, System.unique_integer([:positive])} end,
     before_scenario: fn _ -> awm.init() end}
}

Benchee.run(
  apply_scenarios,
  [inputs: %{"apply_op" => :ok}] ++ Bench.benchee_opts("crdt_apply_op")
)

# ----- interpret_cog (the SEC group-interpret primitive) -----

cog_scenarios = %{
  "lww / interpret_cog (1k events)" =>
    fn _ -> lww.interpret_cog(lww_events, lww.init()) end
}

Benchee.run(
  cog_scenarios,
  [inputs: %{"interpret_cog" => :ok}] ++ Bench.benchee_opts("crdt_interpret_cog")
)

# ----- Encoding/decoding (state codec hot path) -----

lww_bytes = lww.encode_state(lww_warm)
gset_bytes = gset.encode_state(gset_warm)

codec_scenarios = %{
  "lww / encode_state (1k absorbed)" =>
    fn _ -> lww.encode_state(lww_warm) end,
  "lww / decode_state" =>
    fn _ -> lww.decode_state(lww_bytes) end,
  "g_set / encode_state (1k)" =>
    fn _ -> gset.encode_state(gset_warm) end,
  "g_set / decode_state" =>
    fn _ -> gset.decode_state(gset_bytes) end
}

Benchee.run(
  codec_scenarios,
  [inputs: %{"codec" => :ok}] ++ Bench.benchee_opts("crdt_codec")
)
