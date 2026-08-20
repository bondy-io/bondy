# Dynamic listeners

Replace Bondy's fixed set of hardcoded listeners with listeners the operator
defines by name in `bondy.conf`, each carrying its own transport, protocol and
service set.

Status: design agreed, nothing built.

## 1. Problem

Bondy ships nine hardcoded listeners: four HTTP ones defined as macros in
`bondy_http_gateway` (`api_gateway_http`, `api_gateway_https`, `admin_api_http`,
`admin_api_https`, `bondy_http_gateway.erl:102-105`), two raw-socket ones in
`bondy_wamp_tcp` (`wamp_tcp`, `wamp_tls`, `bondy_wamp_tcp.erl:13-14`), a
Unix-domain one in `bondy_wamp_uds`, and two bridge-relay ones in
`bondy_bridge_relay_manager` (`bridge_relay_tcp`, `bridge_relay_tls`, `:24-25`).
Three consequences:

- **The set is not extensible by configuration.** An operator cannot add a
  second WebSocket port with different framing limits, put MCP on its own port,
  or run two TLS contexts for different tenants.
- **The route set per listener is fixed in code.** `base_routes/0`
  (`bondy_http_gateway.erl:995`) mounts `/ws`, `/wamp/sse/*` and
  `/wamp/longpoll/*` on every public listener; `admin_base_routes/0` (`:1023`)
  mounts the admin endpoints on every admin listener. Neither is selectable.
- **The schema pays for a cross product.** `api_gateway.{http,https}` and
  `admin_api.{http,https}` are 220 near-identical mappings; `wamp.{tcp,tls}`
  another 49. They differ almost entirely in whether the transport is TLS.

The third point is the tell: the six TCP/HTTP listeners are really *three
protocols × two transports*, and the schema enumerates the product.

## 2. Verified constraints

Everything in this section was established by reading the implementation or its
tests, not documentation. Each item names what was checked and what was not.

### 2.1 `$name` mappings do get per-listener defaults — which is why we forgo them

`cuttlefish_generator:add_fuzzy_default/4` fills a `$name` mapping's default for
**every name mentioned anywhere under the prefix preceding the `$` segment**.
The prefix comes from `cuttlefish_variable:split_on_match/1`; the name set is
the union across all sibling mappings sharing that prefix.

Evidence: cuttlefish's own `add_defaults_test`
(`cuttlefish_generator.erl:700`). Conf sets `n.ak.x`, `n.bk.x`, `n.ck.y`;
mappings exist for `n.$name.x` and `n.$name.y` with defaults. The test asserts
defaults appear at `n.ck.x`, `n.ak.y` and `n.bk.y` — the full cross product.

This cuts against us twice, so **no `listeners.$name.*` mapping carries a
`{default, ...}`; per-driver defaults live in `bondy_listener_config`**:

- A default on `listeners.$name.websocket.idle_timeout` would materialise for
  every listener, so the key would always be present and the global
  `wamp.websocket.idle_timeout` fallback could never apply — a silently dead
  key.
- A default on `listeners.$name.backlog` would materialise on a `quic`
  listener, so "reject keys the driver cannot use" would fire on values the
  operator never wrote.

With no defaults, *present* means exactly *the operator set it*, which is the
precondition both the fallback rule and the rejection rule need.

Not checked: whether any cuttlefish version in the dependency range behaves
differently. The lockfile pins one version and the test above is from that
tree.

### 2.2 Config validation cannot run in the schema

`cuttlefish` runs as a standalone escript from `bin/hooks/pre_start_cuttlefish`
(declared at `rebar.config:248-252`), **before the VM boots the release**. A
translation function therefore cannot call Bondy code. Consequence: the schema
does syntax only; service-name resolution, driver applicability and route
collisions are checked at application start.

That hook also passes `--allow_extra --silent`, so an unrecognised key is
dropped with neither error nor warning.

A second, sharper reason applies to this design specifically: **a `{validators,
…}` clause on a fuzzy mapping never runs.** `cuttlefish_generator:run_validations/2`
takes `Value = proplists:get_value(cuttlefish_mapping:variable(M), Conf)`, and for
a fuzzy mapping that variable is the literal `["listeners","$name","port"]`, which
is never a key in `Conf` — `Conf` holds only concrete variables, whether written
by the operator or materialised by `add_fuzzy_default/4`. So `Value` is
`undefined` and the first clause, `{undefined, _} -> true`, passes the validation
unconditionally. Probed: `listeners.pub.port = 7` is *accepted* with a
`port_number` validator attached, while the same validator on a non-fuzzy key
rejects it.

This is not a consequence of the default-free rule (§2.1) — it holds with or
without a default, because neither puts the `$name` variable into `Conf`.

Consequence: no `listeners.$name.*` mapping declares validators. Declaring them
would imply a protection that does not exist, which is worse than declaring none.
Every value check lives in the translation or in `bondy_listener_config`.

### 2.3 HTTPS and WAMP-TLS are transports, not protocols

`start_http/2` (`bondy_http_gateway.erl:780`) and `start_https/2` (`:857`) build
identical protocol options from the same `listener_protocol_opts/2` and differ
only in `cowboy:start_clear/3` vs `cowboy:start_tls/3` — that is, only in the
ranch transport module. Likewise `bondy_ranch_listener:ref_to_transport/1`
(`:113-116`) maps `wamp_tcp`/`wamp_tls` to `ranch_tcp`/`ranch_ssl` and both hand
the socket to the same `bondy_wamp_tcp_connection_handler`
(`bondy_wamp_tcp.erl:34-36`).

