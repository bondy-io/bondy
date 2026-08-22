#!/usr/bin/env bash
# =============================================================================
# Fleet-scale distributed load: deploys/scales the bondy-fleet-lg app, then
# runs k6 on every started machine in parallel -- the first SUB_LGS machines
# take the SUBSCRIBER role (users x SUBS_PER_USER subs each, in groups of
# GROUP_SIZE sharing an identical vehicle set), the rest split across the
# PUBLISHER role (each VU = one vehicle, own topic, PUB_INTERVAL_MS rate).
#
# BOTH roles partition VU_OFFSET across their machines: publisher vehicle ids
# (= VU_OFFSET + __VU) never collide, and subscriber group ids
# (= floor((VU_OFFSET + __VU - 1) / GROUP_SIZE)) stay globally unique, so the
# subscriber role is shardable across LGs without changing what it subscribes
# to. A group whose members straddle two LGs is harmless -- membership is
# derived from the GLOBAL index, not from which machine runs the VU.
#
# Sharding the subscriber role is what makes a high-fanout profile measurable:
# a single LG proved out at ~80K deliveries/s (S33), so anything materially
# above that on one machine measures k6, not Bondy.
#
#   FLY_ORG=<org> [NODES=3] [PUB_VUS_TOTAL=450000] [SUB_VUS_TOTAL=3000] \
#     [SUB_LGS=1] ./harness/fleet-scale/run-fleet-lg.sh
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
SUB_LGS="${SUB_LGS:-1}"
GROUP_SIZE="${GROUP_SIZE:-5}"
SUBS_PER_USER="${SUBS_PER_USER:-2000}"
VEHICLE_POOL="${VEHICLE_POOL:-500000}"
PUB_INTERVAL_MS="${PUB_INTERVAL_MS:-1000}"
RAMP="${RAMP:-120s}"; HOLD="${HOLD:-60s}"; SESSION_MS="${SESSION_MS:-240000}"
# Subscriber-side overrides. Delivery latency measured while publishers are
# still ramping is a RAMP measurement, and the aggregate trend k6 prints cannot
# separate the two — which is how a ramp spike gets reported as a steady-state
# tail. Holding the subscriber back until the publishers are up means every
# delivery sample it takes is steady state. Defaults to the publisher values so
# existing invocations are unchanged.
SUB_DELAY_SECS="${SUB_DELAY_SECS:-0}"
# Delivery-tail attribution. Each publisher LG stamps its index into every
# PUBLISH; the subscriber keeps a separate trend per publisher LG. The LGs are
# symmetric, so a systematic gap between those trends is relative clock skew,
# not latency. MEASURE_AFTER_MS (relative to SUBSCRIBER start) splits warmup
# from steady state so the subscribe burst cannot be read as a steady tail.
MEASURE_AFTER_MS="${MEASURE_AFTER_MS:-0}"
SUB_RAMP="${SUB_RAMP:-$RAMP}"; SUB_HOLD="${SUB_HOLD:-$HOLD}"
SUB_SESSION_MS="${SUB_SESSION_MS:-$SESSION_MS}"
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
[ "$SUB_LGS" -ge 1 ] || die "SUB_LGS must be >= 1, got $SUB_LGS"
[ "$n" -gt "$SUB_LGS" ] || die "need at least $(( SUB_LGS + 1 )) LG machines \
($SUB_LGS subscriber + 1+ publisher), got $n"

