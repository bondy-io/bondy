# Comprehensive CBOR vs MsgPack vs JSON Benchmark
#
# Measures:
# - Throughput (operations/second)
# - Latency (average, median, p99, min, max)
# - Memory allocation (total allocated, allocation count)
# - Encoded size comparison
# - CPU time via reduction counting
#
# Run with: mix run bench_comprehensive.exs

IO.puts("""

================================================================================
         COMPREHENSIVE SERIALIZATION BENCHMARK
         bondy_cbor (CBOR) vs msgpack vs json (Erlang OTP)
================================================================================

""")

Application.ensure_all_started(:bondy_cbor)
File.mkdir_p!("output")

################################################################################
# Test Data Generator
################################################################################

defmodule TestData do
  @moduledoc "Generate various test datasets for benchmarking"

  # Tiny payload (~50 bytes JSON)
  def tiny do
    %{"id" => 1, "ok" => true}
  end

  # Small payload (~200 bytes JSON)
  def small do
    %{
      "id" => 12345,
      "name" => "Test Item",
      "active" => true,
      "score" => 98.6,
      "tags" => ["tag1", "tag2", "tag3"]
    }
  end

  # Medium payload (~2KB JSON)
  def medium do
    %{
      "request_id" => "550e8400-e29b-41d4-a716-446655440000",
      "timestamp" => 1_700_000_000,
      "user" => %{
        "id" => 42,
        "username" => "testuser",
        "email" => "test@example.com",
        "settings" => %{
          "theme" => "dark",
          "notifications" => true,
          "language" => "en",
          "timezone" => "UTC"
        }
      },
      "items" => Enum.map(1..20, fn i ->
        %{
          "id" => i,
          "name" => "Item #{i}",
          "price" => i * 10.99,
          "quantity" => rem(i, 10) + 1,
          "in_stock" => rem(i, 3) != 0
        }
      end),
      "metadata" => %{
        "version" => "2.1.0",
        "source" => "api",
        "region" => "us-east-1"
      }
    }
  end

  # Large payload (~20KB JSON)
  def large do
    %{
      "api_version" => "3.0",
      "status" => "success",
      "pagination" => %{
        "page" => 1,
        "per_page" => 100,
        "total" => 10000,
        "total_pages" => 100
      },
      "data" => Enum.map(1..100, fn i ->
        %{
          "id" => i,
          "uuid" => "550e8400-e29b-41d4-a716-#{String.pad_leading("#{i}", 12, "0")}",
          "name" => "Record #{i}",
          "description" => "This is a detailed description for record number #{i} with some additional text to make it longer",
          "created_at" => "2024-01-#{String.pad_leading("#{rem(i, 28) + 1}", 2, "0")}T10:30:00Z",
          "updated_at" => "2024-06-#{String.pad_leading("#{rem(i, 28) + 1}", 2, "0")}T15:45:00Z",
          "status" => Enum.at(["active", "pending", "archived"], rem(i, 3)),
          "priority" => rem(i, 5) + 1,
          "score" => i * 1.5,
          "verified" => rem(i, 2) == 0,
          "tags" => Enum.map(1..5, fn j -> "category_#{rem(i + j, 20)}" end),
          "metrics" => %{
            "views" => i * 100,
            "clicks" => i * 10,
            "conversions" => i
          },
          "attributes" => Map.new(1..10, fn j -> {"attr_#{j}", "value_#{i}_#{j}"} end)
        }
      end)
    }
  end

  # Very large payload (~100KB JSON)
  def very_large do
    %{
      "batch_id" => "batch-2024-001",
      "records" => Enum.map(1..500, fn i ->
        %{
          "id" => i,
          "data" => %{
            "field1" => String.duplicate("x", 50),
            "field2" => Enum.to_list(1..20),
            "field3" => Map.new(1..10, fn j -> {"k#{j}", j * i} end),
            "nested" => %{
              "a" => i,
              "b" => i * 2,
              "c" => [i, i + 1, i + 2]
            }
          }
        }
      end)
    }
  end

  # Integer-heavy payload
  def integers do
    %{
      "small" => Enum.to_list(0..23),
      "medium" => Enum.to_list(24..255),
      "large" => Enum.map(1..100, fn i -> i * 1000000 end),
      "negative" => Enum.map(1..100, fn i -> -i * 1000 end),
      "mixed" => Enum.map(1..200, fn i -> i * (if rem(i, 2) == 0, do: 1, else: -1) end)
    }
  end

  # Float-heavy payload
  def floats do
    %{
      "simple" => [0.0, 1.0, -1.0, 0.5, -0.5],
      "precise" => Enum.map(1..100, fn i -> i / 7.0 end),
      "scientific" => Enum.map(1..50, fn i -> :math.pow(10, i / 10) end),
      "coordinates" => Enum.map(1..100, fn i ->
        %{"lat" => 40.0 + i / 100, "lng" => -74.0 - i / 100}
      end)
    }
  end

  # String-heavy payload
  def strings do
    %{
      "short" => Enum.map(1..100, fn _ -> "ab" end),
      "medium" => Enum.map(1..50, fn i -> "This is string number #{i} with some content" end),
      "long" => Enum.map(1..20, fn i -> String.duplicate("word ", 50) <> "#{i}" end),
      "unicode" => Enum.map(1..50, fn i -> "日本語テスト #{i} émoji 🎉" end)
    }
  end

  # Deeply nested payload
  def nested do
    build_nested(6, 0)
  end

  defp build_nested(0, i), do: %{"leaf" => i, "data" => Enum.to_list(1..10)}
  defp build_nested(depth, i) do
    %{
      "depth" => depth,
      "index" => i,
      "children" => Enum.map(0..2, fn j -> build_nested(depth - 1, i * 3 + j) end)
    }
  end

  # Wide map (many keys)
  def wide_map do
    Map.new(1..500, fn i ->
      {"field_#{String.pad_leading("#{i}", 4, "0")}", %{"value" => i, "label" => "Label #{i}"}}
    end)
  end
end

################################################################################
# Codec Wrappers
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

  # CBOR
  def cbor_encode(term), do: :bondy_cbor.encode(to_erlang(term)) |> :erlang.iolist_to_binary()
  def cbor_encode_det(term), do: :bondy_cbor.encode_deterministic(to_erlang(term))
  def cbor_decode(bin), do: :bondy_cbor.decode(bin)

  # MsgPack
  def msgpack_encode(term) do
    :msgpack.pack(to_erlang(term), [{:map_format, :map}])
  end
  def msgpack_decode(bin) do
    :msgpack.unpack(bin, [{:map_format, :map}])
  end

  # JSON
  def json_encode(term), do: :json.encode(to_json(term)) |> :erlang.iolist_to_binary()
  def json_decode(bin), do: :json.decode(bin)
end

################################################################################
# Custom Statistics Collector
################################################################################

defmodule Stats do
  @moduledoc "Collect additional statistics during benchmarks"

  def measure_reductions(fun) do
    {:reductions, reductions_before} = Process.info(self(), :reductions)
    result = fun.()
    {:reductions, reductions_after} = Process.info(self(), :reductions)
    {result, reductions_after - reductions_before}
  end

  def collect_extended_stats(name, data, iterations \\ 1000) do
    _erl_data = Codec.to_erlang(data)
    _json_data = Codec.to_json(data)

    # Pre-encode for decode benchmarks
    cbor_bin = Codec.cbor_encode(data)
    cbor_det_bin = Codec.cbor_encode_det(data)
    msgpack_bin = Codec.msgpack_encode(data)
    json_bin = Codec.json_encode(data)

    IO.puts("\n--- #{name} ---")
    IO.puts("Encoded sizes: CBOR=#{byte_size(cbor_bin)}, CBOR_det=#{byte_size(cbor_det_bin)}, MsgPack=#{byte_size(msgpack_bin)}, JSON=#{byte_size(json_bin)}")

    # Measure reductions (proxy for CPU work)
    {_, cbor_enc_red} = measure_reductions(fn ->
      for _ <- 1..iterations, do: Codec.cbor_encode(data)
    end)
    {_, msgpack_enc_red} = measure_reductions(fn ->
      for _ <- 1..iterations, do: Codec.msgpack_encode(data)
    end)
    {_, json_enc_red} = measure_reductions(fn ->
      for _ <- 1..iterations, do: Codec.json_encode(data)
    end)

    {_, cbor_dec_red} = measure_reductions(fn ->
      for _ <- 1..iterations, do: Codec.cbor_decode(cbor_bin)
    end)
    {_, msgpack_dec_red} = measure_reductions(fn ->
      for _ <- 1..iterations, do: Codec.msgpack_decode(msgpack_bin)
    end)
    {_, json_dec_red} = measure_reductions(fn ->
      for _ <- 1..iterations, do: Codec.json_decode(json_bin)
    end)

    IO.puts("Reductions per #{iterations} ops (encode): CBOR=#{cbor_enc_red}, MsgPack=#{msgpack_enc_red}, JSON=#{json_enc_red}")
    IO.puts("Reductions per #{iterations} ops (decode): CBOR=#{cbor_dec_red}, MsgPack=#{msgpack_dec_red}, JSON=#{json_dec_red}")
  end
end

################################################################################
# Inputs
################################################################################

inputs = %{
  "01_tiny" => TestData.tiny(),
  "02_small" => TestData.small(),
  "03_medium" => TestData.medium(),
  "04_large" => TestData.large(),
  "05_very_large" => TestData.very_large(),
  "06_integers" => TestData.integers(),
  "07_floats" => TestData.floats(),
  "08_strings" => TestData.strings(),
  "09_nested" => TestData.nested(),
  "10_wide_map" => TestData.wide_map()
}

################################################################################
# Collect Extended Statistics
################################################################################

IO.puts("""
================================================================================
                        EXTENDED STATISTICS
================================================================================
""")

Enum.each(inputs, fn {name, data} ->
  Stats.collect_extended_stats(name, data, 100)
end)

################################################################################
# Benchmark: Encoding Performance
################################################################################

IO.puts("""

================================================================================
                        ENCODING BENCHMARK
================================================================================
Metrics: Operations/sec (throughput), Average time, Median, 99th percentile,
         Standard deviation, Memory allocated, Allocation count
================================================================================
""")

Benchee.run(
  %{
    "bondy_cbor" => fn input -> Codec.cbor_encode(input) end,
    "bondy_cbor_det" => fn input -> Codec.cbor_encode_det(input) end,
    "msgpack" => fn input -> Codec.msgpack_encode(input) end,
    "json" => fn input -> Codec.json_encode(input) end
  },
  inputs: inputs,
  warmup: 2,
  time: 5,
  memory_time: 2,
  reduction_time: 2,
  formatters: [
    {Benchee.Formatters.Console, extended_statistics: true},
    {Benchee.Formatters.HTML, file: "output/encoding.html", auto_open: false},
    {Benchee.Formatters.Markdown, file: "output/encoding.md"}
  ],
  save: [path: "output/encoding.benchee"]
)

################################################################################
# Benchmark: Decoding Performance
################################################################################

IO.puts("""

================================================================================
                        DECODING BENCHMARK
================================================================================
""")

# Pre-encode inputs for decoding benchmarks
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
  reduction_time: 2,
  formatters: [
    {Benchee.Formatters.Console, extended_statistics: true},
    {Benchee.Formatters.HTML, file: "output/decoding.html", auto_open: false},
    {Benchee.Formatters.Markdown, file: "output/decoding.md"}
  ],
  save: [path: "output/decoding.benchee"]
)

