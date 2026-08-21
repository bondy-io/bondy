#!/usr/bin/env bash
# =============================================================================
# SPDX-FileCopyrightText: 2016 - 2026 Leapsight
# SPDX-License-Identifier: Apache-2.0
# =============================================================================
#
# Pre-flight fitness gate for a deployed fleet cluster: cluster IDENTITY, then
# the own-root page-loss tripwire sweep. Both must pass before a campaign is
# worth running.
#
# IDENTITY. Each node must be named bondy@<its own Fly 6PN address>. MEASURED
# 2026-08-21 across three cluster boots: exactly one node per boot instead came
# up as `bondy@127.0.0.1` (the Dockerfile ENV default), and WHICH node varied
# between boots. It is not an environment problem — `priv/hooks/pre_start`
# echoed the CORRECT BONDY_ERL_NODENAME on all five nodes in the boot where one
# still came up wrong, so the value is lost later, in the vm.args substitution.
# The cluster still forms and every node still sees 4 peers, so the fault is
# SILENT. In the two runs where it was measured, the misnamed node carried
# publish.fanout means of 159ms and 436ms against 62-87us for its healthy peers
# (n=2, mechanism unproven) — which is more than enough to invalidate a
# campaign. Gate on it rather than discover it in the results.
#
# The fault this checks for (Fly s16/s25) is a shard whose own MST root
# references pages that are not in its store. It is rare, it self-heals, and
# its log line ages out of Fly's buffer long before anyone looks — which is
# why the evidence is ALSO retained in-node. Each machine is asked for:
#
#   bondy_mst_gc_aborted_total     the collector refused to sweep under an
#                                  unservable root (labelled by which layer
#                                  lost the page: deleted/tombstoned/…)
#   bondy_oplog_mst_rebuilt_total  the self-heal gave up and rebuilt a tree
#   bondy_mst:gc_aborts()          the full forensic ring behind either
#
# Queried through `bondy eval`, NOT by scraping /metrics: the runtime image
# ships neither curl nor wget, so an HTTP probe silently returns nothing.
#
# A PROBE FAILURE IS NOT A PASS. An earlier version of this script counted an
# unreachable machine as zero and printed CLEAN across a fleet it had never
# actually talked to — which is the precise way a verification harness lies.
# Every machine must answer; any that does not makes the whole run
# inconclusive and exits non-zero.
#
#   [APP=bondy-fleet-1] ./harness/fleet-scale/check-tripwires.sh
#
# Exit: 0 clean, 1 a tripwire fired, 2 inconclusive (unreachable/unreadable) or
# a node identity mismatch — in every non-zero case the fleet is not fit to
# measure.
# =============================================================================
set -uo pipefail

APP="${APP:-bondy-fleet-1}"
say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
red() { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }

command -v fly >/dev/null || { echo "flyctl not on PATH" >&2; exit 2; }
command -v jq  >/dev/null || { echo "jq not on PATH" >&2; exit 2; }

# `-1` is the in-band "could not read this counter" sentinel; it is summed like
# any other value so a failed read can never look like a zero.
READ='F=fun(N)->try lists:sum([V||{_,V}<-prometheus_counter:values(default,N)]) catch _:_->-1 end end,{F(bondy_mst_gc_aborted_total),F(bondy_oplog_mst_rebuilt_total),length(bondy_mst:gc_aborts())}.'

MACHINES=$(fly machines list --app "$APP" --json \
    | jq -r '.[]|select(.state=="started")|.id')
[ -n "$MACHINES" ] || { red "no started machines in $APP"; exit 2; }

