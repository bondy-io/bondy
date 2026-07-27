#!/bin/sh
# =============================================================================
# Perf cluster bring-up hook -- sourced by the fly.toml entrypoint before Bondy
# boots. Derives the Erlang node name from the Fly 6PN private IP so DNS
# discovery (node_basename=bondy) forms the full mesh.
# =============================================================================

export BONDY_ERL_NODENAME=bondy@${FLY_PRIVATE_IP}
export BONDY_REGION=${FLY_REGION}
export BONDY_HOST_ID=${FLY_MACHINE_ID}

swapoff -a 2>/dev/null || true
