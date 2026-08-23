# Listener configuration reference

A **listener** is one socket Bondy binds — a TCP port, a TLS port, or a Unix
domain socket — together with the protocol it speaks and, for HTTP, the set
of services it exposes on that socket. Every listener an operator declares
lives under `listeners.$name.*` in `bondy.conf`, where `$name` is a name of
the operator's choosing, e.g. `listeners.public_http.transport = tcp`. A
node with no `listeners.*` key at all keeps the nine listeners it has always
had, at their historical ports and names — declaring even one
`listeners.*` key switches the node onto this configuration surface for
every listener, so a template being converted needs every listener it wants
restated here, not just the one being changed.

## The four keys every listener needs

```
listeners.public_wamp.transport = tcp
listeners.public_wamp.protocol  = wamp_rawsocket
listeners.public_wamp.port      = 18082
```

- **`transport`** selects the socket driver: `tcp`, `tls` or `uds`. TLS is a
  *transport*, not a protocol: an HTTPS listener is `protocol = http` with
  `transport = tls`, not a distinct HTTP variant.
- **`protocol`** selects what frames the wire: `http` (Cowboy, multiplexing
  several services by path), or a raw-socket protocol carrying exactly one
  thing — `wamp_rawsocket` for WAMP clients, `bridge_relay` for the socket a
  peer router's bridge connects to. A protocol Bondy has no handler for is
  refused at boot, naming the listener, rather than accepted and crashing at
  start.
- **`port`** (or `path`, for a `uds` listener) is the bind target. There is
  no default — a default would let two listeners collide silently — so
  every listener must state one. `port = 0` asks the operating system to
  choose, which is the only value two listeners may share.
- **`services`**, comma-separated, is required when `protocol = http` and
  rejected for every other protocol: a raw socket carries one thing by
  construction, so a list of services on one would be ambiguous. `services`
  is what lets an HTTP listener multiplex several things onto one socket —
  the historical public listener served the API Gateway, WAMP-over-WebSocket,
  SSE and long-poll all on port 18080 for exactly this reason.

