# CBOR vs MsgPack vs JSON Benchmark
#
# Run with: mix bench
# Or: mix run bench.exs
#
# This benchmark compares:
# - bondy_cbor (CBOR RFC 8949)
# - msgpack (MessagePack)
# - json (Erlang OTP json module)

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("CBOR vs MsgPack vs JSON Benchmark")
IO.puts(String.duplicate("=", 60) <> "\n")

# Ensure all applications are started
Application.ensure_all_started(:bondy_cbor)

################################################################################
# Test Data Generation
################################################################################

defmodule BenchData do
  @moduledoc """
  Generate various test data for benchmarking serialization formats.
  """

  # Small integers (fit in 1 byte)
  def small_integers, do: Enum.to_list(0..23)

  # Medium integers (1-2 bytes)
  def medium_integers, do: [24, 100, 255, 256, 1000, 65535]

  # Large integers (4-8 bytes)
  def large_integers, do: [65536, 1_000_000, 4_294_967_295, 1_000_000_000_000]

  # Negative integers
  def negative_integers, do: [-1, -10, -100, -1000, -65536, -1_000_000]

  # Floats
  def floats, do: [0.0, 1.0, -1.0, 3.14159, 1.0e10, -273.15]

  # Short strings (< 24 bytes)
  def short_strings do
    [
      "",
      "a",
      "hello",
      "hello world",
      "The quick brown fox"
    ]
  end

  # Medium strings (24-255 bytes)
  def medium_strings do
    [
      String.duplicate("x", 50),
      String.duplicate("abc", 30),
      String.duplicate("hello ", 20)
    ]
  end

  # Long strings (> 255 bytes)
  def long_strings do
    [
      String.duplicate("x", 500),
      String.duplicate("lorem ipsum ", 100),
      String.duplicate("benchmark ", 200)
    ]
  end

  # Binary data
  def binaries do
    [
      <<>>,
      <<1, 2, 3, 4, 5>>,
      :crypto.strong_rand_bytes(100),
      :crypto.strong_rand_bytes(1000)
    ]
  end

  # Small arrays (< 16 elements)
  def small_arrays do
    [
      [],
      [1],
      [1, 2, 3],
      Enum.to_list(1..10),
      Enum.to_list(1..15)
    ]
  end

  # Medium arrays (16-255 elements)
  def medium_arrays do
    [
      Enum.to_list(1..50),
      Enum.to_list(1..100),
      Enum.to_list(1..200)
    ]
  end

  # Large arrays (> 255 elements)
  def large_arrays do
    [
      Enum.to_list(1..500),
      Enum.to_list(1..1000)
    ]
  end

  # Nested arrays
  def nested_arrays do
    [
      [[1, 2], [3, 4]],
      [[[1]], [[2]], [[3]]],
      Enum.map(1..10, fn i -> Enum.to_list(1..i) end)
    ]
  end

  # Small maps (< 16 keys)
  def small_maps do
    [
      %{},
      %{"a" => 1},
      %{"a" => 1, "b" => 2, "c" => 3},
      Map.new(1..10, fn i -> {"key#{i}", i} end)
    ]
  end

  # Medium maps (16-100 keys)
  def medium_maps do
    [
      Map.new(1..50, fn i -> {"key#{i}", i * 2} end),
      Map.new(1..100, fn i -> {"field_#{i}", "value_#{i}"} end)
    ]
  end

  # Large maps (> 100 keys)
  def large_maps do
    [
      Map.new(1..500, fn i -> {"k#{i}", i} end),
      Map.new(1..1000, fn i -> {"item_#{i}", %{"id" => i, "value" => i * 10}} end)
    ]
  end

  # Nested maps
  def nested_maps do
    [
      %{"level1" => %{"level2" => %{"level3" => "deep"}}},
      %{
        "user" => %{
          "name" => "John",
          "address" => %{
            "street" => "123 Main St",
            "city" => "Somewhere",
            "zip" => "12345"
          }
        }
      }
    ]
  end

  # Mixed types (realistic data structures)
  def mixed_simple do
    %{
      "id" => 12345,
      "name" => "Test Item",
      "active" => true,
      "score" => 98.6,
      "tags" => ["tag1", "tag2", "tag3"]
    }
  end

  def mixed_medium do
    %{
      "id" => 999_999,
      "timestamp" => 1_640_000_000,
      "user" => %{
        "id" => 42,
        "username" => "testuser",
        "email" => "test@example.com",
        "settings" => %{
          "theme" => "dark",
          "notifications" => true,
          "language" => "en"
        }
      },
      "items" => Enum.map(1..20, fn i ->
        %{"id" => i, "name" => "Item #{i}", "price" => i * 10.5}
      end),
      "metadata" => %{
        "version" => "1.0.0",
        "source" => "benchmark"
      }
    }
  end

  def mixed_complex do
    %{
      "request_id" => "550e8400-e29b-41d4-a716-446655440000",
      "timestamp" => 1_700_000_000_000,
      "api_version" => "2.0",
      "data" => %{
        "users" => Enum.map(1..50, fn i ->
          %{
            "id" => i,
            "name" => "User #{i}",
            "email" => "user#{i}@example.com",
            "age" => 20 + rem(i, 50),
            "active" => rem(i, 2) == 0,
            "balance" => i * 100.50,
            "tags" => Enum.map(1..5, fn j -> "tag_#{i}_#{j}" end),
            "preferences" => %{
              "theme" => if(rem(i, 2) == 0, do: "dark", else: "light"),
              "notifications" => rem(i, 3) == 0
            }
          }
        end),
        "pagination" => %{
          "page" => 1,
          "per_page" => 50,
          "total" => 1000,
          "total_pages" => 20
        }
      },
      "meta" => %{
        "server" => "api-server-01",
        "region" => "us-east-1",
        "latency_ms" => 45
      }
    }
  end

  # API response simulation
  def api_response_small do
    %{
      "status" => "ok",
      "data" => %{"id" => 1, "value" => "test"}
    }
  end

  def api_response_large do
    %{
      "status" => "ok",
      "count" => 100,
      "data" => Enum.map(1..100, fn i ->
        %{
          "id" => i,
          "type" => "record",
          "attributes" => %{
            "name" => "Record #{i}",
            "created_at" => "2024-01-#{String.pad_leading("#{rem(i, 28) + 1}", 2, "0")}",
            "updated_at" => "2024-01-#{String.pad_leading("#{rem(i, 28) + 1}", 2, "0")}",
            "score" => i * 1.5,
            "flags" => [rem(i, 2) == 0, rem(i, 3) == 0, rem(i, 5) == 0]
          }
        }
      end)
    }
  end
