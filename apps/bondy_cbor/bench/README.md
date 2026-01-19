# bondy_cbor Benchmarks

Comprehensive benchmarks comparing `bondy_cbor` (CBOR RFC 8949) with `msgpack` and Erlang's built-in `json` module.

## Prerequisites

- Elixir 1.14+
- Erlang/OTP 27+ (for the `json` module)

## Setup

```bash
cd bench
mix deps.get
mix compile
```

## Running Benchmarks

### Smoke Test

Verify all libraries are working:

```bash
mix run smoke_test.exs
```

### Quick Benchmark

Fast benchmark with console output:

```bash
mix run bench.exs
```

### Benchmark with HTML Reports

Generates detailed HTML reports with graphs:

```bash
mix run bench_report.exs
```

Reports are saved to `bench/output/`:
- `encoding_benchmark.html`
- `decoding_benchmark.html`
- `roundtrip_benchmark.html`

### Comprehensive Benchmark

Full benchmark suite with all metrics:

```bash
mix run bench_comprehensive.exs
```

This measures:
- **Throughput**: Operations per second
- **Latency**: Average, median, 99th percentile, min, max
- **Memory**: Total allocated, allocation count
- **CPU**: Reduction counts (Erlang VM work units)
- **Size**: Encoded byte sizes

## Test Cases

The benchmarks cover various data patterns:

| Category | Description |
|----------|-------------|
| **Integers** | Small (0-23), medium (24-65535), large (>65535), negative |
| **Floats** | Simple, high precision, scientific notation |
| **Strings** | Short (<24 bytes), medium (24-255), long (>255), unicode |
| **Arrays** | Small (<16), medium (16-255), large (>255), nested |
| **Maps** | Small (<16 keys), medium, large (>100 keys), nested |
| **Mixed** | Realistic API payloads of varying sizes |
| **Binaries** | Raw binary data (CBOR/MsgPack only) |

## Payload Sizes

| Name | Description | Approximate JSON Size |
|------|-------------|----------------------|
| tiny | Minimal object | ~50 bytes |
| small | Simple object with array | ~200 bytes |
| medium | Nested structure with array of objects | ~2 KB |
| large | Complex structure with 100 records | ~20 KB |
| very_large | Batch of 500 records | ~100 KB |

## Metrics Explained

### Throughput (ips)
Operations per second. Higher is better.

### Latency
- **Average**: Mean execution time
- **Median**: 50th percentile (typical case)
- **p99**: 99th percentile (worst 1% of cases)
- **Std Dev**: Consistency (lower = more predictable)

### Memory
- **Memory**: Bytes allocated per operation
- **Allocs**: Number of allocations per operation

### Reductions
Erlang VM work units. Proxy for CPU usage. Lower is better.

## Output Files

After running `bench_comprehensive.exs`:

```
bench/output/
├── encoding.html       # Encoding benchmark graphs
├── encoding.md         # Encoding results markdown
├── encoding.benchee    # Raw data for comparison
├── decoding.html       # Decoding benchmark graphs
├── decoding.md         # Decoding results markdown
├── decoding.benchee    # Raw data for comparison
├── roundtrip.html      # Round-trip benchmark graphs
├── roundtrip.md        # Round-trip results markdown
├── roundtrip.benchee   # Raw data for comparison
└── batch.html          # Batch throughput graphs
```

## Comparing Results Over Time

Save and compare benchmark results:

```elixir
# Load and compare saved results
mix run -e 'Benchee.report(load: ["output/encoding.benchee"])'
```

## Notes

- **JSON limitations**: JSON cannot encode raw binary data, so binary tests only compare CBOR and MsgPack.
- **CBOR deterministic mode**: `bondy_cbor_det` uses deterministic encoding (sorted keys, shortest float representation) per RFC 8949 Section 4.2.
- **Warmup**: Benchmarks include warmup period to ensure JIT compilation and cache warming.
