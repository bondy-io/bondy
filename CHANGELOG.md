# CHANGELOG

## 1.0.0-rc.38
* Refactoring of WAMP APIs (Modules renamed and consolidated)
* New WAMP APIs
    * `bondy.registry.list`
* New standard `CALL.Options`
    * `_disclose_session` - The callee will receive and the session information 
    in  `INVOCATION.Details._session_info`
    
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
* Bug fix in `bondy_resgistry_entry:dirty_delete/1`

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