### 2.4 Only HTTP has an extensible demultiplexing surface

A *list* of services on one socket is possible only where the protocol can
address several endpoints:

- **HTTP** multiplexes on path.
- **WebSocket** multiplexes on the `sec-websocket-protocol` id
  (`bondy_wamp_ws_connection_handler.erl:39`, `select_subprotocol/1` at `:501`),
  which lives inside a path.
- **RawSocket** has a fixed 4-octet header,
  `<<?RAW_MAGIC:8, MaxLen:4, Encoding:4, _:16>>`
  (`bondy_wamp_tcp_connection_handler.erl:165`): one magic byte and one
  serializer nibble, ids 4–15 reserved (`:658`). Nothing addressable.

So `services` is meaningful iff `protocol = http`. A raw-socket listener carries
its protocol in the `protocol` key instead, and no key says the same thing
twice.

### 2.5 Cowboy 2.17 supports HTTP/3, WebTransport and WebSocket-over-QUIC

The locked Cowboy (`rebar.lock:23`, 2.17.0) ships `cowboy_http3.erl`,
`cowboy_quicer.erl`, `cowboy_webtransport.erl` and `cowboy:start_quic/3`.

- WebTransport: `cowboy_http3.erl:783` switches the stream to
  `cowboy_webtransport` on CONNECT `:protocol`.
- WebSocket over HTTP/3: `cowboy_websocket:is_upgrade_request/1` matches
  `Version =:= 'HTTP/3'` with `CONNECT` and `:protocol = websocket`
  (`cowboy_websocket.erl:127-129`); the failure path replies 501 citing
  RFC 9220 §3 (`:172-175`). `cowboy_http3` also has a generic `switch_protocol`
  clause accepting any module (`:810`).

Verified by reading those modules only. **No probe has been run against a live
HTTP/3 or WebTransport client**, and `quicer` is absent from `rebar.lock` and
from `cowboy.app`'s `applications` and `optional_applications`, while
`start_quic/3` opens with `application:ensure_all_started(quicer)`. HTTP/3 is
therefore unusable until that dependency is added.

### 2.6 QUIC bypasses ranch entirely

`cowboy:start_quic/3` (`cowboy.erl:91-140`) spawns its own listener process
calling `quicer:listen/2` with 20 hardcoded acceptor processes, and accepts
`TransOpts` as only `#{socket_opts => [...]}`. The `ranch:ref()` argument is a
name; no ranch listener is created. Therefore on a QUIC listener:

- `acceptors_pool_size`, `max_connections`, `backlog`, `keepalive`, `nodelay`,
  `sndbuf`, `recbuf`, `buffer`, `reuseport`, `linger` do not apply.
- `ranch:suspend_listener/1`, `resume_listener/1`, `procs/2` and
  `set_max_connections/2` do not work, so `bondy_ranch_listener:suspend/1`,
  `resume/1`, `connections/1` (`:66-79`) and
  `bondy_http_gateway:do_suspend_listeners/1` (`:568`) have no QUIC path.
- The 75%/90% connection alarms are ranch `alarms`
  (`bondy_http_gateway.erl:1113-1142`) and do not exist for QUIC.
- Certificates go through quicer socket options, so the **ssl** `sni_fun`
  injected by `bondy_cert_manager:maybe_inject_sni_fun/2` (called at
  `bondy_config.erl:340`) does not apply. QUIC certificate rotation is a
  separate mechanism, out of scope here.
- PROXY protocol (`bondy_http_proxy_protocol`) is TCP-only.

This is why `transport` selects a **driver**, not merely a ranch transport
module, and why key sets are driver-scoped.

### 2.7 The app-env layer can stay unchanged

Every listener mapping already lands at
`bondy_router.<listener_name>.{enabled, transport_opts.*, protocol_opts.*, cors,
security_headers, proxy_protocol.*}` (e.g. `schema/bondy.schema:2131`), and the
consumers are already parameterised by name: `bondy_config:listener_transport_opts/1`
(`bondy_config.erl:335`), `bondy_http_cors:config/1` (`:48`),
`bondy_http_security_headers:init/1`, `bondy_http_proxy_protocol` (`:50`).

`bondy_ct` sets the same shape directly as app env, keyed by listener name
(`bondy_ct.erl:284,313,372,426,477,528`), because test boots never render
cuttlefish. Keeping the shape therefore leaves both production consumers and the
test harness untouched.

**Corrected in part — one consumer changed arity.**
`listener_transport_opts/1` became `/2`. The *shape* claim held:
`bondy_http_cors`, `bondy_http_security_headers`, `bondy_http_proxy_protocol` and
`bondy_ct` were untouched, and nothing about the app-env layout moved. But the
transport-options consumer changed for a reason outside the shape argument.

A listener's `ip` is an **inventory** value, not an app-env socket option
(§4.1). It has to reach `socket_opts` *before* `normalise_socket_opts/1`
reconciles an address with `ip_version`, because that function prepends the
family atom — and anything writing `ip` afterwards can contradict it.
`gen_tcp:listen(0, [inet6, {ip, {0,0,0,0}}])` raises `badarg`, verified
directly. Merging the address over the returned map would have done exactly
that, so it is passed as a second argument and folded in at the single place the
two are reconciled. `ipv6_listener_binds_without_an_explicit_ip` and
`explicit_ipv6_binds_without_an_ip_version` in `bondy_listener_SUITE` bind real
sockets over it.

