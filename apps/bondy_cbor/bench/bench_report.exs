# CBOR vs MsgPack vs JSON Benchmark with HTML Reports
#
# Run with: mix run bench_report.exs
#
# This generates detailed HTML reports in the bench/_output directory

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("CBOR vs MsgPack vs JSON Benchmark (Full Report)")
IO.puts(String.duplicate("=", 60) <> "\n")

Application.ensure_all_started(:bondy_cbor)

# Create output directory
File.mkdir_p!("_output")

################################################################################
# Test Data
################################################################################

defmodule BenchData do
  def small_map do
    %{
      "id" => 12345,
      "name" => "Test",
      "active" => true,
      "score" => 98.6
    }
  end

  def medium_map do
    %{
      "id" => 999_999,
      "timestamp" => 1_640_000_000,
      "user" => %{
        "id" => 42,
        "username" => "testuser",
        "email" => "test@example.com"
      },
      "items" => Enum.map(1..20, fn i ->
        %{"id" => i, "name" => "Item #{i}", "price" => i * 10.5}
      end)
    }
  end

  def large_map do
    %{
      "data" => Enum.map(1..100, fn i ->
        %{
          "id" => i,
          "name" => "User #{i}",
          "email" => "user#{i}@example.com",
          "age" => 20 + rem(i, 50),
          "active" => rem(i, 2) == 0,
          "balance" => i * 100.50,
          "tags" => Enum.map(1..5, fn j -> "tag_#{j}" end)
        }
      end)
    }
  end

  def integer_array, do: Enum.to_list(1..1000)

  def string_array, do: Enum.map(1..100, fn i -> "string_value_#{i}" end)

  def nested_structure do
    %{
      "level1" => %{
        "level2" => %{
          "level3" => %{
            "data" => Enum.map(1..50, fn i ->
              %{"id" => i, "values" => Enum.to_list(1..10)}
            end)
          }
        }
      }
    }
  end
end

################################################################################
# Encoders/Decoders
################################################################################

defmodule Codec do
  def to_erlang(term) when is_map(term) do
    Map.new(term, fn {k, v} -> {to_erlang(k), to_erlang(v)} end)
  end
  def to_erlang(term) when is_list(term), do: Enum.map(term, &to_erlang/1)
  def to_erlang(true), do: true
  def to_erlang(false), do: false
  def to_erlang(nil), do: :null
  def to_erlang(term) when is_atom(term), do: :erlang.atom_to_binary(term, :utf8)
  def to_erlang(term), do: term

  def to_json(term) when is_map(term) do
    Map.new(term, fn {k, v} ->
      {if(is_binary(k), do: k, else: to_string(k)), to_json(v)}
    end)
  end
  def to_json(term) when is_list(term), do: Enum.map(term, &to_json/1)
  def to_json(true), do: true
  def to_json(false), do: false
  def to_json(nil), do: :null
  def to_json(term) when is_atom(term), do: :erlang.atom_to_binary(term, :utf8)
  def to_json(term), do: term

  # Encoding
  def cbor_encode(term), do: :bondy_cbor.encode(to_erlang(term)) |> :erlang.iolist_to_binary()
  def cbor_encode_det(term), do: :bondy_cbor.encode_deterministic(to_erlang(term))
  def msgpack_encode(term) do
    :msgpack.pack(to_erlang(term), [{:map_format, :map}])
  end
  def json_encode(term), do: :json.encode(to_json(term)) |> :erlang.iolist_to_binary()

  # Decoding
  def cbor_decode(bin), do: :bondy_cbor.decode(bin)
  def msgpack_decode(bin) do
    :msgpack.unpack(bin, [{:map_format, :map}])
  end
  def json_decode(bin), do: :json.decode(bin)
end

################################################################################
# Benchmark: Encoding
################################################################################

IO.puts("Running encoding benchmarks...")

inputs = %{
  "small_map" => BenchData.small_map(),
  "medium_map" => BenchData.medium_map(),
  "large_map" => BenchData.large_map(),
  "integer_array_1000" => BenchData.integer_array(),
  "string_array_100" => BenchData.string_array(),
  "nested_structure" => BenchData.nested_structure()
}

