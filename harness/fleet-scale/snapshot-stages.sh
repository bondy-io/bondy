#!/usr/bin/env bash
# =============================================================================
# SPDX-FileCopyrightText: 2016 - 2026 Leapsight
# SPDX-License-Identifier: Apache-2.0
# =============================================================================
#
# Per-node snapshot of the delivery-pipeline stage metrics, for phase-boundary
# differencing.
#
# The histograms are CUMULATIVE, so a single reading at the end of a run mixes
# ramp with steady state — and the ramp is exactly where we expect the tail to
# live. Take a snapshot at each phase boundary and difference the counts/sums:
# the deltas are that phase alone.
#
#   publish.match   registry/trie lookup of matching subscriptions
#   publish.fanout  send-per-local-subscriber + one relayed PUBLISH per peer
#   flow.queue      time a task waited in a flow-pool worker mailbox
#                   (relay INGRESS — the pool's only data-plane role)
#   flow.service    execution time of a flow-pool task
#   shed            messages dropped at an ordered dispatch site
#
# Read it as: tail in match -> registry; tail in fanout -> delivery/egress;
# tail in NEITHER but present end-to-end -> downstream, i.e. flow.queue or the
# subscriber's own connection process.
#
# `bondy eval`, not /metrics (the runtime image ships no curl). Emits one TSV
# row per node per metric; an unreachable machine is reported, never silently
# counted as zero.
#
#   [APP=bondy-fleet-1] ./harness/fleet-scale/snapshot-stages.sh <phase-label>
# =============================================================================
set -uo pipefail

APP="${APP:-bondy-fleet-1}"
PHASE="${1:-unlabelled}"

command -v fly >/dev/null || { echo "flyctl not on PATH" >&2; exit 2; }
command -v jq  >/dev/null || { echo "jq not on PATH" >&2; exit 2; }

# `with_name/1` returns the observation COUNT for a histogram, not its stats —
# the distribution needs snapshot/1 + stats/1. Sum `count`/`sum` across label
# sets so the caller can difference them; carry p50/p95/p99 from the widest
# label set for shape.
READ='
H=fun(N)->try
    Rows=[R||{L,_}<-bondy_metrics:with_name(N),
             {ok,R}<-[bondy_metrics:histogram_snapshot(#{name=>N,label=>L})]],
    C=lists:sum([maps:get(count,R)||R<-Rows]),
    S=lists:sum([maps:get(sum,R)||R<-Rows]),
    St=case Rows of
        []->#{p50=>0,p95=>0,p99=>0};
        _->bondy_metrics:histogram_stats(element(2,hd(lists:reverse(
             lists:keysort(1,[{maps:get(count,R),R}||R<-Rows])))))
    end,
    {C,S,maps:get(p50,St,0),maps:get(p95,St,0),maps:get(p99,St,0)}
  catch _:_->{-1,-1,-1,-1,-1} end end,
Shed=fun()->try lists:sum([V||{L,V}<-prometheus_counter:values(default,
        bondy_wamp_dropped_total), lists:keyfind(shed,2,L)=/=false])
  catch _:_->-1 end end,
{H(bondy_broker_publish_match_microseconds),
 H(bondy_broker_publish_fanout_microseconds),
 H(bondy_router_flow_queue_microseconds),
 H(bondy_router_flow_service_microseconds),
 Shed()}.'

MACHINES=$(fly machines list --app "$APP" --json \
    | jq -r '.[]|select(.state=="started")|.id')
[ -n "$MACHINES" ] || { echo "no started machines in $APP" >&2; exit 2; }

for M in $MACHINES; do
    RAW=$(fly ssh console --app "$APP" --machine "$M" \
            --command "/bondy/bin/bondy eval $(printf '%s' "$READ" | tr -d '\n')" \
            2>/dev/null | tr -d ' \r\n' | grep -oE '\{\{.*\}$' | tail -1)
    if [ -z "$RAW" ]; then
        printf '%s\t%s\tUNREACHABLE\n' "$PHASE" "$M"
    else
        printf '%s\t%s\t%s\n' "$PHASE" "$M" "$RAW"
    fi
done
