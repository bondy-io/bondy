# CHANGELOG
## Unreleased

### New Features

#### New storage and replication architecture
* PlumDB (and its RocksDB backend) has been removed and replaced by a new, purpose-built storage and replication stack:
    * `bondy_db` — the database layer used by all Bondy subsystems (security, realms, API Gateway specs, tickets, tokens, registry). Provides tables with per-table CRDT semantics, point reads, ranged scans, cursor-based pagination (`bondy_relation`), and deletion.
    * `bondy_oplog` — the replicated operation-log substrate underneath `bondy_db`: per-shard write-ahead log, Merkle Search Tree (MST) history, appliers that maintain materialised projections, and pull-based anti-entropy replication over Partisan.
    * `bondy_mst` — the MST library, now vendored as an umbrella app.
    * Durable tables project onto a `leveled` (LSM-tree) backend with ETS point-read caches; ephemeral tables (e.g. the registry) are fully in-memory. The WAL owns durability: writes are acknowledged after the log fsync, and projections are rebuilt from the log on recovery.
* Convergence is op-based CRDT semantics per table — last-writer-wins and multi-value registers, add-wins maps/sets, enable/disable-wins flags, counters — with per-cell Hybrid Logical Clocks and, for concurrency-detecting types, per-cell causal contexts (dotted version vectors). Replicas converge deterministically regardless of delivery order (Strong Eventual Consistency).
* Sharding and physical layout are configurable per table: realm-partitioned or key-hashed placement, configurable shard counts (`oplog.core.shard_count`, `oplog.core.partition_strategy`, `oplog.core.realm_prefix_depth`), and aggregate-root routing that co-locates related keys (e.g. a user's group memberships) on a single shard for the authentication hot path. Realm identifiers are folded into storage keys so identically-named keys in different realms can never collide.
* The node's keying topology is frozen in an on-disk manifest at first boot; incompatible changes (which would corrupt routing) are detected and refused at startup, including changes to the runtime's internal hash function across OTP upgrades. Anti-entropy sessions exchange a topology fingerprint and refuse to sync with peers whose keying differs.
* Anti-entropy (enabled by default, `oplog.aae`): pull-based MST reconciliation with bounded per-round page batches, a node-wide concurrency cap (`oplog.aae.max_concurrency`), a node-wide in-flight page budget (`oplog.aae.max_pages_in_flight`), adaptive live-sync throttling for quiescent shards (`oplog.aae.live_sync`), optional load-reactive yielding under routing pressure (`oplog.aae.load_adaptive`), and exponential retry backoff for failed bootstraps. New and recovering nodes bootstrap by streaming a peer's projection snapshot and then replaying the log delta. A node whose peer has already reclaimed historical pages automatically falls back to a fresh snapshot bootstrap.
* Authentication freshness fence: when replicated security state (credentials, grants) on this node is provably stale beyond `oplog.aae.fence.max_lag`, authentication is refused rather than decided on stale data. The behaviour on cluster isolation is configurable (`oplog.aae.fence.on_isolation`); genuine single-node deployments are exempt.
* Cluster-wide security reactions: a credential change replicated from another node (password or authorized keys) closes the affected user's active sessions on every node; replication that overwrites a concurrent local edit of a grant or source raises a telemetry alarm (`[bondy, aae, merge_conflict]`).
* Group membership is now stored as one replicated fact per (user, group) pair with add-wins semantics, so concurrent membership changes on different nodes merge deterministically without lost updates.
* Registry entries (registrations, subscriptions) live in an ephemeral in-memory database; remote-session liveness is handled by presence masking (suspend/resume/evict) instead of destructive deletes, so a flapping node's entries recover without re-registration.

#### Summary-based registry routing (RIB)
* The registry no longer replicates every registration and subscription to every node. Instead each node publishes a compact **routing summary** — one replicated cell per `(realm, match policy, URI, node)` — and keeps its full entries in node-local memory. Cross-node routing (dealer callee selection and broker subscriber fan-out) is decided from the merged summaries: a registration's replicated footprint becomes one small cell per owning node rather than a full entry copied cluster-wide, which is what lets the registry scale to large, churny registration counts. This is unconditional — there is no mode to select.
* A forwarded cluster call is **node-addressed**: the receiving node re-selects the callee among its own live local registrations (owner-side completion) instead of acting on the sender's possibly-stale choice of entry, and a bounded pre-invocation retry reroutes past a node whose summary was momentarily stale before returning `no_eligible_callee`.
* Observable end to end: a periodic consistency sweep (`registry.rib.check_interval`, default `5m`) compares the summaries against the registry ground truth per realm and logs any divergence, optional owner-side route-flap damping (`registry.rib.damping`), a family of Prometheus metrics (`bondy_registry_rib_*`, `bondy_rpc_rib_*`) and a dedicated **Registry RIB** section in the bundled Grafana dashboard. Documented in `doc/guides/router/registry_routing.md`.

#### Deletion and space reclamation
* `bondy_db:delete/3` deletes a value from a replicated table: the value disappears immediately and everywhere, while the underlying tombstone is retained until it is *causally stable* — provably known to every cluster member — and then physically reclaimed. This is driven by:
    * A stability oracle built on reciprocal sync confirmation: each anti-entropy session confirms the exact MST root both peers hold, and reclamation only proceeds for data below the frontier confirmed by **all** current members (a silent member holds reclamation back; it never ages out implicitly).
    * A background reclamation scheduler (enabled by default) running bounded, resumable sweeps inside each shard's applier.
    * Origin retirement (enabled by default): when a node permanently leaves the cluster, its per-cell causal bookkeeping is garbage-collected via a fail-closed reap-by-complement pass, triggered by membership changes and a slow periodic tick. No origin is ever banned automatically.
* Reclamation is observable end-to-end: telemetry for sweep batches, stalled reclamation (naming the members holding it back), retirement passes and scheduler outcomes, plus rate-limited warning logs. New documentation covers the model and every configuration option (`doc/guides/database/deletion_and_reclamation.md`, `doc/guides/configuration/reclamation_options.md`).

#### Progressive Call Results (WAMP Advanced Profile)
* The dealer now implements progressive call results end to end: a caller opting in with `CALL.Options.receive_progress` receives each of the callee's progressive `YIELD`s as a `RESULT` with `Details.progress = true`, followed by exactly one terminal `RESULT`/`ERROR`. Progressive results arrive in yield order, including when caller and callee are connected to different cluster nodes (results are relayed over the pair's ordered pipeline). The feature is negotiated end to end — it activates only when the dealer feature is enabled and both caller and callee announced `progressive_call_results` in `HELLO` (paired with `call_canceling`, as the specification requires); otherwise the option is removed and the call degrades to a single final result. A progressive `YIELD` for a call that did not request progressive results is a protocol violation: the callee's session is closed and the caller's call fails fast. Documented in `doc/guides/router/progressive_call_results.md`.
* Timeout semantics follow the specification: for a progressive call, `CALL.Options.timeout` is the limit between the call and the first result and between results thereafter — each progressive result restarts it. The new `CALL.Options._deadline` extension (milliseconds) additionally caps the whole call, so a healthy-but-endless stream can still be bounded.
* Cancellation works mid-stream and across the cluster, and when a caller's session ends with calls still in flight the dealer INTERRUPTs (mode `killnowait`) the callees still working on its behalf — local ones directly, remote ones by relaying the cancellation to their node.
* New configuration flag `wamp.dealer.progressive_call_results` (default `off`). Only enable it once every node in the cluster has been upgraded: a node without support settles a call on its first progressive result. *Progressive Calls* (caller-side argument streaming) remains unimplemented and its flag locked off.
* The `bondy_connect` Erlang client supports both sides of the feature: `call_async/5` with `receive_progress => true` delivers each progressive result to the caller as `{bondy_connect, Token, {progress, Result}}` before the single terminal reply (the synchronous `call/5` rejects the option), and a callee handler invoked for a progressive call receives a `progress` fun in its details whose calls become progressive `YIELD`s. The client's per-call timer follows the same spec semantics (restarted per progressive result, capped by `_deadline`). Call results now also expose the WAMP `RESULT.Details` under the `details` key.

