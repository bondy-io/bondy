#!/usr/bin/env bash
# =============================================================================
# M0 capability probe — run INSIDE a Fly VM (as root, via `fly ssh console`).
# =============================================================================
# Answers the single question 06 §M0 exists for: which faults from 03 §5 can we
# actually inject on Fly, and can we CONFIRM each one took effect? For each fault
# it: (1) attempts it, (2) measures a confirmation signal, (3) heals. It emits
# ONE JSON object per fault on stdout (NDJSON) — the orchestrator collates these
# into FLY_FAULT_CAPABILITY.md. It NEVER leaves a fault applied (trap heals all).
#
# The probe is deliberately boring and self-contained: no Bondy internals, only
# OS-level observation (ss, ping, df, capsh, date). It does NOT kill this node
# (that would end the probe) — it only proves we *can* signal the BEAM.
#
# Usage:  bondy-probe.sh <peer-6pn-ipv6>   [iface]
#   peer-6pn-ipv6 : a sibling machine's private IPv6 (for partition/delay tests)
#   iface         : network device for tc/partition confirmation (default eth0)
# =============================================================================
set -u

PEER="${1:-}"
IFACE="${2:-eth0}"
PEER_PORT="${3:-18086}"       # Partisan cluster peer service
ADMIN="http://localhost:18081"

# ---- JSON emit (no jq dependency inside the VM) ------------------------------
emit() {
  # emit <fault> <attempted> <applied> <confirmed> <healed> <detail>
  local fault="$1" attempted="$2" applied="$3" confirmed="$4" healed="$5" detail="$6"
  detail="${detail//\"/\'}"   # keep the line valid JSON
  printf '{"fault":"%s","attempted":%s,"applied":%s,"confirmed":%s,"healed":%s,"detail":"%s"}\n' \
    "$fault" "$attempted" "$applied" "$confirmed" "$healed" "$detail"
}
have() { command -v "$1" >/dev/null 2>&1; }

# ---- global heal (dead-man's-switch; also runs on any exit) ------------------
heal_all() {
  [ -n "$PEER" ] && { iptables  -D INPUT  -s "$PEER" -p tcp --dport "$PEER_PORT" -j DROP 2>/dev/null
                      iptables  -D OUTPUT -d "$PEER" -p tcp --dport "$PEER_PORT" -j DROP 2>/dev/null
                      ip6tables -D INPUT  -s "$PEER" -p tcp --dport "$PEER_PORT" -j DROP 2>/dev/null
                      ip6tables -D OUTPUT -d "$PEER" -p tcp --dport "$PEER_PORT" -j DROP 2>/dev/null; }
  tc qdisc del dev "$IFACE" root 2>/dev/null
  rm -f /bondy/data/.m0_diskfill 2>/dev/null
  true
}
trap heal_all EXIT

# iptables vs ip6tables: 6PN is IPv6, so use ip6tables for the peer rule but keep
# a v4 fallback. Pick the tool matching the peer address family.
IPT=ip6tables
case "$PEER" in *.*.*.*) IPT=iptables ;; esac

# =============================================================================
# 0. Preconditions — capabilities & tooling
# =============================================================================
NETADMIN=false
if have capsh; then
  capsh --print 2>/dev/null | grep -qi 'cap_net_admin' && NETADMIN=true
fi
emit "net_admin_cap" true "$NETADMIN" "$NETADMIN" true \
     "CAP_NET_ADMIN=$NETADMIN iface=$IFACE peer=${PEER:-none} (gates partition+delay)"

# =============================================================================
# 1. Partition — drop Partisan peer traffic (iptables/ip6tables on :18086)
# =============================================================================
if [ -n "$PEER" ] && have "$IPT"; then
  # Confirm at the NETWORK layer, not via ESTAB count: a DROP rule leaves an
  # already-established socket in ESTAB for minutes, so the real signal is that
  # a NEW TCP connection to the peer's Partisan port succeeds before the rule
  # and is blocked (SYN black-holed -> connect times out) after it.
  reach_before=no; timeout 4 bash -c "exec 3<>/dev/tcp/$PEER/$PEER_PORT" 2>/dev/null && reach_before=yes
  "$IPT" -A INPUT  -s "$PEER" -p tcp --dport "$PEER_PORT" -j DROP 2>/dev/null
  a1=$?
  "$IPT" -A OUTPUT -d "$PEER" -p tcp --dport "$PEER_PORT" -j DROP 2>/dev/null
  applied=false; [ "$a1" -eq 0 ] && applied=true
  reach_after=yes; timeout 6 bash -c "exec 3<>/dev/tcp/$PEER/$PEER_PORT" 2>/dev/null || reach_after=no
  sleep 10  # secondary: give Partisan's failure detector a moment to react
  mem=$(curl -s "$ADMIN/metrics" 2>/dev/null | grep -E '^bondy_cluster_all_members_connected' | awk '{print $2}' | head -1)
  confirmed=false; [ "$reach_before" = yes ] && [ "$reach_after" = no ] && confirmed=true
  "$IPT" -D INPUT  -s "$PEER" -p tcp --dport "$PEER_PORT" -j DROP 2>/dev/null
  "$IPT" -D OUTPUT -d "$PEER" -p tcp --dport "$PEER_PORT" -j DROP 2>/dev/null
  emit "partition_iptables" true "$applied" "$confirmed" true \
       "$IPT peer=$PEER port_reach $reach_before->$reach_after all_connected=${mem:-NA}"