sub_machines=("${ids[@]:0:$SUB_LGS}")
pub_machines=("${ids[@]:$SUB_LGS}")
n_sub=${#sub_machines[@]}
n_pub=${#pub_machines[@]}
sub_vus_per_lg=$(( SUB_VUS_TOTAL / n_sub ))
pub_vus_per_lg=$(( PUB_VUS_TOTAL / n_pub ))
[ "$sub_vus_per_lg" -ge 1 ] || die "SUB_VUS_TOTAL=$SUB_VUS_TOTAL over $n_sub \
subscriber LGs leaves <1 VU each"
# Integer division drops the remainder, so the run would quietly carry fewer
# VUs than asked for. Say so rather than let it read as the requested load.
sub_lost=$(( SUB_VUS_TOTAL - sub_vus_per_lg * n_sub ))
pub_lost=$(( PUB_VUS_TOTAL - pub_vus_per_lg * n_pub ))
[ "$sub_lost" -eq 0 ] || echo "  !! SUB_VUS_TOTAL not divisible by $n_sub: \
running $(( sub_vus_per_lg * n_sub )), $sub_lost VU(s) dropped"
[ "$pub_lost" -eq 0 ] || echo "  !! PUB_VUS_TOTAL not divisible by $n_pub: \
running $(( pub_vus_per_lg * n_pub )), $pub_lost VU(s) dropped"

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

# Fly's edge caps concurrent connections per SOURCE IP -- measured at ~8192 in
# s9, where publisher sessions plateaued at 8192/8098/8191 and the excess came
# back as raw TCP EOF; at breach the edge dropped ALL established connections
# on that IP. One LG machine is one source IP, so VUs-per-LG is a connection
# count, and exceeding this does not degrade gracefully: it voids the run.
# Every fleet campaign to date sat under it by construction (6250 VUs/LG).
CONNS_PER_LG_MAX="${CONNS_PER_LG_MAX:-7000}"
for role_vus in "$pub_vus_per_lg" "$sub_vus_per_lg"; do
  [ "$role_vus" -le "$CONNS_PER_LG_MAX" ] || die "$role_vus VUs on one LG \
exceeds the ~${CONNS_PER_LG_MAX}-connection Fly per-source-IP cap; the edge \
will drop every established connection on that machine. Add LG machines."
done

say "$n LGs: $n_sub subscriber(s) (${sub_vus_per_lg} VUs each, $(( sub_vus_per_lg * n_sub )) total) + $n_pub publisher(s) (${pub_vus_per_lg} VUs each, $(( pub_vus_per_lg * n_pub )) total) -> $WS_URL"

pids=()

# Subscriber LGs, each a disjoint VU_OFFSET slice of the user/group space.
for i in "${!sub_machines[@]}"; do
  offset=$(( i * sub_vus_per_lg ))
  echo "   SUB$i ${sub_machines[$i]}  VUS=$sub_vus_per_lg VU_OFFSET=$offset GROUP_SIZE=$GROUP_SIZE SUBS_PER_USER=$SUBS_PER_USER delay=${SUB_DELAY_SECS}s ramp=$SUB_RAMP hold=$SUB_HOLD"
  ( sleep "$SUB_DELAY_SECS"
    fly ssh console --app "$APP" --machine "${sub_machines[$i]}" -C \
      "sh -c 'ulimit -n $ULIMIT_N 2>/dev/null; k6 run -e ROLE=subscriber -e WS_URL=$WS_URL -e REALM=$REALM -e VUS=$sub_vus_per_lg -e VU_OFFSET=$offset -e GROUP_SIZE=$GROUP_SIZE -e SUBS_PER_USER=$SUBS_PER_USER -e VEHICLE_POOL=$VEHICLE_POOL -e RAMP=$SUB_RAMP -e HOLD=$SUB_HOLD -e SESSION_MS=$SUB_SESSION_MS -e LG_COUNT=$n_pub -e MEASURE_AFTER_MS=$MEASURE_AFTER_MS /scripts/fleet_smoke.js'" \
  ) > "$OUT/sub$i.txt" 2>&1 &
  pids+=("$!")
done

# Publisher LGs, each a disjoint VU_OFFSET slice of the vehicle pool.
for i in "${!pub_machines[@]}"; do
  offset=$(( i * pub_vus_per_lg ))
  echo "   PUB$i ${pub_machines[$i]}  VUS=$pub_vus_per_lg VU_OFFSET=$offset"
  fly ssh console --app "$APP" --machine "${pub_machines[$i]}" -C \
    "sh -c 'ulimit -n $ULIMIT_N 2>/dev/null; k6 run -e ROLE=publisher -e WS_URL=$WS_URL -e REALM=$REALM -e VUS=$pub_vus_per_lg -e VU_OFFSET=$offset -e PUB_INTERVAL_MS=$PUB_INTERVAL_MS -e VEHICLE_POOL=$VEHICLE_POOL -e RAMP=$RAMP -e HOLD=$HOLD -e SESSION_MS=$SESSION_MS -e LG_ID=$i /scripts/fleet_smoke.js'" \
    > "$OUT/pub$i.txt" 2>&1 &
  pids+=("$!")
done

say "waiting for all LGs to finish (ramp=$RAMP hold=$HOLD, so allow $((${RAMP%s} + ${HOLD%s} + 30))s+)..."
for p in "${pids[@]}"; do wait "$p" || true; done

line()  { { grep -E "^ *$2" "$1" || true; } | sed 's/^ *//' | head -1; }

# Subscriber LGs are printed SEPARATELY, not merged: percentiles from
# independent k6 summaries cannot be combined, and the LGs are symmetric, so
# agreement between them is itself the signal (and disagreement localises to a
# machine). Same reading as the per-publisher-LG trends below.
echo; echo "==================== SUBSCRIBERS ===================="
for s in "${!sub_machines[@]}"; do
  f="$OUT/sub$s.txt"
  echo "--- SUB$s ---"
  line "$f" 'wamp_delivery_latency_ms\.'
  line "$f" 'wamp_delivery_warmup_ms\.'
  line "$f" 'wamp_delivery_steady_ms\.'
  # Per-publisher-LG steady trends: symmetric LGs, so a systematic gap between
  # these is relative clock skew rather than latency.
  for ((l=0; l<n_pub; l++)); do line "$f" "wamp_delivery_lg${l}_ms\."; done
  line "$f" 'wamp_events_received'
  line "$f" 'wamp_late_subscribe_bursts'
  line "$f" 'wamp_welcome_latency_ms\.'
  line "$f" 'wamp_subscribe_latency_ms\.'
  line "$f" 'wamp_subscribe_burst_ms\.'
  line "$f" 'wamp_all_subscribed_ok'
  line "$f" 'wamp_session_ok'
  line "$f" 'wamp_errors'
  line "$f" 'wamp_aborts'
  line "$f" 'wamp_proto_errors'
  line "$f" 'wamp_parse_errors'
  line "$f" 'wamp_ws_connect_errors'
  { grep -E '✓ ws handshake 101|✗ ws handshake 101|↳' "$f" || true; } | sed 's/^ *//' | head -2
done

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
