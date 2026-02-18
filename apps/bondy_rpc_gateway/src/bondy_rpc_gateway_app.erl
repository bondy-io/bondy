%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rpc_gateway_app).

-moduledoc """
OTP application callback module for `bondy_rpc_gateway`.

The RPC Gateway bridges WAMP RPC procedures to external HTTP/REST services.
It allows Bondy to expose upstream HTTP APIs as WAMP procedures that clients
can call transparently, handling authentication, token caching, retries, and
error mapping automatically.

## How it works

1. **Service configuration** — services are declared in the application
   environment (`bondy_rpc_gateway.services`). Each service defines a target
   `base_url`, an authentication strategy (`auth_mod` + `auth_conf`), and a
   set of WAMP procedures mapped to HTTP method/path pairs.

2. **WAMP registration** — on startup the `bondy_rpc_gateway_manager` reads
   the service configs, resolves any external secrets, starts a dedicated
   HTTP connection pool per service, and spawns a `bondy_rpc_gateway_callee`
   per service/realm pair. Each callee registers its procedures with the
   Bondy Dealer so that WAMP clients can call them.

3. **Request flow** — when a WAMP client invokes a registered procedure the
   Dealer dispatches to `bondy_rpc_gateway_callee_handler`, which:
   - interpolates path template variables from the caller's kwargs,
   - routes remaining kwargs to query parameters (GET/DELETE/HEAD) or a
     JSON body (POST/PUT/PATCH),
   - acquires an auth token via the shared token cache,
   - forwards the request to the upstream service,
   - automatically retries on transient failures with exponential backoff,
   - invalidates the token and retries once on 401/403 responses,
   - maps the HTTP status to a WAMP result or error.

4. **Token caching** — `bondy_rpc_gateway_token_cache` maintains a pool of
   workers that cache tokens per service. Concurrent callers share a single
   token, and preemptive refresh avoids expiry-window failures.

5. **Pluggable auth** — authentication strategies implement the
   `bondy_rpc_gateway_auth_proxy` behaviour. The built-in
   `bondy_rpc_gateway_auth_generic` module provides a fully declarative
   approach (OAuth2 client-credentials, API keys, etc.) without writing
   custom Erlang code.

## Supervision tree

```
bondy_rpc_gateway_app
└── bondy_rpc_gateway_sup (rest_for_one)
    ├── bondy_rpc_gateway_token_cache_sup   (simple_one_for_one — token workers)
    ├── bondy_rpc_gateway_token_cache       (worker — registry / pool)
    ├── bondy_rpc_gateway_http_pool_sup     (simple_one_for_one — hackney pools)
    ├── bondy_rpc_gateway_callee_sup        (simple_one_for_one — WAMP callees)
    └── bondy_rpc_gateway_manager           (worker — orchestrates startup)
```

## Startup

`start/2` initialises configuration defaults via
`bondy_rpc_gateway_config:init/0` and then starts the supervision tree.
The manager's `init` continuation handles secret resolution, pool creation,
and procedure registration asynchronously so that the application starts
even when external secret providers are temporarily unreachable.
""".

-behaviour(application).

-export([start/2]).
-export([stop/1]).

-doc false.
start(_StartType, _StartArgs) ->
    ok = bondy_rpc_gateway_config:init(),
    bondy_rpc_gateway_sup:start_link().

-doc false.
stop(_State) ->
    ok.
