# Audit: defaults removed with the legacy listener mappings

Task 1, Step 1 of `2026-08-19-listener-review-fixes.md`.

## Method

`{mapping, …}` blocks were extracted from `git show 73c7644c:schema/bondy.schema`
and `git show 73c7644c:schema/bondy_bridge_relay.schema` under the prefixes
`api_gateway.`, `admin_api.`, `wamp.tcp.`, `wamp.tls.`, `wamp.uds.` and
`bridge.listener.` — 271 + 47 = **318 mappings, of which 169 carried a
`{default, …}`**. Each default was then traced to whatever supplies that value
today: a shipped template, a code-level default, a consumer's own fallback, or
nothing.

Values on the "today" side were read from source, not assumed:

- Cowboy 2.17 `_build/default/lib/cowboy/src/cowboy_http.erl` — `active_n` 1
  (`:214`), `idle_timeout` 60000 (`:337`), `max_keepalive` 1000 (`:207`),
  `linger_timeout` 1000 (`:1772`), `invalid_response_headers` `error_terminate`
  (`:1470`), `reset_idle_timeout_on_send` false (`:351`).
- ranch 2.2 `ranch_conns_sup.erl:114` — `handshake_timeout` 5000.
- `bondy_bridge_relay_server.erl:132-137` — `auth_timeout` 5000,
  `idle_timeout` `infinity`, `hibernate` `idle`, `ping` `[{enabled, false}]`.
- `bondy_wamp_tcp_connection_handler.erl:125,594` — `idle_timeout` `infinity`,
  `ping` `[{enabled, false}]`.
- `bondy_http_cors:default_config/0`, `bondy_http_security_headers:default_config/0`.

## Scope rule

A shipped template restating a value is **not** universal coverage.
`rebar3_scuttler` generates `etc/bondy.conf` from the schemas for every release
(`rebar.config:1030`), writing each non-fuzzy default as an active line —
verified in `_build/docker/rel/bondy/etc/bondy.conf` (2026-07-31, pre-branch),
which carries `wamp.tcp.ping.enabled = on`. So a **schema** default reached every
release. A **template** value reaches only `dev`, `node1`, `node2`, `node3`,
`edge_1`, `bridge` and `fly`. `prod`, `prod_named` and `docker` overlay no
template, so for those three only a code default counts.

A `listeners.$name.*` mapping cannot appear in a generated conf — a fuzzy mapping
has no concrete name to enumerate — which is why restoring these in the schema is
not available, and also why `bondy_router.listeners` stays unclaimed so
`default_inventory/0` applies.

## Lost — restore

| Old mapping | Old default | Today | Affects |
|---|---|---|---|
| `wamp.{tcp,tls}.ping.enabled` | `on` | absent ⇒ **ping off** | raw-socket, **all releases** |
| `wamp.{tcp,tls}.ping.timeout` | `10s` | absent | raw-socket, all releases |
| `wamp.tcp.ping.max_attempts` | `2` | absent | raw-socket TCP, all releases |
| `wamp.tls.ping.max_attempts` | `3` | absent | raw-socket TLS, all releases |
| `bridge.listener.{tcp,tls}.ping.{enabled,idle_timeout,timeout,max_attempts}` | `on` / `20s` / `10s` / `2` | absent ⇒ ping off | bridge relay, all releases |
| `wamp.{tcp,tls}.idle_timeout` | `8h` | `infinity` | raw-socket, all releases — **and see the coupling below** |
| `bridge.listener.{tcp,tls}.idle_timeout` | `8h` | `infinity` | bridge relay, all releases |
| `api_gateway.http*.active_n` | `100` | Cowboy **1** | every HTTP listener except `admin`, **all releases** |
| `api_gateway.http*.idle_timeout` | `15s` | Cowboy **60s** | every HTTP listener except `admin`, all releases |

