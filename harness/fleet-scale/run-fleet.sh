#!/usr/bin/env bash
# =============================================================================
# Fleet-scale cluster deploy -- N-node Bondy on Fly that accepts anonymous WS
# clients, sized for "500K vehicles each on its own topic; a user subscribes
# to 2K vehicles". Reuses the proven M0 image. Run from the REPO ROOT. Prints
# the WS URL when ready.
#
#   FLY_ORG=<org> [NODES=5] ./harness/fleet-scale/run-fleet.sh
#   M0_SKIP_DEPLOY=1 ... to just re-check health + reprint the run command.
# =============================================================================
set -euo pipefail
if [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
  echo "ERROR: bash >= 4 required (found ${BASH_VERSION:-?}). Try: brew install bash" >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
APP="bondy-fleet-1"
ORG="${FLY_ORG:-leapsight}"
REGION="${FLY_REGION:-lhr}"
NODES="${NODES:-5}"
REALM="com.leapsight.fleet"
CONFIG="harness/fleet-scale/fly.toml"
DOCKERFILE="harness/fleet-scale/Dockerfile"

cd "$ROOT"
say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

command -v fly >/dev/null || die "flyctl not on PATH"
command -v jq  >/dev/null || die "jq not on PATH"
fly auth whoami >/dev/null 2>&1 || die "not logged in -- run: fly auth login"

if [ "${M0_SKIP_DEPLOY:-0}" != "1" ]; then
  if ! fly apps list --json | jq -e --arg a "$APP" '.[]|select(.Name==$a)' >/dev/null 2>&1; then
    say "creating app $APP in org $ORG"; fly apps create "$APP" --org "$ORG"
  fi
  say "deploying (remote build) -- reusing the M0 image"
  fly deploy --config "$CONFIG" --dockerfile "$DOCKERFILE" \
    --app "$APP" --regions "$REGION" --remote-only --ha=false --yes
  say "scaling to $NODES machines in $REGION"
  fly scale count "$NODES" --app "$APP" --region "$REGION" --yes
fi

# `fly deploy` updates a STOPPED machine in place and leaves it stopped, and
# `fly scale count` only reconciles how many exist -- neither starts anything.
# So redeploying an app whose machines were stopped (any app idle long enough
# to be suspended) leaves a cluster that is fully deployed and entirely down:
# the health loop below then burns its whole budget watching started=0. Start
# them explicitly; already-running machines are unaffected.
say "starting any stopped machines"
for M in $(fly machines list --app "$APP" --json \
            | jq -r '.[]|select(.state!="started")|.id'); do
  echo "  starting $M"
  fly machine start "$M" --app "$APP" >/dev/null 2>&1 || \
    echo "  !! could not start $M"
done

say "waiting for $NODES healthy machines"
for i in $(seq 1 60); do
  started=$(fly machines list --app "$APP" --json | jq '[.[]|select(.state=="started")]|length')
  passing=$(fly machines list --app "$APP" --json | jq '[.[]|.checks[]?|select(.status=="passing")]|length')
  printf '  [%2d/60] started=%s checks_passing=%s\n' "$i" "$started" "$passing"
  [ "${started:-0}" -ge "$NODES" ] && [ "${passing:-0}" -ge "$NODES" ] && break
  sleep 15
done
[ "${started:-0}" -ge "$NODES" ] || die "cluster did not reach $NODES started machines"

WS_URL="wss://${APP}.fly.dev/ws"
say "fleet cluster ready"
cat <<EOF

  Nodes:  $NODES ($REGION)
  WS URL: $WS_URL
  Realm:  $REALM   (anonymous auth)

  Tear down:    fly apps destroy $APP --yes
EOF