#### Realm signing keys encrypted at rest
* Realm private keys are now encrypted at rest (AES-256-GCM) using a master key obtained through `bondy_secret_resolver` providers configured via `security.master_key.*`: an environment variable or AWS Secrets Manager. The keyring fails closed — if the master key is unavailable at boot, encrypted keys are not served.

#### HTTP/2
* HTTP/2 is now served on all four HTTP listeners: negotiated via ALPN on the HTTPS listeners and via the h2c upgrade or prior-knowledge preface on the HTTP listeners. Resource use is bounded (at most `max_concurrent_streams` concurrent requests per connection, default 100, plus HPACK and frame-rate caps). Note for capacity planning: one HTTP/2 connection can carry up to `max_concurrent_streams` in-flight requests, so `max_connections`-based alarms undercount request-level load.

### Security
* Inbound rate limiting (`security.rate_limit.*`): token-bucket limits on connection establishment, handshakes and authentication attempts.
* Refined X-Forwarded-For trust handling so source-address checks cannot be spoofed through untrusted proxy headers.
* Clustering now refuses to start when the Partisan peer plane is insecure (plaintext, or TLS without peer verification) — replicated credentials and signing keys would otherwise transit unprotected. Operators on trusted networks can acknowledge the risk explicitly with `cluster.tls.allow_insecure = on`, which downgrades the refusal to a startup warning.
* Fixed ticket scope normalisation on decode: persisted ticket lookups now resolve, making ticket revocation enforceable.
* Fixed a privilege escalation in claim-restricted (e.g. OIDC) sessions: a session restricted to an explicit set of groups also received the grants of the user's locally-stored group memberships. Such sessions now receive only the user's direct grants plus the claimed groups' grants.
* NUL bytes are rejected in realm URIs and storage keys, and WAMP URI validation rejects control characters, closing key-injection paths into the storage layer.
* Cowboy upgraded from 2.13.0 to 2.17.0 (with cowlib 2.18.0), picking up upstream security fixes: an HTTP/1.1 parser denial-of-service, HPACK-bomb protection, early rejection of NUL/CR/LF in unexpected positions, and termination of responses carrying invalid header names or values (a response-splitting defence; a response with e.g. control characters in a header value now yields a 500 instead of being relayed).

### Improvements
* New Cowboy listener options exposed in `bondy.conf` for all four listeners (`admin_api.http[s]`, `api_gateway.http[s]`): `max_authorization_header_value_length` (raise for large bearer tokens without raising the general header limit), `max_cookie_header_value_length`, `max_authority_length`, `invalid_response_headers` (`error_terminate` | `ignore`) and `max_concurrent_streams`.
* Comprehensive Prometheus observability, all exported on the existing Admin API `/metrics` endpoint:
    * Storage stack (`bondy_db`/`bondy_oplog`/`bondy_mst`): WAL activity and durability state, applier pipeline stage latencies and throughput, anti-entropy sync/bootstrap sessions, scheduler activity, MST page store (seals, GC, gossip, integrity/corruption counters), secondary index flushes, substrate read/cache rates and AE freshness lag, per-shard applied-frontier signatures (cluster-wide convergence is computable in PromQL with no scrape-time cross-node calls), and per-Bookie `leveled` LSM state (penciller work backlog, level file distribution, caches, journal compaction score, sampled fetch levels and operation times).
    * Router: WAMP call round-trip latency per procedure (`bondy_wamp_call_latency_milliseconds`, observed at RPC-promise resolution for local and cross-node calls, success and error), in-flight RPC promises and promise timeouts, inbound rate-limiter denials by class, registration/subscription churn, realm and user lifecycle events (including logins and credential changes), registry size/memory, listener saturation and accept/terminate counters per socket listener, load-regulation queue depths, Partisan connection counts per peer and channel, active OTP alarms, node readiness, and mailbox depth of critical singleton processes.
    * BEAM: microstate-accounting scheduler-time metrics (`erlang_vm_msacc_*`) and counters for system-monitor events (`long_gc`, `long_schedule`, `large_heap`, `busy_port`, `busy_dist_port`), which were previously logged and discarded.
* Ready-to-run monitoring stack under `monitoring/`: Docker Compose (Prometheus + Grafana, pre-provisioned) with a comprehensive dashboard — cluster node selector, Partisan connectivity matrix, an N×N anti-entropy convergence matrix (diverged-shard count per node pair) with per-pair drill-down into diverged shards and their replication gaps, and per-area rows (write path/WAL, applier, core substrate, leveled, MST, secondary indexes, router internals, WAMP traffic, HTTP, BEAM VM) using latency heatmaps, state timelines and saturation gauges.
* `bondy_export` import now batches writes (500 records per transaction) instead of syncing per record, making large imports orders of magnitude faster.
* The reference documentation build (`rebar3 ex_doc`) was repaired (legacy doc comments crashed the doc compiler) and module documentation across the storage stack migrated to `-doc` attributes.
* Erlang/OTP 28 is now the minimum supported release; Partisan upgraded to latest.

