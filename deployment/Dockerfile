# syntax=docker/dockerfile:1.3

# ===========================================================================
# Build stage 1
# ===========================================================================

FROM erlang:26 AS builder

# Install build dependencies
RUN --mount=type=cache,id=apt,sharing=locked,target=/var/cache/apt apt-get update && \
    apt-get -y install --no-install-recommends build-essential git libssl-dev libsodium-dev libsnappy-dev curl && \
	rm -rf /var/lib/apt/lists/*

WORKDIR /bondy/src

# Copy Bondy project source to working dir
COPY ../ /bondy/src

# Create dir we will unpack release tar into
RUN mkdir -p /bondy/rel

# Generates tar in /bondy/src/_build and untars in /bondy/rel
RUN rebar3 as docker tar && \
    tar -zxvf /bondy/src/_build/docker/rel/*/*.tar.gz -C /bondy/rel/


# ===========================================================================
# Build stage 2
# ===========================================================================

FROM debian:bookworm-slim as runner

# We define defaults
# We assume you have DNS. Erlang will take the FQDN and generate
# a node name == ${BONDY_ERL_NODENAME}@${FQDN}
ENV BONDY_ERL_NODENAME=bondy@127.0.0.1
ENV BONDY_ERL_DISTRIBUTED_COOKIE=bondy
ENV BONDY_LOG_CONSOLE=console
ENV BONDY_LOG_LEVEL=info
ENV ERL_CRASH_DUMP=/dev/null
ENV ERL_DIST_PORT=27780

# We add Bondy executables to PATH
ENV PATH="/bondy/bin:$PATH"
# This is required so that relx replaces the vm.args
# BONDY_ERL_NODENAME and BONDY_ERL_DISTRIBUTED_COOKIE variables
ENV RELX_REPLACE_OS_VARS=true

ENV HOME "/bondy"

# We install the following utils:
# - bash
# - procps: which includes the commands free, kill, pkill, pgrep, pmap, ps,
#   pwdx, skill, slabtop, snice, sysctl, tload, top, uptime, vmstat, w, and
#   watch
# - iproute2: a collection of utilities for networking and traffic control.
# - net-tools: which includes the commands arp, ifconfig, netstat, rarp, nameif
#   and route
# - curl, jq: for devops to use the REST Admin API
# - nano: for devops
#
# We install the following required packages:
# - openssl: required by Erlang crypto application
# - libsodium: required by enacl application
# We setup the bondy group and user and the /bondy dir
# We also create the /bondy/etc dir to avoid an issue when deploying in K8s
# where the permissions are not assigned to the directory and Bondy will not
# have permission to write.
RUN apt-get update \
    && apt-get -y install \
    sudo bash procps iproute2 net-tools dnsutils curl jq nano \
    openssl libsodium-dev libsnappy-dev\
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 1000 -r bondy \
    && useradd -u 1000 -r -g bondy -d /bondy -s /bin/bash -c "bondy" bondy \
    && mkdir -p /bondy/etc \
    && chown bondy:bondy /bondy/etc

WORKDIR /bondy
USER bondy:bondy

# Copy the release to workdir
COPY --chown=bondy:bondy --from=builder /bondy/rel .

# Define which ports are intended to be published
# We are hardcoding the ports here, the bondy.conf definitions need to match
# these!
# API GATEWAY HTTP and WS (Default: 18080)
EXPOSE 18080/tcp
# ADMIN API HTTP (Default: 18081)
EXPOSE 18081/tcp
# WAMP TCP  (Default: 18082)
EXPOSE 18082/tcp
# API GATEWAY HTTPS and WSS (Default: 18083)
EXPOSE 18083/tcp
# ADMIN API HTTPS (Default: 18084)
EXPOSE 18084/tcp
# WAMP TLS (Default: 18085)
EXPOSE 18085/tcp
# CLUSTER PEER SERVICE (Default: 18086)
EXPOSE 18086/tcp

# The pre_start script will hardcode the following paths i.e. ignoring the
# user-defined environment variables (BONDY_*_DIR)
VOLUME ["/bondy/etc", "/bondy/data", "/bondy/log", "/bondy/tmp"]

ENTRYPOINT ["bondy", "foreground"]