The general lesson is that "the app-env shape is unchanged" bounds what the
*consumers of app env* must do; it says nothing about a value that reaches the
socket from the inventory instead.

### 2.8 Dispatch tables are keyed by scheme, from the spec

`bondy_http_gateway_api_spec_parser:dispatch_table/2` returns
`[{Scheme, Routes}]` where the scheme comes from the API specification, not the
listener (`:1161`). A listener selects the table matching its own scheme:
`http` for `tcp`/`uds`, `https` for `tls`/`quic`.

The same function is deliberately lenient about routes whose realm is absent
(`skip`, `:1180-1190`), because a spec can arrive by anti-entropy before its
realm. That leniency constrains collision checking (§6).

### 2.9 Nothing branches on a listener being "admin"

Every reference to `admin_api*` outside `bondy_http_gateway` is naming,
lifecycle or a config path: `bondy_app.erl:111,333`, `bondy_cert_manager.erl:49`,
`bondy_config.erl:454`. No authentication, authorisation or rate-limiting
decision keys off admin-ness. "Admin" is therefore fully expressed by
`services = admin, metrics` plus `ip = 127.0.0.1`; a `role` key would only
re-encode a preset and is not part of this design.

**Superseded in part — see §3.1.** The claim above is still true of *runtime*
behaviour: no auth, authz or rate-limit decision reads admin-ness, and this
design adds none. But it drew the wrong conclusion. Because the inventory is
operator-defined, "fully expressed by `services`" also means an operator can
express *no* administrable endpoint at all and lock themselves out of the node
— a failure mode the hardcoded listeners made impossible. §3.1 therefore
reserves one listener name and adds one un-removable internal listener. Both
are *lifecycle* guarantees; neither introduces an admin-ness branch in a
request path.

Two facts found while implementing, which §3.1 relies on:

- The built-in HTTP Admin API is an **API Gateway specification**, not a set of
  hardcoded routes. `do_start_listeners(admin)` parsed
  `priv/specs/bondy_admin_api.json` inline via
  `parse_specs([admin_spec()], admin_base_routes())` and mounted the result on
  the admin listeners only. `admin_spec/0` called `exit(enoent)` if the file was
  absent, so it was mandatory, not best-effort.
- The two listener families served **disjoint** route sets. Public listeners got
  stored specs plus `base_routes/0`; admin listeners got the built-in spec plus
  `admin_base_routes/0`. No stored specification was ever reachable on an admin
  port. Preserving that is what keeps realm, user, grant and backup
  administration off a public listener.

### 2.10 The WebSocket handler does not know its listener

`bondy_wamp_ws_connection_handler` reads configuration globally:
`bondy_config:get([wamp_websocket, idle_timeout])` (`:344`) and
`bondy_config:get(wamp_websocket)` (`:463`). Restricting which protocols a given
listener offers over WebSocket therefore requires a new mechanism regardless of
the config surface: the listener identity and its allowed-protocol set must be
threaded through the route's initial state — the `#{}` at
`bondy_http_gateway.erl:1000` — and merged over the globals in `init/2`.

## 3. Config model

Four required axes, plus three key groups. No mapping carries a default (§2.1).

```
listeners.$name.transport  = tcp | tls | uds | quic
listeners.$name.protocol   = http | wamp_rawsocket | bamp_rawsocket
                           | bridge_relay
listeners.$name.port       = <integer>         # tcp | tls | quic
listeners.$name.path       = <file>            # uds, instead of port
listeners.$name.services   = <list>            # iff protocol = http
```

Three further keys apply to every driver and are optional:
`listeners.$name.ip` and `listeners.$name.ip_version` (bind address; today's
admin listeners default to loopback, and that default moves into
`bondy_listener_config`), `listeners.$name.enabled`, and
`listeners.$name.start_phase = early | normal`.

`start_phase` preserves an ordering that exists today: `bondy_app` starts the
admin listeners at `:111` — before the public ones at `:113` — so that `/ping`,
`/ready` and `/metrics` answer while the node is still `initialising`. Public
listeners must not accept clients until the registry is up. Rather than infer
this from `services` (the kind of invisible inference this design rejects
elsewhere), it is an explicit key; the manager defaults it to `normal`.

`enabled` absent means enabled — matching the five call sites that read
`bondy_config:get([Ref, enabled], true)` today (`bondy_ranch_listener.erl:35`,
`bondy_http_gateway.erl:771,810,964,971`). It is a manager default, not a
cuttlefish one, so §2.1 is not violated. It exists so an operator can park a
listener without deleting its block.

`transport` selects the driver (§2.6). `protocol` selects what frames the wire.
`services` selects what is reachable over an HTTP listener; each entry names a
**protocol over a carrier**, so an operator can offer BAMP over WebSocket
without also offering WAMP:

| Service | Carrier | Mounts |
|---|---|---|
| `api_gateway` | HTTP | routes compiled from API specs |
| `wamp_ws`, `bamp_ws` | WebSocket | `/ws` |
| `wamp_wt`, `bamp_wt` | WebTransport | path not yet chosen |
| `wamp_sse` | SSE | `/wamp/sse/*` |
| `wamp_longpoll` | long poll | `/wamp/longpoll/*` |
| `mcp` | streamable HTTP | MCP endpoints |
| `admin` | HTTP | `/ping`, `/ready`, `/cluster/topology` |
| `admin_api` | HTTP | routes compiled from the built-in Admin API spec |
| `metrics` | HTTP | `/metrics/[:registry]` |

