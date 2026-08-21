#!/usr/bin/env bash
# =============================================================================
# SPDX-FileCopyrightText: 2016 - 2026 Leapsight
# SPDX-License-Identifier: Apache-2.0
# =============================================================================
#
# Server-side attribution sampler for a fleet-scale session-establishment run.
#
# k6 can tell you a handshake failed. It CANNOT tell you why. This closes that
# gap by sampling, per node, the three numbers that separate the candidate
# causes of a session that never establishes:
#
#   bondy_wamp_dropped_total{admission,hello}   the HELLO load gate refused it
#                                               (`bondy_wamp_protocol:admit_hello/0`
#                                               -> retryable wamp.error.unavailable)
#   bondy_regulator_load:status()               whether the node is in `busy`
#                                               right now, i.e. whether the gate
#                                               is even armed
#   total_run_queue_lengths_all                 scheduling pressure — the OTHER
#                                               way a handshake dies (fly-proxy
#                                               times out the upgrade before
#                                               Bondy ever parses the HELLO)
#   bondy_sessions_total                        what actually stuck. NOTE this
#                                               family is a `bondy_metrics`
#                                               gauge, NOT a raw prometheus one
#                                               -- reading it via
#                                               `prometheus_gauge:values/2`
#                                               returns [] and sums to a
#                                               perfectly plausible 0, which is
#                                               how a sampler lies.
#
# A refusal count that climbs while sessions still converge is the regulator
# doing its job. A flat refusal count with failing handshakes is NOT the
# regulator — look at the run queue instead.
#
# Same discipline as check-tripwires.sh: `bondy eval`, not /metrics (the
# runtime image ships no curl); `-1` is an in-band "could not read" sentinel so
# a failed probe can never be mistaken for a zero.
#
#   [APP=bondy-fleet-1] [INTERVAL=30] [SAMPLES=30] \
#     ./harness/fleet-scale/sample-admission.sh | tee out/admission.tsv
# =============================================================================
set -uo pipefail

APP="${APP:-bondy-fleet-1}"
INTERVAL="${INTERVAL:-30}"
SAMPLES="${SAMPLES:-30}"

command -v fly >/dev/null || { echo "flyctl not on PATH" >&2; exit 2; }
command -v jq  >/dev/null || { echo "jq not on PATH" >&2; exit 2; }

# One eval per machine returning {DroppedHello, Busy, RunQueue, Sessions}.
# Every read is individually guarded: one missing metric family must not cost
# us the other three.
READ='
C=fun(N,L)->try lists:sum([V||{Lbls,V}<-prometheus_counter:values(default,N),
                              L==[] orelse Lbls==L]) catch _:_->-1 end end,
G=fun(N)->try lists:sum([V||{_,V}<-bondy_metrics:with_name(N)]) catch _:_->-1 end end,
B=try case bondy_regulator_load:status() of busy->1; _->0 end catch _:_->-1 end,
R=try element(1,{erlang:statistics(total_run_queue_lengths_all),x}) catch _:_->-1 end,
{C(bondy_wamp_dropped_total,[]),B,R,G(bondy_sessions_total)}.'

MACHINES=$(fly machines list --app "$APP" --json \
    | jq -r '.[]|select(.state=="started")|.id')
[ -n "$MACHINES" ] || { echo "no started machines in $APP" >&2; exit 2; }

# id -> private_ip, resolved ONCE (this script samples in a loop; one API call
# per sample per machine would dominate the sampling interval).
#
# Each `bondy eval` below is prefixed with the machine's own
# BONDY_ERL_NODENAME because relx rewrites the shared releases/<vsn>/vm.args on
# every `bondy` subcommand, using the invoking shell's environment. Unprefixed,
# the SSH session supplies the Dockerfile default and the rewrite bakes
# bondy@127.0.0.1 into the file, which the node boots under on its next
# restart. See check-tripwires.sh for the full note.
MACHINE_IPS=$(fly machines list --app "$APP" --json \
    | jq -r '.[]|select(.state=="started")|"\(.id) \(.private_ip)"')
ip_of() { printf '%s\n' "$MACHINE_IPS" | awk -v m="$1" '$1==m{print $2}'; }

printf 'ts\tmachine\tdropped_total\tbusy\trun_queue\tsessions\n'

for _ in $(seq 1 "$SAMPLES"); do
    TS=$(date -u +%H:%M:%S)
    for M in $MACHINES; do
        RAW=$(fly ssh console --app "$APP" --machine "$M" \
                --command "env BONDY_ERL_NODENAME=bondy@$(ip_of "$M") /bondy/bin/bondy eval $(printf '%s' "$READ" | tr -d '\n')" \
                2>/dev/null \
              | tr -d ' \r' | grep -oE '\{-?[0-9]+,-?[0-9]+,-?[0-9]+,-?[0-9]+\}' | tail -1)
        if [ -z "$RAW" ]; then
            printf '%s\t%s\tUNREACHABLE\tUNREACHABLE\tUNREACHABLE\tUNREACHABLE\n' "$TS" "$M"
        else
            printf '%s\t%s\t%s\n' "$TS" "$M" \
                "$(printf '%s' "$RAW" | tr -d '{}' | tr ',' '\t')"
        fi
    done
    sleep "$INTERVAL"
done
