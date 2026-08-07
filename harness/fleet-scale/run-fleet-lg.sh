#!/usr/bin/env bash
# =============================================================================
# Fleet-scale distributed load: deploys/scales the bondy-fleet-lg app, then
# runs k6 on every started machine in parallel -- one machine dedicated to
# the SUBSCRIBER role (3K users x 2K subs each, in groups of GROUP_SIZE
# sharing an identical vehicle set), the rest split across the PUBLISHER
# role (each VU = one vehicle, own topic, PUB_INTERVAL_MS publish rate).
#
# Publisher VU_OFFSETs are partitioned across publisher machines so vehicle
# ids (= VU_OFFSET + __VU) never collide.
#
#   FLY_ORG=<org> [NODES=3] [PUB_VUS_TOTAL=450000] [SUB_VUS_TOTAL=3000] \
#     ./harness/fleet-scale/run-fleet-lg.sh
#   SKIP_DEPLOY=1 ... to reuse already-deployed/scaled LG machines.
# =============================================================================
set -euo pipefail
if [ "${BASH_VERSINFO:-0}" -lt 4 ]; then echo "need bash>=4 (brew install bash)"; exit 1; fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
APP="bondy-fleet-lg"
TARGET="bondy-fleet-1"
ORG="${FLY_ORG:-leapsight}"
REGION="${FLY_REGION:-lhr}"
NODES="${NODES:-3}"
WS_URL="${WS_URL:-wss://${TARGET}.fly.dev/ws}"
REALM="${REALM:-com.leapsight.fleet}"
PUB_VUS_TOTAL="${PUB_VUS_TOTAL:-450000}"
SUB_VUS_TOTAL="${SUB_VUS_TOTAL:-3000}"
GROUP_SIZE="${GROUP_SIZE:-5}"
SUBS_PER_USER="${SUBS_PER_USER:-2000}"
VEHICLE_POOL="${VEHICLE_POOL:-500000}"
PUB_INTERVAL_MS="${PUB_INTERVAL_MS:-1000}"
RAMP="${RAMP:-120s}"; HOLD="${HOLD:-60s}"; SESSION_MS="${SESSION_MS:-240000}"
ULIMIT_N="${ULIMIT_N:-1048576}"
OUT="$HERE/out"; mkdir -p "$OUT"; rm -f "$OUT"/*.txt

cd "$ROOT"
say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

command -v fly >/dev/null || die "flyctl not on PATH"
command -v jq  >/dev/null || die "jq not on PATH"
fly auth whoami >/dev/null 2>&1 || die "not logged in -- fly auth login"

if [ "${SKIP_DEPLOY:-0}" != "1" ]; then
  if ! fly apps list --json | jq -e --arg a "$APP" '.[]|select(.Name==$a)' >/dev/null 2>&1; then
    say "creating app $APP in org $ORG"; fly apps create "$APP" --org "$ORG"
  fi
  say "deploying k6 LG image to $REGION"
  fly deploy --config harness/fleet-scale/lg-fly.toml --dockerfile harness/k6-lg/Dockerfile \
    --app "$APP" --regions "$REGION" --remote-only --ha=false --yes
  say "scaling to $NODES machines in $REGION"
  fly scale count "$NODES" --app "$APP" --region "$REGION" --yes
fi

# `fly deploy` updates a STOPPED machine in place and leaves it stopped, and
# `fly scale count` only reconciles how many exist -- neither starts anything.
# An LG app idle long enough to have been suspended therefore comes back fully
# deployed and entirely down, and the loop below just watches started=0 until
# it gives up. Start them explicitly; already-running machines are unaffected.
say "starting any stopped LG machines"
for M in $(fly machines list --app "$APP" --json \
            | jq -r '.[]|select(.state!="started")|.id'); do
  echo "  starting $M"
  fly machine start "$M" --app "$APP" >/dev/null 2>&1 || \
    echo "  !! could not start $M"
done

say "waiting for $NODES LG machines to be running"
for i in $(seq 1 40); do
  started=$(fly machines list --app "$APP" --json | jq '[.[]|select(.state=="started")]|length')
  [ "${started:-0}" -ge "$NODES" ] && break; sleep 6
done
[ "${started:-0}" -ge "$NODES" ] || die "LG machines did not start"

ids=()
while IFS= read -r id; do ids+=("$id"); done \
  < <(fly machines list -a "$APP" --json | jq -r '.[]|select(.state=="started")|.id')
n=${#ids[@]}
[ "$n" -ge 2 ] || die "need at least 2 LG machines (1 subscriber + 1+ publisher), got $n"

sub_machine="${ids[0]}"
pub_machines=("${ids[@]:1}")
n_pub=${#pub_machines[@]}
pub_vus_per_lg=$(( PUB_VUS_TOTAL / n_pub ))

# k6 holds a JS context + WS buffers per VU -- empirically ~150-180 KB for this
# script, so a 32 GB performance-16x tops out around 180 K VUs. Past that k6 is
# OOM-killed DURING VU init: it prints "Init [ nn% ]" progress, dies, and the
# per-LG output file ends up with no scenario results at all. That failure is
# silent in the summary (the PUBLISHERS section is simply empty) and reads as
# "the run happened" -- so refuse up front rather than burn a campaign.
# Observed 2026-08-06: 225 K VUs/LG died at 78% init (~175 K VUs).
PUB_VUS_PER_LG_MAX="${PUB_VUS_PER_LG_MAX:-180000}"
if [ "$pub_vus_per_lg" -gt "$PUB_VUS_PER_LG_MAX" ]; then
  die "$pub_vus_per_lg publisher VUs per LG exceeds the ~${PUB_VUS_PER_LG_MAX} \
that fits in 32 GB; k6 will be OOM-killed mid-init and the publishers will \
produce NO results. Add LG machines (NODES=$(( (PUB_VUS_TOTAL / PUB_VUS_PER_LG_MAX) + 2 ))) \
or lower PUB_VUS_TOTAL."
fi

say "$n LGs: 1 subscriber ($SUB_VUS_TOTAL VUs) + $n_pub publisher(s) (${pub_vus_per_lg} VUs each, ${PUB_VUS_TOTAL} total) -> $WS_URL"

pids=()

# Subscriber LG.
echo "   SUB  $sub_machine  VUS=$SUB_VUS_TOTAL GROUP_SIZE=$GROUP_SIZE SUBS_PER_USER=$SUBS_PER_USER"
fly ssh console --app "$APP" --machine "$sub_machine" -C \
  "sh -c 'ulimit -n $ULIMIT_N 2>/dev/null; k6 run -e ROLE=subscriber -e WS_URL=$WS_URL -e REALM=$REALM -e VUS=$SUB_VUS_TOTAL -e VU_OFFSET=0 -e GROUP_SIZE=$GROUP_SIZE -e SUBS_PER_USER=$SUBS_PER_USER -e VEHICLE_POOL=$VEHICLE_POOL -e RAMP=$RAMP -e HOLD=$HOLD -e SESSION_MS=$SESSION_MS /scripts/fleet_smoke.js'" \
  > "$OUT/sub.txt" 2>&1 &
pids+=("$!")

# Publisher LGs, each a disjoint VU_OFFSET slice of the vehicle pool.
for i in "${!pub_machines[@]}"; do
  offset=$(( i * pub_vus_per_lg ))
  echo "   PUB$i ${pub_machines[$i]}  VUS=$pub_vus_per_lg VU_OFFSET=$offset"
  fly ssh console --app "$APP" --machine "${pub_machines[$i]}" -C \
    "sh -c 'ulimit -n $ULIMIT_N 2>/dev/null; k6 run -e ROLE=publisher -e WS_URL=$WS_URL -e REALM=$REALM -e VUS=$pub_vus_per_lg -e VU_OFFSET=$offset -e PUB_INTERVAL_MS=$PUB_INTERVAL_MS -e VEHICLE_POOL=$VEHICLE_POOL -e RAMP=$RAMP -e HOLD=$HOLD -e SESSION_MS=$SESSION_MS /scripts/fleet_smoke.js'" \
    > "$OUT/pub$i.txt" 2>&1 &
  pids+=("$!")
done

say "waiting for all LGs to finish (ramp=$RAMP hold=$HOLD, so allow $((${RAMP%s} + ${HOLD%s} + 30))s+)..."
for p in "${pids[@]}"; do wait "$p" || true; done

line()  { { grep -E "^ *$2" "$1" || true; } | sed 's/^ *//' | head -1; }