Services sharing a carrier **union** their protocol sets into one route;
different carriers claiming one path is an error (§6).

`admin_api` and `api_gateway` share the HTTP carrier but are deliberately
separate services, because they differ in *which* specifications they mount:
`api_gateway` mounts every specification stored in `bondy_db`, `admin_api`
mounts exactly one specification that ships in `priv/`. Keeping them apart is
what reproduces the disjoint split described in §2.9 — a public listener
declares `api_gateway` and never gains the admin paths; the reserved admin
listener declares `admin_api` and never gains a customer's stored spec. The
alternative, storing the built-in spec in `bondy_db` like any other, cannot
express this: `bondy_http_gateway:routes/1` selects by scheme alone, so every
listener declaring `api_gateway` would serve it.

An operator who *wants* stored specifications on the admin port adds
`api_gateway` to that listener's `services`. The default does not.

### 3.1 The reserved admin listener, and the local safety net

An operator-defined inventory can omit every administrable endpoint, so two
guarantees sit outside operator control.

**`admin` is a reserved listener name.** It is an ordinary `listeners.$name`
entry in every other respect — so it inherits the whole transport matrix, and
gains QUIC and WebTransport for free when those drivers land (§2.5, §2.6),
which is the reason for expressing it this way rather than as a separate
`admin_api.*` config section. It differs from an operator-defined listener in
three ways:

- The manager injects it if `bondy.conf` mentions no `listeners.admin.*` key,
  with defaults `transport = tcp`, `port = 18081`, `ip = 127.0.0.1`.
- Any `listeners.admin.*` key the operator does set overrides the corresponding
  default in place. Deleting every such key reverts it to the defaults rather
  than removing the listener.
- `listeners.admin.enabled = off` is a configuration error, not a way to remove
  it.

**`admin_local` is an internal listener, not configurable at all.** It does not
appear in `bondy.conf` and has no `listeners.$name` mappings:

```
admin_local: transport = uds
             path      = <platform_tmp_dir>/bondy_admin.sock
             services  = admin_api, admin, wamp_ws, metrics
```

A reserved *name* alone does not deliver the guarantee. An operator who sets
`listeners.admin.transport = tls` with an unresolvable `certfile` gets a
listener that fails to bind, and is locked out by a different route. The safety
net closes that: a Unix domain socket needs no certificate, no DNS and no port,
so no `bondy.conf` value can prevent it from binding. It is also unreachable
off-host by construction and governed by filesystem permissions rather than by
Bondy's own authorisation of a network peer.

Both carry `admin_api`, `admin`, `wamp_ws` and `metrics` — the HTTP Admin API
and the WAMP admin procedures — so either endpoint alone is sufficient to
administer the node.

Neither is exempt from validation: both are resolved by
`bondy_listener_config:resolve/2` like any other listener, so a port clash
against `admin` is reported the same way (§6).

Three further key groups, each scoped to where it applies:

- **Stream-socket tuning** — today's ~40 keys (`backlog`, `keepalive`,
  `nodelay`, `sndbuf`, `recbuf`, `buffer`, `reuseport`, `linger`,
  `max_connections`, `acceptors_pool_size`, the `protocol_opts` timeouts and
  limits, `cors.*`, `security_headers.*`, `proxy_protocol.*`). Ranch drivers
  only.
- **`listeners.$name.tls.*`** — `certfile`, `keyfile`, `cacertfile`, `versions`,
  `verify`. Valid iff `transport = tls | quic`.
- **`listeners.$name.{websocket,sse,longpoll}.*`** — the 24 keys currently
  global under `wamp.websocket.*` (17), `wamp.sse.*` (4) and `wamp.longpoll.*`
  (3). A listener that is silent on one of these inherits the global value.

### Examples

```
# public HTTP: REST plus all three WAMP HTTP carriers
listeners.pub.transport = tcp
listeners.pub.protocol  = http
listeners.pub.port      = 18080
listeners.pub.services  = api_gateway, wamp_ws, wamp_sse, wamp_longpoll

# admin, loopback only
listeners.admin.transport = tcp
listeners.admin.protocol  = http
listeners.admin.ip        = 127.0.0.1
listeners.admin.port      = 18081
listeners.admin.services  = admin, metrics

# BAMP over WebSocket only — WAMP is not offered on this port
listeners.bamp.transport    = tls
listeners.bamp.protocol     = http
listeners.bamp.port         = 18443
listeners.bamp.services     = bamp_ws
listeners.bamp.tls.certfile = ./etc/ssl/server/keycert.pem
listeners.bamp.tls.keyfile  = ./etc/ssl/server/key.pem
listeners.bamp.tls.versions = 1.2,1.3

# an IoT port with its own framing limits
listeners.iot.transport                  = tcp
listeners.iot.protocol                   = http
listeners.iot.port                       = 18086
listeners.iot.services                   = wamp_ws
listeners.iot.websocket.idle_timeout      = 10m
listeners.iot.websocket.max_frame_size    = 64KB
listeners.iot.websocket.compression_enabled = off

# WAMP raw socket
listeners.raw.transport = tcp
listeners.raw.protocol  = wamp_rawsocket
listeners.raw.port      = 18082
```

