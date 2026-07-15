#!/usr/bin/env bash
# =============================================================================
# Fly machine boot — wire the persistent volume into the paths the
# bench tooling expects, then hand off to the container's CMD
# (`tail -f /dev/null` to keep the VM alive for `fly ssh console`).
#
# We persist /tmp + /data/results on the volume because they're
# inputs/outputs (bench artefacts under /tmp; bench output under
# /data/results) that should survive across machine restarts.
#
# We deliberately do NOT symlink _build (rebar3 or mix) onto the
# volume:
#   - Mix uses relative symlinks for `_build/<env>/lib/<dep>/priv`
#     that point to `../../../../deps/<dep>/priv`. With a _build
#     volume symlink, that relative path resolves to
#     `/data/_build/bench/deps/...` — which does not exist (deps
#     live at /opt/bondy/bench/deps/). Result: every benchee_html
#     report fails with "could not read priv/assets/.../*.css".
#   - rebar3 _build doesn't have that bug but doesn't gain anything
#     from volume persistence either — Fly's auto-stop preserves
#     the rootfs, so _build survives stop/start cycles. Only a
#     `fly deploy` wipes it, at which point we want a fresh compile
#     against the new source anyway.
# =============================================================================

set -euo pipefail

VOLUME_ROOT=/data

mkdir -p "${VOLUME_ROOT}/tmp"
mkdir -p "${VOLUME_ROOT}/results"

# Bench artefacts (WAL segments, leveled stores, pack stores) land
# under /tmp by convention — see the various test/bench files that
# build paths like /tmp/bondy_mst_*. On Fly we want them on the
# volume so they survive restarts and aren't capped by the small
# rootfs.
if [ ! -L /tmp ] || [ "$(readlink /tmp)" != "${VOLUME_ROOT}/tmp" ]; then
    rm -rf /tmp
    ln -s "${VOLUME_ROOT}/tmp" /tmp
fi

exec "$@"
