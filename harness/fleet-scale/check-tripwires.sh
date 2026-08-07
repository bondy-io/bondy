#!/usr/bin/env bash
# =============================================================================
# SPDX-FileCopyrightText: 2016 - 2026 Leapsight
# SPDX-License-Identifier: Apache-2.0
# =============================================================================
#
# Own-root page-loss tripwire sweep across a deployed fleet cluster.
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
