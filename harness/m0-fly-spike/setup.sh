#!/bin/sh
# =============================================================================
# M0 Fly bring-up hook — sourced by the fly.toml entrypoint before Bondy boots.
# Mirrors deployment/fly/setup.sh: derive the Erlang node name from the Fly 6PN
# private IP so DNS discovery (node_basename=bondy) forms the full mesh.
# =============================================================================

export BONDY_ERL_NODENAME=bondy@${FLY_PRIVATE_IP}
export BONDY_REGION=${FLY_REGION}
export BONDY_HOST_ID=${FLY_MACHINE_ID}

# BEAM distribution is not used for clustering (Partisan carries the cluster on
# 18086); keep it off the public path. Disable swap so GC-pause faults are clean.
swapoff -a 2>/dev/null || true
