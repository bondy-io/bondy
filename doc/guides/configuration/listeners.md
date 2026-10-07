# Listener configuration reference

A **listener** is one socket Bondy binds — a TCP port, a TLS port, or a Unix
domain socket — together with the protocol it speaks and, for HTTP, the set
of services it exposes on that socket. Every listener an operator declares
lives under `listeners.$name.*` in `bondy.conf`, where `$name` is a name of
the operator's choosing, e.g. `listeners.public_http.transport = tcp`. A
node with no `listeners.*` key at all starts three listeners, all plaintext
(`bondy_listener_config:default_inventory/0`):

| Name | Transport | Protocol | Port | Services |
|------|-----------|----------|------|----------|
| `admin` | `tcp` | `http` | 18081 | `admin_api, wamp_ws, admin, metrics` (`start_phase = early`) |
| `api_gateway_http` | `tcp` | `http` | 18080 | `api_gateway, wamp_ws, wamp_sse, wamp_longpoll` |
| `wamp_tcp` | `tcp` | `wamp_rawsocket` | 18082 | — |

Declaring even one `listeners.*` key replaces that set: the node then starts
the listeners declared and the reserved `admin` listener, nothing else. A
template being converted needs every listener it wants restated here, not just
the one being changed.

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
  the default `api_gateway_http` listener serves the API Gateway,
  WAMP-over-WebSocket, SSE and long-poll all on port 18080.

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
| `mcp`          | `mcp`      | MCP      | Mounts `/mcp/realm/:realm` and `/.well-known/oauth-protected-resource/realm/:realm`. |

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

## Health probes

`/ping` and `/ready` are served by the `admin` service on every `early`-phase
HTTP listener that declares it. Those listeners bind as soon as configuration is
loaded, before storage opens, with only the two probe routes mounted. Every other
route on them — `/ws`, `/metrics`, the Admin API — answers 404 until the node's
services have started, at which point the full route set is mounted in place.
An `early` listener without the `admin` service answers 404 to every path until
then.

| Path | Answers |
|------|---------|
| `/ping` | `204` whenever the listener is bound, including while storage is opening. |
| `/ready` | `204` when the node is ready (`bondy_router_app:is_ready/0`), `503` otherwise. `GET` only; any other method answers `405`. |

`bondy_boot_probes_SUITE:probes_answer_while_main_opens` holds a boot inside the
storage open and checks `/ping` 204, `/ready` 503, and `/ws` and `/metrics` 404,
then the full route set after the open completes.

Point a liveness probe at `/ping` and a readiness probe at `/ready`. A liveness
probe on `/ready` restarts a node that is still opening its storage.

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

Both procedures take a `dry_run` keyword argument. With `dry_run = true` the
phase is validated and nothing is suspended or resumed; the result carries
`dry_run: true`, the `phase`, the `listeners` it names, and a `would` sentence
describing the effect
(`bondy_dry_run_SUITE:a_dry_run_reports_the_listeners_it_would_touch`). No other
procedure reports listener state, so this is how to see which listeners a phase
covers before acting on it.

```
bondy.listener.suspend("normal", dry_run=true)
```

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
`<platform_runtime_dir>/bondy_admin.sock` — is injected unconditionally and is
not configurable through `bondy.conf` at all. It exists so the node stays
administrable even if every TCP listener fails to bind. Its socket file is the
only access control it has — there is no peer address to filter on — so Bondy
narrows that one file to mode `0600` after binding it, and refuses to serve on
it if that fails. This applies to the internal socket alone: a `uds` listener
an operator declares keeps the mode the process umask gives it, so a sidecar
running under a different uid can reach it.

The socket lives under `platform_runtime_dir`, which is deliberately not
`platform_tmp_dir`: it has to be on a filesystem that supports Unix domain
sockets, and it must not be shared with another node. The defaults satisfy both
and need nothing from you. See
[Platform directories](../deployment/platform_directories.md) for the
requirement, the deployment rules, and what a failed bind reports.

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
it is parsed while the file is read, so a hostname is refused there and then.
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

## Proxy protocol and forwarded headers

