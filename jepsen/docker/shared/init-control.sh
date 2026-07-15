#!/bin/bash
# Control-container init: Java 21, Leiningen, and the libraries Jepsen
# uses at runtime (gnuplot for perf graphs, graphviz for state
# diagrams, libjna for JNA-based SSH).

set -e

export DEBIAN_FRONTEND=noninteractive

apt update
apt-get install -y -V --fix-missing --no-install-recommends \
    apt-transport-https \
    wget \
    ca-certificates \
    gnupg \
    curl

# Jepsen runtime deps
apt install -y -V --fix-missing --no-install-recommends \
  libjna-java gnuplot graphviz openssh-client git

# Java 21 (Temurin) — pick the binary that matches the container arch.
# `apt -y --no-install-recommends install` above gave us `uname` via the
# default debian image; we don't need a separate package.
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)   JDK_ARCH=x64 ;;
  aarch64|arm64)  JDK_ARCH=aarch64 ;;
  *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac
export JAVA_PATH="/usr/lib/jdk-21"
JAVA_URL="https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.9%2B10/OpenJDK21U-jdk_${JDK_ARCH}_linux_hotspot_21.0.9_10.tar.gz"
wget --progress dot:giga --output-document "$JAVA_PATH.tar.gz" "$JAVA_URL"
mkdir -p $JAVA_PATH
tar --extract --file "$JAVA_PATH.tar.gz" --directory "$JAVA_PATH" --strip-components 1
rm "$JAVA_PATH.tar.gz"
ln -sf "$JAVA_PATH/bin/java" /usr/bin/java

# Leiningen (latest stable installer)
wget -O /usr/bin/lein https://raw.githubusercontent.com/technomancy/leiningen/stable/bin/lein
chmod u+x /usr/bin/lein
lein -v
