# bondy umbrella — bench + Fly substrate + Jepsen task runner
# (https://just.systems)
#
# These recipes drive the bondy_oplog/bondy_db-layer benchmarks (under
# `bench/`, a Mix project) and the Jepsen harness (under `jepsen/`).
# They were extracted from the bondy_mst repo alongside the apps they
# exercise. The MST-library-only benchmarks stay in the bondy_mst repo's
# own `justfile`.

set shell := ["bash", "-cu"]

bench_dir := justfile_directory() / "bench"
output_dir := bench_dir / "_output"

# Jepsen / docker knobs.
jepsen_build_image := "erlang:27"
jepsen_release_name := "bondy_mst_jepsen_release"
jepsen_release_vsn := "0.4.0"

# Show every recipe.
default:
    @just --list

# -----------------------------------------------------------------------------
# Static checks
# -----------------------------------------------------------------------------

# Enforce the storage-stack layering invariant: dependencies flow strictly
# bondy_db -> bondy_oplog -> bondy_mst, with no cycles and no layer-skips.
# Scoped xref check over those three apps (see scripts/check_layering.escript).
xref-layering:
    rebar3 compile
    ./scripts/check_layering.escript _build/default/lib

# -----------------------------------------------------------------------------
# Local benchmarks (oplog/db layer). Compile the umbrella with rebar3,
# fetch the bench Mix deps, then run scripts under bench/benchmarks.
# Reports land in bench/_output/<name>/index.html.
# -----------------------------------------------------------------------------

# Run the full oplog/db benchmark suite.
bench:
    rebar3 compile
    cd {{bench_dir}} && mix deps.get
    cd {{bench_dir}} && mix run benchmarks/all.exs
    @echo ""
    @echo "Reports:"
    @ls -1 {{output_dir}} 2>/dev/null | sed "s|^|  {{output_dir}}/|"

# Run a single benchmark script by name (without the .exs).
#   just bench-one e2e_pipeline
bench-one name:
    rebar3 compile
    cd {{bench_dir}} && mix deps.get
    cd {{bench_dir}} && mix run benchmarks/{{name}}.exs

# Run the substrate read-path primitive benchmarks (HLC, codec, overlay).
bench-primitives:
    rebar3 compile
    cd {{bench_dir}} && mix deps.get
    cd {{bench_dir}} && mix run benchmarks/primitives.exs

# Run the native CRDT primitive benchmarks (apply_op, interpret_cog, codec).
bench-folds:
    rebar3 compile
    cd {{bench_dir}} && mix deps.get
    cd {{bench_dir}} && mix run benchmarks/folds.exs

# Run the bondy_db substrate read-path benchmarks across cache hit rates.
bench-db:
    rebar3 compile
    cd {{bench_dir}} && mix deps.get
    cd {{bench_dir}} && mix run benchmarks/mst_db.exs

# Run the bondy_oplog instance end-to-end benchmarks.
bench-oplog:
    rebar3 compile
    cd {{bench_dir}} && mix deps.get
    cd {{bench_dir}} && mix run benchmarks/oplog.exs

# Run the WAL benchmarks. Disk-dependent — writes to /tmp/bondy_mst_bench_wal.
bench-wal:
    rebar3 compile
    cd {{bench_dir}} && mix deps.get
    cd {{bench_dir}} && mix run benchmarks/wal.exs

# Concurrency: full suite. Pass DURATION_S=N to override per-scenario seconds.
bench-concurrency duration="10":
    rebar3 compile
    cd {{bench_dir}} && mix deps.get
    DURATION_S={{duration}} cd {{bench_dir}} && \
      mix run benchmarks/concurrency_oplog.exs && \
      mix run benchmarks/concurrency_mst_db.exs && \
      mix run benchmarks/concurrency_wal.exs

# Concurrency: oplog instance only.
bench-concurrency-oplog duration="10":
    rebar3 compile
    cd {{bench_dir}} && mix deps.get
    DURATION_S={{duration}} cd {{bench_dir}} && mix run benchmarks/concurrency_oplog.exs

# Concurrency: mst_db substrate only.
bench-concurrency-db duration="10":
    rebar3 compile
    cd {{bench_dir}} && mix deps.get
    DURATION_S={{duration}} cd {{bench_dir}} && mix run benchmarks/concurrency_mst_db.exs

# Concurrency: WAL only.
bench-concurrency-wal duration="8":
    rebar3 compile
    cd {{bench_dir}} && mix deps.get
    DURATION_S={{duration}} cd {{bench_dir}} && mix run benchmarks/concurrency_wal.exs

