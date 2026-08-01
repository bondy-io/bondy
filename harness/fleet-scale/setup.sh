#!/bin/sh
# =============================================================================
# Fleet-scale cluster bring-up hook -- runs as ROOT (this image, unlike the
# base M0 image, does NOT drop to the bondy user before the entrypoint).
# Derives the Erlang node name from the Fly 6PN private IP so DNS discovery
# (node_basename=bondy) forms the full mesh, then raises nofile as root
# (only root can raise its own hard limit -- a non-root `USER bondy` process
# gets "Operation not permitted") and execs Bondy as the bondy user via `su`.
# rlimits are inherited across that privilege drop (they are a per-process
# resource limit, not tied to uid/gid), so the raised limit survives.
#
# leveled (the LSM durable backend) alone wants 200K+ file handles under
# load, and this cluster additionally targets hundreds of thousands of
# concurrent client connections. The default is 10240 (observed, unraised)
# -- far too low for either need.
# =============================================================================

export BONDY_ERL_NODENAME=bondy@${FLY_PRIVATE_IP}
export BONDY_REGION=${FLY_REGION}
export BONDY_HOST_ID=${FLY_MACHINE_ID}

swapoff -a 2>/dev/null || true

echo "nofile before (root): soft=$(ulimit -Sn) hard=$(ulimit -Hn)"
ulimit -n 1048576 2>/dev/null || true
echo "nofile after (root):  soft=$(ulimit -Sn) hard=$(ulimit -Hn)"

# setpriv (not su): a single execve that drops credentials in place, so this
# process stays PID 1 (correct signal delivery for `kill_signal`/
# `kill_timeout` on shutdown) and inherits the rlimit just raised above --
# su instead forks a child and lingers as a wrapper, which both loses PID 1
# and is not guaranteed to forward signals cleanly.
cd /bondy
exec setpriv --reuid=bondy --regid=bondy --clear-groups --inh-caps=-all \
    bin/bondy foreground
