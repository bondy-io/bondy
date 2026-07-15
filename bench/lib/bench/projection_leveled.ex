defmodule Bench.ProjectionLeveled do
  @moduledoc """
  Leveled-backed `bondy_oplog_projection_adapter` for benchmarks.

  Mirrors `src/bondy_db_projection_leveled.erl` (Erlang) but lives
  in the bench app so we don't pull test code into the bench code path.

  The adapter is a **pure mapper**: the Bookie pid is supplied via
  `open/4`'s opts (`%{bookie: pid()}`). Bookie lifecycle is owned by
  the bench scenario — one Bookie per shard, started in the scenario's
  setup and stopped in cleanup. The Bookie **must** be opened with
  `{head_only, with_lookup}` (PR-PS-15b); see
  `bench/benchmarks/e2e_pipeline.exs` for the canonical opts.

  ## SubKey split (PR-PS-15b)

  Each logical cell `(Bucket, Key)` is stored as one or two leveled
  HEAD entries under `?HEAD_TAG` (`:h`), distinguished by SubKey:

  - `"s"` → `<<HlcLen:16, Hlc/binary, StateBytes/binary>>`
  - `"v"` → HEAD wire format
    `<<HlcLen:16, Hlc/binary, ValueBytes/binary>>`

  For folds with `HasValueColumn=0` (value_equals_state, currently
  only G-Set) the value subkey is NOT written; absence on read is the
  signal to reconstruct the V2 frame with `HasValueColumn=0` (using
  StateBytes as ValueBytes).

  Codec is delegated to the Erlang `:bondy_oplog_cell_frame` module —
  identical encoder/decoder as the substrate uses.
  """

  # leveled beams + erlang substrate beams are loaded at runtime via
  # Code.prepend_path; Mix can't see them at compile time.
  @compile {:no_warn_undefined,
            [:leveled_bookie, :bondy_oplog_cell_frame]}

  # Mirrors `-define(HEAD_TAG, h).` in leveled.hrl.
  @head_tag :h

  # SubKey split (PR-PS-15b).
  @sk_state "s"
  @sk_value "v"

  def open(_ns, _index, _shard, %{bookie: pid} = _opts) when is_pid(pid) do
    {:ok, %{bookie: pid}}
  end

  def open(_ns, _index, _shard, opts) when is_map(opts) do
    {:error, {:invalid_opts, opts}}
  end

  def close(%{bookie: _pid}), do: :ok

  def get(%{bookie: pid}, bucket, key)
      when is_binary(bucket) and is_binary(key) do
    case read_state_subkey(pid, bucket, key) do
      :not_found ->
        :not_found

      {:ok, hlc, state_bytes} ->
        # Value subkey absent → value_equals_state fold (HasValueColumn=0).
        case read_value_subkey(pid, bucket, key) do
          :not_found ->
            {:ok,
             :bondy_oplog_cell_frame.encode(hlc, state_bytes, :undefined, true)}

          {:ok, _hlc, value_bytes} ->
            {:ok,
             :bondy_oplog_cell_frame.encode(hlc, state_bytes, value_bytes, false)}
        end
    end
  end

  def head(%{bookie: pid}, bucket, key)
      when is_binary(bucket) and is_binary(key) do
    case :leveled_bookie.book_headonly(pid, bucket, key, @sk_value) do
      {:ok, head_bytes} ->
        {:ok, head_bytes}

      :not_found ->
        # Value subkey absent → value_equals_state cell; state subkey
        # payload IS the HEAD wire format.
        case :leveled_bookie.book_headonly(pid, bucket, key, @sk_state) do
          {:ok, head_bytes} -> {:ok, head_bytes}
          :not_found -> :not_found
        end
    end
  end

  def put_batch(%{bookie: pid}, entries) when is_list(entries) do
    case build_object_specs(entries, []) do
      [] ->
        :ok

      specs ->
        case :leveled_bookie.book_mput(pid, specs) do
          :ok -> :ok
          # leveled returns `pause` under load to ask the caller to slow
          # down. We accept it as success here (the writes ARE durable
          # in the LSM) rather than propagating — the bench's job is to
          # measure raw throughput, not implement back-pressure handling.
          :pause -> :ok
        end
    end
  end

  def range(%{bookie: pid}, bucket, low, high, opts)
      when is_binary(bucket) and is_binary(low) and is_binary(high) and
             is_map(opts) do
    limit = Map.get(opts, :limit, 1000)
    direction = Map.get(opts, :direction, :asc)
    # Range over the {Key, SubKey} composite that brackets every value
    # subkey between low and high.
    key_range = {{low, @sk_value}, {high, @sk_value}}
    fold_fun = make_value_keylist_fold(limit, high)

    {:async, runner} =
      :leveled_bookie.book_keylist(
        pid,
        @head_tag,
        bucket,
        key_range,
        {fold_fun, {0, []}}
      )

    {_n, keys_rev} =
      try do
        runner.()
      catch
        :throw, {:limit_reached, state} -> state
      end

    keys_asc = Enum.reverse(keys_rev)

    # Per-key get/3 to assemble the full V2 frame.
    pairs =
      for k <- keys_asc,
          {:ok, f} <- [get(%{bookie: pid}, bucket, k)] do
        {k, f}
      end

    case direction do
      :asc -> {:ok, pairs}
      :desc -> {:ok, Enum.reverse(pairs)}
    end
  end

  def delete(%{bookie: pid}, bucket, key)
      when is_binary(bucket) and is_binary(key) do
    specs = [
      {:remove, bucket, key, @sk_state, nil},
      {:remove, bucket, key, @sk_value, nil}
    ]

    case :leveled_bookie.book_mput(pid, specs) do
      :ok -> :ok
      :pause -> :ok
    end
  end

  def info(%{bookie: pid}) do
    %{
      backend: :leveled,
      bookie: pid,
      tag: @head_tag,
      subkey_state: @sk_state,
      subkey_value: @sk_value
    }
  end

  # ------------------------------------------------------------------

  defp read_state_subkey(pid, bucket, key) do
    case :leveled_bookie.book_headonly(pid, bucket, key, @sk_state) do
      {:ok, <<hlc_len::16, hlc::binary-size(hlc_len), state_bytes::binary>>} ->
        hlc_int = :binary.decode_unsigned(hlc, :big)
        {:ok, hlc_int, state_bytes}

      :not_found ->
        :not_found
    end
  end

  defp read_value_subkey(pid, bucket, key) do
    case :leveled_bookie.book_headonly(pid, bucket, key, @sk_value) do
      {:ok, <<hlc_len::16, hlc::binary-size(hlc_len), value_bytes::binary>>} ->
        hlc_int = :binary.decode_unsigned(hlc, :big)
        {:ok, hlc_int, value_bytes}

      :not_found ->
        :not_found
    end
  end

  defp build_object_specs([], acc), do: Enum.reverse(acc)

  defp build_object_specs([{bucket, key, frame} | rest], acc)
       when is_binary(bucket) and is_binary(key) and is_binary(frame) do
    {hlc, state_bytes, value_bytes_opt} =
      :bondy_oplog_cell_frame.decode_full(frame)

    hlc_bin = <<hlc::64>>
    hlc_len = byte_size(hlc_bin)
    state_payload = <<hlc_len::16, hlc_bin::binary, state_bytes::binary>>

    acc1 = [{:add, bucket, key, @sk_state, state_payload} | acc]

    acc2 =
      case value_bytes_opt do
        :undefined ->
          acc1

        value_bytes when is_binary(value_bytes) ->
          value_payload = <<hlc_len::16, hlc_bin::binary, value_bytes::binary>>
          [{:add, bucket, key, @sk_value, value_payload} | acc1]
      end

    build_object_specs(rest, acc2)
  end

  defp make_value_keylist_fold(limit, high) do
    fn _bucket, {k, sub_key}, {n, items} ->
      cond do
        sub_key == @sk_value and k != high ->
          n1 = n + 1
          state = {n1, [k | items]}
          if n1 >= limit, do: throw({:limit_reached, state}), else: state

        true ->
          {n, items}
      end
    end
  end
end
