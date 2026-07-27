# syntax=docker/dockerfile:1.3
# =============================================================================
# SPDX-FileCopyrightText: 2016 - 2026 Leapsight
# SPDX-License-Identifier: Apache-2.0
# =============================================================================
#
# M0 Fly fault-injection spike image.
#
# Two differences from deployment/Dockerfile, both required by the harness:
#   1. OTP-28 builder (erlang:28.5.0) — the pinned tag sets minimum_otp_vsn
#      "R28" (rebar.config:6); deployment/Dockerfile is still on erlang:27.3.4
#      and would FAIL to build this branch (00 §9 / 03 §1). This is that fix.
#   2. Runner adds the fault-injection toolbox (iptables, tc via iproute2,
#      libfaketime, stress-ng, fallocate) + the capability probe, so the M0
#      spike can attempt every fault class in 03 §5 and confirm its effect.
#
# Build context is the REPO ROOT (COPY . /bondy/src). Deploy with:
#   fly deploy --config harness/m0-fly-spike/fly.toml \
#              --dockerfile harness/m0-fly-spike/Dockerfile --remote-only
# run from the repo root (see harness/m0-fly-spike/run-spike.sh).
# =============================================================================

# =============================================================================
# Build stage 1 — OTP-28 release build
# =============================================================================
FROM erlang:28.5.0.3 AS builder

# Only what the surviving native NIFs need (RocksDB is gone — no snappy/openssl-dev):
#   build-essential (crc32cer C++, lz4/ezstd C) · cmake (crc32cer's `make nif`) ·
#   git (rebar3 git deps + crc32cer fetches google/crc32c at build).
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

# Some NIFs need a modern CMake policy floor on OTP-28 toolchains.
ENV CMAKE_POLICY_VERSION_MINIMUM=3.5

RUN rebar3 as docker tar && \
    tar -zxvf /bondy/src/_build/docker/rel/*/*.tar.gz -C /bondy/rel/

# =============================================================================
# Build stage 2 — runtime + fault toolbox
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

# Runtime packages: the deployment/Dockerfile minimal set PLUS the fault toolbox.
# The fault tools are only ever driven by root over `fly ssh console`; the Bondy
# process itself runs as the unprivileged `bondy` user (below).
#   base runtime:
#     libstdc++6     : C++ stdlib for the crc32cer NIF (google/crc32c is C++);
#                      previously pulled in transitively by libsnappy1v5, which
#                      is gone with RocksDB — so request it explicitly.
#   fault toolbox:
#     iptables       : partition (drop peer traffic on 18086)
#     iproute2       : tc netem (delay/loss) + ss (connection confirmation)
#     libfaketime    : clock skew via LD_PRELOAD (capability probe)
#     stress-ng      : cpu/mem pressure
#     util-linux     : fallocate (disk fill)
#     libcap2-bin    : capsh/getpcaps (report whether CAP_NET_ADMIN is granted)
#     curl           : hit :18081/ping and /metrics for fault confirmation
#     iputils-ping   : RTT confirmation for tc netem delay
RUN apt-get update && \
    apt-get -y upgrade && \
    apt-get -y install --no-install-recommends \
        bash procps openssl libstdc++6 \
        iproute2 iptables libfaketime stress-ng util-linux \
        libcap2-bin curl iputils-ping \
    && apt-get -y autoremove && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 1000 -r bondy \
    && useradd -u 1000 -r -g bondy -d /bondy -s /bin/bash -c "bondy" bondy \
    && mkdir -p /bondy/etc \
    && chown bondy:bondy /bondy/etc

# The M0 capability probe (root-run via fly ssh). Baked into the image so the
# orchestrator can invoke it without shipping a script over the wire each time.
COPY --chmod=0755 harness/m0-fly-spike/probe.sh /usr/local/bin/bondy-probe.sh

WORKDIR /bondy
USER bondy:bondy

COPY --chown=bondy:bondy --from=builder /bondy/rel .

EXPOSE 18080/tcp
EXPOSE 18081/tcp
EXPOSE 18086/tcp

VOLUME ["/bondy/etc", "/bondy/data", "/bondy/log", "/bondy/tmp"]

ENTRYPOINT ["bondy", "foreground"]
