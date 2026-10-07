# Bridge relay: reconnect and ping

An outbound bridge relay, declared under `bridge.$name.*`, is a client
connection from this node to a remote Bondy router. Two blocks decide how it
keeps that connection alive: `reconnect` decides what happens when the
connection is lost, and `ping` detects a remote that has stopped answering.

## `bridge.$name.reconnect.*`

| Key | Default | Meaning |
| --- | --- | --- |
| `bridge.$name.reconnect` | `on` | Reconnect after a lost or failed connection. |
| `bridge.$name.reconnect.max_retries` | `100` | Failed attempts before the retry budget is spent. |
| `bridge.$name.reconnect.backoff.type` | `jitter` | `jitter` or `normal`. |
| `bridge.$name.reconnect.backoff.min` | `5s` | First delay between attempts. |
| `bridge.$name.reconnect.backoff.max` | `60s` | Largest delay between attempts. |

## `bridge.$name.ping.*`

| Key | Default | Meaning |
| --- | --- | --- |
| `bridge.$name.ping` | `on` | Send pings to the remote router. The client always answers the remote's pings. |
| `bridge.$name.ping.idle_timeout` | `20s` | Inactivity after which the client sends a ping. |
| `bridge.$name.ping.timeout` | `10s` | Time to wait for each pong. |
| `bridge.$name.ping.max_attempts` | `3` | Unanswered pings before the client drops the connection. |

## Defaults apply key by key

The defaults above are those of `bondy_bridge_relay`'s `?RECONNECT_SPEC` and
`?PING_SPEC`. Every `bridge.$name.reconnect.*` and `bridge.$name.ping.*` key is
commented out in the shipped configuration, so a bridge that sets none of them
runs with all of these defaults. A bridge that sets some keys of a block gets
the default for each key it leaves out: setting only
`bridge.$name.reconnect.max_retries = 10` keeps reconnect on, with `jitter`
backoff from `5s` to `60s`.

## What happens when the connection is lost

A connection attempt that fails with `timeout`, `econnrefused`, `econnreset`,
`ehostdown`, `enotconn`, `etimedout`, `enetdown`, `ehostunreach` or
`enetunreach` counts against the retry budget, and the client tries again after
the next backoff delay. Any other connect error stops the client.

The client reconnects when:

- the socket reports that it closed or failed;
- a send fails with a closed socket or a socket error: while the client opens
  its session (sending `HELLO`, answering the challenge, setting up the realm
  sync, announcing the local registrations and subscriptions), or while it
  forwards a message or sends or answers a ping.

If a session was open on the lost connection, the client reconnects at once,
with a fresh retry budget. If no session was open, the attempt counts against
`reconnect.max_retries` and the client waits the next backoff delay first. When
the budget is spent, or when reconnect is `off`, the client stops.

The retry budget is spent after `reconnect.max_retries` failed attempts; it has
no time limit.

Each bridge client is a permanent child of `bondy_bridge_relay_client_sup`: when
it stops, the supervisor starts it again with a new connection and a new retry
budget.

When the remote leaves `ping.max_attempts` pings unanswered, the client logs
"Remote router has not responded to our ping on time. Shutting down and
restarting." and stops.

## See also

- [Listeners](listeners.md): the accepting side of a bridge relay.
