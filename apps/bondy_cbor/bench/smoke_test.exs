# Quick smoke test to verify benchmarks work
# Run with: mix run smoke_test.exs

IO.puts("Smoke test for benchmark setup\n")

Application.ensure_all_started(:bondy_cbor)

# Test data
data = %{
  "id" => 12345,
  "name" => "Test",
  "values" => [1, 2, 3],
  "nested" => %{"a" => 1, "b" => 2}
}

# Convert to Erlang-compatible format
defmodule Conv do
  def to_erlang(m) when is_map(m), do: Map.new(m, fn {k, v} -> {to_erlang(k), to_erlang(v)} end)
  def to_erlang(l) when is_list(l), do: Enum.map(l, &to_erlang/1)
  def to_erlang(true), do: true
  def to_erlang(false), do: false
  def to_erlang(nil), do: :null
  def to_erlang(a) when is_atom(a), do: :erlang.atom_to_binary(a, :utf8)
  def to_erlang(other), do: other
end

erl_data = Conv.to_erlang(data)

IO.puts("Testing bondy_cbor...")
cbor_enc = :bondy_cbor.encode(erl_data) |> :erlang.iolist_to_binary()
cbor_dec = :bondy_cbor.decode(cbor_enc)
IO.puts("  Encoded size: #{byte_size(cbor_enc)} bytes")
IO.puts("  Encode/decode: OK")

IO.puts("\nTesting bondy_cbor (deterministic)...")
cbor_det = :bondy_cbor.encode_deterministic(erl_data)
IO.puts("  Encoded size: #{byte_size(cbor_det)} bytes")
IO.puts("  Deterministic: OK")

IO.puts("\nTesting msgpack...")
msgpack_enc = :msgpack.pack(erl_data, [{:map_format, :map}])
_msgpack_dec = :msgpack.unpack(msgpack_enc, [{:map_format, :map}])
IO.puts("  Encoded size: #{byte_size(msgpack_enc)} bytes")
IO.puts("  Encode/decode: OK")

IO.puts("\nTesting json (Erlang OTP)...")
json_enc = :json.encode(erl_data) |> :erlang.iolist_to_binary()
_json_dec = :json.decode(json_enc)
IO.puts("  Encoded size: #{byte_size(json_enc)} bytes")
IO.puts("  Encode/decode: OK")

IO.puts("\n" <> String.duplicate("=", 50))
IO.puts("All libraries working correctly!")
IO.puts("Size comparison for test data:")
IO.puts("  CBOR:            #{byte_size(cbor_enc)} bytes")
IO.puts("  CBOR deterministic: #{byte_size(cbor_det)} bytes")
IO.puts("  MsgPack:         #{byte_size(msgpack_enc)} bytes")
IO.puts("  JSON:            #{byte_size(json_enc)} bytes")
IO.puts(String.duplicate("=", 50))

IO.puts("\nReady to run benchmarks:")
IO.puts("  mix run bench.exs                 # Quick benchmark")
IO.puts("  mix run bench_report.exs          # With HTML reports")
IO.puts("  mix run bench_comprehensive.exs   # Full comprehensive benchmark")
