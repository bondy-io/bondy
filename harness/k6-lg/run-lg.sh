#!/usr/bin/env bash
# =============================================================================
# Deploy the co-located k6 load generator (lhr) and run the pub/sub smoke from
# INSIDE Fly against the perf cluster -- so WAN + local-machine backpressure drop
# out and the latency reflects the router, not the transatlantic link.
#
#   FLY_ORG=<org> [VUS=50] [HOLD=30s] ./harness/k6-lg/run-lg.sh
#   SKIP_DEPLOY=1 ... to reuse an already-deployed LG machine.
# =============================================================================
set -euo pipefail
if [ "${BASH_VERSINFO:-0}" -lt 4 ]; then echo "need bash>=4 (brew install bash)"; exit 1; fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="bondy-perf-lg"
TARGET="bondy-perf-1"
ORG="${FLY_ORG:-leapsight}"
REGION="${FLY_REGION:-lhr}"
# Public hostname, but reached FROM an lhr machine -> Fly anycast routes to the
# lhr edge, so the path stays intra-region (no transatlantic hop).
WS_URL="${WS_URL:-wss://${TARGET}.fly.dev/ws}"
REALM="${REALM:-com.leapsight.perf}"
VUS="${VUS:-50}"; RAMP="${RAMP:-10s}"; HOLD="${HOLD:-30s}"
SESSION_MS="${SESSION_MS:-40000}"; PUB_INTERVAL_MS="${PUB_INTERVAL_MS:-200}"
PER_VU="${PER_VU:-0}"   # 1 = per-VU topic (self-delivery, scalable); 0 = shared topic (fanout)
SCRIPT="${SCRIPT:-pubsub_smoke.js}"   # pubsub_smoke.js | rpc_smoke.js

cd "$ROOT"
say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
command -v fly >/dev/null || die "flyctl not on PATH"
fly auth whoami >/dev/null 2>&1 || die "not logged in -- fly auth login"

if [ "${SKIP_DEPLOY:-0}" != "1" ]; then
  if ! fly apps list --json | jq -e --arg a "$APP" '.[]|select(.Name==$a)' >/dev/null 2>&1; then
    say "creating app $APP in org $ORG"; fly apps create "$APP" --org "$ORG"
  fi
  say "deploying k6 LG image to $REGION"
  fly deploy --config harness/k6-lg/fly.toml --dockerfile harness/k6-lg/Dockerfile \
    --app "$APP" --regions "$REGION" --remote-only --ha=false --yes
fi

say "waiting for the LG machine to be running"
for i in $(seq 1 20); do
  started=$(fly machines list --app "$APP" --json | jq '[.[]|select(.state=="started")]|length')
  [ "${started:-0}" -ge 1 ] && break; sleep 6
done
[ "${started:-0}" -ge 1 ] || die "LG machine did not start"

say "k6 version on the LG"
fly ssh console --app "$APP" -C "k6 version" 2>&1 | tail -1

say "running $SCRIPT from lhr: VUS=$VUS HOLD=$HOLD PER_VU=$PER_VU -> $WS_URL"
fly ssh console --app "$APP" -C \
  "k6 run -e WS_URL=$WS_URL -e REALM=$REALM -e VUS=$VUS -e RAMP=$RAMP -e HOLD=$HOLD -e SESSION_MS=$SESSION_MS -e PUB_INTERVAL_MS=$PUB_INTERVAL_MS -e CALL_INTERVAL_MS=$PUB_INTERVAL_MS -e PER_VU=$PER_VU /scripts/$SCRIPT"

echo
echo "Tear down the LG when done:  fly apps destroy $APP --yes"
