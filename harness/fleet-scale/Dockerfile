# syntax=docker/dockerfile:1.3
# =============================================================================
# SPDX-FileCopyrightText: 2016 - 2026 Leapsight
# SPDX-License-Identifier: Apache-2.0
# =============================================================================
#
# Fleet-scale cluster image. Based on harness/m0-fly-spike/Dockerfile, with
# one deliberate difference: it does NOT `USER bondy:bondy` before the
# entrypoint. This image targets hundreds of thousands of connections and
# leveled's own 200K+ file-handle need, both requiring a raised nofile
# ulimit -- and only root can raise its own hard limit inside the container.
# setup.sh (this harness's entrypoint) raises the limit as root, then `su
# bondy` into the actual Bondy process; the raised rlimit is inherited across
# that privilege drop.
#
# Build context is the REPO ROOT (COPY . /bondy/src). Deploy with:
#   fly deploy --config harness/fleet-scale/fly.toml \
#              --dockerfile harness/fleet-scale/Dockerfile --remote-only
# run from the repo root (see harness/fleet-scale/run-fleet.sh).
# =============================================================================

# =============================================================================
# Build stage 1 — OTP-29 release build
# =============================================================================
FROM erlang:29.0.5 AS builder

RUN --mount=type=cache,id=apt,sharing=locked,target=/var/cache/apt apt-get update && \
    apt-get -y install --no-install-recommends \
    build-essential \
    cmake \
    git && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /bondy/src

# Repo root is the build context.
COPY . /bondy/src

RUN mkdir -p /bondy/rel

# Some NIFs need a modern CMake policy floor on OTP-29 toolchains.
ENV CMAKE_POLICY_VERSION_MINIMUM=3.5

RUN rebar3 as docker tar && \
    tar -zxvf /bondy/src/_build/docker/rel/*/*.tar.gz -C /bondy/rel/

# =============================================================================
# Build stage 2 — runtime
# =============================================================================
FROM debian:trixie-slim AS runner

ENV BONDY_ERL_NODENAME=bondy@127.0.0.1
ENV BONDY_ERL_DISTRIBUTED_COOKIE=bondy
ENV BONDY_LOG_CONSOLE=console
ENV BONDY_LOG_LEVEL=info
ENV ERL_CRASH_DUMP=/dev/null
ENV ERL_DIST_PORT=27780
ENV PATH="/bondy/bin:$PATH"
ENV RELX_REPLACE_OS_VARS=true
ENV HOME="/bondy"

# libstdc++6: C++ stdlib for the crc32cer NIF (google/crc32c is C++).
# util-linux: provides setpriv, used by setup.sh to drop root -> bondy.
RUN apt-get update && \
    apt-get -y upgrade && \
    apt-get -y install --no-install-recommends \
        bash procps openssl libstdc++6 util-linux \
    && apt-get -y autoremove && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 1000 -r bondy \
    && useradd -u 1000 -r -g bondy -d /bondy -s /bin/bash -c "bondy" bondy \
    && mkdir -p /bondy/etc /bondy/data /bondy/log /bondy/tmp \
    && chown -R bondy:bondy /bondy/etc /bondy/data /bondy/log /bondy/tmp

WORKDIR /bondy

# Deliberately NO `USER bondy:bondy` here -- see header comment. The
# container starts as root; setup.sh raises nofile then `su bondy`s in.

COPY --chown=bondy:bondy --from=builder /bondy/rel .

EXPOSE 18080/tcp
EXPOSE 18081/tcp
EXPOSE 18086/tcp

ENTRYPOINT ["bondy", "foreground"]