# End-to-end pipeline benchmark with ECharts dashboard. Drives the full
# bondy_db substrate (WAL → applier → MST → projection → cache → reads)
# under three scenarios. Knobs (all optional, see e2e_pipeline.exs):
#   duration DURATION_S | shards SHARDS | fsync WAL_FSYNC (per_write|batched)
#   batch BATCH_SIZE | cache BYPASS_CACHE | backends BACKENDS (ets,leveled)
bench-e2e duration="10" shards="4" fsync="per_write" batch="1" cache="false" backends="ets,leveled":
    rebar3 compile
    cd {{bench_dir}} && mix deps.get
    cd {{bench_dir}} && \
      ELIXIR_ERL_OPTIONS="+SDio {{shards}}" \
      DURATION_S={{duration}} \
      SHARDS={{shards}} \
      WAL_FSYNC={{fsync}} \
      BATCH_SIZE={{batch}} \
      BYPASS_CACHE={{cache}} \
      BACKENDS={{backends}} \
      mix run benchmarks/e2e_pipeline.exs

# Ephemeral (ets-backed, in-memory) vs durable (leveled-backed) tables,
# head-to-head across the e2e scenarios.
#   ephemeral = ets projection + in-memory MST + batched fsync
#   durable   = leveled projection + pack-store MST + per_write fsync
bench-ephemeral-vs-leveled duration="15" shards="4" cache="false":
    rebar3 compile
    cd {{bench_dir}} && mix deps.get
    cd {{bench_dir}} && \
      ELIXIR_ERL_OPTIONS="+SDio {{shards}}" \
      DURATION_S={{duration}} \
      SHARDS={{shards}} \
      BYPASS_CACHE={{cache}} \
      BACKENDS=ephemeral,durable \
      mix run benchmarks/e2e_pipeline.exs

