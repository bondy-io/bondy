# CHANGELOG

## 0.8.0
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
- Depencies
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