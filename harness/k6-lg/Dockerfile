# =============================================================================
# k6 load generator image for Fly (co-located with the perf cluster in lhr).
# Runs k6 from inside Fly so client<->server traffic stays intra-region,
# removing the WAN RTT + local-machine backpressure that dominate a laptop run.
#
# The machine idles on `sleep infinity`; run-lg.sh execs `k6 run` over `fly ssh`.
# Build context is the repo root (COPY harness/k6 ...).
# =============================================================================
FROM grafana/k6:latest

# Bake the WAMP client + workload scripts in.
COPY harness/k6 /scripts

# Keep the machine alive so we can exec k6 in it via fly ssh. (grafana/k6 is
# alpine-based; busybox provides sleep + sh for fly ssh.)
USER root
ENTRYPOINT ["sleep", "infinity"]