# Open the most recently generated HTML report (macOS / Linux).
bench-open:
    @latest=$(ls -1t {{output_dir}}/*/index.html 2>/dev/null | head -1); \
    if [ -z "$latest" ]; then \
      echo "no reports under {{output_dir}}"; exit 1; \
    fi; \
    echo "opening $latest"; \
    if command -v open >/dev/null; then open "$latest"; \
    elif command -v xdg-open >/dev/null; then xdg-open "$latest"; \
    else echo "open the file manually: $latest"; fi

# Wipe generated bench artefacts.
bench-clean:
    rm -rf {{output_dir}}
    rm -rf {{bench_dir}}/_build {{bench_dir}}/deps

# -----------------------------------------------------------------------------
# Fly.io Linux bench substrate.
#
# fly.toml lives at the umbrella root because flyctl resolves the build
# context relative to its location, and the Dockerfile's `COPY .` needs
# the umbrella source (the apps + bench). All other Fly assets stay under
# bench/fly/. The in-VM project path is /opt/bondy.
#
# Cost-control rule: always `just bench-fly-down` when you're done.
# -----------------------------------------------------------------------------

# Local Dockerfile validation via docker buildx (~3-5 min, needs Docker Desktop).
# NOTE: On Apple Silicon, linux/amd64 emulation under QEMU can segfault during
# Elixir compilation of certain hex deps; Fly's remote builder runs native
# amd64 and is not affected — if this fails locally past `mix deps.get`,
# deploy to Fly directly to validate the rest.
bench-fly-build-local:
    docker buildx build --platform linux/amd64 \
      -f bench/fly/Dockerfile -t bondy-db-bench:local .

# First-time setup: create app + volume + initial deploy (interactive).
bench-fly-init:
    fly apps create bondy-db-bench --org leapsight
    fly volumes create bench_data --size 10 --region lhr --app bondy-db-bench --yes
    just bench-fly-deploy

# Build + deploy the image to Fly (remote build, preserves volume cache).
bench-fly-deploy:
    fly deploy --remote-only

# Start the VM (idempotent, no-op if already running).
bench-fly-up:
    fly machine start

# Interactive ssh into the VM (auto-starts if stopped).
bench-fly-shell:
    fly ssh console -C "bash -c 'cd /opt/bondy && exec bash'"

# Run a single bench script on the VM, tee output to /data/results/.
#   just bench-fly-run e2e_pipeline
bench-fly-run name:
    fly ssh console -C \
      "bash -c 'mkdir -p /data/results && cd /opt/bondy && just bench-one {{name}} 2>&1 | tee /data/results/{{name}}_\$(date +%Y%m%d_%H%M%S).txt'"

# Applier pipeline residual profiling sweep on the VM (Run A + Run B).
# Drives the e2e bench against leveled-only twice — Run A with full
# per-stage applier telemetry attached, Run B with the per-stage handlers
# detached (control). See APPLIER_PIPELINE_RESIDUAL_PLAN §4.
bench-fly-applier-profile duration="30":
    fly ssh console -C \
      "bash -c 'set -e; mkdir -p /data/results; cd /opt/bondy; \
        ts=\$(date +%Y%m%d_%H%M%S); \
        echo \"=== Run A — full per-stage applier telemetry ===\" | tee /data/results/applier_profile_run_\$ts.log; \
        APPLIER_PROFILE=full \
          just bench-e2e {{duration}} 4 per_write 1 false leveled \
            2>&1 | tee /data/results/applier_profile_runA_full_\$ts.txt; \
        echo \"=== Run B — control (per-stage handlers detached) ===\" | tee -a /data/results/applier_profile_run_\$ts.log; \
        APPLIER_PROFILE=control \
          just bench-e2e {{duration}} 4 per_write 1 false leveled \
            2>&1 | tee /data/results/applier_profile_runB_control_\$ts.txt; \
        echo \"Done. Results in /data/results/applier_profile_*_\$ts.txt\"'"

# Long stability run on a single scenario (Run A only, multiple reps).
# `scenario` matches by name prefix (write_only|mixed|concurrent_rw|read_only).
#   just bench-fly-applier-profile-long mixed 180 5
bench-fly-applier-profile-long scenario="write_only" duration="120" reps="3":
    fly ssh console -C \
      "bash -c 'set -e; mkdir -p /data/results; cd /opt/bondy; \
        ts=\$(date +%Y%m%d_%H%M%S); \
        echo \"=== Long stability run — {{scenario}}, {{reps}} reps × {{duration}}s ===\" \
          | tee /data/results/applier_long_{{scenario}}_\$ts.log; \
        for rep in \$(seq 1 {{reps}}); do \
          echo \"--- Rep \$rep/{{reps}} ---\" | tee -a /data/results/applier_long_{{scenario}}_\$ts.log; \
          APPLIER_PROFILE=full SCENARIOS={{scenario}} \
            just bench-e2e {{duration}} 4 per_write 1 false leveled \
              2>&1 | tee /data/results/applier_long_{{scenario}}_rep\${rep}_\$ts.txt; \
        done; \
        echo \"Done. Results in /data/results/applier_long_{{scenario}}_rep*_\$ts.txt\" \
          | tee -a /data/results/applier_long_{{scenario}}_\$ts.log'"

# Run vmstat/iostat/strace companion data collection during a bench.
bench-fly-companion seconds="60":
    fly ssh console -C \
      "bash -c 'mkdir -p /data/results; ts=\$(date +%Y%m%d_%H%M%S); \
        vmstat 1 {{seconds}} > /data/results/vmstat_\$ts.txt & \
        iostat -x 1 {{seconds}} > /data/results/iostat_\$ts.txt & \
        beam_pid=\$(pgrep -f beam.smp || true); \
        if [ -n \"\$beam_pid\" ]; then \
          strace -c -p \"\$beam_pid\" 2> /data/results/strace_\$ts.txt & \
          sleep 10; kill %3 2>/dev/null || true; \
        else \
          echo \"no BEAM running — start a bench layer first\" >&2; \
        fi; \
        wait'"

# Pull /data/results from the VM into a fresh local dir (timestamped by default).
bench-fly-results dest="":
    #!/usr/bin/env bash
    set -eu
    dest='{{dest}}'
    if [ -z "$dest" ]; then
      dest="./fly-bench-results-$(date +%Y%m%d_%H%M%S)"
    fi
    if [ -e "$dest" ]; then
      echo "destination '$dest' already exists — pick another or remove it first" >&2
      exit 1
    fi
    mkdir -p "$dest"
    remote_tar="/tmp/fly-bench-results-$$.tgz"
    echo "tarring /data/results on the VM..."
    fly ssh console -C "bash -c 'tar czf $remote_tar -C /data results'"
    echo "sftp'ing $remote_tar → $dest/_fetch.tgz"
    ( cd "$dest" && fly ssh sftp get "$remote_tar" )
    mv "$dest/$(basename "$remote_tar")" "$dest/_fetch.tgz"
    echo "extracting → $dest"
    tar xzf "$dest/_fetch.tgz" -C "$dest" --strip-components=1
    rm -f "$dest/_fetch.tgz"
    fly ssh console -C "bash -c 'rm -f $remote_tar'" || true
    echo "done: $dest"

# Tail the VM's logs (boot, entrypoint, stdout).
bench-fly-logs:
    fly logs

# Stop the VM (idle cost drops to volume-only).
bench-fly-down:
    #!/usr/bin/env bash
    set -eu
    ids=$(fly machines list --json | jq -r '.[].id')
    if [ -z "$ids" ]; then
      echo "no machines to stop"; exit 0
    fi
    for id in $ids; do
      echo "stopping $id..."
      fly machines stop "$id"
    done

# DESTRUCTIVE — destroys the app AND its volume (results lost forever).
bench-fly-destroy:
    @echo "This will destroy the bondy-db-bench app and its volume."
    @echo "Volume data (including /data/results) will be PERMANENTLY LOST."
    @echo "Pull results first with: just bench-fly-results"
    @echo ""
    @read -p "Type 'destroy' to confirm: " confirm && \
      [ "$confirm" = "destroy" ] || (echo "aborted"; exit 1)
    fly apps destroy bondy-db-bench --yes

# -----------------------------------------------------------------------------
# Fly.io perf-8x variant (dedicated-CPU, larger IOPS budget). Uses
# fly-8x.toml + the bondy-db-bench-8x app. Every recipe passes
# `--config fly-8x.toml` explicitly (flyctl only auto-discovers fly.toml).
# Always `just bench-fly-8x-down` after a session.
# -----------------------------------------------------------------------------

# First-time setup: create perf-8x app + 40 GB volume + initial deploy.
bench-fly-8x-init:
    fly apps create bondy-db-bench-8x --org leapsight
    fly volumes create bench_data_8x --size 40 --region lhr --app bondy-db-bench-8x --yes
    just bench-fly-8x-deploy

# Build + deploy the image to the perf-8x app (remote build).
bench-fly-8x-deploy:
    fly deploy --config fly-8x.toml --remote-only

# Start the perf-8x VM (idempotent).
bench-fly-8x-up:
    fly machine start --config fly-8x.toml

# Interactive ssh into the perf-8x VM (auto-starts if stopped).
bench-fly-8x-shell:
    fly ssh console --config fly-8x.toml -C "bash -c 'cd /opt/bondy && exec bash'"

# Long stability run on perf-8x (same shape as bench-fly-applier-profile-long).
#   just bench-fly-8x-applier-profile-long write_only 120 3 batched
bench-fly-8x-applier-profile-long scenario="write_only" duration="120" reps="3" fsync="per_write":
    fly ssh console --config fly-8x.toml -C \
      "bash -c 'set -e; mkdir -p /data/results; cd /opt/bondy; \
        ts=\$(date +%Y%m%d_%H%M%S); \
        echo \"=== perf-8x long stability run — {{scenario}} ({{fsync}}), {{reps}} reps × {{duration}}s ===\" \
          | tee /data/results/applier_long_8x_{{scenario}}_{{fsync}}_\$ts.log; \
        for rep in \$(seq 1 {{reps}}); do \
          echo \"--- Rep \$rep/{{reps}} ---\" | tee -a /data/results/applier_long_8x_{{scenario}}_{{fsync}}_\$ts.log; \
          APPLIER_PROFILE=full SCENARIOS={{scenario}} \
            just bench-e2e {{duration}} 4 {{fsync}} 1 false leveled \
              2>&1 | tee /data/results/applier_long_8x_{{scenario}}_{{fsync}}_rep\${rep}_\$ts.txt; \
        done; \
        echo \"Done. Results in /data/results/applier_long_8x_{{scenario}}_{{fsync}}_rep*_\$ts.txt\" \
          | tee -a /data/results/applier_long_8x_{{scenario}}_{{fsync}}_\$ts.log'"

# Ephemeral vs durable on perf-8x.
#   just bench-fly-8x-ephemeral-vs-leveled 120 8
bench-fly-8x-ephemeral-vs-leveled duration="60" shards="4" cache="false":
    fly ssh console --config fly-8x.toml -C \
      "bash -c 'set -e; mkdir -p /data/results; cd /opt/bondy; \
        ts=\$(date +%Y%m%d_%H%M%S); \
        out=/data/results/ephemeral_vs_leveled_8x_\$ts.txt; \
        echo \"=== perf-8x ephemeral vs leveled — {{duration}}s x {{shards}} shards (cache_bypass={{cache}}) ===\" \
          | tee \$out; \
        just bench-e2e {{duration}} {{shards}} per_write 1 {{cache}} ephemeral,durable \
          2>&1 | tee -a \$out; \
        echo \"Done. Result table in \$out; HTML under bench/_output/e2e_pipeline/\" \
          | tee -a \$out'"

# Durable per-shard ceiling + linear shard-scaling on perf-8x.
#   just bench-fly-8x-shard-scaling 90 "1 2 4" 4
bench-fly-8x-shard-scaling duration="90" shard_list="1 2 4 8" writers_per_shard="2" oldstate_cache="false" fsync="per_write":
    fly ssh console --config fly-8x.toml -C \
      "bash -c 'set -e; mkdir -p /data/results; cd /opt/bondy; \
        ts=\$(date +%Y%m%d_%H%M%S); \
        out=/data/results/shard_scaling_8x_oc{{oldstate_cache}}_{{fsync}}_\$ts.log; \
        echo \"=== perf-8x durable shard-scaling — write_only, pack MST, {{fsync}}, {{duration}}s/point, shards={{shard_list}}, {{writers_per_shard}} writers/shard, oldstate_cache={{oldstate_cache}} ===\" \
          | tee \$out; \
        for s in {{shard_list}}; do \
          w=\$((s * {{writers_per_shard}})); \
          echo \"--- shards=\$s writers=\$w oldstate_cache={{oldstate_cache}} fsync={{fsync}} ---\" | tee -a \$out; \
          MST_BACKEND=pack WRITERS=\$w SCENARIOS=write_only \
          APPLY_BATCH_MAX_EVENTS=256 INSTALL_COALESCE_MAX=16 \
          OLDSTATE_CACHE={{oldstate_cache}} \
            just bench-e2e {{duration}} \$s {{fsync}} 1 false leveled \
              2>&1 | tee /data/results/shard_scaling_8x_oc{{oldstate_cache}}_{{fsync}}_s\${s}_\$ts.txt \
              | tee -a \$out; \
        done; \
        echo \"Done. Per-point tables: /data/results/shard_scaling_8x_oc{{oldstate_cache}}_{{fsync}}_s*_\$ts.txt\" \
          | tee -a \$out'"

# Ephemeral fused-writer A/B on perf-8x.
#   just bench-fly-8x-fused-scaling 90 "1 2 4 8" 6
bench-fly-8x-fused-scaling duration="60" shard_list="1 2 4" writers_per_shard="4":
    fly ssh console --config fly-8x.toml -C \
      "bash -c 'set -e; mkdir -p /data/results; cd /opt/bondy; \
        ts=\$(date +%Y%m%d_%H%M%S); \
        out=/data/results/fused_ab_8x_\$ts.log; \
        echo \"=== perf-8x EPHEMERAL fused A/B — write_only, ets MST, batched fsync, {{duration}}s/point, shards={{shard_list}}, {{writers_per_shard}} w/shard ===\" \
          | tee \$out; \
        for f in false true; do \
          for s in {{shard_list}}; do \
            w=\$((s * {{writers_per_shard}})); \
            echo \"--- FUSED=\$f shards=\$s writers=\$w ---\" | tee -a \$out; \
            FUSED=\$f WRITERS=\$w SCENARIOS=write_only PREPOPULATE=10000 \
              just bench-e2e {{duration}} \$s per_write 1 false ephemeral \
                2>&1 | tee /data/results/fused_ab_8x_f\${f}_s\${s}_\$ts.txt \
                | tee -a \$out; \
          done; \
        done; \
        echo \"Done. Per-point: /data/results/fused_ab_8x_f*_s*_\$ts.txt\" \
          | tee -a \$out'"

# Ephemeral ETS WAL A/B on perf-8x (disk vs mem WAL, both fused).
#   just bench-fly-8x-wal-scaling 90 "1" 4 4
bench-fly-8x-wal-scaling duration="60" shard_list="1 2 4" writers_per_shard="4" reps="3":
    fly ssh console --config fly-8x.toml -C \
      "bash -c 'set -e; mkdir -p /data/results; cd /opt/bondy; \
        ts=\$(date +%Y%m%d_%H%M%S); \
        out=/data/results/wal_ab_8x_\$ts.log; \
        echo \"=== perf-8x EPHEMERAL WAL-backend A/B (fused) — write_only, ets MST, {{duration}}s/point, shards={{shard_list}}, {{writers_per_shard}} w/shard, {{reps}} reps ===\" \
          | tee \$out; \
        for r in \$(seq 1 {{reps}}); do \
          if [ \$((r % 2)) -eq 0 ]; then order=\"disk mem\"; else order=\"mem disk\"; fi; \
          for s in {{shard_list}}; do \
            w=\$((s * {{writers_per_shard}})); \
            for b in \$order; do \
              echo \"--- rep=\$r WAL_BACKEND=\$b shards=\$s writers=\$w ---\" | tee -a \$out; \
              WAL_BACKEND=\$b FUSED=true WRITERS=\$w SCENARIOS=write_only PREPOPULATE=10000 \
                just bench-e2e {{duration}} \$s per_write 1 false ephemeral \
                  2>&1 | tee /data/results/wal_ab_8x_r\${r}_\${b}_s\${s}_\$ts.txt \
                  | tee -a \$out; \
            done; \
          done; \
        done; \
        echo \"Done. Per-point: /data/results/wal_ab_8x_r*_*_s*_\$ts.txt\" \
          | tee -a \$out'"

# Ephemeral ETS WAL — 1-shard writer-depth sweep on perf-8x.
#   just bench-fly-8x-wal-writers 90 "8 16 32 64" 3
bench-fly-8x-wal-writers duration="60" writer_list="4 8 16 32" reps="2":
    fly ssh console --config fly-8x.toml -C \
      "bash -c 'set -e; mkdir -p /data/results; cd /opt/bondy; \
        ts=\$(date +%Y%m%d_%H%M%S); \
        out=/data/results/wal_writers_8x_\$ts.log; \
        echo \"=== perf-8x EPHEMERAL 1-shard writer-depth A/B (fused) — write_only, ets MST, {{duration}}s/point, writers={{writer_list}}, {{reps}} reps ===\" \
          | tee \$out; \
        for r in \$(seq 1 {{reps}}); do \
          if [ \$((r % 2)) -eq 0 ]; then order=\"disk mem\"; else order=\"mem disk\"; fi; \
          for w in {{writer_list}}; do \
            for b in \$order; do \
              echo \"--- rep=\$r WAL_BACKEND=\$b shards=1 writers=\$w ---\" | tee -a \$out; \
              WAL_BACKEND=\$b FUSED=true WRITERS=\$w SCENARIOS=write_only PREPOPULATE=10000 \
                just bench-e2e {{duration}} 1 per_write 1 false ephemeral \
                  2>&1 | tee /data/results/wal_writers_8x_r\${r}_\${b}_w\${w}_\$ts.txt \
                  | tee -a \$out; \
            done; \
          done; \
        done; \
        echo \"Done. Per-point: /data/results/wal_writers_8x_r*_*_w*_\$ts.txt\" \
          | tee -a \$out'"

# Ephemeral ETS WAL — bounded-MST A/B on perf-8x (COMPACT on vs off).
#   just bench-fly-8x-wal-compact 90 16 3 250
bench-fly-8x-wal-compact duration="60" writers="8" reps="3" compact_interval="500":
    fly ssh console --config fly-8x.toml -C \
      "bash -c 'set -e; mkdir -p /data/results; cd /opt/bondy; \
        ts=\$(date +%Y%m%d_%H%M%S); \
        out=/data/results/wal_compact_8x_\$ts.log; \
        echo \"=== perf-8x EPHEMERAL bounded-MST A/B (mem, fused) — write_only, 1 shard, {{writers}} writers, {{duration}}s/point, {{reps}} reps, compact_interval={{compact_interval}}ms ===\" \
          | tee \$out; \
        for r in \$(seq 1 {{reps}}); do \
          if [ \$((r % 2)) -eq 0 ]; then order=\"false true\"; else order=\"true false\"; fi; \
          for c in \$order; do \
            echo \"--- rep=\$r COMPACT=\$c writers={{writers}} ---\" | tee -a \$out; \
            WAL_BACKEND=mem FUSED=true WRITERS={{writers}} SCENARIOS=write_only PREPOPULATE=10000 \
              COMPACT=\$c COMPACT_INTERVAL_MS={{compact_interval}} \
              just bench-e2e {{duration}} 1 per_write 1 false ephemeral \
                2>&1 | tee /data/results/wal_compact_8x_r\${r}_c\${c}_\$ts.txt \
                | tee -a \$out; \
          done; \
        done; \
        echo \"Done. Per-point: /data/results/wal_compact_8x_r*_c*_\$ts.txt\" \
          | tee -a \$out'"

# Write→readable latency sampling overhead on perf-8x.
#   just bench-fly-8x-latency 90 8
bench-fly-8x-latency e2e_duration="60" shards="4":
    fly ssh console --config fly-8x.toml -C \
      "bash -c 'set -e; mkdir -p /data/results; cd /opt/bondy; \
        ts=\$(date +%Y%m%d_%H%M%S); \
        log=/data/results/latency_8x_\$ts.log; \
        echo \"=== perf-8x latency sampling overhead — \$ts ===\" | tee \$log; \
        echo \"--- microbench: per-write sampling cost ---\" | tee -a \$log; \
        just bench-one latency_sampling 2>&1 | tee /data/results/latency_micro_\$ts.txt | tee -a \$log; \
        echo \"--- e2e A/B: ephemeral write_only, sampling OFF ---\" | tee -a \$log; \
        LATENCY_SAMPLING=off SCENARIOS=write_only \
          just bench-e2e {{e2e_duration}} {{shards}} batched 1 false ephemeral \
          2>&1 | tee /data/results/latency_e2e_off_\$ts.txt | tee -a \$log; \
        echo \"--- e2e A/B: ephemeral write_only, sampling ON ---\" | tee -a \$log; \
        LATENCY_SAMPLING=on SCENARIOS=write_only \
          just bench-e2e {{e2e_duration}} {{shards}} batched 1 false ephemeral \
          2>&1 | tee /data/results/latency_e2e_on_\$ts.txt | tee -a \$log; \
        echo \"Done. Results: /data/results/latency_*_\$ts.*\" | tee -a \$log'"

# Pull /data/results from the perf-8x VM into a fresh local dir.
bench-fly-8x-results dest="":
    #!/usr/bin/env bash
    set -eu
    dest='{{dest}}'
    if [ -z "$dest" ]; then
      dest="./fly-bench-results-8x-$(date +%Y%m%d_%H%M%S)"
    fi
    if [ -e "$dest" ]; then
      echo "destination '$dest' already exists — pick another or remove it first" >&2
      exit 1
    fi
    mkdir -p "$dest"
    remote_tar="/tmp/fly-bench-results-8x-$$.tgz"
    echo "tarring /data/results on the perf-8x VM..."
    fly ssh console --config fly-8x.toml -C "bash -c 'tar czf $remote_tar -C /data results'"
    local_tar="$dest/_fetch.tgz"
    echo "sftp'ing $remote_tar → $local_tar"
    fly ssh sftp get --config fly-8x.toml "$remote_tar" > "$local_tar"
    echo "extracting → $dest"
    tar xzf "$local_tar" -C "$dest" --strip-components=1
    rm -f "$local_tar"
    fly ssh console --config fly-8x.toml -C "bash -c 'rm -f $remote_tar'" || true
    echo "done: $dest"

# Tail the perf-8x VM's logs.
bench-fly-8x-logs:
    fly logs --config fly-8x.toml

# Stop the perf-8x VM.
bench-fly-8x-down:
    fly machine stop --config fly-8x.toml

# DESTRUCTIVE — destroys the perf-8x app AND its 40 GB volume.
bench-fly-8x-destroy:
    @echo "This will destroy the bondy-db-bench-8x app and its 40 GB volume."
    @echo "Volume data (including /data/results) will be PERMANENTLY LOST."
    @echo "Pull results first with: just bench-fly-8x-results"
    @echo ""
    @read -p "Type 'destroy' to confirm: " confirm && \
      [ "$confirm" = "destroy" ] || (echo "aborted"; exit 1)
    fly apps destroy bondy-db-bench-8x --yes

# -----------------------------------------------------------------------------
# Jepsen harness (jepsen/). The Erlang shim (bondy_mst_jepsen) depends on
# bondy_db via _checkouts symlinks to apps/. Ported from the bondy_mst
# Makefile; the in-container project path is /usr/src/bondy.
# -----------------------------------------------------------------------------

# Build a Linux release of the jepsen shim inside a one-shot Docker
# container. Produces a tarball the Jepsen control container installs
# onto n1/n2/n3. REBAR_BASE_DIR is forced off-tree so the in-container
# OTP doesn't trip over host-compiled .beam files.
rel-jepsen:
    docker run --rm \
      -v "$(pwd)":/usr/src/bondy \
      -e REBAR_BASE_DIR=/tmp/jepsen_build \
      -w /usr/src/bondy/jepsen/bondy_mst_jepsen \
      {{jepsen_build_image}} \
      bash -c 'rebar3 tar -n {{jepsen_release_name}} && cp /tmp/jepsen_build/default/rel/{{jepsen_release_name}}/{{jepsen_release_name}}-{{jepsen_release_vsn}}.tar.gz /usr/src/bondy/jepsen/jepsen.bondymst/'

# Same as rel-jepsen but builds locally (skip Docker). Only useful on a
# Linux dev box; macOS-built releases will not run inside the Debian nodes.
rel-jepsen-local:
    cd jepsen/bondy_mst_jepsen && rebar3 release tar
    cp jepsen/bondy_mst_jepsen/_build/default/rel/{{jepsen_release_name}}/{{jepsen_release_name}}-{{jepsen_release_vsn}}.tar.gz jepsen/jepsen.bondymst/

# Bring up the 3-node docker compose cluster + provision.
jepsen-up:
    cd jepsen/docker && \
      test -f shared/jepsen-bot || ssh-keygen -t rsa -m pem \
        -f shared/jepsen-bot -C jepsen-bot -N '' && \
      docker compose up --detach && \
      ./provision.sh

# Tear down the docker compose cluster.
jepsen-down:
    cd jepsen/docker && docker compose down

# Re-run the provision step against the running cluster.
jepsen-provision:
    cd jepsen/docker && ./provision.sh

# Wipe generated jepsen artefacts (leiningen + rebar3 build + test scratch).
# Preserves jepsen/store_runs/, the _checkouts symlinks, and the SSH keys.
jepsen-clean:
    rm -rf {{justfile_directory()}}/jepsen/jepsen.bondymst/target
    rm -rf {{justfile_directory()}}/jepsen/jepsen.bondymst/store
    rm -rf {{justfile_directory()}}/jepsen/bondy_mst_jepsen/_build

# =============================================================================
# Test harness — M0 Fly fault-injection spike (harness/m0-fly-spike)
# Design: _design/test-harness/06 §M0. Requires `fly auth login` + a Fly org.
# =============================================================================

# One-shot: build+deploy 3 nodes, probe fault capability, render the report.
#   FLY_ORG=<org> just m0-run
m0-run:
    ./harness/m0-fly-spike/run-spike.sh

# Build+deploy the 3-node M0 cluster only (remote build), then scale to 3.
m0-deploy:
    fly deploy --config harness/m0-fly-spike/fly.toml \
      --dockerfile harness/m0-fly-spike/Dockerfile \
      --app bondy-perf-m0 --remote-only --ha=false --yes
    fly scale count 3 --app bondy-perf-m0 --yes

# Re-probe an already-running cluster (skip deploy + scale).
m0-probe:
    M0_SKIP_DEPLOY=1 ./harness/m0-fly-spike/run-spike.sh

# Tail cluster logs.
m0-logs:
    fly logs --app bondy-perf-m0

# SSH into a node (auto-starts one if stopped).
m0-shell:
    fly ssh console --app bondy-perf-m0

# Stop all machines (idle cost drops to volume-only).
m0-down:
    #!/usr/bin/env bash
    set -eu
    ids=$(fly machines list --app bondy-perf-m0 --json | jq -r '.[].id')
    for id in $ids; do echo "stopping $id"; fly machines stop "$id" --app bondy-perf-m0; done

# DESTRUCTIVE — destroy the app AND its volumes (probe output is lost).
m0-destroy:
    @echo "This destroys the bondy-perf-m0 app and all its volumes."
    @read -p "Type 'destroy' to confirm: " c && [ "$c" = "destroy" ] || (echo aborted; exit 1)
    fly apps destroy bondy-perf-m0 --yes

# =============================================================================
# Test harness — perf cluster + k6 smoke (harness/perf-cluster, harness/k6)
# Requires `fly auth login` + a Fly org; the smoke needs k6 (brew install k6).
# =============================================================================

# Deploy the 3-node perf cluster (anonymous WS realm) + print the k6 command.
#   FLY_ORG=<org> just perf-deploy
perf-deploy:
    ./harness/perf-cluster/run-perf.sh

# Re-check health + reprint the run command (no redeploy).
perf-info:
    M0_SKIP_DEPLOY=1 ./harness/perf-cluster/run-perf.sh

# Run the pub/sub smoke against the perf cluster (default 50 VUs).
#   just perf-smoke 200
perf-smoke vus="50":
    k6 run -e WS_URL=wss://bondy-perf-1.fly.dev/ws -e REALM=com.leapsight.perf -e VUS={{vus}} harness/k6/pubsub_smoke.js

perf-logs:
    fly logs --app bondy-perf-1

perf-shell:
    fly ssh console --app bondy-perf-1

# Stop all machines (halt compute cost).
perf-down:
    #!/usr/bin/env bash
    set -eu
    ids=$(fly machines list --app bondy-perf-1 --json | jq -r '.[].id')
    for id in $ids; do echo "stopping $id"; fly machines stop "$id" --app bondy-perf-1; done

# DESTRUCTIVE — destroy the bondy-perf-1 app.
perf-destroy:
    @echo "This destroys the bondy-perf-1 app and all its machines."
    @read -p "Type 'destroy' to confirm: " c && [ "$c" = "destroy" ] || (echo aborted; exit 1)
    fly apps destroy bondy-perf-1 --yes

# Deploy a co-located k6 load generator in lhr and run the smoke from INSIDE Fly
# (no WAN). First run builds+deploys the LG; use perf-lg-run to reuse it.
#   FLY_ORG=<org> just perf-lg 200
perf-lg vus="50":
    VUS={{vus}} ./harness/k6-lg/run-lg.sh

# Re-run the smoke on the already-deployed LG (no redeploy).
perf-lg-run vus="50":
    SKIP_DEPLOY=1 VUS={{vus}} ./harness/k6-lg/run-lg.sh

# Destroy the LG app.
perf-lg-destroy:
    fly apps destroy bondy-perf-lg --yes