### Performance
* Durable-table pack sealing is asynchronous: the write path is no longer frozen while the MST pack store seals, cutting p99 apply latency roughly in half under sustained write load. The seal threshold default was lowered (16MB → 2MB) so seals are frequent-but-small instead of rare-but-long.

### Fixes
* Call canceling did not work when the callee was connected to another cluster node: the caller's node only looked for local invocation state (which for a remote callee lives on the callee's node), so the `CANCEL` was silently dropped — no `INTERRUPT` ever reached the callee and, for `kill` mode, the caller received no acknowledgement. The caller's node now relays the cancellation to the callee's node, which resolves the invocation and interrupts the callee; all three modes (`skip`, `kill`, `killnowait`) behave per the specification across nodes. Additionally, the `skip`-mode acknowledgement ERROR now correctly references the `CALL` message type.
* Cross-node RPC promises recorded no procedure URI (an internal field mix-up), so per-procedure call-latency metrics were silently skipped and `CANCEL` authorisation checks ran against an undefined procedure for calls whose caller is on another node. The promise now carries the procedure URI on that path.
* In-flight invocations whose **caller** session died were left to expire on their own — the callee kept working for a caller that was gone, and the promise lingered until the call timeout. These are now cleaned up immediately, with the callee interrupted (see Progressive Call Results above).
* The session and socket duration histograms (`bondy_session_duration_seconds`, `bondy_socket_duration_seconds`) mis-recorded every observation: values fed in seconds were interpreted as native time units (the prometheus library infers a duration unit from the metric-name suffix), so every observation landed in the lowest bucket and sums under-read by ~10⁹×. Both now record correctly.
* Cold boot after an unclean shutdown could lose the tail of the write-ahead log when multiple tables shared a WAL: draining is now gated until every co-hosted table has registered.
* Stopping a node destroyed the durable MST history and forced a full log replay on next boot; history is now closed on shutdown and destroyed only for ephemeral tables.
* Two durability-ordering bugs in the durable MST pack store: the root could be persisted before the pages it references (leaving a dangling root after a crash) and the root was only persisted lazily (forcing full log replays after clean shutdowns). Pages are now synced before the root, and the root is flushed at every commit barrier.
* A freshly bootstrapped node adopted the peer's data but not its replication frontier, permanently reporting divergence; the frontier is now merged at bootstrap completion.
* Boot-time configuration application is declarative and idempotent: re-applying the same `security` config on every boot no longer generates spurious replicated writes.
* Realm signing keys were part of the realm's identity hash, causing every boot to regenerate and re-replicate them; keys now live in their own union-merged structure and cross-node JWT verification works while keys propagate.
* The `<listener>.buffer.min/max` (dynamic socket buffer) options were broken: setting them silently disabled dynamic buffering instead of bounding it. Values are now validated at boot (both bounds required, 1KB–128KB, `0` disables) and reach the HTTP server in the shape it expects; when unset, the adaptive default (512B–128KB) applies. The equivalent `wamp.websocket.buffer.*` options are documented as having no effect (a WebSocket connection inherits its listener's buffer configuration).

### Changes
* The router OTP application was renamed `bondy` → `bondy_router` (directory `apps/bondy_router`). The release, node name, configuration file and WAMP URIs are unchanged (`bondy`).
* On-disk data from previous releases (PlumDB/RocksDB) is not readable by this release; there is no in-place migration. Carry data across with export/import, and wipe stale data directories before starting.
* The PlumDB `store.*` configuration options were removed, together with the `plum_db` broadcast wiring. New storage options live under `oplog.*` (see the reclamation configuration reference for the reclamation/retirement application-environment options).
* Requests with more than 100 query-string parameters or form fields are now rejected (Cowboy 2.17 default).

## 1.0.0-rc.65
* Fix bug in decoding of Error messages when using partial JSON encoding

## 1.0.0-rc.64
### Fixes
* Dockerfile security fixes to reduce CVE surface in runtime image

## 1.0.0-rc.63
### Performance
* Registry pattern matching (prefix and wildcard) rewritten as a lock-free persistent Adaptive Radix Trie (`bondy_registry_ptrie`), replacing the `art` library and its serialising gen_server. Match latency drops from ~133µs to ~1µs and reads scale with cores instead of being capped at ~5k ops/s. Per-handle QSBR reclamation is driven by `bondy_registry_ptrie_janitor` processes managed by each registry partition.
* RPC dealer: removed expensive defensive liveness checks from the call hot path; in-flight promises are now flushed when a Callee dies.

### Improvements
* RPC Gateway: significant refactor of callee lifecycle, HTTP pool management, and token cache; added `bondy_rpc_gateway_callee_lifecycle_SUITE` for coverage.
* `bondy_table_manager` supports anonymous ETS tables to avoid creating atoms from runtime-generated names; broader protections added across the codebase against atom-table exhaustion.

### Fixes
* `bondy_rpc_gateway.schema`: corrected duration unit on `pool.checkout_timeout`, `pool.connect_timeout`, `pool.idle_timeout`, and `pool.recv_timeout` (`s` → `ms`) so sub-second values round-trip correctly.
* Fixed a raise that prevented ETS table cleanup in `bondy_transport_queue` / `bondy_http_transport_session`.

## 1.0.0-rc.62
### Fixes
* Race condition in longpolling connection (between longpoll timeout and idle timeout, now separate configs)

## 1.0.0-rc.61
### Fixes
- `cookie_same_site` validation was using atoms as opposed to strings (binaries)

## 1.0.0-rc.60
### Added
- Configurable `cookie_same_site` option for OIDC providers (`lax`, `strict`, `none`; default `lax`). Required for cross-subdomain deployments where Safari refuses to send cookies on SSE/fetch requests. Both `cookie_domain` and `cookie_same_site` can be overridden via query parameters on `/oidc/logout`.

## 1.0.0-rc.59
### Added
- bondy_http_cors.erl — Centralised CORS logic with 3 origin modes (`*, auto, explicit allowlist`). Never combines credentials: true with origin: `*`. Adds Vary: Origin for non-wildcard origins.
- bondy_http_security_headers.erl — Static security headers (HSTS, X-Frame-Options, X-Content-Type-Options, CSP) cached in
  persistent_term per-listener. Configurable server header (suppress/customise).
- CORS + security headers schema keys to `bondy.schema` for all 4 listeners (admin_api http/https, api_gateway
  http/https)
- HSTS defaults to enabled for HTTPS listeners, disabled for HTTP
- X-Frame-Options defaults to SAMEORIGIN, X-Content-Type-Options to nosniff
- Removed duplicated cors_headers/1 from 4 handlers (OIDC, SSE, SSE stream, long-poll)
- Replaced ?HEADERS/?OPTIONS_HEADERS macros in OAuth2 handler
- Added CORS fallback in API Gateway REST handler (uses spec headers when present, falls back to listener config)
- Updated admin ping/ready handlers to use set_all_headers/1
- Removed ?CORS_HEADERS macro from http_api.hrl
- Removed hardcoded CORS from bondy_admin_api.json and example specs

### Fixes
- Fixed config defaults with wrong types

## 1.0.0-rc.58
### Changes
* Change user auto provisioning in OIDC to `false`
### Added
* RBAC property-based tests

## 1.0.0-rc.57
### Fixes
* Fixes an issue with OIDC tokens containin roles unknown to Bondy

## 1.0.0-rc.56
### Fixes
* Fix set comparison on authroles calculation
* Add error logs for failed OIDC conections

## 1.0.0-rc.55
### Fixes
* Fixed issues with role mapping and metadata merging in OIDC/Cookies

## 1.0.0-rc.54
### New Features
* new `bondy_cert_manager` used for validation of outgoing TLS certificates and other features like live certificate rotation

## 1.0.0-rc.53
## Fixes
* Fixes to OIDC Handler

## 1.0.0-rc.52
## Fixes
* SSL verification fixes for OIDC HTTP connections

## 1.0.0-rc.51
### New Features
* Experimental implementation of 2 additional WAMP Transports:
    * HTTP Longpoll according to the WAMP Spec.
    * HTTP SSE, a variation on Longpoll that uses Server Sent Events (SSE) for `receive` (This only works with JSON encoding only at the moment)
* Support for Cookie-based authentication in combination with OpenID Connect, where Bondy acts as OIDC Relaying Party (`oidcrp` authentication method). Configuration done at the realm level. This requires the definition of an HTTP API using Bondy API Gateway.
* RP-Initiated Logout for OIDC sessions. The `/oidc/logout` endpoint now performs a two-step logout: revokes the Bondy ticket and clears cookies, then redirects to the IdP's `end_session_endpoint` (with `id_token_hint` and `post_logout_redirect_uri`) to terminate the IdP session as well. Falls back to a direct SPA redirect if the IdP does not support `end_session_endpoint`. The `post_logout_redirect_uri` must be registered in the IdP's client configuration.
* Experimental implementation of RPC Gateway that allows for the definition of WAMP to HTTP routing, taking care of Secret Management and Token flows and caching. This is entirely configured on the `bondy.conf` file.
* Cookies now have the realm as suffix e.g. `bondy_ticket_my_realm`
* New `bondy.session.self` RPC that returns the caller's session information (usefull when using cookie-based authentication as the cookie cannot be read by the client code).

### Fixes
* Fixed CORS headers missing from OIDC handler endpoints (`/oidc/login`, `/oidc/callback`, `/oidc/logout`). Cross-origin requests from SPAs were blocked by the browser. The handler now sets CORS headers on all responses and handles `OPTIONS` preflight requests.
* Fixed `bondy_csrf` cookie never being set during the OIDC callback. The cookie used `SameSite=Strict` which prevented the browser from accepting it on the cross-site redirect from the IdP. Changed to `SameSite=Lax` to match `bondy_ticket`.
* Fixed `/oidc/logout` not clearing the `bondy_ticket` cookie in cross-site deployments. The endpoint now accepts `GET` requests (in addition to `POST`) so the SPA can use a top-level navigation, which allows the browser to both send and clear `SameSite=Lax` cookies. The response is a `302` redirect instead of `200 OK`.

### Changes
* Session `authextra.meta` map now collects metadata from the User object as well as all the groups this user belongs to directly or indirectly (transitive closure). As a result both keys in `HELLO.Details.authextra.meta` and `Details._session_info.meta` can return lists (arrays) when 2 or more values have been collected for that key or when any of the values was originally a list.

## 1.0.0-rc.50
* Upgraded PlumDB with:
    * Fixes to configuration of shared write buffer and block cache
    * Latest version of RocksDB (10.7.5)
* set option `store.use_direct_io_for_flush_and_compaction` default to `false`

## 1.0.0-rc.49
* Fix dockerfile mistake

## 1.0.0-rc.48
- Upgraded to latest PlumDB wich contains fixes to the RocksDB defaults (the previous valus might cause issues due to excessive compaction)
- RocksDB can be configured via `bondy.conf` using `store.*` options.

## 1.0.0-rc.47
### Changes
- Implementation of JSON partial decoding/encoding for WAMP messages.
    - Bondy now decodes/encodes only the control message data (head of the WAMP message) preserving the payload (tail) in JSON format. This improves performance as the payload is never decoded unless a destination peer requires a different encoding. For networks using JSON end-to-end you should see important performance improvements.

## 1.0.0-rc.46
### Fixes
- Fixes a bug in the OAUTH2 rest handler which would prevent the `client_device_id` option to be considered when obtaining a new token. This was introduced with the new token subsystem. This issue limites teh token scope to {realm, client} as opposed to {realm, client, device_id}.

## 1.0.0-rc.45
### Fixes
- Fix bug in calculation of prometheus metrics preventing /metrics to complete

## 1.0.0-rc.44
### Changes
- Make wamp router features configurable and prevent using pattern matching when not enabled
- Define a sensible default of 4MB for max_frame_size

## 1.0.0-rc.43
* Fixed TLS support for Rawsocket listener

## 1.0.0-rc.42
### Changes
- **Partial Registry concurrency improvement** - As we prepare to formalize our battle-tested platform with a `1.0.0` release, we've enhanced the registry with a more scalable and concurrent solution for EXACT matching registrations and subscriptions. PREFIX and WILDCARD matching support retain their existing concurrency limitations. In the next release candidate, we'll implement a more scalable solution for these features alongside a new replication mechanism - the final step to complete the implementation.
- `bondy.ping` added to be used as connection hearbeats where the client doesn't
support transport level hearbeats e.g. Web Browser Websocket pings. The RPC replies a single positional argument `"pong"` and it is always authorised to be called by all sessions.

## 1.0.0-rc.41
- Minor fix to new listener `liner.timeout` option to avoid confusion between protocol and socket options.

## 1.0.0-rc.40
- Major HTTP API Gateway bottleneck removed and memory usage reduced
    - Avoid Cowboy to close over the dispatch table when compiling the routing
    logic and passing it into the request handling process.
    - Uses new `persistent_term` capability from Cowboy to store the dispatch
    table
- Major refactoring of protocol/transport options for better reuse
- Added almost all options to configuration schemas

## 1.0.0-rc.39
* Completely redesigned the OAUTH2 token storage.
    * Tokens are now bounded by {User, Client, Device} (idem WAMP Tickets)
    * Tokens are sharded across all partitions, allowing for more scalability
      (idem WAMP Tickets)
    * This is part of a roadmap to completely redesign and complete the OAuth2
    and OIDC capabilities in Bondy
* OTP/Partisan compatibiliey issue fixes in PlumDB
* Refactoring of WAMP APIs (Modules renamed and consolidated)
* New WAMP APIs
    * `bondy.registry.list`
* New standard `CALL.Options`
    * `_disclose_session` - The callee will receive and the session information
    in  `INVOCATION.Details._session_info`
- Drop x_ prefix for RPC experimental options

## 1.0.0-rc.38
- Failed tag

## 1.0.0-rc.37
* Added bounded queues for job worker pool and their configuration
    * `load_regulation.job_manager.queue.size`
    * `load_regulation.job_manager.queue.ttl`
* Configure HTTP dynamic buffers via `bondy.conf` options
    * `bondy.api_gateway_http.socket_opts.buffer.[min | max]`
    * `bondy.api_gateway_https.socket_opts.buffer.[min | max]`
    * `bondy.admin_api_http.socket_opts.buffer.[min | max]`
    * `bondy.admin_api_https.socket_opts.buffer.[min | max]`
* Minor fixes and Log improvements

## 1.0.0-rc.36
* Migration to Erlang OTP 27 (latest)
* Move `wamp` library as part of the umbrella as `bondy_wamp`
* New version of plum_db with solution to map key ordering encoding issue
  (using `deterministic` option in call to `term_to_binary/2`)
* WS dynamic buffers via `bondy.conf` options
    * `wamp.websocket.buffer.[min | max]`

## 1.0.0-rc.35
* No changes from previous version

## 1.0.0-rc.34
## Changes
* It is now an error to open a session to a Realm when security is disabled and using an `authmethod` other than anonymous.

## Fixes
* #42 - error when authentication using anonymous when realm's security is disabled (additional case)

## 1.0.0-rc.33
## Fixes
* #41 - error when authentication using anonymous when realm's security is disabled

## 1.0.0-rc.32
* Updated Dockerfile
    * Removed deprecated libraries
    * Upgraded OS and Erlang/OTP versions
    * New multi-arch Github action

## 1.0.0-rc.31
* Removed support for OTP25
* Updated Github Actions

## 1.0.0-rc.30
## Fixes
* Fixed a memory leak caused by the uncleaned `bondy_session_counter` table, which was used for session-scoped WAMP ID generation in the HTTP API Gateway. The new implementation uses random numbers for HTTP API Gateway requests instead of maintaining a counter. All logic related to WAMP message ID generation has been consolidated in the bondy_message_id module. Counters are not only used for WAMP sessions.


## 1.0.0-rc.29
## Changes
* Changed the `bondy_session_manager` pool worker selection to use the Session
 Id as opposed to the realm to distribute load evenly when a single realm is
 used

## Fixes
* Fixed sending a GOODBYE message only when session is close by the Router.


## 1.0.0-rc.28
## Fixes
* Upgraded `plum_db` with a fix to a bug causing a partition a crash when
  forcing a partition hashtree reset
* Upgraded `observer_cli` and `prometheus` dependencies
* Remove unused `bear` dependency

## 1.0.0-rc.27
## Changes
* Moved json encoding to `bondy_json` module which now uses the new `json` moduled instead of `jsone` when running on OTP27. In addition, float and date formatting has been implemented to mirror those existing in `jsone`. Also the defaul float format respects the deprecated `jsx` lib format for backwards compatibility.
* A new option `serializers.json.float_format` has been added to `bondy.conf` that takes a string representation of the options supported by `erlang:float_to_bionary/2`.
* **NOTICE**: This only affects HTTP Gateway JSON encoding at the moment and not WAMP. This will be addressed in the next release.

## 1.0.0-rc.26
### Fixes
* Fixed bug in password hash comparison for version 1.0 passwords (PR #40)

## 1.0.0-rc.25
### Changes
* Removed `enacl` and `pbkdf2` libraries, replacing its funcionality with
  Erlang's `public_key` and `crypto` applications for password hashing and WAMP
  Cryptosign.
* Upgraded several dependencies
**BREAKING CHANGE NOTICE**
* As a result of `enacl` removal we have temporarily retired support for the `argon2` algorithm until we finish an implementation via Rustler.

### Fixes
* Fixes a bug in `bondy_rbac:conca_role` function that affected the RBAC APIs.

## 1.0.0-rc.24
* Upgraded PlumDB and Partisan with fix to avoid partisan_plumree_brodcast to crash when the behaviour implementors raise an exception
* Fixes to Debian dockerfile
## 1.0.0-rc.23
### Changes
**BREAKING CHANGE NOTICE**
* This version replaces Leveldb with Rocksdb - Rocksdb storage is incompatible with Leveldb so if you rely on Bondy storing real information (realms, users, groups, grants, etc), you will need to export/import them using the `bondy.backup.create` and `bondy.backup.restore` WAMP procedures.
* Bug fix in `bondy_registry_entry:dirty_delete/1`

## 1.0.0-rc.22
* Fix CI for OTP26 docker variant

## 1.0.0-rc.21
### Fixed
* Fix checking user credentials changes in `on_merge` (#31)
* Fixes several bugs reported in #30:
    * Missing `authroles` in WAMP context for Oauth2 flow
    * Pattern matching exception in Bondy Dealer where the atom `no_proc` was wrongly used instead of `noproc`
    * Fix in bondy Oauth2 un be able to handle undefined as a "token_type" in the  `revoke_token` operation

## 1.0.0-rc.20
* Drop Min OTP version to OTP25 and CI workflow to publish Bondy build with OTP25 and OTP26

## 1.0.0-rc.19
* Upgrade Dockerfile to OTP 26.2.5 to avoid memory-related bugs in BEAM

## 1.0.0-rc.18
* Downgrade to OTP 26.2.2 to avoid issue with cgroups cpu_quota bug in 26.2.4 and avoid memory crash issue with 26.2.3 until 26.2.5 is released.

## 1.0.0-rc.17
### Fixed
* Fixes a bug when synchronising legacy formatted data

## 1.0.0-rc.16
### Fixed
* Bug introduced `1.0.0-rc.15` on JWT parsing

## 1.0.0-rc.15

### Added
- Partisan forwarding guarantees configuration.
   - `router.forward.ack`
   - `router.forward.retransmission`
   - `bridge.forward.ack`
   - `bridge.forward.retransmission`

### Changed
- Until Partisan gurantees are provided by a more scalable backend we are disabling them by default by removing the previosuly hardcoded configuration and defining the following `bondy.conf` options defauls
   - `router.forward.ack = on|off`
   - `router.forward.retransmission = on|off`
   - `bridge.forward.ack = on|off`
   - `bridge.forward.retransmission = on|off`
   -

### Fixed
- Fixed a bug that occured in `bondy_rpc_laod_balancer` when entries are empty

## 1.0.0-rc.14

### Added
* Support for TCP/TLS proxy protocol and HTTP equivalent via headers
  `forwarded`, `x-real-ip`, `x-forwarded-for`. The algorithm searches for
  the presence of headers in that order and chooses the first Private IP found,
  returning the first IP Address if none are private.
    * New config options to enable/disable it
        * `wamp.tcp.proxy_protocol`
        * `wamp.tls.proxy_protocol`
        * `admin_api.http.proxy_protocol`
        * `admin_api.https.proxy_protocol`
        * `api_gateway.http.proxy_protocol`
        * `api_gateway.https.proxy_protocol`
        * `bridge.listener.tcp.proxy_protocol`
        * `bridge.listener.tls.proxy_protocol`
        * Default: `off`
    * New config options to define whether to reject connections when a
    `source_ip` address cannot be obtained from the proxy (`strict`) or
    fallback to the local IP address (`relaxed`).
        * `wamp.tcp.proxy_protocol.mode`
        * `wamp.tls.proxy_protocol.mode`
        * `admin_api.http.proxy_protocol.mode`
        * `admin_api.https.proxy_protocol.mode`
        * `api_gateway.http.proxy_protocol.mode`
        * `api_gateway.https.proxy_protocol.mode`
        * `bridge.listener.tcp.proxy_protocol.mode`
        * `bridge.listener.tls.proxy_protocol.mode`
        * Default: `relaxed`



### Fixes
* Fix bug in WAMP procedure `bondy.oauth2.token.revoke`
* Re-establish support for HTTP `x-forwarded-for` and `x-real-ip` headers
* Fixed logger formatter so that metadata values for keys not included in the
  template are included as part of the message.

## 1.0.0-rc.13
* Fixes #28 - default configuration value for Bridge Relay produces a crash. This happened because some of the Bridge Relay options in the schema were using `default` as opposed to `commented`. The result was an invalid configuration for a Bridge relayed called `name` when this should be empty.

## 1.0.0-rc.12

### Fixes
* Fixes #24 - missing command in Makefile target

### Changes
* Upgrades PlumDB to latest

## 1.0.0-rc.11

### Changes
* Upgrades Partisan to latest
* Upgrades OTP to latest

## 1.0.0-rc.10

### Fixes
* Fixes trying to restore non expired OAUTH2 refresh tokens based on its expiration time (issued at + expires in) from an old backup (tested case `0.41.6` version).

## 1.0.0-rc.9

### Fixes
* Fixes bug in enacl dependency via a fork

## 1.0.0-rc.8

### Fixes
* Fixes bug in authentication when migrating from Bondy version =< 0.8
* Change in Backup restore to avoid restoring and migrating expired OAUTH2 refresh tokens

## 1.0.0-rc.7
* Updated Docker image base OS version to match those of the new OTP26 images

## 1.0.0-rc.6
#### Fixes
* Upgrade Partisan with fixes to fast forward which was not working

## 1.0.0-rc.5
#### Fixes
* Upgrade PlumDB with fixes to hashtree encoding on OTP26
* PlumDB no creates a manifest will be used in the near future to enable database migration

## 1.0.0-rc.4
### Changes
* New config params `cluter.peer_ip` and `cluster.listen_addresses` based on updated Partisan

## 1.0.0-rc.3

### Changes
* Added support for IPv6 across all listeners
* Fixed port validaros accepting full port range (as opposed to previous rule which prescribed system ports)
* Added marketplace demo realm for testing
* Added Fly deployment
* Added dnsutils to Dockerimage
* Upgraded Partisan with support for IPv6 in DNS discovery.

```erlang
cluster.peer_discovery.type = dns
cluster.peer_discovery.config.record_type = aaaa
cluster.peer_discovery.config.nameservers.1 = fdaa::3
cluster.peer_discovery.config.query = bondy.internal
cluster.peer_discovery.config.node_basename = bondy
```

## 1.0.0-rc.2

### Changes
* The peer discovery capabilities was moved from bondy to Partisan. The interface remains very similar. The following two examples show how to configure the `list` and `dns` strategies in `bondy.conf`

```erlang
cluster.peer_discovery.enabled = on
cluster.peer_discovery.initial_delay = 10s
cluster.peer_discovery.polling_interval = 10s
cluster.peer_discovery.timeout = 5s
cluster.peer_discovery.type = list
cluster.peer_discovery.config.addresses = [127.0.0.1:18086]
```

```erlang
cluster.peer_discovery.enabled = on
cluster.peer_discovery.initial_delay = 10s
cluster.peer_discovery.polling_interval = 10s
cluster.peer_discovery.timeout = 5s
cluster.peer_discovery.type = dns
cluster.peer_discovery.config.record_type = fqdns
cluster.peer_discovery.config.query = bondy.internal
cluster.peer_discovery.config.node_basename = bondy
```

#### Fixes
* This revision addresses an issue in the Active Anti-Entropy (AAE) implementation of PlumDB and the latest version of Erlang/OTP. In the latest version of Erlang, the binary serialization of terms is not deterministic by default, causing the AAE merkle tree to compute different values for the same object in different nodes. As a result, the AAE sync continuously exchanges terms that are actually the same.


## 1.0.0-beta

### Added
 * Pattern matching now supports wildcards
 * Pattern-based Registration

#### General
* Upgraded to OTP 24

#### Security
* WAMP Cryptosign authentication
* WAMP Ticket-based authentication
* Same Sign-on and Single Sign-on (SSO Realms)
* Realm Prototypes
* Added libsodium (enacl lib)

#### Bondy Edge (EXPERIMENTAL)

* New Bridge Relay connection allows to link an edge router to a core/remote router. This syncs (at the moment) a single realm and forwards procedures and subscriptions to the remote.

### Fixed
* Fixes group ordering issue in processing of security (realm) configuration files.
    - bondy_realm topological ordering of groups within each realm according to their group membership relationship. If any cycles are found amongst groups, an error is raised.
    - Existing groups referred by name in the group's 'group' property are not fetched, so cycles might still be created once the new groups are stored on the database.
* Fixes a concurrency issue with busy clients, in particular when they end up calling themselves. This was produced by an unnecessary used of internal acknowledgments which have been removed
* Fixes the following issues: #6, #7, #8

### WAMP
* Erlang encoding now enforces WAMP-compatible data structures and tries to convert certain types e.g. pids while it fails with others.

### Changed
* Realm database representation
* User database representation
* Error types and description improvements
* Logging improvements
* Removed high cardinality labels in promethues metrics (before we would tag each WAMP message stats with realm, session, message type etc. this is not good for stats databases like Promethues).
* Added RBAC context caching to avoid computing the user grants on every request.
* Tickets database location: The location of the tickets changes on beta.64 onwards

## Known Issues

#### Security
* The RBAC context cache is not evicted or refreshed when a user is assigned to new realms or granted new permissions.

## 0.9.0
### Added

* `bondy.subscription.list` procedure
* First verstion of Retained messages
* Added a non-standard WAMP Authentication method `oauth2` based on OAuth2 JWT Tokens
    - Is equivalent to WAMP-Ticket authentication method but expects the secret to be a JWT produced by Bondy OAuth2
    - `authid` property value needs to be present and needs to match the JWT’s `sub` property value
* Added Bondy specific load balancing strategies through the standard  `REGISTER.Options.invoke` option:
    - queue_least_loaded
    - quede_least_loaded_sample
    - jump_consistent_hash (MUST not be used as this is experimental and the implementation will change with upcoming definitions from WAMP Specification)
* Added support for WS compression
    - now supports permessage-deflate websocket extension and enabled by default
    - added configuration option `wamp.websocket.compression_enabled`
    - added configuration option `wamp.websocket.deflate.level`
    - added configuration option `wamp.websocket.deflate.mem_level`
    - added configuration option `wamp.websocket.deflate.strategy`
    - added configuration option `wamp.websocket.deflate.server_context_takeover`
    - added configuration option `wamp.websocket.deflate.client_max_window_bits`
    - added configuration option `wamp.websocket.idle_timeout`
    - added configuration option `bondy.wamp_websocket.max_frame_size`
    - Not working with Mozilla as it seems to be sending a corrupted PING message

### Fixed

* Minor WAMP protocol fixes
* Several bug fixes during removal of an API Specification
    - Removal did not rebuilt the web server dispatch tables and thus the API removed was still active until reboot.
* Cleanup of session data when web server processes crash abnormally

### Changed
* Upgraded to Erlang 23
* Security data structures
* Security methods (more methods added and a clear distinction between 'anontmous' and 'trust')

## 0.8.8
### Added

* API Gateway
    * The API specification body object now supports any external-friendly data type e.g. erlang tuples, pids, references excluded.
    * Fixes a bug in the validation of the response body which failed in case the body was not a MOPS expression, a binary or map. Now all external-friendly types are allows e.g. numbers, booleans, strings, binaries, maps, lists and MOPS expressions. This allows to return static content i.e. not a result of evaluating a MOPS expression in any given type of action.
    * Upgraded MOPS which has better error reporting and support for a new function `random(N)` which returns N random members from a list. If the value random is applied is static, this will yield the same results on every request.

### Fixed

* API Gateway
    * Minor fixes to enhance error handling and logging
    * Fixed a case where an invalid API Specification can crash the gateway process during startup
* Configuration
    * Fixed an error in which private/default lager configuration would override user configuration (bondy.conf)
    * OAuth2
        * Fixed a bug on the removal of refresh token indices during refresh token revocation.
* Clustering
    * Fixed missing handler for WAMP ERROR(CALL) messages forwarded by a peer node

### Changed

* Configuration
    * The WAMP raw socket serialiser slot assignment is now configurable. Bondy provides Erlang (erl) and BERT serialisers in addition to JSON and Messagepack. This change allows the user to configure to which of the 13 available slots (3..15) are those serialisers mapped to.



## 0.8.7

### Added

- Added a controlled phased startup process
  - Bondy now starts in phases allowing to block on several steps using configuration parameters. The main benefit is to avoid starting up the WAMP client socket listeners before several subsystems have finish initialisation and/or some processes have been completed.
    - `startup.wait_for_store_partitions` - controls whether to block further stages until all db partitions have been initialised, this includes loading all data into those entities stored in ram and disk. Default is `on`.
    - `startup.wait_for_store_hashtrees` - defines whether Bondy will wait for the db hashtrees to be built before continuing with initialisation. Default is `on`.
    - `startup.wait_for_store_aae_exchange` - Defines whether Bondy will wait for the first active anti-entropy exchange to be finished before continuing with initialisation. These only works if Bondy is part of a cluster i.e. when Peer Discovery and Automatic Cluster join is enabled.
  - The Bondy Admin HTTP API listeners are started as soon as the store partitions and other subsystems are initialised. This allows for liveness probes to be able to check on Bondy and/or admin users to inspect and/or operate while the other phases are running.

### Fixed

- Several fixes to Security Configuration file format
  - `sources.usernames` now takes a string "any" of a list of usernames, including "anonymous"
  - `grants.roles` now takes a string "any" of a list of rolenames, including "anonymous"

## 0.8.6

- First implementation of Peer Discovery and Automatic Cluster join.
  - Implementation of DNS srv based discovery tested to work with Kubernetes DNS
- Finished Bondy Broker schema specification
- Added authorization controls for all WAMP verbs (register, unregister, call, cancel, publish, subscribe and unsubscribe). Authorization is managed by the existing Security subsystem which now can be configured using JSON files defined in the bondy.conf file (in addition to the WAMP and HTTP/REST APIs).
- Fixed WAMPRA (with salted password) authentication method.
  - This requires a rehash of the existing passwords. If you are migrating from an existing Bondy installation, the migration occurs lazily on the new user login (as we need the user to provide the password for Bondy to be able to rehash, as Bondy never stores clear text passwords).
- Refactoring of configuration via bondy.conf
  - Removed legacy config options,
  - Renamed a few a config options and introduced new ones to support static configuration via JSON files and new features like Peer Discovery and Automatic Cluster join.

## 0.8.2

- Migration to OTP 21.3 or higher.
- Upgraded all dependencies to support OTP 21

## 0.8.1

This version includes a complete redesign of event management and instrumentation.
The new `bondy_event_manager` is now the way for the different subsystems to asynchronously publish events (notifications) and offload all instrumentation to event handlers:

- `bondy_promethues` is an event handler that implements all promethues instrumentation
- `bondy_wamp_meta_events` is an event handler that selectively re-published bondy events to WAMP Meta events.

### New Modules

- `bondy_event_manager` implements a form of supervised handlers similar to lager (logging library), by spawning a "watcher" processes per handler (module) under a supervision tree and restarting it when it crashes.

- `bondy_alarm_handler` replaces sasl’s default alarm_handler.

### Deprecated Modules

`bondy_stats` containing legacy exometer instrumentation was removed.

## 0.8.0

This version introduces an incompatibility with previous versions data storage. If you want to upgrade an existing installation you will need to use the bondy_backup module's functions or the Admin Backup API.

- Upgrade to plum_db 0.2.0 which introduces prefix types to determine which storage type to use with the following types supported: ram (ets-based storage), disk (leveledb) and ram_disk(ets and leveldb).
    - Registry uses `ram` storage type
    - All security resources use `ram_disk` storage type
    - Api Gateway (specs) and OAuth2 tokens use `disk` storage type
- Handling of migration in bondy_backup. To migrate from v0.7.1 perform a backup on Bondy v0.7.1 and then restore it on Bondy v0.7.2.

## 0.7.1
- New Trie data structure for bondy_registry
    - Bondy now uses Leapsight's `art` library to implement the registry index structure use to match RPC calls and PubSub subscriptions. `art`  provides a single-writter, multi-reader Radix Trie following the Adaptive Radix Tree algorithm. The implementation uses one gen_server and one ets table per trie and currently supports WAMP `exact` and `prefix` matching strategies. `wildcard` matching support is on its way.
- Internal wamp subscriptions
    - We have implemented a first version of an internal WAMP subscription so that Bondy internally can subscribe to WAMP events. This is done through new functions in bondy_broker and the new module bondy_broker_events
- OAuth 2 Security
    - Major changes to security subsystem including harmonisation of APIs, deduplication and bug fixes.
    - Use new internal wamp subscriptions to avoid coupling Bondy Security with Bondy API Gateway & OAuth.
        - Bondy Security modules publishe wamp events on entity actions e.g. user creation, deletion, etc.
        - Bondy API Gateway modules and bondy_api_gateway_client subscribe to the user delete events to cleanup OAuth tokens
    - Fixed a bug where internal security operations will not trigger token revocation.
        - Bondy API Gateway modules, i.e. are now implemented by calling Bondy Security modules e.g. bondy_security_user instead of calling bondy_security (former Basho Riak Core Security) directly. This will help in the refactoring of bondy_security and in addition all event publishing is centralised in bondy_security_user.
        - Implemented additional index for tokens to enable deletion of all users’ tokens
        - Added two db maintenance functions to (i) remove dangling tokens and (ii) rebuild the indices on an existing db
    - Added additional Internal wamp events to subsystems e.g. bondy_realm and bondy_backup

## 0.7.0

- Clustering
    - Completion of clustering implementation using partisan library (at the moment supporting the default peer service only, hyparview to be considered in the future)
    - bondy_router can now route WAMP messages across nodes. The internal load balancer prefers local callees by default, only when a local callee is not found for a procedure the invocation is routed to another node. Load balancer state is local and not replicated. Future global load balancing strategies based on ant-colony optimisation to be considered in the future.
    - `bondy-admin` (bondy_cli) implementation of cluster management commands (join, leave, kick-out and members)
- Storage and Replication
    - new storage based on plum_db which
        - uses lasp-lang/plumtree and lasp-lang/partisan to support data replication
        - provides more concurrency than plumtree and removes the capacity limitation imposed by the use of dets
- API Gateway
    - API Specs are replicated using plum_db. A single bondy_api_gateway gen_server process rebuilds the Cowboy dispatch table when API Spec updates are received from other nodes in the cluster (using plum_db pubsub capabilities)
- Registry
    - The registry entries are replicated using plum_db. This is not ideal as we are using disk for transient data but it is a temporary solution for replication and AAE, as we are planning to change the registry by a new implementation of a trie data structure at which point we might use plumtree and partisan directly avoiding storing to disk.
    - A single bondy_registry gen_server process rebuilds the in-memory indices when entry updates are received from other nodes in the cluster (using plum_db pubsub capabilities)
- bondy_backup
    - A new module that allows to backup the contents of the database to a file, and restore it.
    - Allows to migrate from previous versions that use plumtree (dets) to plum_db

## 0.6.6

- General
    - Removed unused modules
    - Minor error description fixes
    - Code tidy up
- Dependencies
    - cowboy, hackney, jsx, sidejob, promethus, lager and other dependencies upgraded
- Oauth2
    - Revoke refresh_token
    - Added client_device_id optional parameter for token request which will generate an inde mapping a Username/ClientDeviceId to a refresh_token to enabled revoking token by Username/ClientDeviceId.
    - JWT.iat property using unix erlang:system_time/1 instead of erlang:monotonic_time/1 (as users might want to use this property)
    - Token expiration is now configured via cuttlefish
- API Gateway
    - JSON errors no longer include the status_code property (this was redundant with HTTP Status Code and were sometimes inconsistent)
    - Added http_method in forward actions to enable transforming the upstream HTTP request method e.g. a GET can be transformed to a POST
    - API Gateway Spec now allows to use a mop expression for WAMP procedure URIs
    - New mops functions: min, max and nth on lists (equivalent to the lists module functions)
- Testing
    - Fixed mops suite bugs
    - Added oauth2 refresh_token CRUD test case, covering creation, refresh and revoke by token and by user/client_device_id

## 0.6.3

* Upgraded Cowboy dependency to 2.1.0
* Upgraded promethues_cowboy to latest and added cowboy metrics to prometheus endpoint
* Minor changes in function naming for enhanced understanding
* Minor fixes in options and defaults
