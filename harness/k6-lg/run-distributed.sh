#!/usr/bin/env bash
# =============================================================================
# Distributed load: run k6 on EVERY started machine of the LG app in parallel,
# each with a distinct VU_OFFSET (so per-VU topics stay globally unique), then
# aggregate throughput. Total sessions = (#LG machines) x VUS_PER_LG.
#
# Prereq: the LG app already has N machines (fly scale count N -a bondy-perf-lg)
# built with the current scripts.
#
#   FLY_ORG=<org> VUS_PER_LG=3000 ./harness/k6-lg/run-distributed.sh
# =============================================================================
set -euo pipefail
if [ "${BASH_VERSINFO:-0}" -lt 4 ]; then echo "need bash>=4 (brew install bash)"; exit 1; fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="bondy-perf-lg"
TARGET="bondy-perf-1"
WS_URL="${WS_URL:-wss://${TARGET}.fly.dev/ws}"
REALM="${REALM:-com.leapsight.perf}"
VUS_PER_LG="${VUS_PER_LG:-3000}"
RAMP="${RAMP:-45s}"; HOLD="${HOLD:-45s}"; SESSION_MS="${SESSION_MS:-120000}"
PUB_INTERVAL_MS="${PUB_INTERVAL_MS:-200}"; SCRIPT="${SCRIPT:-pubsub_smoke.js}"; PER_VU="${PER_VU:-1}"
OUT="$HERE/out"; mkdir -p "$OUT"; rm -f "$OUT"/lg*.txt

command -v fly >/dev/null || { echo "flyctl not on PATH"; exit 1; }
fly auth whoami >/dev/null 2>&1 || { echo "not logged in -- fly auth login"; exit 1; }

ids=()
while IFS= read -r id; do ids+=("$id"); done \
  < <(fly machines list -a "$APP" --json | jq -r '.[]|select(.state=="started")|.id')
n=${#ids[@]}
[ "$n" -ge 1 ] || { echo "no started LG machines in $APP"; exit 1; }
echo "==> $n LGs x $VUS_PER_LG VUs = $((n * VUS_PER_LG)) total sessions ($SCRIPT) -> $WS_URL"

pids=()
for i in "${!ids[@]}"; do
  offset=$(( i * VUS_PER_LG ))
  echo "   LG$i ${ids[$i]}  VU_OFFSET=$offset"
  fly ssh console --app "$APP" --machine "${ids[$i]}" -C \
    "k6 run -e WS_URL=$WS_URL -e REALM=$REALM -e VUS=$VUS_PER_LG -e VU_OFFSET=$offset -e RAMP=$RAMP -e HOLD=$HOLD -e SESSION_MS=$SESSION_MS -e PUB_INTERVAL_MS=$PUB_INTERVAL_MS -e PER_VU=$PER_VU /scripts/$SCRIPT" \
    > "$OUT/lg$i.txt" 2>&1 &
  pids+=("$!")
done

echo "==> waiting for $n LGs to finish (~$(( ${RAMP%s} + ${HOLD%s} + 20 ))s)..."
for p in "${pids[@]}"; do wait "$p" || true; done

# ---- aggregate --------------------------------------------------------------
# pull a metric's per-second rate from a k6 text summary
rate()  { grep -E "^ *$2" "$1" | grep -oE '[0-9]+\.?[0-9]*/s' | head -1 | tr -d '/s'; }
line()  { grep -E "^ *$2" "$1" | sed 's/^ *//' | head -1; }

echo; echo "==================== per-LG ===================="
tot_ev=0
for i in "${!ids[@]}"; do
  f="$OUT/lg$i.txt"
  echo "--- LG$i ---"
  line "$f" 'wamp_delivery_latency_ms\.'
  line "$f" 'wamp_welcome_latency_ms\.'
  line "$f" 'wamp_events_received'
  line "$f" 'wamp_errors'
  line "$f" 'wamp_ws_connect_errors'
  ev=$(rate "$f" 'wamp_events_received'); ev=${ev:-0}
  tot_ev=$(awk "BEGIN{print $tot_ev + $ev}")
done
echo; echo "==================== AGGREGATE ===================="
echo "total sessions attempted : $(( n * VUS_PER_LG ))"
echo "total events delivered/s : $tot_ev"
echo "raw per-LG output        : $OUT/lg*.txt"