Two notes on the HTTP pair. The templates *do* restate them, but **only for
`listeners.admin`** (`config/dev/bondy.conf.template:25-26`,
`config/bridge/…:68-69`); the public `listeners.api_gateway_http` block sets
socket options and not these, so the public listener lost them in every release.
`active_n` 100 → 1 changes how many packets a socket is set active for per read
cycle, so this is a throughput regression on the main API port, not a cosmetic
one.

### The raw-socket coupling: ping requires a finite `idle_timeout`

`bondy_wamp_tcp_connection_handler:maybe_enable_ping/2` takes the ping interval
from **the listener's** `idle_timeout`, not from the ping block — `:778-779`,
`%% Use the listener's idle_timeout, not from ping options` — and `reset_ping/1`
(`:823`, `:834`) passes it straight to `erlang:start_timer/3`.
`erlang:start_timer(infinity, self(), x)` answers `error:badarg`, measured
directly here.

So the two restorations are not independent: enabling ping on a raw-socket
listener whose `idle_timeout` is `infinity` crashes the connection on its first
inbound message. Pre-branch this could not happen, because both defaults were in
force (`on` and `8h`).

**This is a live defect in the branch as it stands**, not only a consideration
for the fix. An operator who writes

```
listeners.wamp_tcp.ping.enabled = on
listeners.wamp_tcp.ping.timeout = 10s
listeners.wamp_tcp.ping.max_attempts = 2
```

passes `assert_listener_ping/3` — those are the only siblings it requires — and
then every connection on that listener dies with `badarg` in `reset_ping/1`. The
existing guard cannot see it: the value it would need to check lives outside the
`ping` block it validates. Restoring the `8h` default closes it; a raw-socket
listener with ping enabled and an explicitly `infinite` `idle_timeout` must still
be refused at boot.

## Lost — RESTORED 2026-08-19, after the key's unit was corrected

The row below was withheld in Task 1 and is now restored. `{duration, ms}` →
`{duration, s}` on `listeners.$name.linger.timeout`, and
`protocol_option_defaults/1` carries `linger_timeout => 1` for both stream
protocols. Two things measured against cuttlefish while doing it:

- `cuttlefish_duration:parse/2` uses `cuttlefish_util:ceiling/1` (`:65`), so a
  sub-second value rounds **up**: `500ms` → 1, `1ms` → 1. The floor-to-zero
  hazard that made the alternative fix unattractive does not exist in this
  direction, so `{linger, {true, 0}}` — abort on close — cannot be reached by
  rounding.
- A bare integer is returned unconverted (`cuttlefish_datatypes.erl:232`), so the
  bare form already meant seconds and is unaffected. It is also the only form the
  `-1` sentinel can arrive in: `"-1"` and `"0"` as duration STRINGS are both
  `{error, {duration, _}}`. The datatype must keep its `integer` alternative.

Also corrected: this plan asserted `{duration, s}` would be the only
seconds-valued duration in the schema. `schema/bondy.schema` already had **8**,
plus 4 in `oauth2.schema`, 4 in `bondy_broker_bridge.schema`, 2 in
`bondy_http_connector.schema` and 1 in `hidden/vm_args.schema`.

## Lost — the value was wrong (superseded by the section above)

| Old mapping | Old default | What it actually did |
|---|---|---|
| `wamp.{tcp,tls}.linger.timeout` | `1s` | Datatype `[{duration, ms}, integer]`, so the default rendered **1000**. `bondy_config:normalise_socket_opts/1:806-808` passes the value straight into `{linger, {true, 1000}}`, and `inet` documents that second component as **seconds** (`kernel/src/inet.erl:1124`, OTP 28.5) — so what shipped on every raw-socket listener was a **1000-second** linger on close, not a one-second one. |

The unit mismatch belongs to the key, not to the default: an operator writing
`listeners.$name.linger.timeout = 1s` gets the same 1000-second linger today.
Restoring `1000` would restore the defect; restoring `1` would give the default a
different unit from every operator value for the same key. So the key's unit is
fixed on its own first, and the default goes back on top of that.
`rawsocket_linger_default_is_deliberately_not_restored_test` holds the decision.

