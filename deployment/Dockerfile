# syntax=docker/dockerfile:1.3
# =============================================================================
# SPDX-FileCopyrightText: 2016 - 2026 Leapsight
# SPDX-License-Identifier: Apache-2.0
# =============================================================================

# =============================================================================
# Build stage 1
# =============================================================================
FROM erlang:27.3.4 AS builder

# Install build dependencies.
# libsnappy-dev (headers) is correct HERE — the NIFs that link snappy are
# compiled in this stage. The runtime stage only needs the shared library.
RUN --mount=type=cache,id=apt,sharing=locked,target=/var/cache/apt apt-get update && \
    apt-get -y install --no-install-recommends \
    build-essential \
    cmake \
    git \
    libssl-dev \
    libsnappy-dev \
    curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /bondy/src

# Copy Bondy project source to working dir
COPY ../ /bondy/src

# Create dir we will unpack release tar into
RUN mkdir -p /bondy/rel

# Generates tar in /bondy/src/_build and untars in /bondy/rel
RUN rebar3 as docker tar && \
    tar -zxvf /bondy/src/_build/docker/rel/*/*.tar.gz -C /bondy/rel/

# =============================================================================
# Build stage 2
# =============================================================================
# debian trixie (Debian 13). `debian:stable-slim` rolled from bookworm to
# trixie, so watch the Debian 13 security tracker for this image.
#
# For reproducible, audit-friendly builds, pin the base by digest instead of
# the floating tag, e.g.:
#   FROM debian:trixie-slim@sha256:<digest> AS runner
# You can get the current digest with:
#   docker buildx imagetools inspect debian:trixie-slim
FROM debian:trixie-slim AS runner

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

# Runtime packages — kept deliberately minimal to reduce CVE surface.
#
#   - bash      : entrypoint / relx boot scripts
#   - procps    : ps, top, free, kill, sysctl, etc. (ops diagnostics)
#   - iproute2  : ip, ss (replaces the deprecated net-tools)
#   - openssl   : required by the Erlang crypto application
#   - libsnappy1v5 : runtime shared lib for snappy compression (not the -dev headers)
#
# Deliberately NOT installed (each removed a CVE class):
#   - sudo      : container runs as the single non-root `bondy` user; no use for
#                 it, and it carried a HIGH (CVE-2026-35535).
#   - dnsutils  : pulls bind9-libs -> libxml2 + libkrb5, the source of 5 HIGH /
#                 several MEDIUM findings with NO upstream fix. Bondy resolves
#                 DNS via the Erlang runtime; dig/nslookup are not needed.
#   - nano      : editor, not needed in a production image (2 CVEs).
#   - net-tools : deprecated; superseded by iproute2.
#
# `apt-get upgrade` ensures base-image packages pick up Debian security updates
# (glibc, systemd, libcap2, nghttp2, ...) rather than staying frozen at the
# versions cached in the base layer.
RUN apt-get update && \
    apt-get -y upgrade && \
    apt-get -y install --no-install-recommends \
        bash procps iproute2 openssl libsnappy1v5 \
    && apt-get -y autoremove && apt-get clean \
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
# WAMP TCP (Default: 18082)
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