Benchee.run(
  %{
    "bondy_cbor" => fn input -> Codec.cbor_encode(input) end,
    "bondy_cbor_deterministic" => fn input -> Codec.cbor_encode_det(input) end,
    "msgpack" => fn input -> Codec.msgpack_encode(input) end,
    "json" => fn input -> Codec.json_encode(input) end
  },
  inputs: inputs,
  warmup: 2,
  time: 5,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.HTML, file: "_output/encoding_benchmark.html"},
    {Benchee.Formatters.Markdown, file: "_output/encoding_benchmark.md"}
  ],
  save: [path: "_output/encoding_results.benchee", tag: "encoding"]
)

################################################################################
# Benchmark: Decoding
################################################################################

IO.puts("\nRunning decoding benchmarks...")

# Pre-encode all inputs
decode_inputs = Map.new(inputs, fn {name, data} ->
  {name, %{
    cbor: Codec.cbor_encode(data),
    msgpack: Codec.msgpack_encode(data),
    json: Codec.json_encode(data)
  }}
end)

Benchee.run(
  %{
    "bondy_cbor" => fn %{cbor: bin} -> Codec.cbor_decode(bin) end,
    "msgpack" => fn %{msgpack: bin} -> Codec.msgpack_decode(bin) end,
    "json" => fn %{json: bin} -> Codec.json_decode(bin) end
  },
  inputs: decode_inputs,
  warmup: 2,
  time: 5,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.HTML, file: "_output/decoding_benchmark.html"},
    {Benchee.Formatters.Markdown, file: "_output/decoding_benchmark.md"}
  ],
  save: [path: "_output/decoding_results.benchee", tag: "decoding"]
)

################################################################################
# Benchmark: Round-trip (Encode + Decode)
################################################################################

IO.puts("\nRunning round-trip benchmarks...")

Benchee.run(
  %{
    "bondy_cbor" => fn input ->
      bin = Codec.cbor_encode(input)
      Codec.cbor_decode(bin)
    end,
    "msgpack" => fn input ->
      bin = Codec.msgpack_encode(input)
      Codec.msgpack_decode(bin)
    end,
    "json" => fn input ->
      bin = Codec.json_encode(input)
      Codec.json_decode(bin)
    end
  },
  inputs: inputs,
  warmup: 2,
  time: 5,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.HTML, file: "_output/roundtrip_benchmark.html"},
    {Benchee.Formatters.Markdown, file: "_output/roundtrip_benchmark.md"}
  ]
)

################################################################################
# Size Comparison
################################################################################

IO.puts("\n" <> String.duplicate("=", 70))
IO.puts("ENCODED SIZE COMPARISON (bytes)")
IO.puts(String.duplicate("=", 70))

header = String.pad_trailing("Input", 25) <>
         String.pad_leading("CBOR", 10) <>
         String.pad_leading("CBOR Det", 10) <>
         String.pad_leading("MsgPack", 10) <>
         String.pad_leading("JSON", 10) <>
         String.pad_leading("Savings", 10)

IO.puts(header)
IO.puts(String.duplicate("-", 75))

Enum.each(inputs, fn {name, data} ->
  cbor_size = byte_size(Codec.cbor_encode(data))
  cbor_det_size = byte_size(Codec.cbor_encode_det(data))
  msgpack_size = byte_size(Codec.msgpack_encode(data))
  json_size = byte_size(Codec.json_encode(data))

  # Calculate savings vs JSON (most common format)
  savings = Float.round((1 - cbor_size / json_size) * 100, 1)

  IO.puts(
    String.pad_trailing(name, 25) <>
    String.pad_leading("#{cbor_size}", 10) <>
    String.pad_leading("#{cbor_det_size}", 10) <>
    String.pad_leading("#{msgpack_size}", 10) <>
    String.pad_leading("#{json_size}", 10) <>
    String.pad_leading("#{savings}%", 10)
  )
end)

IO.puts("\nSavings = reduction vs JSON (positive = smaller than JSON)")

IO.puts("\n" <> String.duplicate("=", 70))
IO.puts("Benchmark Complete! Results saved to bench/_output/")
IO.puts(String.duplicate("=", 70) <> "\n")
