# Top-level runner for the bondy_oplog/bondy_db benchmark suite — loads
# every oplog/db benchmark script in sequence so a single
# `mix run benchmarks/all.exs` produces the full HTML report tree under
# `bench/_output/<name>/index.html`.
#
# The MST-library-only benchmarks (mst_*, pack store, folds over a raw
# tree) live in the bondy_mst repo's own `bench/`.

scripts = ~w(
  primitives.exs
  folds.exs
  mst_db.exs
  oplog.exs
  wal.exs
  e2e_pipeline.exs
  latency_sampling.exs
  concurrency_oplog.exs
  concurrency_wal.exs
  concurrency_mst_db.exs
)

base = Path.dirname(__ENV__.file)

Enum.each(scripts, fn name ->
  path = Path.join(base, name)
  IO.puts("\n==> " <> name)
  Code.eval_file(path)
end)

IO.puts("\n[bench] HTML reports → bench/_output/<name>/index.html")
