# Securing the Bondy cluster peer plane (C-1)

Bondy clusters over **Partisan**, not Erlang distribution. The peer transport
(default port **18086**) is, by default, **plaintext and unauthenticated**:

- `cluster.tls.enabled = off`
- `cluster.tls.server.verify = verify_none` and `cluster.tls.client.verify =
  verify_none` (so even turning TLS *on* only encrypts — it does not authenticate
  peers; any certificate is accepted and the channel is MITM-able).

On this plane Bondy replicates security state (grants, users, tickets/tokens and
**realm signing keys**) via anti-entropy. An attacker with network reach to the
peer port, or an on-path position between nodes, can therefore read/modify
replicated credentials and realm keys, or join as a rogue peer and inject
security state. **Isolate the peer port** (private subnet / security group;
never internet- or tenant-reachable) and enable mutual TLS.

## The startup safety gate

When a node is configured to auto-cluster (`cluster.peer_discovery.enabled =
on`) but its peer plane is insecure (TLS off, or on with `verify_none` on either
side), Bondy **refuses to start**. To proceed anyway — e.g. a cluster you know
is on a fully isolated network — acknowledge it explicitly:

```
cluster.tls.allow_insecure = on
```

That downgrades the refusal to a prominent startup warning. Non-clustering
(single-node / dev) nodes are never gated. The secure fix is mutual TLS below.

## Enabling mutual TLS with a private cluster CA

1. Generate a private CA and a per-node key/cert with the bootstrap helper:

   ```
   deployment/cluster-ca-bootstrap.sh ./cluster-ca \
       bondy1.internal bondy2.internal bondy3.internal
   ```

   Ship each node ONLY its own `<node>-key.pem` + `<node>-cert.pem` and the
   shared `ca.pem`. Keep `ca-key.pem` offline; never distribute it.

2. On each node, set in `bondy.conf`:

   ```
   cluster.tls.enabled           = on
   cluster.tls.server.verify     = verify_peer
   cluster.tls.client.verify     = verify_peer
   cluster.tls.server.cacertfile = /etc/bondy/tls/ca.pem
   cluster.tls.client.cacertfile = /etc/bondy/tls/ca.pem
   cluster.tls.server.certfile   = /etc/bondy/tls/<node>-cert.pem
   cluster.tls.server.keyfile    = /etc/bondy/tls/<node>-key.pem
   cluster.tls.client.certfile   = /etc/bondy/tls/<node>-cert.pem
   cluster.tls.client.keyfile    = /etc/bondy/tls/<node>-key.pem
   ```

   With `verify_peer` on both sides + a shared private CA, only nodes presenting
   a CA-signed certificate can join the peer plane — the gate is then satisfied
   and Bondy starts without `allow_insecure`.

3. Bind the peer plane to a private interface, never `0.0.0.0`:

   ```
   cluster.peer_ip = 10.0.0.5   # this node's private address
   ```

   Restrict TLS keys/certs to `0600`. Rotate node certs before expiry
   (`BONDY_CERT_DAYS`, default ~27 months).

mTLS is defence-in-depth; it does not replace network isolation of the peer port.