################################################################################
# Benchmark: Round-trip Performance
################################################################################

IO.puts("""

================================================================================
                        ROUND-TRIP BENCHMARK (Encode + Decode)
================================================================================
""")

Benchee.run(
  %{
    "bondy_cbor" => fn input ->
      Codec.cbor_decode(Codec.cbor_encode(input))
    end,
    "msgpack" => fn input ->
      Codec.msgpack_decode(Codec.msgpack_encode(input))
    end,
    "json" => fn input ->
      Codec.json_decode(Codec.json_encode(input))
    end
  },
  inputs: inputs,
  warmup: 2,
  time: 5,
  memory_time: 2,
  reduction_time: 2,
  formatters: [
    {Benchee.Formatters.Console, extended_statistics: true},
    {Benchee.Formatters.HTML, file: "output/roundtrip.html", auto_open: false},
    {Benchee.Formatters.Markdown, file: "output/roundtrip.md"}
  ],
  save: [path: "output/roundtrip.benchee"]
)

################################################################################
# Benchmark: Throughput Under Load (Batch Processing)
################################################################################

IO.puts("""

================================================================================
                        BATCH THROUGHPUT BENCHMARK
================================================================================
Processing 1000 items per operation to measure sustained throughput
================================================================================
""")

batch_data = Enum.map(1..1000, fn i ->
  %{"id" => i, "name" => "Item #{i}", "value" => i * 1.5, "active" => rem(i, 2) == 0}
end)

