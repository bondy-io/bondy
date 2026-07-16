#!/usr/bin/env bash
# =============================================================================
# SPDX-FileCopyrightText: 2016 - 2026 Leapsight
# SPDX-License-Identifier: Apache-2.0
# =============================================================================
#
# Bootstraps a PRIVATE certificate authority (CA) for the Bondy cluster peer
# plane (Partisan), and issues one key/cert per node signed by that CA. Use the
# output to enable mutual TLS on the peer plane and close finding C-1 (the
# peer plane is plaintext + unauthenticated by default).
#
# Usage:
#   deployment/cluster-ca-bootstrap.sh OUT_DIR NODE_HOST [NODE_HOST ...]
#
# Example (3-node cluster):
#   deployment/cluster-ca-bootstrap.sh ./cluster-ca \
#       bondy1.internal bondy2.internal bondy3.internal
#
# Then, on EACH node, wire the matching files into bondy.conf:
#
#   cluster.tls.enabled          = on
#   cluster.tls.server.verify    = verify_peer
#   cluster.tls.client.verify    = verify_peer
#   cluster.tls.server.cacertfile = /etc/bondy/tls/ca.pem
#   cluster.tls.client.cacertfile = /etc/bondy/tls/ca.pem
#   cluster.tls.server.certfile  = /etc/bondy/tls/<node>-cert.pem
#   cluster.tls.server.keyfile   = /etc/bondy/tls/<node>-key.pem
#   cluster.tls.client.certfile  = /etc/bondy/tls/<node>-cert.pem
#   cluster.tls.client.keyfile   = /etc/bondy/tls/<node>-key.pem
#
# Copy ONLY that node's key + cert + the shared ca.pem to the node. The CA
# PRIVATE key (ca-key.pem) stays on the bootstrap host — never ship it.
#
# The peer port (default 18086) must NEVER be reachable from the internet or a
# tenant network; bind cluster.peer_ip to a private interface. mTLS is
# defence-in-depth, not a substitute for network isolation.
# =============================================================================

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "usage: $0 OUT_DIR NODE_HOST [NODE_HOST ...]" >&2
    exit 2
fi

OUT_DIR="$1"; shift
NODES=("$@")

DAYS_CA="${BONDY_CA_DAYS:-3650}"      # CA validity (10y default)
DAYS_CERT="${BONDY_CERT_DAYS:-825}"   # node cert validity (~27m default)
CURVE="${BONDY_EC_CURVE:-prime256v1}" # EC P-256

command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 1; }

mkdir -p "$OUT_DIR"
umask 077

CA_KEY="$OUT_DIR/ca-key.pem"
CA_CERT="$OUT_DIR/ca.pem"

if [[ -f "$CA_KEY" && -f "$CA_CERT" ]]; then
    echo "Reusing existing CA in $OUT_DIR"
else
    echo "Creating private cluster CA in $OUT_DIR"
    openssl ecparam -name "$CURVE" -genkey -noout -out "$CA_KEY"
    openssl req -x509 -new -key "$CA_KEY" -sha256 -days "$DAYS_CA" \
        -subj "/O=Bondy/OU=Cluster/CN=Bondy Cluster CA" -out "$CA_CERT"
    chmod 600 "$CA_KEY"
fi

issue_node() {
    local host="$1"
    local key="$OUT_DIR/${host}-key.pem"
    local csr="$OUT_DIR/${host}.csr"
    local cert="$OUT_DIR/${host}-cert.pem"
    local ext="$OUT_DIR/${host}.ext"

    echo "Issuing cert for node: $host"
    openssl ecparam -name "$CURVE" -genkey -noout -out "$key"
    chmod 600 "$key"
    openssl req -new -key "$key" -subj "/O=Bondy/OU=Cluster/CN=${host}" -out "$csr"

    # SAN: DNS name, plus an IP SAN when the host is an IP literal. Peers verify
    # both the CA signature AND that the presented cert matches the peer.
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf 'subjectAltName=IP:%s\nextendedKeyUsage=serverAuth,clientAuth\n' "$host" > "$ext"
    else
        printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth,clientAuth\n' "$host" > "$ext"
    fi

    openssl x509 -req -in "$csr" -CA "$CA_CERT" -CAkey "$CA_KEY" \
        -CAcreateserial -days "$DAYS_CERT" -sha256 -extfile "$ext" -out "$cert"
    rm -f "$csr" "$ext"
}

for node in "${NODES[@]}"; do
    issue_node "$node"
done

echo
echo "Done. Files in $OUT_DIR:"
echo "  ca.pem          -> cluster.tls.{server,client}.cacertfile (ship to every node)"
echo "  <node>-cert.pem -> cluster.tls.{server,client}.certfile   (per node)"
echo "  <node>-key.pem  -> cluster.tls.{server,client}.keyfile    (per node, secret)"
echo "  ca-key.pem      -> KEEP OFFLINE on this host; never distribute."
