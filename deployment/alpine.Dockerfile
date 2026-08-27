# syntax=docker/dockerfile:1.3

# ===========================================================================
# Build stage 1
# ===========================================================================

FROM erlang:29.0.5-alpine AS builder

# Build dependencies. snappy-dev is removed with RocksDB (its only consumer);
# build-base/cmake/git/patch stay for the surviving native NIFs — notably
# crc32cer, whose cmake build fetches and patches google/crc32c at build time.
RUN --mount=type=cache,id=apk,sharing=locked,target=/var/cache/apk \
    ln -s /var/cache/apk /etc/apk/cache && \
    apk add --no-cache \
        build-base \
        cmake \
        libstdc++ \
        git \
        tar \
        patch \
        ncurses \
        openssl \
        jq \
        curl \
        bash \
        nano

# google/crc32c 1.1.2 ships a pre-3.5 CMakeLists; give modern cmake a policy floor.
ENV CMAKE_POLICY_VERSION_MINIMUM=3.5

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

# Keep this Alpine version >= the erlang:*-alpine builder base (musl ABI must be
# equal-or-newer, or the stage-1 NIFs fail to load). `erlang:29.0.5-alpine`
# reports 3.24.1 in /etc/alpine-release, so this tracks it.
FROM alpine:3.24 as runner

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
# - nano: for devops
#
# We install the following required packages:
# - openssl: required by Erlang crypto application
# We setup the bondy group and user and the /bondy dir
#
# The four VOLUME paths (etc, data, log, tmp) MUST exist in the image and be
# owned by `bondy` BEFORE the VOLUME instruction below. Docker creates a missing
# mountpoint as root:root 0755 at container-create time, and this image runs as
# the unprivileged `bondy` user — so an image without them boots into
# `filelib:ensure_path/1` failing on `/bondy/data/bondy_db/main` (surfaced by
# `bondy_namespace_catalog` as `{badmatch,{error,enoent}}`; ensure_path/1 reports
# the underlying EACCES as `enoent`). When the mountpoint DOES exist, Docker
# seeds the anonymous volume from it and carries its ownership over. Creating
# /bondy/etc also avoids a K8s deployment issue where the directory is otherwise
# not writable by Bondy.
#
# `/bondy/run` is created here for the opposite reason: it holds the internal
# admin listener's Unix domain socket and must stay on the container's own
# filesystem, so it is deliberately NOT a VOLUME (see the VOLUME line below).
# It still has to be created and chowned here — `/bondy` itself is root:root
# 0755, so the `bondy` uid cannot create a child of it at runtime.
RUN --mount=type=cache,id=apk,sharing=locked,target=/var/cache/apk \
    ln -s /var/cache/apk /etc/apk/cache \
    && apk add --no-cache \
        libstdc++  \
        bash procps iproute2 net-tools nano ncurses openssl \
    && addgroup --gid 1000 bondy \
    && adduser \
        --uid 1000 \
        --disabled-password \
        --ingroup bondy \
        --home /bondy \
        --shell /bin/bash bondy \
    && mkdir -p /bondy/etc /bondy/data /bondy/log /bondy/tmp /bondy/run \
    && chown bondy:bondy /bondy/etc /bondy/data /bondy/log /bondy/tmp /bondy/run

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
#
# `/bondy/run` is NOT in this list and must not be added to it. It holds the
# internal admin listener's Unix domain socket, and several filesystems an
# operator can legitimately mount reject an AF_UNIX bind with ENOTSUP (NFS,
# SMB/CIFS, 9p, some FUSE CSI drivers, gVisor's gofer). Declaring it a VOLUME
# invites exactly the mount that breaks the node's control endpoint. With a
# read-only root filesystem, mount an emptyDir/tmpfs there instead — both
# accept the bind.
VOLUME ["/bondy/etc", "/bondy/data", "/bondy/tmp", "/bondy/log"]

ENTRYPOINT ["bondy", "foreground"]
