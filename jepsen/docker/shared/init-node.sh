#!/bin/bash
# Per-node init: minimal apt deps + sshd + the Jepsen control's public
# key in authorized_keys so SSH-based db/setup hooks can install the
# Erlang release archive. iptables is needed for the partition nemeses
# (`tc qdisc` / `iptables -A INPUT -j DROP`). openssl + libstdc++6 are the
# runtime libraries the Bondy release needs (the same two
# deployment/Dockerfile's runner installs): erts' crypto links libcrypto, and
# the crc32cer NIF links libstdc++ — jepsen.bondy installs that release here.

set -e

export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y -V --fix-missing --no-install-recommends \
    apt-transport-https \
    wget \
    ca-certificates \
    gnupg \
    curl \
    iproute2 \
    iptables \
    procps \
    less \
    openssl \
    libstdc++6

apt install -y openssh-server sudo
/etc/init.d/ssh start

mkdir -p ~/.ssh/
cat /root/shared/jepsen-bot.pub > ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
