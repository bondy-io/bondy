defmodule Bench.ProjectionEts do
  @moduledoc """
  In-memory `bondy_oplog_projection_adapter` for benchmarks. Mirrors
  `test/bondy_oplog_projection_ets.erl`: rows are keyed by
  `{Bucket, Key}` so an `ordered_set` scan over a single bucket stays
  in `(Bucket, Key)` lexicographic order.

  Lives in the bench project so we don't need to add `_build/test/lib`
  to the code path.
  """

  # The Erlang behaviour module is loaded at runtime via Code.prepend_path,
  # so we don't declare `@behaviour` — Mix can't verify it.

  def open(_ns, _index, _shard, _opts) do
    tab =
      :ets.new(__MODULE__, [
        :ordered_set,
        :public,
        {:read_concurrency, true}
      ])

    {:ok, tab}
  end

  def close(tab) do
    true = :ets.delete(tab)
    :ok
  end

  def get(tab, bucket, key) do
    case :ets.lookup(tab, {bucket, key}) do
      [{_, frame}] -> {:ok, frame}
      [] -> :not_found
    end
  end

  def put_batch(tab, entries) do
    rows = for {b, k, f} <- entries, do: {{b, k}, f}
    true = :ets.insert(tab, rows)
    :ok
  end

  def range(tab, bucket, low, high, opts) do
    limit = Map.get(opts, :limit, 1000)
    direction = Map.get(opts, :direction, :asc)

    ms = [
      {{{:"$1", :"$2"}, :"$3"},
       [
         {:"=:=", :"$1", {:const, bucket}},
         {:>=, :"$2", {:const, low}},
         {:<, :"$2", {:const, high}}
       ], [{{:"$2", :"$3"}}]}
    ]

    result =
      case :ets.select(tab, ms, limit) do
        :"$end_of_table" -> []
        {found, _cont} -> found
      end

    ordered =
      case direction do
        :asc -> result
        :desc -> Enum.reverse(result)
      end

    {:ok, ordered}
  end

  def delete(tab, bucket, key) do
    true = :ets.delete(tab, {bucket, key})
    :ok
  end

  def info(tab) do
    %{size: :ets.info(tab, :size), memory: :ets.info(tab, :memory)}
  end
end