batch_cbor = Enum.map(batch_data, &Codec.cbor_encode/1)
batch_msgpack = Enum.map(batch_data, &Codec.msgpack_encode/1)
batch_json = Enum.map(batch_data, &Codec.json_encode/1)

Benchee.run(
  %{
    "bondy_cbor_encode_batch" => fn -> Enum.each(batch_data, &Codec.cbor_encode/1) end,
    "msgpack_encode_batch" => fn -> Enum.each(batch_data, &Codec.msgpack_encode/1) end,
    "json_encode_batch" => fn -> Enum.each(batch_data, &Codec.json_encode/1) end,
    "bondy_cbor_decode_batch" => fn -> Enum.each(batch_cbor, &Codec.cbor_decode/1) end,
    "msgpack_decode_batch" => fn -> Enum.each(batch_msgpack, &Codec.msgpack_decode/1) end,
    "json_decode_batch" => fn -> Enum.each(batch_json, &Codec.json_decode/1) end
  },
  warmup: 2,
  time: 10,
  memory_time: 2,
  reduction_time: 2,
  formatters: [
    {Benchee.Formatters.Console, extended_statistics: true},
    {Benchee.Formatters.HTML, file: "output/batch.html", auto_open: false}
  ]
)

################################################################################
# Size Comparison Summary
################################################################################