end

################################################################################
# Encoding Wrappers
################################################################################

defmodule Encoders do
  @moduledoc """
  Wrapper functions for encoding with different libraries.
  """

  # CBOR encoding using bondy_cbor
  def cbor_encode(term) do
    # Convert Elixir types to Erlang-compatible types
    erlang_term = to_erlang(term)
    :bondy_cbor.encode(erlang_term) |> :erlang.iolist_to_binary()
  end

  def cbor_encode_deterministic(term) do
    erlang_term = to_erlang(term)
    :bondy_cbor.encode_deterministic(erlang_term)
  end

  # MsgPack encoding
  def msgpack_encode(term) do
    erlang_term = to_erlang(term)
    :msgpack.pack(erlang_term, [{:map_format, :map}])
  end

  # JSON encoding using Erlang's json module
  def json_encode(term) do
    # JSON requires string keys in maps, convert atoms
    json_term = to_json_compatible(term)
    :json.encode(json_term) |> :erlang.iolist_to_binary()
  end

  # Convert Elixir types to Erlang types
  defp to_erlang(term) when is_map(term) do
    Map.new(term, fn {k, v} -> {to_erlang(k), to_erlang(v)} end)
  end
  defp to_erlang(term) when is_list(term) do
    Enum.map(term, &to_erlang/1)
  end
  defp to_erlang(true), do: true
  defp to_erlang(false), do: false
  defp to_erlang(nil), do: :null
  defp to_erlang(term) when is_binary(term), do: term
  defp to_erlang(term) when is_atom(term), do: :erlang.atom_to_binary(term, :utf8)
  defp to_erlang(term), do: term

  # Convert to JSON-compatible format (strings must be binaries, maps need binary keys)
  defp to_json_compatible(term) when is_map(term) do
    Map.new(term, fn {k, v} ->
      key = if is_binary(k), do: k, else: to_string(k)
      {key, to_json_compatible(v)}
    end)
  end
  defp to_json_compatible(term) when is_list(term) do
    Enum.map(term, &to_json_compatible/1)
  end
  defp to_json_compatible(true), do: true
  defp to_json_compatible(false), do: false
  defp to_json_compatible(nil), do: :null
  defp to_json_compatible(term) when is_atom(term), do: :erlang.atom_to_binary(term, :utf8)
  defp to_json_compatible(term), do: term