## 4. App-env contract

The shape stays exactly as it is today (§2.7). The one new key is an inventory:

```erlang
{bondy_router, [
    {listeners, [
        {pub, #{
            transport => tcp,
            protocol  => http,
            services  => [api_gateway, wamp_ws, wamp_sse, wamp_longpoll]
        }},
        {raw, #{transport => tcp, protocol => wamp_rawsocket}}
    ]},
    %% unchanged, per listener name
    {pub, [{transport_opts, [...]}, {protocol_opts, [...]}, {cors, ...}]}
]}
```

Because the shape is unchanged, `listener_transport_opts/1`, `bondy_http_cors`,
`bondy_http_security_headers`, `bondy_http_proxy_protocol` and `bondy_ct` need no
change, and the change at the app-env boundary is purely additive.

**Corrected — `listener_transport_opts/1` became `/2`; see the retraction at the
end of §2.7.** The rest of the sentence holds.

### 4.1 How the per-listener block is rendered

**Cuttlefish cannot write to `bondy_router.<name>.*` directly.** It substitutes a
fuzzy match into the conf-file *variable* only, never into the mapping *target*:
`cuttlefish_generator.erl:153` tokenises the target string as written, and
`set_value/3` (`:257-267`) calls `list_to_atom/1` on each token. A target
containing `$name` therefore produces the literal atom `'$name'`. Probed
end-to-end through `cuttlefish_schema:files/1` → `cuttlefish_generator:map/2`
with two listeners and two such mappings:

```erlang
{'$name',[{websocket,[{idle_timeout,undefined}]},
          {transport_opts,[{socket_opts,[{backlog,undefined}]}]}]}
```

One literal `'$name'` key, every value `undefined`, every operator-set
per-listener option silently discarded — no error and no log, because
`--allow_extra --silent` (§2.2) is not what governs this. Stock cuttlefish 3.0.1,
not a fork.

Every existing fuzzy block in this repository already works around it the same
way: `bridge.$name.endpoint`, `bridge.$name.tls.certfile` and
`broker_bridge.kafka.clients.$name.*` all name **one fixed target** and let a
translation do the shaping.

So the mechanism is:

1. Every `listeners.$name.*` mapping targets the single fixed key
   `bondy_router.listeners`.
2. One translation walks the `listeners.*` conf variables and builds
   `[{Name, Spec}]`, where each `Spec` carries both the inventory keys
   (`transport`, `protocol`, `port`/`path`, `services`, `ip`, `enabled`,
   `start_phase`) and that listener's option block (`transport_opts`,
   `protocol_opts`, `tls`, `proxy_protocol`, `cors`, `security_headers`,
   `websocket`/`sse`/`longpoll`).
3. `bondy_config:init/1` splats each entry's option block to
   `bondy_router.<name>.*` before `bondy_listener_manager:init/0` and
   `bondy_cert_manager:init/0` run.

The app-env *shape* is still what §2.7 describes and consumers still need no
change; only the renderer moves from cuttlefish-direct to a boot-time splat.
`bondy_ct` already installs listener blocks exactly this way, with
`bondy_config:set/2`.

Two consequences for the translation, both verified:

- `cors` and `security_headers` are **not** leaf keys. Each is consumed as a
  single map — `bondy_http_cors:config_from_req/1` reads
  `bondy_config:get([Ref, cors], …)` and `bondy_http_security_headers:init/1`
  reads `[ListenerName, security_headers]` — and today each is assembled by its
  own per-listener aggregating translation (`schema/bondy.schema:2485`, `:2560`).
  The `listeners` translation must build those maps, not emit their leaves.
- `ip` is an **inventory** key, not an app-env socket option:
  `bondy_listener_config:resolve_ip/3` reads it from the spec and the resolved
  type wants an `inet:ip_address()` tuple, so the translation parses the string.

### Legacy configuration — REMOVED 2026-08-18

`api_gateway.*`, `admin_api.*`, `wamp.{tcp,tls}.*` and `bridge.listener.*` were
retained for one release behind a deprecation notice. That retention is over:
all 331 mappings and translations are deleted, `bondy_listener_manager:init/0`
has one path, and `bondy_listener_config:default_inventory/0` (three plaintext
listeners) is what a node with no `listeners.*` key gets.

Three claims made in this section turned out to be wrong and are corrected here:

- "There is no capability loss." There is one. The legacy `*.ip` keys carried the
  `ip_address` validator (`inet:getaddr/2`) and accepted any resolvable
  hostname; `listeners.$name.ip` is parsed by `inet:parse_address/1` at render
  time and takes a literal. `to_address/2` still resolves a name, so an inventory
  from `sys.config` is unaffected — the loss is on the conf path only.
- The retention was described as costless. It was not: because a listener's
  options are read under its *current* name, renaming the admin listener to the
  reserved `admin` left 26 `admin_api.http.*` options unread in six shipped
  templates while the legacy mappings still existed to make them look live.
- Deleting the mappings deleted the **defaults** they carried, and eleven of
  those were load-bearing. See the audit below.

All three are the same mistake: reasoning about the *keys* being replaced and not
about everything else the old mapping was carrying — a validator, a name binding,
a default. A mapping is not only a path.