echo; echo "==================== SUBSCRIBER ===================="
line "$OUT/sub.txt" 'wamp_delivery_latency_ms\.'
line "$OUT/sub.txt" 'wamp_welcome_latency_ms\.'
line "$OUT/sub.txt" 'wamp_subscribe_latency_ms\.'
line "$OUT/sub.txt" 'wamp_subscribe_burst_ms\.'
line "$OUT/sub.txt" 'wamp_all_subscribed_ok'
line "$OUT/sub.txt" 'wamp_session_ok'
line "$OUT/sub.txt" 'wamp_errors'
line "$OUT/sub.txt" 'wamp_aborts'
line "$OUT/sub.txt" 'wamp_proto_errors'
line "$OUT/sub.txt" 'wamp_parse_errors'
line "$OUT/sub.txt" 'wamp_ws_connect_errors'
{ grep -E '✓ ws handshake 101|✗ ws handshake 101|↳' "$OUT/sub.txt" || true; } | sed 's/^ *//' | head -2

echo; echo "==================== PUBLISHERS ===================="
for i in "${!pub_machines[@]}"; do
  f="$OUT/pub$i.txt"
  echo "--- PUB$i ---"
  line "$f" 'wamp_session_ok'
  line "$f" 'wamp_publishes_sent'
  line "$f" 'wamp_welcome_latency_ms\.'
  line "$f" 'wamp_errors'
  line "$f" 'wamp_aborts'
  line "$f" 'wamp_ws_connect_errors'
  { grep -E '✓ ws handshake 101|✗ ws handshake 101|↳' "$f" || true; } | sed 's/^ *//' | head -2
done

echo; echo "raw per-LG output: $OUT/*.txt"
