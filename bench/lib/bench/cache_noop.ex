defmodule Bench.CacheNoop do
  @moduledoc """
  No-op `bondy_oplog_cache_adapter` for the bench.

  Every `get/3` returns `:not_found`, so the substrate read path
  always falls through to the projection adapter. `put/4` discards
  writes so a "hot" key never gets cached and subsequent reads are
  forced through the projection again.

  Used when the bench wants to isolate raw projection-adapter read
  performance (e.g. ETS vs leveled) without the
  `bondy_oplog_cache_ets` cache absorbing the traffic.

  This is a *bench-only* affordance — production code should always
  use a real cache.
  """

  def init(_ns, _index, _shard, _opts), do: {:ok, :noop}

  def close(_handle), do: :ok

  def get(_handle, _bucket, _key), do: :not_found

  def put(_handle, _bucket, _key, _value_hlc), do: :ok

  def delete(_handle, _bucket, _key), do: :ok

  def invalidate_all(_handle), do: :ok

  def info(_handle) do
    %{adapter: __MODULE__, mode: :bypass, size: 0, memory: 0}
  end
end