IO.puts("""

================================================================================
                        ENCODED SIZE COMPARISON
================================================================================
""")

IO.puts(String.pad_trailing("Input", 20) <>
        String.pad_leading("CBOR", 12) <>
        String.pad_leading("CBOR Det", 12) <>
        String.pad_leading("MsgPack", 12) <>
        String.pad_leading("JSON", 12) <>
        String.pad_leading("CBOR/JSON", 12) <>
        String.pad_leading("MP/JSON", 12))
IO.puts(String.duplicate("-", 92))

Enum.each(inputs, fn {name, data} ->
  cbor = byte_size(Codec.cbor_encode(data))
  cbor_det = byte_size(Codec.cbor_encode_det(data))
  msgpack = byte_size(Codec.msgpack_encode(data))
  json = byte_size(Codec.json_encode(data))

  cbor_ratio = Float.round(cbor / json * 100, 1)
  msgpack_ratio = Float.round(msgpack / json * 100, 1)

  IO.puts(
    String.pad_trailing(name, 20) <>
    String.pad_leading("#{cbor}", 12) <>
    String.pad_leading("#{cbor_det}", 12) <>
    String.pad_leading("#{msgpack}", 12) <>
    String.pad_leading("#{json}", 12) <>
    String.pad_leading("#{cbor_ratio}%", 12) <>
    String.pad_leading("#{msgpack_ratio}%", 12)
  )
end)

IO.puts("\nCBOR/JSON and MP/JSON columns show size as percentage of JSON (lower = better compression)")

################################################################################
# Summary
################################################################################

IO.puts("""

================================================================================
                              BENCHMARK COMPLETE
================================================================================

Reports generated in bench/output/:
  - encoding.html      - Encoding performance with graphs
  - decoding.html      - Decoding performance with graphs
  - roundtrip.html     - Round-trip performance with graphs
  - batch.html         - Batch throughput performance
  - *.md               - Markdown versions of reports
  - *.benchee          - Raw benchmark data for comparison

To compare results over time:
  mix run -e 'Benchee.report(load: ["output/encoding.benchee"])'

================================================================================
""")
