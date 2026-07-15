Bench.setup()

# Profile probe for the `append_many_8w_bs100` ceiling.
#
# Runs the same workload as the bench (8 writers × 100-event batches,
# await_apply every 32 batches) for a fixed duration. Snapshots the
# Erlang runtime once per second during steady state. Reports:
#
#   - per-scheduler utilisation
#   - top processes by reductions delta
#   - mailbox sizes for {WAL, applier, instance} of the target subtree
#   - overlay size (events) and admit-counter pressure
#   - WAL writer's gen_server's reductions-per-second
#
# The goal is to identify which process / resource is the actual
# wall-clock ceiling at ~14k events/sec.

duration_s = String.to_integer(System.get_env("DURATION_S", "10"))
batch_size = String.to_integer(System.get_env("BATCH_SIZE", "100"))
worker_count = String.to_integer(System.get_env("WORKERS", "8"))

id = "profile-am-" <> Integer.to_string(System.unique_integer([:positive]))
{:ok, _} = :bondy_oplog.start_instance(id)

# Warm the instance.
for i <- 1..1_000, do: :bondy_oplog.append(id, {:warmup, i})
:ok = :bondy_oplog.await_apply(id, 30_000)

# Resolve the per-subtree pids (these can shift across instances).
wal_pid = :bondy_oplog_registry.wal_pid(id)
applier_pid = :bondy_oplog_registry.applier_pid(id)
instance_pid = :bondy_oplog_registry.instance_pid(id)
overlay_tab = :bondy_oplog_registry.overlay_tab(id)

IO.puts("\n=== profiling #{id} ===")
IO.puts("  wal=#{inspect(wal_pid)} applier=#{inspect(applier_pid)} instance=#{inspect(instance_pid)}")
IO.puts("  duration=#{duration_s}s batch=#{batch_size} workers=#{worker_count}\n")

# Enable scheduler wall time so we can compute utilisation.
:erlang.system_flag(:scheduler_wall_time, true)

# Snapshot the per-scheduler {Active, Total} pairs keyed by sched id.
# `scheduler_wall_time` returns a list of `{SchedId, Active, Total}` tuples.
sched_snapshot = fn ->
  case :erlang.statistics(:scheduler_wall_time) do
    :undefined -> %{}
    list -> Map.new(list, fn {id, a, t} -> {id, {a, t}} end)
  end
end

# Process-level snapshot of {reductions, message_queue_len} for the
# named pids, plus the top-N system-wide by reductions delta.
proc_snapshot = fn pids ->
  Map.new(pids, fn {label, pid} ->
    case :erlang.process_info(pid, [:reductions, :message_queue_len]) do
      nil -> {label, nil}
      info -> {label, Map.new(info)}
    end
  end)
end

# Worker that drives the batch_op, with own atomic state for cadence.
worker = fn parent, deadline_ms, ack_counter ->
  state = :atomics.new(1, [{:signed, false}])
  spawn_link(fn ->
    loop = fn loop ->
      now = :erlang.monotonic_time(:millisecond)
      cond do
        now >= deadline_ms ->
          send(parent, {:done, self()})
        true ->
          batch = for i <- 1..batch_size, do: {{:am, i}, :undefined}
          case :bondy_oplog.append_many(id, batch) do
            {:error, _} -> :counters.add(ack_counter, 1, 1)
            _           -> :counters.add(ack_counter, 2, 1)
          end
          n = :atomics.add_get(state, 1, 1)
          if rem(n, 32) == 0, do: _ = :bondy_oplog.await_apply(id, 60_000)
          loop.(loop)
      end
    end
    loop.(loop)
  end)
end

deadline = :erlang.monotonic_time(:millisecond) + duration_s * 1000
ack = :counters.new(2, [:write_concurrency])

# Spawn workers.
worker_pids =
  for _ <- 1..worker_count, do: worker.(self(), deadline, ack)

# Sampling loop. One sample per second.
named_pids = [
  {:wal, wal_pid}, {:applier, applier_pid}, {:instance, instance_pid}
]

initial_sched = sched_snapshot.()
initial_procs = proc_snapshot.(named_pids)
initial_t = :erlang.monotonic_time(:millisecond)

samples =
  Stream.iterate(0, &(&1 + 1))
  |> Stream.take_while(fn _ ->
    :erlang.monotonic_time(:millisecond) < deadline
  end)
  |> Enum.map(fn n ->
    Process.sleep(1_000)
    sched = sched_snapshot.()
    procs = proc_snapshot.(named_pids)
    overlay_count = :ets.info(overlay_tab, :size)
    %{
      t: n + 1,
      sched: sched,
      procs: procs,
      overlay: overlay_count
    }
  end)