else
  emit "partition_iptables" true false false true "no peer arg or $IPT missing"
fi

# =============================================================================
# 2. Delay — tc netem 100ms on the egress device; confirm via ping RTT rise
# =============================================================================
if [ -n "$PEER" ] && have tc && have ping; then
  base=$(ping -6 -c 3 -q "$PEER" 2>/dev/null | awk -F'/' '/rtt|round-trip/{print $5}')
  tc qdisc add dev "$IFACE" root netem delay 100ms 2>/dev/null
  applied=false; [ $? -eq 0 ] && applied=true
  aft=$(ping -6 -c 3 -q "$PEER" 2>/dev/null | awk -F'/' '/rtt|round-trip/{print $5}')
  tc qdisc del dev "$IFACE" root 2>/dev/null
  confirmed=false
  awk "BEGIN{exit !(${aft:-0}+0 > ${base:-0}+0 + 50)}" && confirmed=true
  emit "delay_tc_netem" true "$applied" "$confirmed" true \
       "iface=$IFACE rtt_ms ${base:-?}->${aft:-?} (expect +100ms)"
else
  emit "delay_tc_netem" true false false true "no peer arg or tc/ping missing"
fi

# =============================================================================
# 3. Clock skew — libfaketime capability (does NOT skew live Bondy; proves the
#    LD_PRELOAD mechanism works — live use is restart-time per 03 §5)
# =============================================================================
FT=$(find /usr/lib /usr/local/lib -name 'libfaketime.so*' 2>/dev/null | head -1)
if [ -n "$FT" ]; then
  real=$(date +%s)
  fake=$(LD_PRELOAD="$FT" FAKETIME='+3600' date +%s 2>/dev/null)
  delta=$(( ${fake:-0} - real ))
  confirmed=false; [ "$delta" -ge 3000 ] && [ "$delta" -le 4200 ] && confirmed=true
  emit "clock_skew_libfaketime" true true "$confirmed" true \
       "lib=$FT delta_s=$delta (expect ~3600)"
else
  emit "clock_skew_libfaketime" true false false true "libfaketime.so not found"
fi

# =============================================================================
# 4. Disk fill — fallocate on the data volume; confirm free space drop; remove
# =============================================================================
if have fallocate; then
  free_before=$(df -Pm /bondy/data 2>/dev/null | awk 'NR==2{print $4}')
  fallocate -l 256M /bondy/data/.m0_diskfill 2>/dev/null
  applied=false; [ $? -eq 0 ] && applied=true
  free_after=$(df -Pm /bondy/data 2>/dev/null | awk 'NR==2{print $4}')
  rm -f /bondy/data/.m0_diskfill 2>/dev/null
  confirmed=false; [ "${free_after:-0}" -lt "${free_before:-0}" ] && confirmed=true
  emit "disk_fill_fallocate" true "$applied" "$confirmed" true \
       "free_mb ${free_before:-?}->${free_after:-?} (256M alloc)"
else
  emit "disk_fill_fallocate" true false false true "fallocate missing"
fi

# =============================================================================
# 5. CPU stress — stress-ng burst (confirm it runs to completion)
# =============================================================================
if have stress-ng; then
  stress-ng --cpu 1 --timeout 2s >/dev/null 2>&1
  ok=false; [ $? -eq 0 ] && ok=true
  emit "cpu_stress_stressng" true "$ok" "$ok" true "stress-ng --cpu 1 --timeout 2s"
else
  emit "cpu_stress_stressng" true false false true "stress-ng missing"
fi

# =============================================================================
# 6. Signal capability — can we signal the BEAM? (do NOT actually kill it)
# =============================================================================
# Match the process NAME (comm=beam.smp); `pgrep -f` would miss it because the
# BEAM's argv is "/bondy/bin/bondy ...", which does not contain "beam.smp".
BEAM=$(pgrep -x beam.smp | head -1)
if [ -n "$BEAM" ]; then
  kill -0 "$BEAM" 2>/dev/null
  ok=false; [ $? -eq 0 ] && ok=true
  emit "signal_beam" true "$ok" "$ok" true "beam pid=$BEAM (kill -0 only; real KILL/STOP at M3)"
else
  emit "signal_beam" true false false true "no beam.smp process found"
fi

exit 0
