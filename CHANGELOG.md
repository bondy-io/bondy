# CHANGELOG
## 1.0.0

### Action required
* Upgrading from a pre-release that carries `bondy_db` (for example `1.0.0-rc.olive` or `1.0.0-rc.pear`) requires stopping every node and starting them all on this release. See [Upgrading from the bondy_db pre-releases](doc/guides/configuration/upgrading_from_bondy_db_prereleases.md).
* Upgrading from `1.0.0-rc.65` requires a new cluster: PlumDB data is not readable by this release. See the [migration guide](doc/guides/configuration/migrating_from_1.0.0-rc.65.md).
* A single-node deployment must set `cluster.enabled = off`; with `on` and no other member, compaction, reclamation, origin retirement and the authentication freshness fence hold. See [Clustering](doc/guides/configuration/clustering.md#running-a-single-node).
* Listeners are declared under `listeners.$name.*`; the fixed per-scheme listener keys are removed, and every enabled `tls` listener must state its certificate. See [Listeners](doc/guides/configuration/listeners.md#migrating-from-the-pre-10-keys).
* `listeners.$name.linger.timeout` is in seconds; a value written with a unit suffix changes meaning (`scripts/migrate_conf.escript check` reports it). See [Listeners](doc/guides/configuration/listeners.md).
* Renamed or removed `bondy.conf` keys: `wamp.transport_queue.*` → `wamp.http_transport.*`; the global `wamp.{websocket,sse,longpoll}.*` blocks, the thirty `wamp.broker.*`/`wamp.dealer.*` feature keys, `wamp.dealer.pattern_based_registration`, `wamp.broker.pattern_based_subscription`, `store.*`, `oplog.core.scan_max_concurrency` and `db.compaction.peer_timeout` are removed; `rpc_gateway.*` is `http_connector.*`. `scripts/migrate_conf.escript` reports and rewrites them.
* `advanced.config` stanzas for the router move from `{bondy, …}` to `{bondy_router, …}`, and remote-console module names changed. See the [migration guide](doc/guides/configuration/migrating_from_1.0.0-rc.65.md).
* A custom `bondy_oplog_cache_adapter` must implement `ticket/1` and `fill/5` in place of `put/4`.

### New Features
* New storage and replication stack replacing PlumDB/RocksDB: `bondy_db` on `bondy_oplog` and the vendored `bondy_mst`. See [Database architecture](doc/guides/architecture/db_architecture.md) and [Database options](doc/guides/configuration/database_options.md).
* Op-based CRDT convergence per table, with per-cell hybrid logical clocks. See [Convergence](doc/guides/database/convergence.md).
* Deletion with causal-stability tombstone reclamation and origin retirement, both on by default. See [Deletion and reclamation](doc/guides/database/deletion_and_reclamation.md) and [Reclamation options](doc/guides/configuration/reclamation_options.md).
* Authentication freshness fence (`db.aae.fence.*`). See [Database options](doc/guides/configuration/database_options.md).
* Replicated security reactions: a credential change or user deletion on one node closes the user's sessions on every node; the `[bondy, aae, merge_conflict]` event. See [Replicated security state](doc/guides/security/replicated_security_state.md).
* Group membership stored as one replicated fact per (user, group).
* Summary-based registry routing (RIB). See [Registry routing](doc/guides/router/registry_routing.md).
* Progressive Call Results and Progressive Calls, including across cluster nodes. See [Progressive call results](doc/guides/router/progressive_call_results.md) and [Progressive calls](doc/guides/router/progressive_calls.md).
* `CALL.Options._deadline` caps a whole call. See [WAMP features](doc/guides/router/wamp_features.md).
* Optional encryption at rest of realm private keys (`security.master_key.*`, off by default). See [Realm key encryption](doc/guides/security/realm_key_encryption.md).
* HTTP/2 on every `http` listener. See [Listeners](doc/guides/configuration/listeners.md#http-versions).
* Operator-defined listeners (`listeners.$name.*`), validated at boot. See [Listeners](doc/guides/configuration/listeners.md).
* `bondy.listener.suspend` and `bondy.listener.resume` take a node out of rotation and back. See [Listeners](doc/guides/configuration/listeners.md#taking-a-node-out-of-rotation).
* `scripts/migrate_conf.escript` checks and rewrites a `bondy.conf`. See [Checking your configuration](doc/guides/configuration/checking_your_configuration.md).
* One error payload for every transport. See the [error catalogue](doc/guides/reference/error_catalogue.md).
* `cluster.enabled = off` runs a node without clustering; it compacts and reclaims on its own frontier. New error `bondy.error.cluster_disabled` (`K004`). See [Clustering](doc/guides/configuration/clustering.md).

### Security
* Inbound rate limiting (`security.rate_limit.*`, off by default). See [Load regulation and rate limiting](doc/guides/configuration/load_regulation_and_rate_limiting.md).
* Forwarding headers are honoured only from a trusted proxy. See [Listeners](doc/guides/configuration/listeners.md#proxy-protocol-and-forwarded-headers).
* A node with peer discovery enabled refuses to start on an insecure cluster peer plane unless `cluster.tls.allow_insecure = on`. See [Cluster peer plane](doc/guides/security/cluster_peer_plane.md).
* Fixed ticket scope normalisation on decode, so stored tickets are found by lookup.
* A revoked ticket kept authenticating under the default `security.ticket.allow_not_found = on`. Revocation now replicates to every node, and `bondy.ticket.revoke` revokes a ticket. See [Authorization](doc/guides/security/authorization.md#ticket-revocation).
* `security.master_key.id` accepts only 0 to 65535.
* Fixed: a claim-restricted (for example OIDC) session received the grants of the user's locally stored group memberships. See [Authorization](doc/guides/security/authorization.md).
* WAMP URI validation rejects control characters, and realm URIs with NUL bytes are refused.
* Cowboy 2.18.0 and cowlib 2.19.0. See [Listeners](doc/guides/configuration/listeners.md#request-validation).

### Improvements
* Built and shipped on Erlang/OTP 29; OTP 28 still builds the tree. See [Runtime requirements](doc/guides/deployment/runtime_requirements.md).
* New `listeners.$name.http.*` options: `max_authorization_header_value_length`, `max_cookie_header_value_length`, `max_authority_length`, `invalid_response_headers`, `max_concurrent_streams` and `max_cookies`. See [Listeners](doc/guides/configuration/listeners.md#request-limits).
* Prometheus metrics for the storage stack, the router and the BEAM, and a bundled Prometheus and Grafana stack under `monitoring/`. See [Metrics](doc/guides/reference/metrics.md).
* `bondy_http_connector` metrics, dashboard and per-service liveness probe. See [HTTP connector](doc/guides/configuration/http_connector.md).
* `bondy_export` import writes in batches.
* `rebar3 ex_doc` builds the reference documentation again.
* Reading the cluster membership no longer blocks on Partisan's peer-service manager.
* Compaction held back by a member is reported as a trigger outcome and a "GC stalled" warning; `bondy_oplog_gc_scheduler_events_total` gains a `scheduler` label. See [Reclamation options](doc/guides/configuration/reclamation_options.md) and [Log messages](doc/guides/reference/log_messages.md).
* A refused snapshot install (`source_behind_truncation`) logs what to do. See [Clustering](doc/guides/configuration/clustering.md).
* New metric `bondy_oplog_core_range_pages_total`. See [Metrics](doc/guides/reference/metrics.md).

### Performance
* A database's shards open concurrently, and write-ahead-log recovery reads in larger chunks.
* Durable pack sealing runs off the apply path (`db.pack_seal_mode = async`, default), with a smaller seal threshold (`db.pack_auto_seal_bytes`). See [Database options](doc/guides/configuration/database_options.md).
* The in-memory registry's cell sweep resumes from its cursor instead of re-reading the whole cell directory on every batch.

### Fixes
* `bondy_db:close/1` closes every table still open on the DB. A table left open at close kept its index-shard registry rows on a dead projection handle, and the next restart of the index writers' supervisor took the oplog application down.
* A power loss could undo renames in the durable stores; `platform_data_dir` must accept `fsync` on a directory. See [Platform directories](doc/guides/deployment/platform_directories.md).
* A read could keep returning a value a later write had replaced.
* A node whose `main` database opened slowly failed its liveness probe and was restarted in a loop. See [Listeners](doc/guides/configuration/listeners.md#health-probes).
* A storage shard whose processes crashed repeatedly stayed down until the node restarted. See [Platform directories](doc/guides/deployment/platform_directories.md#when-a-storage-shard-stops).
* After an applier crash, a shard of `main` stopped applying writes.
* A node could create several replica origins at once.
* An in-VM client's registrations and subscriptions kept routing after it disconnected.
* Over HTTP long-poll, a router `ABORT` or `GOODBYE` never reached the client.
* A WAMP session over HTTP long-poll or SSE could receive messages out of order. See [Listeners](doc/guides/configuration/listeners.md#node-wide-http-transport-queue).
* An outbound bridge relay with no `ping` block crashed, and one with no `reconnect` block never reconnected. See [Bridge relay](doc/guides/configuration/bridge_relay.md).
* The error formatter could crash on some reasons.
* A malformed WAMP `ABORT` reason crashed the connection handler.
* Building `WWW-Authenticate` raised `badarg` for atom error codes.
* The HTTP API Gateway put raw `hackney` reasons and unrendered upstream errors into response bodies.
* HTTP long-poll errors had an empty body.
* Two WAMP-error-to-HTTP-status tables disagreed; there is one.
* `bondy_regulator` dropped its error details.
* `format_error/2` in `bondy_mst` and `bondy_registry` crashed when `error_info` had no `cause`.
* `bondy_connect_humanized:join/1` mishandled two items and a single non-iodata item.
* `?WAMP_FEATURE_NOT_SUPPORTED` expanded to `wamp.error.no_available_callee`.
* `rebar3 dialyzer` failed on a removed warning option.
* `CANCEL` was dropped when the callee was on another node. See [WAMP features](doc/guides/router/wamp_features.md).
* Cross-node calls lost their per-procedure latency metrics and checked `CANCEL` authorisation against no procedure.
* Invocations whose caller session died kept running until their timeout.
* `bondy_session_duration_seconds` and `bondy_socket_duration_seconds` recorded every observation in the lowest bucket.
* Cold boot after an unclean shutdown could lose the tail of a shared write-ahead log.
* Stopping a node destroyed its durable MST history.
* The MST pack store could persist a root before its pages.
* A freshly bootstrapped node reported divergence indefinitely.
* Re-applying the same `security` configuration at boot generated replicated writes.
* Every boot regenerated and re-replicated realm signing keys.
* Setting `listeners.$name.http.buffer.min/max` disabled dynamic buffering.
* A ping block without `ping.enabled` killed every connection on the listener.
* A TLS listener that set one security header lost its default HSTS header.
* An API Gateway specification's `host` was ignored.
* Bondy's own HTTP paths were unreachable on hosts a specification named.
* A stored specification reusing a built-in path aborted the dispatch rebuild.
* A listener naming an unimplemented carrier failed late, without naming the listener.
* `listeners.$name.linger.timeout` written with a unit suffix was read as milliseconds.
* Raw-socket and bridge-relay listeners sent no keepalive probes; a dead peer is now dropped after three unanswered probes on every protocol.
* Idle raw-socket and bridge-relay connections were never reaped.
* The raw-socket keepalive fired on the idle-reap timer and closed connections instead of probing them.
* HTTP listeners other than `admin` ran on Cowboy's `active_n` and idle-timeout defaults instead of Bondy's.
* TLS HTTP listeners sent no HSTS header.
* Bondy's own procedures and subscribers could not read JSON or CBOR payloads.
* A Payload Passthru call to one of Bondy's own procedures crashed instead of failing.
* Over CBOR, every string was sent as a byte string. See [Serialisation](doc/guides/introduction/wamp.md#serialisation).
* `bondy_connect_sdk` gave up after a router `GOODBYE`, and retried failed connections without backoff.
* An outbound bridge relay crashed on a socket error while sending its `HELLO`.
* The Kafka bridge's `encoding = erl` raised `badarg` on every message.
* A write that re-created a reclaimed projection cell failed with `context_regression`.
* A member partitioned or down for longer than 30 s could lose writes to compaction. See [Convergence](doc/guides/database/convergence.md).
* A re-bootstrapping node could lose events it had compacted away.
* A re-bootstrap could leave a node missing events, or holding deleted values, while it reported itself in sync. See [Convergence](doc/guides/database/convergence.md#re-bootstrap).
* A re-bootstrapping or just-restarted replica could serve data that did not match the frontier it advertised.
* A removed set or map entry, or a disabled flag, could come back after a re-fold.
* An event held for a sequence gap could stay unapplied after a compaction.
* Two causes of needless full re-bootstraps.
* The oplog could commit `consumer.offset` past an MST root that was not durable.
* Paging through a table could stop early after a run of deleted entries.
* Reopening after a crash during a pack seal could delete the sealing file on a transient error.
* A write whose WAL writer died mid-append was reported as not written.
* `bondy_db:close_table/1` could lose index updates.
* The log line listing loaded realms printed `a, b` instead of their URIs.
* A raw-socket listener's `idle_timeout` never closed an idle connection, and a bridge-relay listener's closed live ones; both now close a connection whose peer has sent nothing for `idle_timeout`. See [Listeners](doc/guides/configuration/listeners.md).
* A bridge relay's reconnect budget ended 30 seconds after the first failure, whatever `reconnect.max_retries` said, and a send failure while forwarding or pinging stopped the client instead of reconnecting. See [Bridge relay](doc/guides/configuration/bridge_relay.md).
* Removing a running bridge relay failed and left it running.
* A CALL whose options the load balancer refused was answered `wamp.error.no_such_procedure` instead of `wamp.error.invalid_argument`, and an ERROR the router raised for a Payload Passthru CALL copied its `ppt_*` options.
* A CANCEL in `kill` or `killnowait` mode sent INTERRUPT to a callee that had not announced `call_canceling`. Such a cancel now acts as `skip`, on the callee's node as well as locally. See [WAMP features](doc/guides/router/wamp_features.md).
* `bondy_cluster_channel_connections` was exported by two collectors in one scrape, which a strict Prometheus parser rejects. See [Metrics](doc/guides/reference/metrics.md).
* A `registry` shard staged a catalogue install under `/tmp` rather than `platform_tmp_dir`. See [Platform directories](doc/guides/deployment/platform_directories.md#install-spool).
* `scripts/migrate_conf.escript` called four WAMP features unimplemented or implemented contrary to what the build advertises; its self-test now checks every reason against the build.
* A departed node's registrations and subscriptions were never reclaimed on a cluster with two or more surviving members.
* A departed node's registrations and subscriptions survived retirement once the survivors had compacted their registry history.
* A node or index writer that stopped between a durable write and its index updates lost those updates.
* Reading a durable cell while its first write landed could crash the reader with `badarg`: the projection's HEAD read fell back from the value column to the state column between two store calls. It now reads the one column the cell's fold writes.

### Changes
* MessagePack is encoded and decoded by Bondy's own `bondy_msgpack`; four behaviours change for MessagePack clients. See [Serialisation](doc/guides/introduction/wamp.md#serialisation).
* WAMP broker and dealer features are build capabilities, not configuration; `payload_passthru_mode`, `progressive_calls` and `progressive_call_results` are advertised, `call_reroute` is not. See [WAMP features](doc/guides/router/wamp_features.md).
* Pattern-based registration and subscription are always on.
* A single security header can be switched off with `off`. See [HTTP security headers](doc/guides/configuration/http_security_headers.md).
* Changed listener log records: connection-threshold alarms, the drain notice, and the WebSocket idle close. See [Log messages](doc/guides/reference/log_messages.md).
* Two listeners may share a port when they bind different addresses.
* An HTTP listener with an empty `services` list is refused at boot.
* `api_gateway` and `admin_api` are separate carriers; registering an external carrier takes `bondy_router.http_services` and `bondy_router.http_carriers`.
* `wamp.error.not_authorized` maps to HTTP 403 and `wamp.error.authorization_failed` to 500.
* An API Gateway specification's `status_codes` overrides the built-in defaults at every level.
* `bondy_connect_sdk` reports a crashed callee handler as `bondy.error.internal_error`.
* The meta API reports inconsistencies as `bondy.error.inconsistency_error`.
* API Gateway request ids and error trace ids are W3C trace-ids. See the [error catalogue](doc/guides/reference/error_catalogue.md).
* The router application is `bondy_router`, and the RPC Gateway is `bondy_http_connector`.
* Requests with more than 100 query-string parameters or form fields are rejected.
* `listeners.$name.ip` takes a literal IP address.
* Compaction and reclamation wait for every member, on every database, to apply an event and checkpoint its frontier. See [Deletion and reclamation](doc/guides/database/deletion_and_reclamation.md#when-history-may-be-removed).
* The write-ahead log is its own application, `bondy_log`; `bondy_stdlib` is `bondy_connect_lib`.
* Renamed log messages: "Prefix-closure hold" is "Causal hold", and "Reclamation stalled" is "GC stalled".
* Removed metric `bondy_oplog_peer_exclusions_total`.
* `bondy_oplog_core:subscribe/2` accepts `all`, `{prefix, P}` and `{exact, K}` patterns; the `{match, F}` pattern is removed. A consumer `verify_event`, `refresh` or `publish_fun` callback that raises now crashes its caller instead of being logged.
* A peer must announce `call_canceling` in `HELLO` to obtain it; an omitted feature is no longer inherited from the router's advertised set.
* `bondy_cluster_channel_connections` is labelled by `peer` and `channel`.
* The authentication freshness fence counts only sync rounds; a local write no longer defers its refusal.
* Partisan 6.3.1, from 5.0.3.

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
* Fixes an issue with OIDC tokens containing roles unknown to Bondy

## 1.0.0-rc.56
### Fixes
* Fix set comparison on authroles calculation
* Add error logs for failed OIDC connections

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
* New `bondy.session.self` RPC that returns the caller's session information (useful when using cookie-based authentication as the cookie cannot be read by the client code).

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
- Upgraded to latest PlumDB which contains fixes to the RocksDB defaults (the previous values might cause issues due to excessive compaction)
- RocksDB can be configured via `bondy.conf` using `store.*` options.

## 1.0.0-rc.47
### Changes
- Implementation of JSON partial decoding/encoding for WAMP messages.
    - Bondy now decodes/encodes only the control message data (head of the WAMP message) preserving the payload (tail) in JSON format. This improves performance as the payload is never decoded unless a destination peer requires a different encoding. For networks using JSON end-to-end you should see important performance improvements.

## 1.0.0-rc.46
### Fixes
- Fixes a bug in the OAUTH2 rest handler which would prevent the `client_device_id` option to be considered when obtaining a new token. This was introduced with the new token subsystem. This issue limites the token scope to {realm, client} as opposed to {realm, client, device_id}.

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
- `bondy.ping` added to be used as connection heartbeats where the client doesn't
support transport level heartbeats e.g. Web Browser Websocket pings. The RPC replies a single positional argument `"pong"` and it is always authorised to be called by all sessions.

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
* Moved json encoding to `bondy_json` module which now uses the new `json` moduled instead of `jsone` when running on OTP27. In addition, float and date formatting has been implemented to mirror those existing in `jsone`. Also the default float format respects the deprecated `jsx` lib format for backwards compatibility.
* A new option `serializers.json.float_format` has been added to `bondy.conf` that takes a string representation of the options supported by `erlang:float_to_binary/2`.
* **NOTICE**: This only affects HTTP Gateway JSON encoding at the moment and not WAMP. This will be addressed in the next release.

## 1.0.0-rc.26
### Fixes
* Fixed bug in password hash comparison for version 1.0 passwords (PR #40)

## 1.0.0-rc.25
### Changes
* Removed `enacl` and `pbkdf2` libraries, replacing its functionality with
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
* Bug fix in bondy_registry_entry:dirty_delete/1

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
- Until Partisan guarantees are provided by a more scalable backend we are disabling them by default by removing the previously hardcoded configuration and defining the following `bondy.conf` options defaults
   - `router.forward.ack = on|off`
   - `router.forward.retransmission = on|off`
   - `bridge.forward.ack = on|off`
   - `bridge.forward.retransmission = on|off`
   -

### Fixed
- Fixed a bug that occurred in `bondy_rpc_laod_balancer` when entries are empty

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
* Removed high cardinality labels in prometheus metrics (before we would tag each WAMP message stats with realm, session, message type etc. this is not good for stats databases like Prometheus).
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

- `bondy_promethues` is an event handler that implements all prometheus instrumentation
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