# --- cluster identity gate -------------------------------------------------
# `partisan:node()` is the ONLY trustworthy source for a node's name. Do NOT
# read /bondy/releases/*/vm.args or /proc/<beam>/environ: the release start
# script runs with RELX_REPLACE_OS_VARS=true, so every `bondy eval` (including
# the ones this harness makes) REGENERATES vm.args from vm.args.orig using the
# SSH session's environment, where BONDY_ERL_NODENAME is the Dockerfile
# default. After any probing those files read `bondy@127.0.0.1` on every
# machine, correctly-named ones included.
say "cluster identity"
IDENT_BAD=0; IDENT_UNREACHABLE=0
for M in $MACHINES; do
    IP=$(fly machines list --app "$APP" --json \
        | jq -r --arg m "$M" '.[]|select(.id==$m)|.private_ip')
    NODE=$(fly ssh console --app "$APP" --machine "$M" \
            --command "/bondy/bin/bondy eval partisan:node()." 2>/dev/null \
          | tr -d " '\r" | grep -oE '^bondy@.+$' | tail -1)
    if [ -z "$NODE" ]; then
        red "  !! $M UNREACHABLE — no node name obtained"
        IDENT_UNREACHABLE=$((IDENT_UNREACHABLE + 1))
    elif [ "$NODE" = "bondy@$IP" ]; then
        echo "  $M  $NODE"
    else
        red "  !! $M  is '$NODE'  expected 'bondy@$IP'"
        IDENT_BAD=$((IDENT_BAD + 1))
    fi
done
if [ "$IDENT_UNREACHABLE" -gt 0 ]; then
    red "  INCONCLUSIVE — $IDENT_UNREACHABLE machine(s) gave no node name"
    exit 2
fi
if [ "$IDENT_BAD" -gt 0 ]; then
    red "  IDENTITY MISMATCH on $IDENT_BAD node(s) — restart the fleet and"
    red "  re-check; do NOT spend a campaign on this cluster"
    exit 2
fi
green "  identity OK — every node is bondy@<its own 6PN address>"

TOTAL_ABORTS=0; TOTAL_REBUILDS=0; TOTAL_RING=0; UNREACHABLE=0; PROBED=0

for M in $MACHINES; do
    say "machine $M"
    RAW=$(fly ssh console --app "$APP" --machine "$M" \
            --command "/bondy/bin/bondy eval $READ" 2>/dev/null \
          | tr -d ' \r' | grep -oE '\{-?[0-9]+,-?[0-9]+,-?[0-9]+\}' | tail -1)

    if [ -z "$RAW" ]; then
        red "  !! UNREACHABLE — no reading obtained"
        UNREACHABLE=$((UNREACHABLE + 1))
        continue
    fi

    A=$(echo "$RAW" | sed -E 's/^\{(-?[0-9]+),.*/\1/')
    R=$(echo "$RAW" | sed -E 's/^\{[^,]+,(-?[0-9]+),.*/\1/')
    G=$(echo "$RAW" | sed -E 's/.*,(-?[0-9]+)\}$/\1/')
    PROBED=$((PROBED + 1))
    echo "  gc_aborted_total=$A  mst_rebuilt_total=$R  ring_entries=$G"
    TOTAL_ABORTS=$((TOTAL_ABORTS + A))
    TOTAL_REBUILDS=$((TOTAL_REBUILDS + R))
    TOTAL_RING=$((TOTAL_RING + G))

    if [ "$G" -gt 0 ]; then
        red "  -- in-node forensic ring --"
        fly ssh console --app "$APP" --machine "$M" \
            --command "/bondy/bin/bondy eval bondy_mst:gc_aborts()." \
            2>/dev/null | sed 's/^/    /'
    fi
done

say "fleet totals  (machines probed: $PROBED, unreachable: $UNREACHABLE)"
echo "  gc_aborted_total  = $TOTAL_ABORTS"
echo "  mst_rebuilt_total = $TOTAL_REBUILDS"
echo "  ring_entries      = $TOTAL_RING"

if [ "$UNREACHABLE" -gt 0 ]; then
    red "  INCONCLUSIVE — $UNREACHABLE machine(s) never answered; this is NOT a pass"
    exit 2
fi
if [ "$TOTAL_ABORTS" -lt 0 ] || [ "$TOTAL_REBUILDS" -lt 0 ]; then
    red "  INCONCLUSIVE — a counter could not be read (-1 sentinel)"
    exit 2
fi
if [ "$TOTAL_ABORTS" -eq 0 ] && [ "$TOTAL_REBUILDS" -eq 0 ] && [ "$TOTAL_RING" -eq 0 ]; then
    green "  CLEAN — every machine answered, no tripwire fired"
    exit 0
fi
red "  TRIPWIRE FIRED — read the ring above before drawing conclusions"
exit 1