Everything else — `enabled`, `start_phase`, connection tuning, CORS, security
headers, and the carrier overrides below — is optional and, where it has no
value, falls back to a global default or the driver's own default. None of
it has a `listeners.$name.*`-level default of its own; see
[TLS material](#tls-material) for the one place that matters in practice.

## Services

| Service        | Carrier    | Protocol | Notes |
|----------------|------------|----------|-------|
| `api_gateway`  | `api_gateway` | —     | Stored API Gateway specifications. |
| `admin_api`    | `admin_api` | —       | The built-in Admin API (realms, users, grants). |
| `admin`        | —          | —        | Liveness/readiness endpoints (`/ping`, `/ready`). |
| `metrics`      | —          | —        | Prometheus scrape endpoint. |
| `wamp_ws`      | WebSocket  | WAMP     | |
| `bamp_ws`      | WebSocket  | BAMP     | Mounts `/ws` restricted to the `bamp` subprotocol. BAMP's wire implementation has not shipped, so a session cannot yet be carried over it. |
| `wamp_sse`     | SSE        | WAMP     | |
| `wamp_longpoll`| Long-poll  | WAMP     | |

**An HTTP listener must declare at least one service.** Both a missing
`services` key and an empty one are refused at boot, naming the listener. Such a
listener would bind its socket and answer 404 to everything, with nothing
reported anywhere. Note that `listeners.<name>.services =` with no value after it
renders as an empty list, so it produces this error rather than a listener with
some default set of services. A `wamp_rawsocket` or `bridge_relay` listener is
the other way round: it serves one protocol by definition, so declaring
`services` on one is itself an error.

A listener can declare several services that share a carrier — `wamp_ws` and
`bamp_ws` both mount on `/ws` — and they resolve to one route carrying both
protocols rather than two routes competing for the same path. Declaring only
one of them restricts that path to that subprotocol: a WAMP client offering
`wamp.2.json` to a `bamp_ws`-only listener is refused with 400.

`admin_api` and `api_gateway` deliberately never share a listener in Bondy's own
defaults: mounting a customer's stored API specification on the same socket that
administers realms and grants would put it one misconfiguration away from being
reachable by the wrong audience. Keep that split when declaring your own
listeners.

Two services on one carrier do not collide, they *shadow*. A path claimed by two
different **carriers** fails the dispatch build with `route_collision` — but only
when both route sets are static. Once either side comes from an API Gateway
specification it cannot: a specification arrives by replication after boot, so
refusing it would take this node's dispatch table down over a document another
node accepted. There the first route assembled answers the path, the other
becomes unreachable on that listener, and a warning naming the path and host is
logged. Bondy's own route sets are assembled first, so a specification cannot
take over `/ws`, `/ping`, `/ready` or `/metrics`.

## Virtual hosts

An API Gateway specification's `host` field is honoured: a specification
declaring `"host": "api.example.com"` answers only requests carrying that `Host`
header, and `"host": "_"` answers on every host. Two specifications may declare
the same path for different hosts.

Bondy's own paths — `/ws`, the SSE and long-poll endpoints, `/ping`, `/ready`,
`/cluster/topology`, `/metrics` — are served on *every* host, including one a
specification names. That is not automatic in Cowboy: its router commits to the
first host entry whose host matches and never falls through to a later one, so a
route mounted only on the wildcard host would be unreachable on any named host.
Bondy copies its listener-wide routes into each named host to prevent that. If a
specification declares one of those paths for its own host, the specification's
route answers there and a warning is logged, because one of Bondy's endpoints is
then not reachable on that host.

## `start_phase`

```
listeners.admin.start_phase = early
```

`early` starts the listener before any `normal` one, while the node still
reports `initialising` — so a liveness or readiness probe, or the metrics
scrape, answers before the node is ready to serve WAMP sessions. Absent
means `normal`. Reaching `ready` means the normal phase finished binding,
not that no client has connected yet — nothing gates connection acceptance
on the node's readiness status.

## Taking a node out of rotation

Two WAMP procedures suspend and resume a phase at runtime, so a node can leave
rotation without a restart or a configuration change:

```
bondy.listener.suspend("normal")
bondy.listener.resume("normal")
```

The argument is a phase — `early`, `normal` or `all` — and both procedures are
callable only from the master realm, because whether this node accepts
connections is not a per-realm decision. Any other value is refused.

Suspending stops a listener accepting *new* connections and leaves established
ones running, which is what makes this a drain: suspend, let the in-flight
sessions finish, and the node has left rotation without dropping work. Nothing
here stops a listener or closes a connection.

Suspending `all` includes the `early` phase, which carries `/ping`, `/ready` and
`/metrics` — an orchestrator watching those will see the node as dead and may
kill it. That is why the shutdown path suspends `normal` only. Resuming a phase
that is already accepting is not an error.

## The reserved `admin` listener

`admin` is a name, not a keyword, but it is reserved: `bondy_listener_manager`
always includes one, either the operator's own `listeners.admin.*` block or
its own default (`tcp`, port `18081`, `start_phase = early`, services
`admin_api, wamp_ws, admin, metrics`, bound to loopback). Declaring it
overrides the default in place; an operator does not have to declare it at
all. What cannot be done is disabling or removing it — a node that could
lose its only administrable listener to a configuration mistake would be
harder to recover than one that refuses that mistake outright.

A second, internal listener — a Unix domain socket at
`<platform_tmp_dir>/bondy_admin.sock` — is injected unconditionally and is
not configurable through `bondy.conf` at all. It exists so the node stays
administrable even if every TCP listener fails to bind. Its socket file is the
only access control it has — there is no peer address to filter on — so Bondy
narrows that one file to mode `0600` after binding it, and refuses to serve on
it if that fails. This applies to the internal socket alone: a `uds` listener
an operator declares keeps the mode the process umask gives it, so a sidecar
running under a different uid can reach it.

## UDS listeners

A connection over a Unix domain socket has no network peer to log, embed in
events, or match against a `bondy_rbac_source` rule. Every listener that binds
over `uds` — `admin_local`'s internal socket and any operator-declared one —
represents such a connection as loopback, `127.0.0.1`, with port `0`. A
`bondy_rbac_source` rule scoped to `127.0.0.1/32` therefore also matches a
client arriving over a `uds` listener, which is consistent with what the rule
already expresses: a Unix socket is reachable only by local processes, a
subset of what a loopback TCP listener admits.

`bridge_relay` is not available over `uds`: a bridge relay is a network link
between Bondy nodes, and there is no driver for one over a local socket.
`listeners.$name.transport = uds` combined with
`listeners.$name.protocol = bridge_relay` is refused at boot, naming the
listener.

## Bind address and IP version

```
listeners.public_wamp.ip         = 192.168.10.4
listeners.public_wamp.ip_version = 6
```

Neither key has a default, so a disagreement between them is always two
explicit statements rather than one of them being supplied for you. `ip`
narrows the listener to one interface and takes an address literal, v4 or v6 —
it is parsed while the file is read, so a hostname is refused there and then,
unlike the historical `*.ip` keys, which accept any name that resolves.
`ip_version` is `4` or `6` and selects the socket family: the thing that
decides whether Bondy opens an IPv4 or an IPv6 socket.

**An address, where one is given, determines the family by itself.** An
address carries its own version and cannot be bound on a socket of the other
one, so `ip_version` decides the family only for a listener that configures no
address — there it chooses which wildcard is bound, `0.0.0.0` for `4` and `::`
for `6`. Where both keys are set and disagree, the address wins and
`ip_version` has no effect: `ip = 127.0.0.1` with `ip_version = 6` binds IPv4.

**Two listeners may share a port when they bind different addresses.** A
socket is identified by its address and port together, so `10.0.0.1:443` and
`10.0.0.2:443` are two sockets and Bondy starts both — one certificate per
interface on a single port is the case this exists for. A listener that
configures no `ip` binds the wildcard, which covers every address on its port
and so excludes every other listener there; Bondy refuses that at startup,
naming both listeners, rather than letting the second one fail its bind.

Addresses of different families count as overlapping whenever either is a
wildcard, so `::` and `127.0.0.1` on one port are refused together. Whether
they truly collide depends on the host's `bindv6only` setting, and Bondy does
not consult it — the refusal is deliberately the conservative answer.

## Connection and socket tuning

```
listeners.public_wamp.acceptors_pool_size = 200
listeners.public_wamp.backlog             = 1024
listeners.public_wamp.keepalive           = on
listeners.public_wamp.nodelay             = on
listeners.public_wamp.max_connections     = 100000
```

These map to ranch's own acceptor pool and socket options, plus a raw-socket
`idle_timeout`, `ping.*` and `proxy_protocol.*` block. A `bridge_relay` listener
also takes `auth_timeout` — how long a connected peer router has to authenticate
before the connection is dropped, 5s if unset. Other protocols ignore it. For an
HTTP listener, the equivalent Cowboy-level settings — timeouts, header limits, the
dynamic receive buffer — carry an `http.` prefix
(`listeners.$name.http.idle_timeout`, not `listeners.$name.idle_timeout`),
because the bare name already means something different on a raw socket and a
setting whose meaning depended on a sibling `protocol` value would be worse than
a longer one.

### Keepalive and idle timeouts

A `wamp_rawsocket` or `bridge_relay` listener that states none of these gets:

```
listeners.public_wamp.idle_timeout      = 8h
listeners.public_wamp.ping.enabled      = on
listeners.public_wamp.ping.idle_timeout = 20s
listeners.public_wamp.ping.timeout      = 10s
listeners.public_wamp.ping.max_attempts = 3
```

`idle_timeout` is the reap deadline: how long a connection may be silent before
Bondy closes it. `ping.idle_timeout` is a different and much shorter thing — how
long before Bondy *probes* a silent connection. Keeping them apart is the point:
a probe is only useful if it comes due well before the reap, and a keepalive
whose interval equalled the reap deadline could neither hold a NAT binding open
nor detect a dead peer any sooner than the reap already did.

`ping.timeout` is how long a probe waits for its answer and `ping.max_attempts`
how many unanswered probes mean a dead peer, so a peer that stops responding is
dropped after `ping.idle_timeout + max_attempts × timeout`. The transport does
not change that judgement: `tcp` and `tls` listeners take the same defaults.

An HTTP listener ignores all of these — a WebSocket connection's keepalive is
configured under its carrier (`listeners.$name.websocket.ping.*`), and Cowboy
owns the idle timeout for a plain request. The carrier's own ping defaults are
the same as the raw-socket ones above — probe after 20s, wait 10s, give up after
3 — so `max_attempts` means one thing across every protocol.

### `linger.timeout` is in seconds

```
listeners.public_wamp.linger.timeout = 1s
```

How long `close` blocks waiting for unsent data to be acknowledged, defaulting
to `1s` on a raw-socket or bridge-relay listener. It is the one duration in
`bondy.conf` expressed in **seconds** rather than milliseconds, because the value
becomes the OS socket option `{linger, {true, N}}` and that component is seconds.
A value written as a bare integer also means seconds. A sub-second value rounds
**up** to one second: `{linger, {true, 0}}` does not mean "linger briefly", it
means abort the connection on close and discard whatever is unsent, so rounding
down would silently turn a graceful close into a reset.

`-1` disables lingering, which is the OS default behaviour — `close` returns
immediately and the kernel finishes sending in the background. `0` requests the
abort described above.

`listeners.$name.http.linger.timeout` is a **different setting**: it is Cowboy's,
it governs how long the HTTP server waits before closing to avoid the TCP reset
problem in RFC 7230 §6.6, and it is in milliseconds. The two are unrelated
despite the near-identical spelling.

### Cookie limits

```
listeners.public_http.http.max_cookie_header_value_length = 4096
listeners.public_http.http.max_cookies                    = 100
```

Two independent bounds on the same header. The first is a **size** limit, in
bytes, on the `Cookie` header value; unset, the listener's general
`max_header_value_length` applies to it. The second is a limit on the **number**
of cookies parsed out of that header, and defaults to 100. A request exceeding
either is answered with a 400.

They are not interchangeable: a single header of legal length can still hold
thousands of tiny cookies, and it is the count that decides how much parsing one
request can cost. Both matter on the endpoints that read cookies — the OIDC
flow, the ticket and CSRF cookies, and the SSE and long-poll carriers.

## CORS and security headers

```
listeners.public_http.cors.enabled                       = on
listeners.public_http.cors.allowed_origins                = https://app.example.com
listeners.public_http.security_headers.enabled             = on
listeners.public_http.security_headers.hsts                 = max-age=31536000; includeSubDomains
listeners.public_http.security_headers.frame_options         = SAMEORIGIN
```

Both blocks are per-listener and meaningful only for `protocol = http`. A
listener that sets none of `cors.*` does **not** come up closed: the settings
it did not state are taken from Bondy's own defaults — `enabled = on`,
`allowed_origins = *` — and the security headers default the same way, to
`enabled = on` with `SAMEORIGIN` and `nosniff` set. Declaring a listener with
no `cors.*`/`security_headers.*` therefore emits **wildcard CORS** and Bondy's
default security headers, not none. Setting one key does not close the rest
either: the defaults fill in per key, so restricting `allowed_origins` leaves
`allowed_methods` and `allowed_headers` at their defaults unless those are
stated too.

**To drop one security header, give it the value `off`.**

```
listeners.public_http.security_headers.hsts = off
```

That suppresses just that header and leaves the rest, including the default HSTS
a TLS listener would otherwise send. `security_headers.enabled = off` is the
all-or-nothing switch and drops every header. `off` is the only word treated this
way — every other value is the header's content, so `frame_options = office`
sends `office`.

Note there is no "empty value" spelling: `security_headers.hsts =` with nothing
after it is a *syntax error* in `bondy.conf`, not an empty setting.

There is no global block to inherit a deliberate choice from — no
`wamp.cors.*`/`wamp.security_headers.*` — so the only fallback is the module's
own default above. An HTTPS listener whose CORS previously restricted origins to
an allowlist needs that allowlist restated under
`listeners.<name>.cors.allowed_origins`; without it the listener is not "closed
by default", it is open to any origin.

## Carrier settings

`websocket.*`, `sse.*` and `longpoll.*` configure the WebSocket, SSE and
long-poll connections a listener serves. They belong to the listener the
connection arrived on: setting one on `listeners.public_http` says nothing about
`listeners.admin`, and there is **no global block** covering all listeners at
once. The `wamp.websocket.*`, `wamp.sse.*` and `wamp.longpoll.*` keys that used
to serve that purpose are gone; see *Migrating from the pre-1.0 keys*.

```
listeners.public_http.websocket.compression_enabled = on
listeners.public_http.websocket.max_frame_size      = 4MB
```

A key you do not set takes the default below. These defaults are **not** written
into the generated `etc/bondy.conf` the way most settings are — they come from
`bondy_listener_config`, so this table is where they are documented.

### `websocket.*`

| Key | Default |
| --- | --- |
| `ping.enabled` | `on` |
| `ping.idle_timeout` | `20s` |
| `ping.timeout` | `10s` |
| `ping.max_attempts` | `3` |
| `idle_timeout` | `8h` |
| `max_frame_size` | `4MB` |
| `hibernate` | `idle` |
| `compression_enabled` | `off` |
| `deflate.level` | `5` |
| `deflate.mem_level` | `8` |
| `deflate.strategy` | `default` |
| `deflate.server_context_takeover` | `takeover` |
| `deflate.client_context_takeover` | `takeover` |
| `deflate.server_max_window_bits` | `11` |
| `deflate.client_max_window_bits` | `11` |

The `deflate.*` block only takes effect when `compression_enabled` is `on`.

### `sse.*`

| Key | Default |
| --- | --- |
| `ping.enabled` | `on` |
| `ping.interval` | `20s` |
| `idle_timeout` | `10m` |
| `reset_idle_timeout_on_send` | `on` |

### `longpoll.*`

| Key | Default |
| --- | --- |
| `poll_timeout` | `30s` |
| `idle_timeout` | `10m` |
| `reset_idle_timeout_on_send` | `on` |

`poll_timeout` must stay strictly below `idle_timeout`, or the connection can be
torn down for inactivity before the long-poll reply is sent.

A setting stated on the listener wins **key by key**, not block by block: a
listener that sets only `websocket.ping.idle_timeout` keeps the defaults for
`ping.enabled`, `ping.timeout` and `ping.max_attempts`.

### These are not HTTP settings

`websocket.*`, `sse.*` and `longpoll.*` describe one connection style each. The
listener's HTTP itself — keep-alive, header limits, request and idle timeouts —
is configured under `listeners.<name>.http.*` and applies to everything the
listener serves, whichever services are mounted on it. See *Connection and
socket tuning* above.

## TLS material

```
listeners.public_wamp_tls.transport = tls
listeners.public_wamp_tls.protocol  = wamp_rawsocket
listeners.public_wamp_tls.port      = 18085
```

A `tls`-transport listener needs a certificate and key, and is checked for them
at boot. The check applies only to a listener that will start: `enabled = off`
skips it, so you can declare a TLS listener and provision its certificate later.
The check is deferred, not dropped — turning it on runs it, and a listener that
is still missing its certificate is refused then.

That refusal fails the **whole** boot, not just that listener: the inventory is
resolved as a unit, so one unusable entry stops every other listener starting
too.

`listeners.$name.tls.{certfile,keyfile,cacertfile,versions,verify}` is where
a listener declares its own certificate:

```
listeners.public_wamp_tls.tls.certfile = /path/to/keycert.pem
listeners.public_wamp_tls.tls.keyfile  = /path/to/key.pem
```

This block is the only place a certificate is read from — the reserved `admin`
listener can be given one here directly, like any other.

For mTLS, `tls.verify = verify_peer` on its own only *requests* a client
certificate — a client presenting none still connects. Requiring one takes
both keys:

```
listeners.public_wamp_tls.tls.verify               = verify_peer
listeners.public_wamp_tls.tls.cacertfile           = /path/to/cacert.pem
listeners.public_wamp_tls.tls.fail_if_no_peer_cert = on
```

`tls` is one option block among several — `transport_opts`, `protocol_opts`,
`cors`, and the rest below — and each is written key by key, so setting one
leaf never clears its siblings.

## Migrating from the pre-1.0 keys

The per-scheme keys that configured Bondy's fixed listeners —
`admin_api.{http,https}.*`, `api_gateway.{http,https}.*`, `wamp.{tcp,tls}.*`
and `bridge.listener.{tcp,tls}.*` — **have been removed**. Nothing reads them.
A file that still sets them loses every one of those settings silently, because
cuttlefish drops an unknown key rather than refusing the file.

The global carrier keys `wamp.websocket.*`, `wamp.sse.*` and `wamp.longpoll.*`
are removed for the same reason and behave the same way when left in a file.
These need one extra decision the others do not: a single global key covered
every listener at once, so moving it means choosing **which** listeners it
applies to. Restate it under `listeners.<name>.<carrier>.*` for each listener
that serves the carrier, or drop it if it only restated the default in the table
above — the defaults are unchanged, so a line that matched one can go.

Two consequences worth stating separately, because a file can hit the second
while looking like it survived the first:

- A listener you do not declare **does not exist**. A file with no
  `listeners.*` key at all starts the three built-in defaults (`admin`,
  `api_gateway_http`, `wamp_tcp`) and nothing else — every TLS listener and
  every bridge-relay listener is gone.
- Renaming the option keys is not enough. A `listeners.<name>.*` block that
  carries options but no `transport`, `protocol` and bind target is refused at
  boot with `{invalid_listener, <name>, {missing, transport}}`, which aborts the
  whole node rather than skipping that listener.

`scripts/migrate_conf.escript` reports both, per key and per listener, and
rewrites the keys for you — see
[Checking your configuration](checking_your_configuration.md). The names it
renames to are these, and only the first one is forced:

| Removed prefix           | `listeners.*` name |
|--------------------------|--------------------|
| `admin_api.http.*`       | `admin` (reserved) |
| `admin_api.https.*`      | `admin_api_https`  |
| `api_gateway.http.*`     | `api_gateway_http` |
| `api_gateway.https.*`    | `api_gateway_https`|
| `wamp.tcp.*`             | `wamp_tcp`         |
| `wamp.tls.*`             | `wamp_tls`         |
| `bridge.listener.tcp.*`  | `bridge_relay_tcp` |
| `bridge.listener.tls.*`  | `bridge_relay_tls` |

`admin` is forced because it is the reserved name for the administrable
listener: the manager always provides one, so declaring the same listener under
any other name gives you two listeners competing for one port.

The tails move too, and three groups do not keep their spelling:

- TLS material (`certfile`, `keyfile`, `cacertfile`, `versions`, `verify`,
  `fail_if_no_peer_cert`) moves under `listeners.<name>.tls.*`.
- Cowboy protocol options on an HTTP listener (`idle_timeout`, `max_headers`,
  `active_n`, `linger.timeout` and the rest) move under
  `listeners.<name>.http.*`. Note that `idle_timeout` and `linger.timeout`
  exist in both places: on an HTTP listener they are Cowboy's, on a raw-socket
  or bridge-relay listener they are the listener's own and stay at the top
  level.
- `bridge.listener.<t>` alone was that listener's `enabled` flag, and
  `bridge.listener.<t>.ping` alone was `ping.enabled`.

Two keys have no destination: `bridge.listener.{tcp,tls}.max_frame_size` was
never read by anything, and `admin_api.*.dynamic_buffer.*` was the internal name
of `buffer.min`/`buffer.max`.

One capability is narrower than before: the removed `*.ip` keys accepted any
resolvable hostname, while `listeners.$name.ip` takes a literal address. An
inventory supplied through `sys.config` is still resolved by name.
