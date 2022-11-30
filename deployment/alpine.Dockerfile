# syntax=docker/dockerfile:1.3

# ===========================================================================
# Build stage 1
# ===========================================================================

FROM erlang:24-alpine AS builder

# Install build dependencies
RUN --mount=type=cache,id=apk,sharing=locked,target=/var/cache/apk \
    ln -s /var/cache/apk /etc/apk/cache && \
    apk add --no-cache build-base libstdc++ git tar patch ncurses openssl snappy-dev libsodium-dev jq curl bash nano

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

FROM alpine:3.16 as runner

# We define defaults
# We assume you have DNS. Erlang will take the FQDN and generate
# a node name == ${BONDY_ERL_NODENAME}@${FQDN}
ENV BONDY_ERL_NODENAME=bondy
ENV BONDY_ERL_DISTRIBUTED_COOKIE=bondy
ENV BONDY_LOG_CONSOLE=console
ENV BONDY_LOG_LEVEL=info
ENV ERL_CRASH_DUMP=/dev/null
ENV ERL_DIST_PORT=27784

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
# We setup the bondy group and user, the /bondy dir
# and we override directory locations
RUN --mount=type=cache,id=apk,sharing=locked,target=/var/cache/apk \
    ln -s /var/cache/apk /etc/apk/cache \
    && apk add --no-cache \
        libstdc++  \
        bash procps iproute2 net-tools curl jq nano \
        ncurses openssl libsodium-dev snappy-dev \
    && addgroup --gid 1000 bondy \
    && adduser \
        --uid 1000 \
        --disabled-password \
        --ingroup bondy \
        --home /bondy \
        --shell /bin/bash bondy \
    && export BONDY_ETC_DIR=/bondy/etc \
    && export BONDY_DATA_DIR=/bondy/data \
    && export BONDY_LOG_DIR=/bondy/log \
    && export BONDY_TMP_DIR=/bondy/tmp


WORKDIR /bondy
USER bondy:bondy

# Copy the release to workdir
COPY --chown=bondy:bondy --from=builder /bondy/rel .


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

VOLUME ["/bondy/etc", "/bondy/data", "/bondy/tmp", "/bondy/log"]

ENTRYPOINT ["bondy", "foreground"]
