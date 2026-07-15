Bench.setup()

# Instrumented profile: drives append_many_8w_bs100 and breaks down
# install_local_batch handler time into install / publish / evict.
# Requires the instrumentation hooks in bondy_oplog_instance:handle_cast.

duration_s = String.to_integer(System.get_env("DURATION_S", "10"))

ref = :atomics.new(5, [{:signed, false}])
:persistent_term.put({:bondy_oplog_instance, :instrument}, ref)

id = "prof-inst-" <> Integer.to_string(System.unique_integer([:positive]))
{:ok, _} = :bondy_oplog.start_instance(id)

for i <- 1..1_000, do: :bondy_oplog.append(id, {:warmup, i})
:ok = :bondy_oplog.await_apply(id, 30_000)

# Reset the counters AFTER warmup so we only measure steady-state.
for slot <- 1..5 do
  v = :atomics.get(ref, slot)
  if v > 0, do: :atomics.sub(ref, slot, v)
end

parent = self()
deadline = :erlang.monotonic_time(:millisecond) + duration_s * 1000

# 8 workers driving 100-event batches with await_apply every 32 batches.
workers = for _ <- 1..8 do
  state = :atomics.new(1, [{:signed, false}])
  spawn_link(fn ->
    batch = for i <- 1..100, do: {{:am, i}, :undefined}
    loop = fn loop ->
      now = :erlang.monotonic_time(:millisecond)
      if now >= deadline do
        send(parent, {:done, self()})
      else
        _ = :bondy_oplog.append_many(id, batch)
        n = :atomics.add_get(state, 1, 1)
        if rem(n, 32) == 0, do: _ = :bondy_oplog.await_apply(id, 60_000)
        loop.(loop)
      end
    end
    loop.(loop)
  end)
end

Enum.each(workers, fn _ ->
  receive do
    {:done, _} -> :ok
  after
    60_000 -> :timeout
  end
end)

install_us = :atomics.get(ref, 1)
publish_us = :atomics.get(ref, 2)
evict_us   = :atomics.get(ref, 3)
casts      = :atomics.get(ref, 4)
events     = :atomics.get(ref, 5)

total_us = install_us + publish_us + evict_us

IO.puts("\n=== install_local_batch breakdown ===")
IO.puts("  casts:           #{casts}")
IO.puts("  events:          #{events}  (avg #{Float.round(events / max(casts, 1), 1)} per cast)")
IO.puts("  install_us:      #{install_us}  (avg #{Float.round(install_us / max(casts, 1), 1)}µs per cast, #{Float.round(install_us / max(events, 1), 2)}µs per event)")
IO.puts("  publish_us:      #{publish_us}  (avg #{Float.round(publish_us / max(casts, 1), 1)}µs per cast)")
IO.puts("  evict_us:        #{evict_us}  (avg #{Float.round(evict_us / max(casts, 1), 1)}µs per cast, #{Float.round(evict_us / max(events, 1), 2)}µs per event)")
IO.puts("  cast handler:    #{Float.round(total_us / max(casts, 1), 1)}µs total per cast")
IO.puts("")
IO.puts("  install:  #{Float.round(install_us / max(total_us, 1) * 100, 1)}%")
IO.puts("  publish:  #{Float.round(publish_us / max(total_us, 1) * 100, 1)}%")
IO.puts("  evict:    #{Float.round(evict_us / max(total_us, 1) * 100, 1)}%")

:persistent_term.erase({:bondy_oplog_instance, :instrument})
:ok = :bondy_oplog.stop_instance(id)
