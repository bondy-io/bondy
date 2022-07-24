# syntax=docker/dockerfile:1.3

# ===========================================================================
# Build stage 1
# ===========================================================================

FROM erlang:24 AS builder

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
RUN rebar3 as prod tar && \
    tar -zxvf /bondy/src/_build/prod/rel/*/*.tar.gz -C /bondy/rel/


# ===========================================================================
# Build stage 2
# ===========================================================================

FROM debian:bullseye-slim as runner

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
RUN apt-get update \
    && apt-get -y install \
    bash procps iproute2 net-tools curl jq nano \
    openssl libsodium-dev libsnappy-dev \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 1000 -r bondy \
    && useradd -u 1000 -r -g bondy -d /bondy -s /bin/bash -c "Bondy user" bondy


WORKDIR /bondy
USER bondy:bondy

# Copy the release to workdir
COPY --chown=bondy:bondy --from=builder /bondy/rel .

# We add Bondy executables to PATH
ENV PATH="/bondy/bin:$PATH"
ENV BONDY_LOG_CONSOLE=console
ENV BONDY_LOG_LEVEL=info
ENV ERL_CRASH_DUMP=/dev/null

# This is required so that relx replaces the vm.args
# BONDY_ERL_NODENAME and BONDY_ERL_DISTRIBUTED_COOKIE variables
ENV RELX_REPLACE_OS_VARS=true
# Default value. We assume you have DNS. Erlang will take the FQDN and generate
# a node name == ${BONDY_ERL_NODENAME}@${FQDN}
ENV BONDY_ERL_NODENAME=bondy
# Default value.
ENV BONDY_ERL_DISTRIBUTED_COOKIE=bondy
# This env var is read by the Erlang VM
ENV ERL_DIST_PORT=27784

ENV HOME "/bondy"

# Define which ports are intended to be published
# 18080 API GATEWAY HTTP and WS
EXPOSE 18080/tcp
# 18081 ADMIN API HTTP
EXPOSE 18081/tcp
# 18082 WAMP TCP
EXPOSE 18082/tcp
# 18083 API GATEWAY HTTPS and WSS
EXPOSE 18083/tcp
# 18084 ADMIN API HTTPS
EXPOSE 18084/tcp
# 18085 WAMP TLS
EXPOSE 18085/tcp
# 18086 CLUSTER PEER SERVICE
EXPOSE 18086/tcp

VOLUME ["/bondy/data", "/bondy/etc", "/bondy/tmp", "/bondy/log"]

ENTRYPOINT ["bondy", "foreground"]
