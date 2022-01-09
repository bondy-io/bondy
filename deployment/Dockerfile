# syntax=docker/dockerfile:1.3

# ===========================================================================
# Build stage 1
# ===========================================================================

FROM erlang:24 AS builder

ARG BONDY_TAG=1.0.0-beta.19
ENV BONDY_REPO=https://gitlab.com/leapsight/bondy.git
ENV BUILD_DIR /bondy-build
ENV REBAR_BASE_DIR /bondy-build/_build

WORKDIR $BUILD_DIR

# Install build deps
RUN --mount=type=cache,id=apk,sharing=locked,target=/var/cache/apt apt-get update && \
    apt-get -y install --no-install-recommends build-essential git libssl-dev libsodium-dev libsnappy-dev curl && \
	rm -rf /var/lib/apt/lists/*

# Copy bondy sourc root to working dir
COPY ../ .

# create the directory to unpack the release to
RUN mkdir -p /opt/rel

# Generates tar in REBAR_BASE_DIR and untars in /opt/rel
RUN rebar3 as prod tar && \
    tar -zxvf $REBAR_BASE_DIR/prod/rel/*/*.tar.gz -C /opt/rel


# ===========================================================================
# Build stage 2
# ===========================================================================

FROM debian:bullseye as runner

ENV BONDY_LOG_CONSOLE=console
ENV BONDY_LOG_LEVEL=info
ENV ERL_CRASH_DUMP=/dev/null

WORKDIR /opt/bondy

# Erlang crypto needs openssl
# enacl dep needs libsodium
# we add curl and jq for HTTP/REST api operations
RUN apt-get update \
    && apt-get -y install openssl libsodium-dev iproute2 curl jq \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/rel .

# We add Bondy and Erlang execultables to PATH
ENV PATH="/opt/bondy/bin:/opt/bondy/erts-12.2/bin:$PATH"

# Ports
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
