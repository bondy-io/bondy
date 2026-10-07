# Securing the Cluster Peer Plane

Cluster nodes talk to each other over the peer plane, which carries
replicated security state: users and their credentials, grants, and realm
signing keys. Over plaintext, or over TLS that does not verify the peer, an
on-path attacker can read or change that state, and a rogue node can inject
it.

Bondy refuses to start a node that discovers its peers automatically over an
insecure peer plane.

## When the check applies

The check runs at node start, and applies only when both of these are on:

| Key | Default |
| --- | --- |
| `cluster.enabled` | `on` |
| `cluster.peer_discovery.enabled` | `off` |

With the defaults, the check does not apply. A node with
`cluster.enabled = off` has no peer plane (see
[Clustering](../configuration/clustering.md)). A node with peer discovery off
is not checked even if it joins a cluster by other means, so secure its peer
plane with the same settings.

The check is in `bondy_router_app:peer_plane_gate/1`
(`bondy_router_app_peer_plane_test`).

## Settings that satisfy it

The peer plane is secure when TLS is on and both sides verify the peer:

```
cluster.tls.enabled = on
cluster.tls.server.verify = verify_peer
cluster.tls.client.verify = verify_peer
```

| Key | Default |
| --- | --- |
| `cluster.tls.enabled` | `off` |
| `cluster.tls.server.verify` | `verify_none` |
| `cluster.tls.client.verify` | `verify_none` |

Point `cluster.tls.server.{certfile,keyfile,cacertfile}` and
`cluster.tls.client.{certfile,keyfile,cacertfile}` at certificates issued by
a private cluster CA, so that only your own nodes pass verification.
`cluster.tls.server.versions` and `cluster.tls.client.versions` default to
`1.3`.

## What happens otherwise

When the check applies and the peer plane is insecure, the node logs an error
and the `bondy_router` application fails to start with:

```erlang
{insecure_cluster_peer_plane, Reason}
```

| `Reason` | Cause |
| --- | --- |
| `tls_disabled` | `cluster.tls.enabled` is `off`. |
| `verify_none` | TLS is on, but the server side, the client side, or both do not use `verify_peer`. |

(`bondy_router_app_peer_plane_test:clustering_tls_off_refuses_test`,
`bondy_router_app_peer_plane_test:clustering_verify_none_refuses_test`.)

## Accepting the risk

`cluster.tls.allow_insecure` (`on | off`, default `off`) turns the refusal
into a warning. The node starts, and logs a warning with the same `Reason` at
every start
(`bondy_router_app_peer_plane_test:allow_insecure_downgrades_to_warn_test`).
Turn it on only when the network between the nodes is trusted. On a secure
peer plane the setting has no effect
(`bondy_router_app_peer_plane_test:allow_insecure_noop_when_secure_test`).