#### Audit: the defaults that went with the mappings

318 legacy mappings were removed, **169 of which carried a `{default, …}`**. Each
was traced to whatever supplies that value today — a shipped template, a code
default, a consumer's own fallback, or nothing. Full working in
`_plans/2026-08-19-lost-defaults-audit.md`.

The scope rule that decides whether a default was really lost: `rebar3_scuttler`
generates `etc/bondy.conf` from the schemas for **every** release, writing each
non-fuzzy default as an active line, so a *schema* default was in force
everywhere. A *template* value reaches only the seven releases that overlay a
template; `prod`, `prod_named` and `docker` overlay none, so for those only a code
default counts. And a `listeners.$name.*` mapping can never appear in a generated
conf — a fuzzy mapping has no concrete name to enumerate — which is why §2.1's
"no defaults on fuzzy mappings" also means these could not simply be re-declared
in the schema. They live in `bondy_listener_config:option_defaults/2` instead,
keyed on transport × protocol.

**Restored.** Keepalive was off on every raw-socket and bridge-relay listener
(`ping.enabled` `on`, `ping.timeout` `10s`, `ping.max_attempts` `2`,
`ping.idle_timeout` `20s`); an idle raw-socket or bridge-relay connection was
never reaped (`idle_timeout` `8h`, fallen back to `infinity`); and every HTTP
listener but `admin` lost `active_n` `100` to Cowboy's `1` and `idle_timeout`
`15s` to Cowboy's `60s`. `wamp.tls.ping.max_attempts` defaulted to `3` where
`wamp.tcp` defaulted to `2`; both are now `2`, since the transport does not
change how many unanswered probes mean a dead peer.

**A coupling the individual defaults hid.** The raw-socket keepalive took its
probe interval from the *listener's* `idle_timeout` rather than from the ping
block, so probe and reap came due at the same instant and the connection was
closed instead of probed — and at `idle_timeout = infinity`,
`erlang:start_timer(infinity, …)` raises `badarg`, killing every connection on
the listener. Pre-branch this was unreachable only because both defaults happened
to be in force. Restoring them was therefore not sufficient: the interval now
comes from `ping.idle_timeout`, independent of the reap deadline.

**Decided rather than restored.** `admin_api.https.security_headers.hsts` was
carried by one listener that defaulted to `enabled = off`. Reinstating it as a
code default applies HSTS to *every* TLS HTTP listener — a change in the other
direction, and the one taken.

**Deliberately not restored.** `wamp.{tcp,tls}.linger.timeout`'s `1s`. Its
datatype rendered `1000`, and `inet` documents the second component of `{linger,
{true, N}}` as **seconds** (`kernel/src/inet.erl:1124`, OTP 28.5), so what
shipped was a 1000-*second* linger on close. The unit mismatch belongs to the key
and not to the default — an operator writing `1s` today gets the same
1000-second linger — so the key is fixed first and the default goes back on top.

**Not a loss.** `wamp.tcp.ping.idle_timeout` and `wamp.tls.ping.interval` were
never read by anything, and `bridge.listener.*.max_frame_size` targeted a path
nothing reads. All three were dead before the removal; restoring them would
revive knobs that do nothing.

**The conversion is Erlang, not a schema translation** — corrected here after
the original design assumed otherwise. A translation cannot do it: cuttlefish
discards a translation unless some mapping targeting the same app-env key has a
`{default, ...}` or appears in the conf file
(`cuttlefish_generator.erl:139-168`), and every `listeners.$name.*` mapping is
default-free by §2.1. So a legacy-only `bondy.conf` leaves
`bondy_router.listeners` unclaimed and the translation never runs — which is
also, conveniently, the provenance signal the gate needs: an absent key means
the operator has not adopted the new block.
`bondy_listener_manager:legacy_inventory/0` synthesised the nine historical
entries in that case.

**Both of the following two paragraphs describe the retention period and are
dead as of the removal above.** `legacy_inventory/0` no longer exists; an absent
`bondy_router.listeners` now selects `bondy_listener_config:default_inventory/0`,
three plaintext listeners named `admin`, `api_gateway_http` and `wamp_tcp`. The
provenance signal itself survives and is still read exactly as described — it is
what `init/0` logs the inventory's origin from — so the reasoning is kept rather
than deleted.

Two related constraints, both verified at source. Only one translation may
target a key — `cuttlefish_translation:parse_and_merge/2` does
`lists:keyreplace/4` on the mapping name, and all schema files fold into one
translation list, so a second `{translation, "bondy_router.listeners", ...}`
anywhere silently replaces the first. And a translation suppresses the direct
write of every mapping sharing its target, so retargeting the legacy mappings to
keep a translation alive would move every existing deployment's option blocks
onto the boot-time splat during an upgrade.

The legacy entries keep their historical names (`api_gateway_http`,
`admin_api_http`, …) because a listener's name is simultaneously its app-env
option-block key and its Cowboy `ref` (§2.7); renaming one orphans every option
its mappings wrote. The reserved `admin` listener (§3.1) is therefore injected
only for an operator who has adopted `listeners.*`. The two spellings are
mutually exclusive, so nothing collides on port 18081.

