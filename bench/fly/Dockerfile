# =============================================================================
# bondy (umbrella) — Linux bench substrate for Fly.io (bondy_oplog/bondy_db)
#
# Long-lived SSH-only Debian 12 image built on the community
# `hexpm/elixir` image which bundles a tested OTP + Elixir pair.
# Adds rebar3 + just + sysstat/strace/procps for the bench plan
# §4 companion-data tools, and pre-compiles the project under
# both rebar3 and mix so the first ssh session lands at usable
# speed.
#
# Why hexpm/elixir vs the bare official `erlang:28`: the bench
# harness under `bench/` is an Elixir Mix project, so we need both
# toolchains anyway; hexpm/elixir bakes them in together. Why
# hexpm/elixir vs kerl-built OTP: ~10 min faster cold builds, and
# the community image carries security patches and OTP releases
# without us tracking them. The "minimal OTP build" win from kerl
# (no observer/wx/odbc) is irrelevant on a 4 GB bench VM.
#
# See `bench/fly/README.md` for the operator runbook and
# `_design/latest/PACK_STORE_WRITE_PATH_FLOOR_BENCH_PLAN.md` §10
# for the QA #14 execution context.
# =============================================================================

# OTP 28 + Elixir 1.18.4 on Debian 12 (bookworm) slim.
#
# `hexpm/elixir` tag format is
# `<elixir>-erlang-<otp>-<os>-<os_version>[-slim]`. Rolling tags
# (no date snapshot) are used here because we re-pin via the
# Fly.io substrate doc whenever production OTP is fixed; if you
# need fully reproducible image bytes, pin to a dated snapshot
# tag from https://hub.docker.com/r/hexpm/elixir/tags.
FROM hexpm/elixir:1.18.4-erlang-28.0-debian-bookworm-20260518-slim

ARG REBAR3_VERSION=3.24.0
ARG JUST_VERSION=1.36.0

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    CMAKE_POLICY_VERSION_MINIMUM=3.5

# Runtime + bench companion tools.
#   - sysstat / procps / strace: bench plan §4 explicitly calls
#     for `iostat`, `vmstat`, `strace`.
#   - build-essential: the project ships NIFs (lz4, ezstd via
#     `c_src/lz4.c` and friends) that `rebar3 compile` builds
#     from source. Without `cc` the compile step fails. Also lets
#     operators recompile after `git pull` without reaching for
#     a separate dev image.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        ca-certificates \
        curl \
        git \
        procps \
        strace \
        sysstat \
        less \
        vim-tiny \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# rebar3 binary (pinned). hexpm/elixir ships its own rebar3 via
# `mix local.rebar`, but we want a project-level pinned version
# for `rebar3 compile` from the shell.
RUN curl -fsSL -o /usr/local/bin/rebar3 \
        https://github.com/erlang/rebar3/releases/download/${REBAR3_VERSION}/rebar3 \
    && chmod +x /usr/local/bin/rebar3

# just (justfile runner). The project's bench commands are driven
# through `just bench-*` recipes so the image needs it on PATH.
RUN curl -fsSL -o /tmp/just.tar.gz \
        "https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
    && tar -xzf /tmp/just.tar.gz -C /usr/local/bin just \
    && rm /tmp/just.tar.gz

# Mix + hex + rebar3 archive bootstrap. Done once at build time
# (not at runtime) so first ssh into a fresh machine doesn't fetch.
RUN mix local.hex --force \
    && mix local.rebar --force

# Project source. Copied last so source edits only invalidate the
# tail of the layer cache. `_build` is excluded via .dockerignore;
# the runtime symlink to /data/_build keeps it on the volume.
WORKDIR /opt/bondy
COPY . /opt/bondy

# Pre-fetch Erlang and Elixir deps. Pre-compile:
#   - rebar3 default profile — builds the whole umbrella (bondy_db,
#     bondy_oplog, bondy_mst, leveled and the rest of the apps)
#   - bench Mix project (Bench module + bench/lib/* support code).
# `leveled` is a normal dependency of `bondy_db`, so the durable
# benchmark scenarios are available without a separate bench profile.
RUN rebar3 compile \
    && cd bench && mix deps.get && mix compile

# Entrypoint:
#   1. Symlink /tmp to the persistent Fly volume so bench artefacts
#      survive machine restarts.
#   2. Stay alive (Fly machines stop when PID 1 exits).
COPY bench/fly/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["tail", "-f", "/dev/null"]