## Lost — decide

| Old mapping | Old default | Today | Note |
|---|---|---|---|
| `admin_api.https.security_headers.hsts` | `max-age=31536000; includeSubDomains` | `undefined` ⇒ header not sent | Only the HTTPS admin listener carried it, and that listener defaulted to `enabled = off`. A TLS HTTP listener declared today sends no HSTS. Restoring it as a code default would apply it to every TLS listener, which is a behaviour *change* in the other direction — hence a decision, not a restoration. |

## Covered — no action

| Group | Covered by |
|---|---|
| `cors.*` (all 5) | `bondy_http_cors:default_config/0` — values compared one by one, identical. This is the duplication Task 3 removes. |
| `security_headers.{enabled,frame_options,content_type_options}` | `bondy_http_security_headers:default_config/0`, identical |
| `server_header` (`"bondy"`) | `bondy_config:get([Name, server_header], <<"bondy">>)` |
| `transport_opts.handshake_timeout` (`5s`) | ranch's own 5000 |
| `transport_opts.socket_opts.ip_version` (`"4"`) | `normalise_socket_opts/1`'s `inet` fallback, added by this branch |
| `admin_api.http*.ip` (`127.0.0.1`) | `resolve_ip/3` narrows a listener carrying `admin` or `metrics` to loopback |
| `transport_opts.socket_opts.port` (7 ports) | the inventory's own `port` key; `default_inventory/0` for the three built-ins, and an undeclared listener does not exist |
| `enabled` (8, mixed `on`/`off`) | `maps:get(enabled, Spec, true)`; the six that defaulted `off` are simply undeclared now |
| `bridge.listener.tcp.auth_timeout` (`5s`) | `bondy_bridge_relay_server.erl:132` fallback 5000 |
| `bridge.listener.{tcp,tls}.hibernate` (`idle`) | `bondy_bridge_relay_server.erl:137` fallback `idle` |
| 14 further `protocol_opts.*` keys | Cowboy's and cowlib's own defaults, which the old schema values had been chosen to match exactly: `max_keepalive` 1000, `max_headers` 100, `max_header_name_length` 64, `max_header_value_length` 4096, `max_empty_lines` 5, `max_method_length` 32, `max_request_line_length` 8000, `max_skip_body_length` 1000000, `request_timeout` 5s, `inactivity_timeout` 5m, `linger_timeout` 1s, `sendfile` on, `invalid_response_headers` `error_terminate`, `reset_idle_timeout_on_send` off |
| `protocol_opts.max_concurrent_streams` (`100`) | cowlib's own default is also 100 — `cow_http2_machine.erl:246-249`, whose comment reads "We use a default of 100 even though the protocol default is infinity". The HTTP/2 stream ceiling is intact. |

## Not a loss — already orphaned before the branch

- `wamp.tcp.ping.idle_timeout` (`20s`) and `wamp.tls.ping.interval` (`30s`) were
  never read. `bondy_wamp_tcp_connection_handler:maybe_enable_ping/2` reads only
  `timeout` and `max_attempts` out of the ping block (`:780-781`) and takes its
  interval from the listener's own `idle_timeout` (`:778-779`). Both keys were
  dead before the removal, so neither is restored — restoring them would revive
  a knob that does nothing. The bridge-relay handler *does* read
  `ping.idle_timeout` (`bondy_bridge_relay_server.erl:1062`), so that one is a
  genuine loss and is in the restore table.
- `bridge.listener.{tcp,tls}.max_frame_size` (`infinity`) targeted
  `bondy_router.bridge_relay_{tcp,tls}.max_frame_size`, and nothing read that
  path. `max_frame_size` is read only as a WebSocket carrier key
  (`bondy_listener_config.erl:129`) and for outbound bridges
  (`bondy_bridge_relay.erl:202`). The key was dead before the removal.