```
listeners.public_http.proxy_protocol                 = on
listeners.public_http.proxy_protocol.mode            = strict
listeners.public_http.proxy_protocol.trusted_proxies = 10.0.0.0/8, 192.168.1.10/32
```

These keys decide the source IP Bondy logs, rate-limits by and matches against
`bondy_rbac_source` rules. Off (the default), the source IP is the socket peer.
Unset, `mode` is `relaxed`.

On a `wamp_rawsocket` or `bridge_relay` listener, `proxy_protocol = on` reads a
PROXY protocol header from each connection (`ranch:recv_proxy_header/2`) and
takes the source address from it. `trusted_proxies` is not consulted there.

On an `http` listener, Bondy reads forwarding headers instead, and believes them
only when the socket peer is inside one of the `trusted_proxies` CIDRs.
`trusted_proxies` is empty by default, so with `proxy_protocol = on` and no
`trusted_proxies`, every peer is untrusted and the source IP is the socket peer;
a request from an untrusted peer that carries forwarding headers is logged at
warning level and its headers are ignored
(`bondy_http_proxy_protocol_test:untrusted_by_default_test`). An IPv4 CIDR
never matches an IPv6 peer, and an entry that does not parse is skipped.

From a trusted peer, the headers are tried in this order and the first that
yields an address wins:

1. `Forwarded` — the `for=` values.
2. `X-Forwarded-For`.
3. `X-Real-IP`.

For the first two, the chain is read from the right and the first address
outside `trusted_proxies` is the client, so hops a client prepends to the chain
are never selected (`rightmost_ignores_prepended_spoof_test`). An entry that is
not an IP address is skipped.

`mode` decides what happens when no source address can be established: on an
HTTP listener, a trusted peer whose headers yield none; on a raw socket, a
missing or malformed PROXY header. `relaxed` falls back to the socket peer.
`strict` refuses the connection or request — the API Gateway answers `403` with
`bondy.error.proxy_protocol_error`.

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