**Corrected — `admin` is now injected on BOTH paths.** With the legacy inventory
gone there is only one spelling, so the conditional injection has no purpose, and
`with_reserved/1` runs over the default inventory as well as a configured one.
That is safe rather than merely harmless *because* the default inventory names its
admin listener `admin` — the reserved name — so the injection finds it already
present and is a no-op. It would not be safe if that inventory used the historical
`admin_api_http`: injecting `admin` beside it would put two listeners on 18081 and
`assert_bind_free/2` would refuse the boot. This is the same name-is-the-key
hazard the paragraph above describes, met from the other side.

Removal, later, is deletion of schema lines plus one Erlang function.

Retaining them also avoids the failure mode a clean break would create: with
`--allow_extra --silent` (§2.2), deleted keys would be *silently ignored* and a
node would come up bound to nothing an operator asked for.

## 5. Modules

Four units. `bondy_http_gateway` gets smaller, not larger: it keeps API specs,
storage, replication and dispatch *content*, and loses its four listener macros,
its ten lifecycle functions, `base_routes/0` and `admin_base_routes/0`.

**`bondy_listener_config`** — pure. Inventory plus app env in, a validated list
of listener records out, or a boot error. Owns required-key checks, driver
applicability, per-driver defaults, carrier-config resolution (per-listener over
global), service-to-module resolution, and route-collision detection. Being pure
makes it table-testable with no sockets.

**`bondy_listener`** — behaviour: `start/1`, `stop/1`, `suspend/1`, `resume/1`,
`connections/1`. Implementations: `bondy_listener_ranch` (wrapping today's
`bondy_ranch_listener`, `cowboy:start_clear/3`, `cowboy:start_tls/3` and the
ranch alarms) and, later, `bondy_listener_quic` (`cowboy:start_quic/3`). The
manager never branches on transport.

**`bondy_http_service`** — behaviour: `routes(Carrier, CarrierSpec, Listener)`,
returning Cowboy route rules grouped by virtual host. A listener's services are
grouped by carrier and each carrier is called **once** with the union of its
protocols, so `wamp_ws` + `bamp_ws` yield one `/ws` route bearing
`#{listener => Name, protocols => [wamp, bamp]}`.

**Two tables, keyed differently — corrected here.** The original sentence said a
service atom's carrier, carried protocol *and implementing module* are data
keyed by the service. The first two are: carrier and carried protocol are
intrinsic to a service name, so `service_spec/1` is data and no compatibility
matrix is needed. The module is not. It depends on the **carrier** alone, so it
lives in its own table keyed by carrier (`carrier_module/1`).

That split is what makes a carrier/module disagreement *unrepresentable* rather
than merely detectable. Under the original keying, two services naming one
carrier each carried their own module, so they could disagree — and the code that
resolved it took the first service's answer and dropped the second's silently,
because there was nowhere to report a conflict that the data structure permitted.
Removing the place the conflict can be written removes the resolution rule with
it.

`rest` was the case in point. `api_gateway` and `admin_api` both named it, so one
carrier stood for two *route sources* — the API Gateway specifications in storage
and the built-in Admin API specification in `priv/` — and the route-building
function had to read the listener's `services` back to decide which set to fetch.
They are now two carriers. They differ by route source rather than by protocol,
and since both declare `undefined` for protocol, a shared carrier's protocol
union could never have told them apart.

All in-tree services live in a single `bondy_http_services` module (one clause
per carrier) rather than one module each; the behaviour exists so an external
app — `apps/bondy_mcp` — can supply its own. Registering one therefore takes
**two** app-env entries, not one: `bondy_router.http_services` maps a service to
its carrier and protocol, and `bondy_router.http_carriers` maps that carrier to
the module serving it.

**`bondy_listener_manager`** — a **plain module**, not a gen_server, replacing
the eight `*_listeners/0` functions in `bondy_http_gateway` and the two in
`bondy_wamp_tcp`. It resolves the inventory once at boot into `persistent_term`
and offers `start/1` (by start phase), `stop/0`, `suspend/0`, `resume/0`. It
needs no process: it holds no mutable state, and the one event-driven duty —
rebuilding dispatch tables on an API-spec change — already belongs to the
`bondy_http_gateway` gen_server, which keeps it (with its existing debounce) and
consults the inventory for which listeners include `api_gateway`. Adding a
process would add supervision ordering to get wrong for no gain.

Three hardcoded lists become inventory-derived:
`bondy_ranch_listener:ref_to_transport/1` (`:113-116`),
`bondy_cert_manager:?TLS_LISTENERS` (`:47-51`), and the four literal
`dynamic_buffer` paths in `bondy_config:setup_wamp/0` (`:451-456`).

### Bridge-relay listeners

`bridge_relay_tcp` and `bridge_relay_tls` are inbound listeners for edge nodes,
configured in a separate schema under `bridge.listener.{tcp,tls}.*` and started
by `bondy_bridge_relay_manager` (`:24-25`). They enter the inventory as
`protocol = bridge_relay`, with their existing keys shimmed exactly like the
other legacy blocks (§4). Including them is not optional scope creep: both
`ref_to_transport/1` and `?TLS_LISTENERS` name them, so leaving them out would
force those two lists to stay half-hardcoded and defeat the point of increment 3.

Outbound **bridges** (`bridge.$name.*` — endpoint, reconnect, realms) are
clients, not listeners, and are untouched by this work.

Carrier configuration is resolved **once per listener at start**, by the
manager, not per connection — so the resolved map travels in the route's initial
state and `init/2` performs no config lookups. Resolving in the manager rather
than in a cuttlefish translation keeps one resolution site, exercised by both
released boots and test boots (§2.7).

