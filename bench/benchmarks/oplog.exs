Bench.setup()

# End-to-end oplog instance benchmarks. Each scenario starts a fresh
# instance, pre-populates it to a target size, then times the public
# API against the warmed instance. Cleanup stops the instance.

unique_id = fn prefix ->
  "bench-" <> prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))
end

start_instance = fn id ->
  {:ok, _pid} = :bondy_oplog.start_instance(id)
  id
end

stop_instance = fn id -> :ok = :bondy_oplog.stop_instance(id) end

# Drive `n` synchronous appends and wait for the applier to land them.
populate = fn id, n ->
  Enum.each(1..n, fn i -> _ = :bondy_oplog.append(id, {:op, i}) end)
  :ok = :bondy_oplog.await_apply(id)
  :ok
end

# Capture every event key so the read scenarios have a sample to pick from.
populate_with_keys = fn id, n ->
  keys =
    for i <- 1..n do
      :bondy_oplog.append(id, {:op, i})
    end

  :ok = :bondy_oplog.await_apply(id)
  List.to_tuple(keys)
end

# ----- Inputs -----

inputs = %{
  "size=1k"  => 1_000,
  "size=10k" => 10_000
}

# ----- Append throughput (write path) -----

append_scenarios = %{
  "oplog / append (no await)" =>
    {fn id -> _ = :bondy_oplog.append(id, :op) end,
     before_scenario: fn n ->
       id = start_instance.(unique_id.("append"))
       :ok = populate.(id, n)
       id
     end,
     after_scenario: fn id -> stop_instance.(id) end},
  "oplog / append + await_apply" =>
    {fn id ->
       _ = :bondy_oplog.append(id, :op)
       :ok = :bondy_oplog.await_apply(id)
     end,
     before_scenario: fn n ->
       id = start_instance.(unique_id.("await"))
       :ok = populate.(id, n)
       id
     end,
     after_scenario: fn id -> stop_instance.(id) end},
  "oplog / append_many (size=16)" =>
    {fn id ->
       items = for _ <- 1..16, do: {:op, :rand.uniform(1_000_000)}
       :bondy_oplog.append_many(id, items)
     end,
     before_scenario: fn n ->
       id = start_instance.(unique_id.("many"))
       :ok = populate.(id, n)
       id
     end,
     after_scenario: fn id -> stop_instance.(id) end}
}

Benchee.run(append_scenarios, [inputs: inputs] ++ Bench.benchee_opts("oplog_append"))

# ----- Read path -----

read_scenarios = %{
  "oplog / get (random key)" =>
    {fn %{id: id, keys: keys, n: n, cursor: cursor} ->
       idx = :atomics.add_get(cursor, 1, 1)
       k = elem(keys, rem(idx - 1, n))
       :bondy_oplog.get(id, k)
     end,
     before_scenario: fn n ->
       id = start_instance.(unique_id.("get"))
       keys = populate_with_keys.(id, n)
       %{id: id, keys: keys, n: n, cursor: :atomics.new(1, [{:signed, false}])}
     end,
     after_scenario: fn %{id: id} -> stop_instance.(id) end},
  "oplog / size" =>
    {fn id -> :bondy_oplog.size(id) end,
     before_scenario: fn n ->
       id = start_instance.(unique_id.("size"))
       :ok = populate.(id, n)
       id
     end,
     after_scenario: fn id -> stop_instance.(id) end},
  "oplog / root_hash" =>
    {fn id -> :bondy_oplog.root_hash(id) end,
     before_scenario: fn n ->
       id = start_instance.(unique_id.("root"))
       :ok = populate.(id, n)
       id
     end,
     after_scenario: fn id -> stop_instance.(id) end},
  "oplog / fold_range (full)" =>
    {fn id ->
       :bondy_oplog.fold_range(
         id,
         :bondy_oplog_event.min_key(),
         :bondy_oplog_event.max_key_for_hlc(:bondy_oplog_hlc.encode(:erlang.system_time(:millisecond) + 60_000, 0)),
         fn _e, acc -> acc + 1 end,
         0
       )
     end,
     before_scenario: fn n ->
       id = start_instance.(unique_id.("fold"))
       :ok = populate.(id, n)
       id
     end,
     after_scenario: fn id -> stop_instance.(id) end}
}

Benchee.run(read_scenarios, [inputs: inputs] ++ Bench.benchee_opts("oplog_read"))