Two of those differ from Cowboy's own defaults on every HTTP listener that does
not state them: `http.active_n` is `100` and `http.idle_timeout` is `15s`
(`bondy_listener_config:option_defaults/2`). A listener serving SSE or long-poll
takes a longer idle timeout; see
[Held streams](#held-streams-and-the-connection-idle-timeout).

### Dynamic receive buffer

```
listeners.public_http.http.buffer.min = 4KB
listeners.public_http.http.buffer.max = 64KB
```

Cowboy resizes an HTTP connection's socket receive buffer between these two
bounds. The rules, checked at boot (`bondy_config:normalize_dynamic_buffer/1`):

- set both or neither — one without the other refuses the boot;
- each within 1KB..128KB, with `min` ≤ `max`;
- either set to `0` disables dynamic buffering for the listener, whatever the
  other is.

Unset, Cowboy's own default applies: an adaptive buffer between 512 bytes and
128KB, unless the socket `buffer` size is set explicitly, in which case there is
no dynamic buffering. A WebSocket connection uses the buffer of the listener it
arrived on (`cowboy_websocket` takes it from the listener's protocol options);
there is no WebSocket-specific buffer setting.

### HTTP versions

```
listeners.public_http.http.versions = 2, 1.1
```

A comma separated, priority ordered list of the HTTP protocol versions the
listener offers; the default is `2, 1.1`. On a TLS listener the order is the
server's ALPN preference; HTTP/2 is served only to a client that negotiates
`h2` via ALPN (RFC 7540 requires that), so a client that negotiates `http/1.1`
or sends no ALPN is served HTTP/1.1 whenever `1.1` is listed. On a plaintext
listener, listing `2` enables the HTTP/2 prior-knowledge and Upgrade paths.
Set `1.1` alone to switch HTTP/2 off for a listener.

SSE and long-poll behave identically on both versions: a held stream's
lifetime is governed by the listener's **connection** idle timeout, which a
listener serving `wamp_sse` or `wamp_longpoll` derives from the carriers'
`idle_timeout` (below) rather than the plain 15s HTTP default — see the next
section.

### Held streams and the connection idle timeout

On a listener whose services include `wamp_sse` or `wamp_longpoll`, the
defaults for `http.idle_timeout` and `http.reset_idle_timeout_on_send`
change: the idle timeout is taken from the largest `sse.idle_timeout` /
`longpoll.idle_timeout` in play (10m if unstated) and reset-on-send is
switched on, so a stream that is sending — events, keepalives, poll replies
— keeps its connection alive, and a fully quiet one is closed after the
carrier's idle timeout. This applies to every service sharing that
listener: idle keep-alive API connections on a mixed listener are retained
for the same window. An explicit `http.idle_timeout` or
`http.reset_idle_timeout_on_send` on the listener overrides both.

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
Bondy closes it. Only the peer breaks the silence, and a pong counts, so a peer
that answers probes is never reaped (`bondy_listener_SUITE`:
`rawsocket_silent_peer_is_reaped`, `rawsocket_peer_answering_pings_is_kept`). `ping.idle_timeout` is a different and much shorter thing — how
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
`max_header_value_length` applies to it. Cowboy enforces it on HTTP/1.1 and
answers `431`. The second is a limit on the **number** of cookies parsed out of
that header, and defaults to 100; a request exceeding it is answered with a 400.

They are not interchangeable: a single header of legal length can still hold
thousands of tiny cookies, and it is the count that decides how much parsing one
request can cost. Both matter on the endpoints that read cookies — the OIDC
flow, the ticket and CSRF cookies, and the SSE and long-poll carriers.

One endpoint is an exception to the count limit. An API Gateway `/oidc/verify`
endpoint treats a request over `max_cookies` as carrying no cookies at all,
the same as a malformed `Cookie` header, rather than refusing it
(`bondy_http_utils:safe_parse_cookies/1`). Its credential can then come only
from a bearer token or the `x-bondy-ticket` header, so an over-limit request
without one is unauthenticated, not rejected with `400`.

### HTTP/2 limits

```
listeners.public_http.http.max_concurrent_streams = 100
```

`http.max_concurrent_streams` is how many requests one HTTP/2 connection may
have in flight at once. Bondy sets no default: unset, cowlib advertises `100`
(`cow_http2_machine:settings_init/1`, cowlib 2.19.0).

Cowboy also caps, per connection, the rate of received frames, of stream resets
and of cancelled streams. Bondy neither sets nor exposes these, so Cowboy's
defaults apply (`cowboy_http2:init_rate_limiting/1`, Cowboy 2.18.0):

| Cap | Cowboy default |
|-----|----------------|
| Received frames | 10000 per 10s |
| Stream resets | 10 per 10s |
| Cancelled streams | 500 per 10s |

One HTTP/2 connection carries many requests. Anything that counts connections —
`max_connections`, a connection-count alarm, a load balancer's connection
metric — therefore undercounts the request load an HTTP/2 client puts on the
node by up to a factor of `max_concurrent_streams`. Size against requests, not
connections.

### Request limits

| Key | Unset | Effect |
|-----|-------|--------|
| `http.max_authorization_header_value_length` | `http.max_header_value_length` | Size, in bytes, of the `Authorization` header value. Raise it for large bearer tokens without raising every header's limit. HTTP/1.1; over the limit answers `431`. |
| `http.max_authority_length` | `255` (Cowboy) | Size, in bytes, of the request authority (`Host` or `:authority`). Over the limit, HTTP/1.1 answers `414` and HTTP/2 resets the stream. |
| `http.invalid_response_headers` | `error_terminate` (Cowboy) | `error_terminate` terminates the stream instead of sending a response whose header values contain a CR or LF; `ignore` sends it unchanged. |

A query string or an `application/x-www-form-urlencoded` body may carry at most
100 fields. This is cowlib's `cow_qs` default; Bondy passes no `max_keys` to
`cowboy_req:parse_qs/1` or `cowboy_req:read_urlencoded_body/1`, so it is not
configurable. A request with more is refused.

### Request validation

Bondy inherits these checks from Cowboy 2.18.0. They are not configurable.

- **Fragments.** An HTTP/1.1 request-target containing a fragment (`#…`) is
  rejected with `400` (RFC 9110 §4.1).
- **Authority and `Host` must agree.** An HTTP/1.1 request whose absolute-form
  authority differs from its `Host` header is rejected with `400`; an HTTP/2
  request whose `host` header differs from its `:authority` has its stream
  reset (RFC 9113 §8.3.1).
- **Pipelining.** Pipelined HTTP/1.1 requests are read one at a time: the next
  request on a connection is not parsed until the current one's stream has
  finished.

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
own default above. An HTTPS listener that should restrict CORS origins to an
allowlist needs that allowlist stated under
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

### `longpoll.*`

| Key | Default |
| --- | --- |
| `poll_timeout` | `30s` |
| `idle_timeout` | `10m` |

`poll_timeout` must stay strictly below `idle_timeout`, or the connection can be
torn down for inactivity before the long-poll reply is sent.

The two `idle_timeout` values are how long a fully quiet stream (SSE) or an
idle connection between polls (long-poll) is kept. They take effect as the
listener's **connection** idle timeout default — see "Held streams and the
connection idle timeout" above — identically over HTTP/1.1 and HTTP/2.

A setting stated on the listener wins **key by key**, not block by block: a
listener that sets only `websocket.ping.idle_timeout` keeps the defaults for
`ping.enabled`, `ping.timeout` and `ping.max_attempts`.

### These are not HTTP settings

`websocket.*`, `sse.*` and `longpoll.*` describe one connection style each. The
listener's HTTP itself — keep-alive, header limits, request and idle timeouts —
is configured under `listeners.<name>.http.*` and applies to everything the
listener serves, whichever services are mounted on it. See *Connection and
socket tuning* above.

## Node-wide HTTP transport queue

A WAMP session carried over long-poll or SSE has no process holding a socket for
its lifetime: a long-poll client is not connected at all between polls, and an
SSE stream can drop and reconnect while the session survives. Messages for such
a session wait in a bounded queue per transport. The `wamp.http_transport.*`
keys bound it. They are **node-wide**, not per listener, and apply only to
long-poll and SSE; a WebSocket or raw-socket session never reaches them.

| Key | Default | Meaning |
|-----|---------|---------|
| `wamp.http_transport.idle_timeout` | `1h` | How long a session survives with no HTTP request touching it. While an SSE stream is attached, the session counts as active. On expiry the session closes and its queued messages are discarded. |
| `wamp.http_transport.queue.max_messages` | `1000` | Most messages held per transport. |
| `wamp.http_transport.queue.max_bytes` | `10MB` | Most bytes held per transport. |
| `wamp.http_transport.queue.message_ttl` | `5m` | How long a queued message stays deliverable. An older message is skipped by a poll and removed by the sweep. |
| `wamp.http_transport.queue.eviction_interval` | `5s` | How often the TTL sweep runs. |
| `wamp.http_transport.queue.partitions` | scheduler count | ETS partitions the queue is sharded across; all of one transport's entries share one partition. |

When a new message would exceed `max_messages` or `max_bytes`, the transport's
**oldest** entry is evicted to make room (`bondy_http_transport_queue:enqueue/3`).
There is no other policy.

The router's messages and the protocol's synchronous replies to the client's own
messages (an inline `ERROR`, a throttle rejection) share one queue, in the order
they were produced, under the same limits and the same `message_ttl`.

When the router ends a session — an `ABORT` or `GOODBYE` — the terminal message
is queued and handed to a long-poll request that is waiting at that moment, and
the session then closes. A long-poll client that is between polls when that
happens does not receive it: its next poll answers `404` with
`transport_not_found`, as does a poll that is waiting when the session dies.

Long-poll error replies — `transport_not_found` (404), `unauthorized` (401),
`csrf_validation_failed` (403), `payload_too_large` (413), `method_not_allowed`
and `message_error` (400) — carry the standard error payload (see
[Error Catalogue](../reference/error_catalogue.md)) plus an `error` key holding
the short name, kept for existing clients. `transport_not_found` is not a
catalogue entry, so its payload carries the `unknown_error` handle and message;
branch on the status or the `error` key. The two refusals of `/open` —
`no_supported_protocol` and `invalid_json` (400) — carry only the `error` key.

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

Bondy sets neither `supported_groups` nor `signature_algs` on a listener, so the
key-exchange groups and signature algorithms offered are OTP's `ssl` defaults
for the negotiated TLS version.

`tls` is one option block among several — `transport_opts`, `protocol_opts`,
`cors`, and the rest below — and each is written key by key, so setting one
leaf never clears its siblings.

## Boot-time validation

The listener inventory is resolved as a unit at boot. The first invalid entry
is logged as `Invalid listener configuration` with reason
`{invalid_listener, Name, Reason}`, and the node does not start: one bad
listener refuses the whole node, not just itself
(`bondy_listener_manager:init/0`). `Reason` is one of:

| Reason | Cause |
|--------|-------|
| `{missing, transport}`, `{missing, protocol}` | The key is absent. |
| `{unknown_transport, T}` | `transport` is not `tcp`, `tls` or `uds`. |
| `{unknown_protocol, P}` | `protocol` is not `http`, `wamp_rawsocket` or `bridge_relay`. |
| `{unsupported_combination, uds, bridge_relay}` | A bridge relay over a Unix domain socket. |
| `{missing, port}`, `{missing, path}` | No bind target: `path` for `uds`, `port` otherwise. |
| `duplicate_name` | Two listeners share a name. |
| `{port_in_use_by, Other}`, `{path_in_use_by, Other}` | The bind target overlaps listener `Other`'s. See [Bind address and IP version](#bind-address-and-ip-version). |
| `{invalid_ip, Ip}`, `{unresolvable_ip, Ip, Reason}` | `ip` is not a valid address. The second is reachable only from an inventory in `sys.config`, which may name a host. |
| `{missing, services}` | An `http` listener with no `services`, or an empty list. |
| `{services_not_supported, P}` | `services` on a `wamp_rawsocket` or `bridge_relay` listener. |
| `{unknown_service, S}` | `S` is not a service this node knows. |
| `{unknown_carrier, Carrier, Service}` | `Service` was registered by an extension whose carrier no module serves. |
| `{incompatible_services, mcp, admin_api}` | One listener declares both. |
| `{missing, [tls, certfile]}`, `{missing, [tls, keyfile]}` | A `tls` listener without its certificate or key. |
| `{tls_not_supported, T}` | Any `tls.*` key on a `tcp` or `uds` listener. |
| `reserved_name` | The name is `admin_local`, which the node injects itself. |
| `reserved_cannot_be_disabled` | `listeners.admin.enabled = off`. |
| `{invalid_ping_enabled, Label, V}`, `{incomplete_ping, listener, Keys}` | A malformed `ping` block. Reachable only from `sys.config`; `bondy.conf` cannot express one. |

A listener with `enabled = off` skips the TLS checks — a `tls` listener may be
declared before its certificate exists — and is checked again at the boot that
enables it (`bondy_listener_config_test:disabling_a_listener_defers_the_tls_check_it_does_not_lose_it_test`).
Every other check applies to a disabled listener too.

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

Some of these keys change name as they move, and some have no destination
(`scripts/migrate_conf.escript` applies the same table):

| Key | Destination |
|-----|-------------|
| `wamp.websocket.ping.interval` | `listeners.<name>.websocket.ping.idle_timeout` |
| `wamp.websocket.ping.max_retries` | `listeners.<name>.websocket.ping.max_attempts` |
| `wamp.websocket.buffer.min`, `.max` | None. A WebSocket connection uses its listener's buffer; set `listeners.<name>.http.buffer.min`/`.max`. |
| `wamp.sse.reset_idle_timeout_on_send`, `wamp.longpoll.reset_idle_timeout_on_send` | None. The working control is `listeners.<name>.http.reset_idle_timeout_on_send`, which covers every service on the listener. |
| `wamp.transport_queue.transport_ttl` | `wamp.http_transport.idle_timeout` |
| `wamp.transport_queue.overflow_strategy` | None. Eviction of the oldest entry is the only policy. |
| `wamp.transport_queue.*` (the rest) | `wamp.http_transport.queue.*` |

On a listener's own keys, `ping.interval` becomes `ping.idle_timeout` and
`ping.max_retries` becomes `ping.max_attempts`.

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