end

################################################################################
# Decoding Wrappers
################################################################################

defmodule Decoders do
  @moduledoc """
  Wrapper functions for decoding with different libraries.
  """

  def cbor_decode(binary) do
    :bondy_cbor.decode(binary)
  end

  def msgpack_decode(binary) do
    :msgpack.unpack(binary, [{:map_format, :map}])
  end

  def json_decode(binary) do
    :json.decode(binary)
  end
end

################################################################################
# Benchmark Execution
################################################################################

# Prepare test data
IO.puts("Preparing test data...\n")

test_cases = %{
  # Primitive types
  "small_integers" => BenchData.small_integers(),
  "medium_integers" => BenchData.medium_integers(),
  "large_integers" => BenchData.large_integers(),
  "negative_integers" => BenchData.negative_integers(),
  "floats" => BenchData.floats(),

  # Strings
  "short_strings" => BenchData.short_strings(),
  "medium_strings" => BenchData.medium_strings(),
  "long_strings" => BenchData.long_strings(),

  # Arrays
  "small_arrays" => BenchData.small_arrays(),
  "medium_arrays" => BenchData.medium_arrays(),
  "large_arrays" => BenchData.large_arrays(),
  "nested_arrays" => BenchData.nested_arrays(),

  # Maps
  "small_maps" => BenchData.small_maps(),
  "medium_maps" => BenchData.medium_maps(),
  "large_maps" => BenchData.large_maps(),
  "nested_maps" => BenchData.nested_maps(),

  # Mixed/realistic data
  "mixed_simple" => [BenchData.mixed_simple()],
  "mixed_medium" => [BenchData.mixed_medium()],
  "mixed_complex" => [BenchData.mixed_complex()],

  # API responses
  "api_response_small" => [BenchData.api_response_small()],
  "api_response_large" => [BenchData.api_response_large()]
}

# Note: JSON doesn't support raw binary data, so we exclude binary tests for JSON
# and run them separately for CBOR and MsgPack only

################################################################################
# Run Encoding Benchmarks
################################################################################

IO.puts("\n" <> String.duplicate("-", 60))
IO.puts("ENCODING BENCHMARKS")
IO.puts(String.duplicate("-", 60) <> "\n")

Enum.each(test_cases, fn {name, data_list} ->
  IO.puts("\n### Encoding: #{name} ###\n")

  # Prepare inputs - use the first item for single benchmarks or all for array benchmarks
  input = if length(data_list) == 1, do: hd(data_list), else: data_list

  Benchee.run(
    %{
      "bondy_cbor" => fn -> Enum.each(List.wrap(input), &Encoders.cbor_encode/1) end,
      "bondy_cbor_det" => fn -> Enum.each(List.wrap(input), &Encoders.cbor_encode_deterministic/1) end,
      "msgpack" => fn -> Enum.each(List.wrap(input), &Encoders.msgpack_encode/1) end,
      "json" => fn -> Enum.each(List.wrap(input), &Encoders.json_encode/1) end
    },
    warmup: 1,
    time: 3,
    memory_time: 1,
    print: [configuration: false]
  )
end)

################################################################################
# Run Decoding Benchmarks
################################################################################

IO.puts("\n" <> String.duplicate("-", 60))
IO.puts("DECODING BENCHMARKS")
IO.puts(String.duplicate("-", 60) <> "\n")