# Drain remaining worker messages.
Enum.each(worker_pids, fn _ ->
  receive do
    {:done, _} -> :ok
  after
    60_000 -> :timeout
  end
end)

final_sched = sched_snapshot.()
final_procs = proc_snapshot.(named_pids)
final_t = :erlang.monotonic_time(:millisecond)
total_ms = final_t - initial_t

# Aggregate scheduler utilisation = sum(Active deltas) / sum(Total deltas).
sched_util = fn before, aft ->
  pairs =
    Map.merge(before, aft, fn _k, {a0, t0}, {a1, t1} ->
      {a1 - a0, t1 - t0}
    end)
  active_sum = pairs |> Map.values() |> Enum.map(fn {a, _} -> a end) |> Enum.sum()
  total_sum  = pairs |> Map.values() |> Enum.map(fn {_, t} -> t end) |> Enum.sum()
  if total_sum > 0, do: active_sum / total_sum, else: 0.0
end

# Per-process reductions delta + final mailbox.
proc_delta = fn label, before, aft ->
  cond do
    is_nil(before) or is_nil(aft) -> %{reds_per_sec: 0, mqueue: 0}
    true ->
      reds_delta = aft[:reductions] - before[:reductions]
      %{
        label: label,
        reds_per_sec: reds_delta * 1000 / max(total_ms, 1),
        mqueue: aft[:message_queue_len]
      }
  end
end

util = sched_util.(initial_sched, final_sched)
errors = :counters.get(ack, 1)
oks    = :counters.get(ack, 2)
total  = errors + oks
ms = total_ms

IO.puts("=== run results ===")
IO.puts("  wall=#{ms}ms  ops=#{total}  batches=#{oks}+#{errors}  err_rate=#{Float.round(errors / max(total, 1) * 100, 2)}%")
IO.puts("  events_per_sec≈#{Float.round(oks * batch_size / (ms / 1000), 0)}")
IO.puts("  scheduler utilisation: #{Float.round(util * 100, 1)}%")
IO.puts("")
IO.puts("=== per-process activity ===")

for {label, _pid} <- named_pids do
  delta = proc_delta.(label, initial_procs[label], final_procs[label])
  IO.puts("  #{String.pad_trailing(to_string(label), 10)} " <>
          "reds/s=#{Float.round(delta.reds_per_sec, 0)} " <>
          "final_mqueue=#{delta.mqueue}")
end

IO.puts("")
IO.puts("=== per-second snapshots (overlay size, mailboxes) ===")
IO.puts(String.pad_trailing("t", 4) <> "overlay  " <>
        String.pad_trailing("wal_mq", 8) <>
        String.pad_trailing("appl_mq", 8) <>
        String.pad_trailing("inst_mq", 8))

for s <- samples do
  wal_mq = get_in(s.procs, [:wal, :message_queue_len]) || 0
  appl_mq = get_in(s.procs, [:applier, :message_queue_len]) || 0
  inst_mq = get_in(s.procs, [:instance, :message_queue_len]) || 0
  IO.puts(String.pad_trailing("#{s.t}s", 4) <>
          String.pad_trailing("#{s.overlay}", 9) <>
          String.pad_trailing("#{wal_mq}", 8) <>
          String.pad_trailing("#{appl_mq}", 8) <>
          String.pad_trailing("#{inst_mq}", 8))
end

# Top processes by total reductions accumulated over their lifetime.
# Long-lived heavy hitters dominate, which is what we want — the
# instance/wal/applier are all post-startup-init by sample time so
# their reductions are dominated by the workload we just drove.
all_procs_post =
  for p <- Process.list(),
      do: {p, :erlang.process_info(p, [:reductions, :registered_name, :initial_call])}

top =
  all_procs_post
  |> Enum.filter(fn {_p, info} -> not is_nil(info) end)
  |> Enum.map(fn {p, info} ->
    name = case Keyword.get(info, :registered_name) do
      [] -> Keyword.get(info, :initial_call)
      n -> n
    end
    {p, name, Keyword.get(info, :reductions, 0)}
  end)
  |> Enum.sort_by(fn {_p, _n, r} -> -r end)
  |> Enum.take(10)

IO.puts("")
IO.puts("=== top 10 processes by total reductions ===")
for {p, name, r} <- top do
  IO.puts("  #{inspect(p)}  reds=#{r}  #{inspect(name)}")
end

:ok = :bondy_oplog.stop_instance(id)