## 6. Validation

Config errors are static and deterministic, so they **abort boot**. Skipping a
misconfigured listener would bring a node up not serving traffic, which is
worse. Bind-time errors (`eaddrinuse`) keep the behaviour `start_http/2` has
today.

| Condition | Result |
|---|---|
| missing `transport`, `protocol`, `port`/`path`, or `services` when `protocol = http` | error naming listener and key |
| `services` set when `protocol =/= http` | error — no demux surface (§2.4) |
| `tls.*` set when `transport = tcp \| uds` | error, not ignored |
| `certfile` or `keyfile` absent when `transport = tls \| quic` | error |
| stream-socket key set when `transport = quic` | error naming key and driver (§2.6) |
| unknown service atom | error listing valid services |
| two different carriers claiming one path | error |
| same carrier, several protocols | union into one route |

Requiring all four axes is what keeps `--allow_extra --silent` from biting: a
mistyped *name* yields two boot errors rather than a silent phantom listener
(the intended block lacks keys; the typo'd block lacks the rest), and a mistyped
*sub-key* surfaces as a missing required key rather than a default quietly
taking over — the latter only because mappings are default-free (§2.1).

What remains undetectable is a consistently mistyped name where every key is
set; names are arbitrary, so nothing structural can catch it. The manager
therefore logs one resolved line per listener at boot — name, driver, protocol,
bind address, services — so a wrong name is visible.

Service-versus-*spec* path collisions cannot be a boot error, because specs
arrive by anti-entropy after boot; that is why `dispatch_table/2` is already
lenient (§2.8). Those are logged at rebuild time, matching current behaviour.

## 7. Extension

- **MCP** — one `bondy_http_service` module and one service atom. Because
  validation is at app start rather than in the schema (§2.2), **no schema
  change is needed.** `apps/bondy_mcp` is currently an empty shell (`src` exists
  with no modules), so nothing constrains this.
- **BAMP over raw socket** — a new `protocol` value plus a ranch protocol
  module, taking its own magic byte or its own port (§2.4).
- **BAMP over WebSocket** — a new subprotocol id negotiated in
  `select_subprotocol/1`, plus the `bamp_ws` service. Not a new carrier.
- **WebTransport** — a new carrier, services `wamp_wt`/`bamp_wt`. Note
  WebTransport has no `sec-websocket-protocol` equivalent, so the carried
  protocol *must* come from the mount. Per-listener protocol restriction is the
  only available mechanism, not a convenience.
- **HTTP/3** — `transport = quic`, a second `bondy_listener` implementation, and
  the `quicer` dependency (§2.5, §2.6).

## 8. Increments

One mechanism each, verified before the next.

1. **`bondy_listener_config`, `bondy_listener` behaviour, ranch driver.** No
   schema change; the nine current listeners come from a hardcoded inventory
   reproducing today's behaviour. Falsification target: every existing CT suite
   passes unchanged — any behavioural difference means the wrapper is
   unfaithful.
2. **`bondy_http_service` behaviour.** `base_routes/0` and
   `admin_base_routes/0` become service modules. Test: compile the old and new
   route lists and assert the compiled dispatch tables are identical.
3. **`bondy_listener_manager`.** Delete the ten `*_listeners/0` functions;
   `bondy_app` calls the manager; the three hardcoded lists in §5 become
   inventory-derived.
4. **Schema `listeners.$name.*`, then the legacy compatibility path.**
   Falsification target, the load-bearing one: a legacy-only configuration and
   its new-style equivalent must produce the **same resolved inventory**.
   Nothing else proves the two cannot drift. Note where the comparison has to be
   made: the legacy path is Erlang (§4), so this is asserted on `resolve/2`'s
   output, not on rendered app env — a render-level comparison cannot see the
   legacy side at all, because cuttlefish drops the inventory translation for a
   conf file that mentions no `listeners.*` key.
5. **Per-listener carrier configuration.** Route-state threading, the `init/2`
   merge, the 24 mappings. Tests: two WebSocket listeners with different
   `max_frame_size`, the same frame accepted on one and rejected on the other; a
   protocol-restricted listener rejecting an otherwise-valid subprotocol; and a
   listener setting no carrier keys receiving the **global** value — that last
   one fails the moment anyone adds a `{default, ...}` to a per-listener carrier
   mapping, which is the regression guard for §2.1.
6. **Regenerate configuration.** The 7 shipped conf templates plus
   `config/bondy.conf.defaults`, which alone carries 212 legacy listener keys.
   Documentation.

Increments 1–3 are pure refactor with no operator-visible change, so they land
and are verified before any new config surface exists.

Deferred to its own piece of work: the `quicer` dependency and
`bondy_listener_quic`. It is a native msquic/cmake change, and landing it
separately keeps it and the config refactor from being verified only in
combination.

## 9. Not verified

- HTTP/3, WebTransport and WebSocket-over-QUIC support is established by reading
  Cowboy 2.17 sources only (§2.5). No probe against a live client has been run.
- QUIC certificate rotation has no design here; the ssl `sni_fun` path does not
  apply (§2.6).
- Per-listener rate limiting and CIDR allow-lists are **not** in scope. Rate
  limiting is configured globally under `security.rate_limit.*` and is untouched
  by this work.
- Listeners are defined at boot. Adding or removing one at runtime is not part
  of this design.