Enum.each(test_cases, fn {name, data_list} ->
  IO.puts("\n### Decoding: #{name} ###\n")

  input = if length(data_list) == 1, do: hd(data_list), else: data_list

  # Pre-encode data for decoding benchmarks
  cbor_encoded = Enum.map(List.wrap(input), &Encoders.cbor_encode/1)
  msgpack_encoded = Enum.map(List.wrap(input), &Encoders.msgpack_encode/1)
  json_encoded = Enum.map(List.wrap(input), &Encoders.json_encode/1)

  Benchee.run(
    %{
      "bondy_cbor" => fn -> Enum.each(cbor_encoded, &Decoders.cbor_decode/1) end,
      "msgpack" => fn -> Enum.each(msgpack_encoded, &Decoders.msgpack_decode/1) end,
      "json" => fn -> Enum.each(json_encoded, &Decoders.json_decode/1) end
    },
    warmup: 1,
    time: 3,
    memory_time: 1,
    print: [configuration: false]
  )
end)

################################################################################
# Binary Data Benchmarks (CBOR and MsgPack only - JSON doesn't support binaries)
################################################################################

IO.puts("\n" <> String.duplicate("-", 60))
IO.puts("BINARY DATA BENCHMARKS (CBOR and MsgPack only)")
IO.puts(String.duplicate("-", 60) <> "\n")

binary_data = BenchData.binaries()

IO.puts("\n### Encoding: binaries ###\n")

Benchee.run(
  %{
    "bondy_cbor" => fn -> Enum.each(binary_data, &Encoders.cbor_encode/1) end,
    "bondy_cbor_det" => fn -> Enum.each(binary_data, &Encoders.cbor_encode_deterministic/1) end,
    "msgpack" => fn -> Enum.each(binary_data, &Encoders.msgpack_encode/1) end
  },
  warmup: 1,
  time: 3,
  memory_time: 1,
  print: [configuration: false]
)

IO.puts("\n### Decoding: binaries ###\n")

cbor_binaries = Enum.map(binary_data, &Encoders.cbor_encode/1)
msgpack_binaries = Enum.map(binary_data, &Encoders.msgpack_encode/1)

Benchee.run(
  %{
    "bondy_cbor" => fn -> Enum.each(cbor_binaries, &Decoders.cbor_decode/1) end,
    "msgpack" => fn -> Enum.each(msgpack_binaries, &Decoders.msgpack_decode/1) end
  },
  warmup: 1,
  time: 3,
  memory_time: 1,
  print: [configuration: false]
)

################################################################################
# Size Comparison
################################################################################

IO.puts("\n" <> String.duplicate("-", 60))
IO.puts("ENCODED SIZE COMPARISON")
IO.puts(String.duplicate("-", 60) <> "\n")

size_test_cases = [
  {"mixed_simple", BenchData.mixed_simple()},
  {"mixed_medium", BenchData.mixed_medium()},
  {"mixed_complex", BenchData.mixed_complex()},
  {"api_response_large", BenchData.api_response_large()}
]

IO.puts(String.pad_trailing("Test Case", 25) <>
        String.pad_leading("CBOR", 12) <>
        String.pad_leading("CBOR Det", 12) <>
        String.pad_leading("MsgPack", 12) <>
        String.pad_leading("JSON", 12))
IO.puts(String.duplicate("-", 73))

Enum.each(size_test_cases, fn {name, data} ->
  cbor_size = byte_size(Encoders.cbor_encode(data))
  cbor_det_size = byte_size(Encoders.cbor_encode_deterministic(data))
  msgpack_size = byte_size(Encoders.msgpack_encode(data))
  json_size = byte_size(Encoders.json_encode(data))

  IO.puts(String.pad_trailing(name, 25) <>
          String.pad_leading("#{cbor_size}", 12) <>
          String.pad_leading("#{cbor_det_size}", 12) <>
          String.pad_leading("#{msgpack_size}", 12) <>
          String.pad_leading("#{json_size}", 12))
end)

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("Benchmark Complete!")
IO.puts(String.duplicate("=", 60) <> "\n")
