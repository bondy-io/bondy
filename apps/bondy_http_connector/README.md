bondy_http_connector
=====

An OTP application that translates WAMP RPC calls into upstream HTTP
requests and maps the HTTP responses back to WAMP results or errors.

A WAMP client calls a registered procedure; the gateway interpolates
kwargs into a path template, routes remaining kwargs as query parameters
or a JSON body (depending on the HTTP method), authenticates with the
upstream service, and returns the HTTP response as a WAMP result.

## Request flow

```
WAMP Call(KWArgs)
  │
  ├─ 1. Extract custom headers from KWArgs[<<"_headers">>]
  ├─ 2. Interpolate path template variables (consumed from KWArgs)
  ├─ 3. Route remaining KWArgs by HTTP method:
  │       GET / DELETE / HEAD  → query parameters
  │       POST / PUT / PATCH   → JSON request body
  ├─ 4. Acquire auth token (via token cache)
  ├─ 5. Apply auth to headers/URL
  └─ 6. HTTP request (with retries + auth retry on 401/403)
          │
          └─ HTTP Response → WAMP Result / Error
```

## Architecture

### Supervision tree

```
bondy_http_connector_sup (rest_for_one)
├── bondy_http_connector_token_cache_sup   (one_for_one — worker pool)
├── bondy_http_connector_token_cache       (gen_server — gproc_pool registry)
├── bondy_http_connector_http_pool_sup     (simple_one_for_one)
├── bondy_http_connector_callee_sup        (simple_one_for_one)
└── bondy_http_connector_manager           (gen_server)
```

`rest_for_one` ensures that a manager restart re-spawns the http pools
and callees. The manager is started last and drives startup through a
chain of `handle_continue` steps:

1. **`resolve_secrets`** — reach external providers (e.g. AWS Secrets
   Manager) for any service whose `auth.secrets` block is configured.
   Successes are written to the readiness ETS (`{ServiceName, {ready,
   Vars}}`); failures are recorded as `{ServiceName, not_ready}` and
   retried indefinitely in the background with jittered exponential
   backoff.
2. **`start_pools`** — spawn one `bondy_http_connector_http_pool` per
   service. Pools start in `down` state and defer their first health
   check to a `handle_continue`, so a slow upstream cannot serialise
   startup of the other pools. On manager-restart the pool's
   `hackney_pool` peer is adopted via `{error, {already_started, _}}`.
3. **`start_callees`** — for each service, group procedures by realm
   and spawn one `bondy_http_connector_callee` per service/realm pair.

### Components

| Module | Role |
|---|---|
| `bondy_http_connector_manager` | Owns service config, secret resolution, pool/callee orchestration |
| `bondy_http_connector_http_pool` | One per service — wraps a hackney pool with health checks and `persistent_term`-backed status |
| `bondy_http_connector_callee` | One per service+realm — opens a WAMP session and registers procedures with the dealer |
| `bondy_http_connector_callee_handler` | Stateless callback module invoked **inline** by the dealer; translates WAMP calls into HTTP requests |
| `bondy_http_connector_token_cache` + `_worker` | Sharded token cache: `gproc_pool` hash → ETS lookup, `gen_server` only on miss |
| `bondy_http_connector_secret_resolver` | Pluggable secret-store provider (currently AWS Secrets Manager) |
| `bondy_http_connector_auth_generic` | Declarative auth strategy: fetch token (HTTP) → apply to outgoing request |

### Hot path

The WAMP handler runs **inline on the caller's process** — it is not a
`gen_server` hop. Per call, in order:

1. Pattern-match on `vars_resolved = true` in the precomputed
   `#http_connector_proc_conf{}` record (built once at registration time).
2. Path-template interpolation using a precomputed list of variables
   stored in the record.
3. Token lookup — `gproc_pool:pick/2` → `ets:lookup_element/4` (lock-free).
4. `hackney:request/5` through the pool's stored options, read from
   `persistent_term` with no copy.

`persistent_term` writes are deduped (no-op when the value is unchanged)
to avoid the global GC every consumer pays on a write.

### Callee lifecycle

Each callee gets its own WAMP `SessionId` and opens it via
`bondy_session_manager:open/3` in `init/1`. The session manager monitors
the callee process; when it exits — crash, supervisor shutdown, or a
`rest_for_one` cascade — the `'DOWN'` handler fires
`bondy_router:flush/2`, which calls `bondy_dealer:flush/2` and
`bondy_registry:remove_all/5` keyed on the callee's `SessionId`.

This is what allows a restarted callee to re-register the same procedure
URIs without colliding with stale entries from the previous incarnation.

### Resilience

- **Pool down** — while a pool is `down`, `request/5,6` returns
  `{error, pool_down}` immediately. The WAMP handler treats this as
  fast-fail — no retry, no backoff — because the same `persistent_term`
  value will keep coming back until the pool's own health-check loop
  flips it to `up`.
- **Pool health-check** — uses `bondy_retry` with indefinite retries
  (`max_retries` resets on hit). `hackney_pool:start_pool/2` is
  idempotent, so transient health failures do not tear down in-flight
  connections.
- **Liveness probe** — while a pool is `up`, a periodic probe
  (`..liveness.*`, enabled by default) detects a degrading upstream and
  marks the pool `down` (raising an alarm) before a live WAMP call fails
  against it, instead of only re-checking once already down. See
  [Observability](#observability).
- **Token refresh** — each token's TTL drives a `send_after` timer.
  On preemptive refresh failure the worker re-arms a short retry
  (`?REFRESH_RETRY_MS = 30s`) so that the cached token never goes stale
  silently and trips the slow-path 401 retry.
- **Secret-resolution fallback** — services whose secrets are still
  resolving register their procedures with `vars_resolved = false`.
  The handler then falls back to a per-call merge keyed on the
  manager's readiness ETS until the callee is recycled by the
  supervisor for an unrelated reason.

## Service configuration

Services are defined in the `bondy_http_connector` application environment
under the `services` key. Each service maps one or more WAMP procedures
to upstream HTTP endpoints.

```erlang
#{
    name       => <<"billing">>,
    base_url   => <<"https://billing.example.com/api">>,
    auth_mod   => bondy_http_connector_auth_generic,
    auth_conf  => #{...},
    timeout    => 15000,         %% ms, default 30000
    retries    => 2,             %% default 3
    procedures => #{
        <<"get_invoice">> => #{
            uri    => <<"com.billing.get_invoice">>,
            realm  => <<"realm1">>,
            method => get,
            path   => <<"/invoices/{{id}}">>
        },
        <<"create_invoice">> => #{
            uri    => <<"com.billing.create_invoice">>,
            realm  => <<"realm1">>,
            method => post,
            path   => <<"/invoices">>
        }
    }
}
```

The same service can be defined using the Cuttlefish schema in a `.conf`
file. The flat key-value pairs are assembled into the nested Erlang map
at startup.

```ini
## ---------------------------------------------------------------
## Service: base settings
## ---------------------------------------------------------------

http_connector.services.billing.base_url = https://billing.example.com/api
http_connector.services.billing.prefix = /billing
http_connector.services.billing.auth_mod = generic
http_connector.services.billing.timeout = 15s
http_connector.services.billing.retries = 2

## ---------------------------------------------------------------
## Connection pool
## ---------------------------------------------------------------

http_connector.services.billing.pool.size = 25
http_connector.services.billing.pool.checkout_timeout = 5s
http_connector.services.billing.pool.connect_timeout = 8s
http_connector.services.billing.pool.idle_timeout = 5m
http_connector.services.billing.pool.recv_timeout = 60s
http_connector.services.billing.pool.follow_redirect = off
http_connector.services.billing.pool.max_redirect = 5

## ---------------------------------------------------------------
## Liveness probe
## ---------------------------------------------------------------

http_connector.services.billing.liveness.enabled = on
http_connector.services.billing.liveness.path = /
http_connector.services.billing.liveness.method = head
http_connector.services.billing.liveness.interval = 30s
http_connector.services.billing.liveness.timeout = 5s
http_connector.services.billing.liveness.failure_threshold = 3
http_connector.services.billing.liveness.success_threshold = 1

## ---------------------------------------------------------------
## Auth: token acquisition (fetch)
## ---------------------------------------------------------------

http_connector.services.billing.auth.fetch.method = post
http_connector.services.billing.auth.fetch.url = https://idp.example.com/token
http_connector.services.billing.auth.fetch.body_encoding = form
http_connector.services.billing.auth.fetch.token_path = access_token
http_connector.services.billing.auth.fetch.expires_in_path = expires_in
# http_connector.services.billing.auth.fetch.error_path = error.message

## Token request body key-value pairs
http_connector.services.billing.auth.fetch.body.grant_type = client_credentials
http_connector.services.billing.auth.fetch.body.client_id = {{client_id}}
http_connector.services.billing.auth.fetch.body.client_secret = {{client_secret}}

## Optional: HTTP Basic auth on the token request itself
# http_connector.services.billing.auth.fetch.basic_auth.username = {{client_id}}
# http_connector.services.billing.auth.fetch.basic_auth.password = {{client_secret}}

## ---------------------------------------------------------------
## Auth: token placement on forwarded requests (apply)
## ---------------------------------------------------------------

http_connector.services.billing.auth.apply.placement = header
http_connector.services.billing.auth.apply.name = Authorization
http_connector.services.billing.auth.apply.format = Bearer {{token}}

## ---------------------------------------------------------------
## Auth: variable bindings for {{var}} interpolation
## ---------------------------------------------------------------

http_connector.services.billing.auth.vars.client_id = my-app
http_connector.services.billing.auth.vars.client_secret = s3cret

## ---------------------------------------------------------------
## Auth: token cache
## ---------------------------------------------------------------

http_connector.services.billing.auth.cache.default_ttl = 1h
http_connector.services.billing.auth.cache.refresh_margin = 2m

## ---------------------------------------------------------------
## Auth: external secrets (optional, overrides static vars)
## ---------------------------------------------------------------

# http_connector.services.billing.auth.secrets.provider = aws_sm
# http_connector.services.billing.auth.secrets.secret_id = /integrations/credentials/billing
# http_connector.services.billing.auth.secrets.region = sa-east-1
#
# http_connector.services.billing.auth.secrets.vars.client_id.field = AUTHORIZATION_HEADER
# http_connector.services.billing.auth.secrets.vars.client_id.transform = basic_username
#
# http_connector.services.billing.auth.secrets.vars.client_secret.field = AUTHORIZATION_HEADER
# http_connector.services.billing.auth.secrets.vars.client_secret.transform = basic_password

## ---------------------------------------------------------------
## WAMP procedure mappings
## ---------------------------------------------------------------

http_connector.services.billing.procedures.get_invoice.uri = com.billing.get_invoice
http_connector.services.billing.procedures.get_invoice.realm = realm1
http_connector.services.billing.procedures.get_invoice.method = get
http_connector.services.billing.procedures.get_invoice.path = /invoices/{{id}}

http_connector.services.billing.procedures.create_invoice.uri = com.billing.create_invoice
http_connector.services.billing.procedures.create_invoice.realm = realm1
http_connector.services.billing.procedures.create_invoice.method = post
http_connector.services.billing.procedures.create_invoice.path = /invoices
```

### Cuttlefish key reference

| Key | Type | Default | Description |
|---|---|---|---|
| `..base_url` | string | — | Upstream service URL |
| `..prefix` | string | `/` | Path prefix to strip from incoming requests |
| `..auth_mod` | enum (`generic`) | `generic` | Auth module |
| `..timeout` | duration | `30s` | Upstream request timeout |
| `..retries` | integer | `3` | Retry attempts with exponential backoff |
| `..pool.size` | integer | `25` | Max connections in hackney pool |
| `..pool.checkout_timeout` | duration | `5s` | Pool checkout timeout |
| `..pool.connect_timeout` | duration | `8s` | Connection timeout |
| `..pool.idle_timeout` | duration | `5m` | Idle connection lifetime |
| `..pool.recv_timeout` | duration | `60s` | Receive timeout |
| `..pool.follow_redirect` | on/off | `off` | Follow HTTP redirects |
| `..pool.max_redirect` | integer | `5` | Max redirect count |
| `..liveness.enabled` | on/off | `on` | Enable the periodic liveness probe |
| `..liveness.path` | string | `/` | Path probed on `base_url` |
| `..liveness.method` | enum (`get`, `head`) | `head` | Probe HTTP method |
| `..liveness.interval` | duration | `30s` | Delay between probes while the pool is `up` |
| `..liveness.timeout` | duration | `5s` | Probe request timeout |
| `..liveness.failure_threshold` | integer | `3` | Consecutive failures before marking the pool `down` and raising the alarm |
| `..liveness.success_threshold` | integer | `1` | Consecutive successes (while recovering) before clearing the alarm |
| `..auth.fetch.method` | enum (`get`, `post`) | `post` | Token endpoint HTTP method |
| `..auth.fetch.url` | string | — | Token endpoint URL |
| `..auth.fetch.body_encoding` | enum (`form`, `json`, `none`) | `none` | Token request body encoding |
| `..auth.fetch.body.$key` | string | — | Token request body key-value pair |
| `..auth.fetch.headers.$key` | string | — | Token request header |
| `..auth.fetch.token_path` | string | — | Dot-separated JSON path to token |
| `..auth.fetch.error_path` | string | — | Dot-separated JSON path to error |
| `..auth.fetch.expires_in_path` | string | — | Dot-separated JSON path to TTL (seconds) |
| `..auth.fetch.basic_auth.username` | string | — | Basic auth username for token request |
| `..auth.fetch.basic_auth.password` | string | — | Basic auth password for token request |
| `..auth.apply.placement` | enum (`header`, `query_param`) | `header` | Where to place the token |
| `..auth.apply.name` | string | `Authorization` | Header or query param name |
| `..auth.apply.format` | string | — | Format template, e.g. `Bearer {{token}}` |
| `..auth.vars.$var` | string | — | Variable binding for `{{var}}` interpolation |
| `..auth.cache.default_ttl` | duration | `1h` | Default token TTL |
| `..auth.cache.refresh_margin` | duration | `1m` | Preemptive refresh time before expiry |
| `..auth.secrets.provider` | enum (`aws_sm`) | — | External secrets provider |
| `..auth.secrets.secret_id` | string | — | Secret identifier |
| `..auth.secrets.region` | string | — | AWS region |
| `..auth.secrets.vars.$var.field` | string | — | JSON field name in secret |
| `..auth.secrets.vars.$var.transform` | enum (`none`, `basic_username`, `basic_password`) | `none` | Transform to apply |
| `..procedures.$proc.uri` | string | — | WAMP procedure URI (required) |
| `..procedures.$proc.realm` | string | — | Bondy realm (required) |
| `..procedures.$proc.method` | enum (`get`, `post`, `put`, `patch`, `delete`, `head`) | `get` | HTTP method |
| `..procedures.$proc.path` | string | `/` | Path template with `{{var}}` placeholders |

All keys are prefixed with `http_connector.services.$service`.

## Path template interpolation

Path templates use `{{var}}` placeholders. Matching keys are **consumed**
from KWArgs before the remaining kwargs are routed to query params or body.

```
Template:  /orgs/{{org}}/invoices/{{id}}
KWArgs:    #{<<"org">> => <<"acme">>, <<"id">> => <<"42">>, <<"status">> => <<"paid">>}

Result:    /orgs/acme/invoices/42
Remaining: #{<<"status">> => <<"paid">>}
```

If a template variable is missing from KWArgs the call fails immediately:

```
{error, <<"wamp.error.invalid_argument">>, #{}, [],
 #{<<"status">> => 400,
   <<"message">> => <<"Missing required path variable: id">>}}
```

## Custom headers

Pass a `<<"_headers">>` key in KWArgs to inject custom HTTP headers.
This key is extracted before path interpolation and does not appear
in query params or the request body.

```erlang
KWArgs = #{
    <<"_headers">> => #{
        <<"X-Request-ID">> => <<"req-abc-123">>,
        <<"X-Tenant">>     => <<"acme">>
    },
    <<"id">> => <<"INV-001">>
}
```

The values are merged with the default headers (`Content-Type` and `Accept`).

## WAMP → HTTP → WAMP examples

All examples below assume the following service configuration:

```erlang
#{
    name     => <<"billing">>,
    base_url => <<"https://billing.example.com/api">>,
    ...
    procedures => #{...}
}
```

---

### GET

Remaining KWArgs (after path interpolation) become **query parameters**.
The request body is always empty.

**Procedure config:**

```erlang
#{method => get, path => <<"/invoices/{{id}}">>}
```

**Example 1 — path variable + query parameter:**

```
WAMP Call
  procedure: com.billing.get_invoice
  KWArgs = #{<<"id">> => <<"INV-001">>, <<"status">> => <<"paid">>}

→ HTTP GET https://billing.example.com/api/invoices/INV-001?status=paid
  (path template: /invoices/{{id}})
  (<<"id">> consumed by path, <<"status">> becomes query param)

→ {ok, #{}, [], #{<<"status">> => 200, <<"body">> => #{
       <<"id">>     => <<"INV-001">>,
       <<"amount">> => 1500,
       <<"status">> => <<"paid">>
   }}}
```

**Example 2 — no remaining kwargs:**

```
WAMP Call
  procedure: com.billing.get_invoice
  KWArgs = #{<<"id">> => <<"INV-001">>}

→ HTTP GET https://billing.example.com/api/invoices/INV-001
  (<<"id">> consumed by path, no remaining kwargs, no query string)

→ {ok, #{}, [], #{<<"status">> => 200, <<"body">> => #{...}}}
```

**Example 3 — multiple query parameters, no path variables:**

```erlang
#{method => get, path => <<"/invoices">>}
```

```
WAMP Call
  procedure: com.billing.list_invoices
  KWArgs = #{<<"status">> => <<"overdue">>, <<"limit">> => 10, <<"offset">> => 20}

→ HTTP GET https://billing.example.com/api/invoices?status=overdue&limit=10&offset=20
  (no path variables, all kwargs become query params)

→ {ok, #{}, [], #{<<"status">> => 200, <<"body">> => [#{...}, #{...}]}}
```

**Example 4 — with custom headers:**

```
WAMP Call
  procedure: com.billing.get_invoice
  KWArgs = #{
      <<"_headers">> => #{<<"X-Request-ID">> => <<"req-42">>},
      <<"id">>       => <<"INV-001">>,
      <<"expand">>   => <<"lines">>
  }

→ HTTP GET https://billing.example.com/api/invoices/INV-001?expand=lines
  Headers: Content-Type: application/json
           Accept: application/json
           X-Request-ID: req-42
  (<<"_headers">> extracted, <<"id">> consumed by path, <<"expand">> becomes query param)

→ {ok, #{}, [], #{<<"status">> => 200, <<"body">> => #{...}}}
```

---

### DELETE

Same routing as GET — remaining KWArgs become **query parameters**.
The request body is always empty.

**Procedure config:**

```erlang
#{method => delete, path => <<"/invoices/{{id}}">>}
```

**Example 1 — simple delete:**

```
WAMP Call
  procedure: com.billing.delete_invoice
  KWArgs = #{<<"id">> => <<"INV-001">>}

→ HTTP DELETE https://billing.example.com/api/invoices/INV-001
  (<<"id">> consumed by path, no remaining kwargs)

→ {ok, #{}, [], #{<<"status">> => 204, <<"body">> => <<>>}}
```

**Example 2 — delete with query parameters:**

```
WAMP Call
  procedure: com.billing.delete_invoice
  KWArgs = #{<<"id">> => <<"INV-001">>, <<"reason">> => <<"duplicate">>}

→ HTTP DELETE https://billing.example.com/api/invoices/INV-001?reason=duplicate
  (<<"id">> consumed by path, <<"reason">> becomes query param)

→ {ok, #{}, [], #{<<"status">> => 200, <<"body">> => #{
       <<"deleted">> => true
   }}}
```

---

### HEAD

Same routing as GET — remaining KWArgs become **query parameters**.
The request body is always empty. Typically used to check resource
existence or retrieve metadata without a response body.

**Procedure config:**

```erlang
#{method => head, path => <<"/invoices/{{id}}">>}
```

**Example 1 — check existence:**

```
WAMP Call
  procedure: com.billing.invoice_exists
  KWArgs = #{<<"id">> => <<"INV-001">>}

→ HTTP HEAD https://billing.example.com/api/invoices/INV-001
  (<<"id">> consumed by path, no remaining kwargs)

→ {ok, #{}, [], #{<<"status">> => 200, <<"body">> => <<>>}}
```

**Example 2 — not found:**

```
WAMP Call
  procedure: com.billing.invoice_exists
  KWArgs = #{<<"id">> => <<"INV-999">>}

→ HTTP HEAD https://billing.example.com/api/invoices/INV-999

→ {error, <<"wamp.error.not_found">>, #{}, [],
   #{<<"status">> => 404, <<"body">> => <<>>}}
```

---

### POST

Remaining KWArgs (after path interpolation) become the **JSON request body**.
No query parameters are appended.

**Procedure config:**

```erlang
#{method => post, path => <<"/invoices">>}
```

**Example 1 — create a resource:**

```
WAMP Call
  procedure: com.billing.create_invoice
  KWArgs = #{
      <<"customer">> => <<"cust-42">>,
      <<"amount">>   => 2500,
      <<"currency">> => <<"USD">>,
      <<"lines">>    => [
          #{<<"desc">> => <<"Widget">>, <<"qty">> => 5, <<"price">> => 500}
      ]
  }

→ HTTP POST https://billing.example.com/api/invoices
  Content-Type: application/json

  {"customer":"cust-42","amount":2500,"currency":"USD",
   "lines":[{"desc":"Widget","qty":5,"price":500}]}

→ {ok, #{}, [], #{<<"status">> => 201, <<"body">> => #{
       <<"id">>       => <<"INV-002">>,
       <<"customer">> => <<"cust-42">>,
       <<"amount">>   => 2500,
       <<"status">>   => <<"draft">>
   }}}
```

**Example 2 — path variable + body (nested resource):**

```erlang
#{method => post, path => <<"/invoices/{{invoice_id}}/payments">>}
```

```
WAMP Call
  procedure: com.billing.create_payment
  KWArgs = #{
      <<"invoice_id">> => <<"INV-001">>,
      <<"amount">>     => 1500,
      <<"method">>     => <<"credit_card">>
  }

→ HTTP POST https://billing.example.com/api/invoices/INV-001/payments
  Content-Type: application/json

  {"amount":1500,"method":"credit_card"}

  (<<"invoice_id">> consumed by path, remaining kwargs become body)

→ {ok, #{}, [], #{<<"status">> => 201, <<"body">> => #{
       <<"payment_id">> => <<"PAY-001">>,
       <<"status">>     => <<"completed">>
   }}}
```

**Example 3 — empty body (trigger action):**

```erlang
#{method => post, path => <<"/invoices/{{id}}/send">>}
```

```
WAMP Call
  procedure: com.billing.send_invoice
  KWArgs = #{<<"id">> => <<"INV-001">>}

→ HTTP POST https://billing.example.com/api/invoices/INV-001/send
  Content-Type: application/json

  (<<"id">> consumed by path, no remaining kwargs → empty body)

→ {ok, #{}, [], #{<<"status">> => 200, <<"body">> => #{
       <<"sent_at">> => <<"2026-02-19T10:30:00Z">>
   }}}
```

---

### PUT

Same routing as POST — remaining KWArgs become the **JSON request body**.
Typically used for full resource replacement.

**Procedure config:**

```erlang
#{method => put, path => <<"/invoices/{{id}}">>}
```

**Example 1 — full update:**

```
WAMP Call
  procedure: com.billing.replace_invoice
  KWArgs = #{
      <<"id">>       => <<"INV-001">>,
      <<"customer">> => <<"cust-42">>,
      <<"amount">>   => 3000,
      <<"currency">> => <<"USD">>,
      <<"status">>   => <<"final">>
  }

→ HTTP PUT https://billing.example.com/api/invoices/INV-001
  Content-Type: application/json

  {"customer":"cust-42","amount":3000,"currency":"USD","status":"final"}

  (<<"id">> consumed by path, remaining kwargs become body)

→ {ok, #{}, [], #{<<"status">> => 200, <<"body">> => #{
       <<"id">>       => <<"INV-001">>,
       <<"customer">> => <<"cust-42">>,
       <<"amount">>   => 3000,
       <<"status">>   => <<"final">>
   }}}
```

**Example 2 — upsert (create-or-replace):**

```erlang
#{method => put, path => <<"/settings/{{key}}">>}
```

```
WAMP Call
  procedure: com.billing.set_setting
  KWArgs = #{
      <<"key">>   => <<"tax_rate">>,
      <<"value">> => 0.21
  }

→ HTTP PUT https://billing.example.com/api/settings/tax_rate
  Content-Type: application/json

  {"value":0.21}

  (<<"key">> consumed by path)

→ {ok, #{}, [], #{<<"status">> => 201, <<"body">> => #{
       <<"key">>   => <<"tax_rate">>,
       <<"value">> => 0.21
   }}}
```

---

### PATCH

Same routing as POST — remaining KWArgs become the **JSON request body**.
Typically used for partial updates.

**Procedure config:**

```erlang
#{method => patch, path => <<"/invoices/{{id}}">>}
```

**Example 1 — partial update:**

```
WAMP Call
  procedure: com.billing.update_invoice
  KWArgs = #{
      <<"id">>     => <<"INV-001">>,
      <<"status">> => <<"paid">>,
      <<"notes">>  => <<"Paid in full">>
  }

→ HTTP PATCH https://billing.example.com/api/invoices/INV-001
  Content-Type: application/json

  {"status":"paid","notes":"Paid in full"}

  (<<"id">> consumed by path, remaining kwargs become body)

→ {ok, #{}, [], #{<<"status">> => 200, <<"body">> => #{
       <<"id">>     => <<"INV-001">>,
       <<"status">> => <<"paid">>,
       <<"notes">>  => <<"Paid in full">>
   }}}
```

**Example 2 — nested resource patch with custom headers:**

```erlang
#{method => patch, path => <<"/orgs/{{org}}/invoices/{{id}}">>}
```

```
WAMP Call
  procedure: com.billing.update_org_invoice
  KWArgs = #{
      <<"_headers">> => #{<<"If-Match">> => <<"etag-abc123">>},
      <<"org">>      => <<"acme">>,
      <<"id">>       => <<"INV-001">>,
      <<"amount">>   => 4200
  }

→ HTTP PATCH https://billing.example.com/api/orgs/acme/invoices/INV-001
  Content-Type: application/json
  Accept: application/json
  If-Match: etag-abc123

  {"amount":4200}

  (<<"_headers">> extracted, <<"org">> and <<"id">> consumed by path)

→ {ok, #{}, [], #{<<"status">> => 200, <<"body">> => #{
       <<"id">>     => <<"INV-001">>,
       <<"amount">> => 4200
   }}}
```

---

## HTTP response → WAMP result mapping

### Success (2xx)

Any HTTP status 200–299 returns an `{ok, ...}` tuple. The response body
is JSON-decoded when possible, otherwise returned as a raw binary.

```
HTTP 200 {"id":"INV-001"}
→ {ok, #{}, [], #{<<"status">> => 200, <<"body">> => #{<<"id">> => <<"INV-001">>}}}

HTTP 201 {"id":"INV-002"}
→ {ok, #{}, [], #{<<"status">> => 201, <<"body">> => #{<<"id">> => <<"INV-002">>}}}

HTTP 204 (empty body)
→ {ok, #{}, [], #{<<"status">> => 204, <<"body">> => <<>>}}
```

### Error (3xx+)

Non-2xx responses return `{error, ErrorUri, ...}` with the HTTP status
mapped to a WAMP error URI:

| HTTP Status | WAMP Error URI |
|---|---|
| 400 | `wamp.error.invalid_argument` |
| 401 | `wamp.error.not_authorized` |
| 403 | `wamp.error.not_authorized` |
| 404 | `wamp.error.not_found` |
| 408 | `wamp.error.timeout` |
| 422 | `wamp.error.invalid_argument` |
| 429 | `bondy.error.too_many_requests` |
| 4xx (other) | `bondy.error.invalid_argument` |
| 502 | `bondy.error.bad_gateway` |
| 503 | `bondy.error.bad_gateway` |
| 504 | `wamp.error.timeout` |
| 5xx (other) | `bondy.error.bad_gateway` |

```
HTTP 404 {"error":"not found"}
→ {error, <<"wamp.error.not_found">>, #{}, [],
   #{<<"status">> => 404, <<"body">> => #{<<"error">> => <<"not found">>}}}

HTTP 422 {"errors":["amount is required"]}
→ {error, <<"wamp.error.invalid_argument">>, #{}, [],
   #{<<"status">> => 422, <<"body">> => #{<<"errors">> => [<<"amount is required">>]}}}
```

### Auth rejection (401/403) auto-retry

When the upstream returns 401 or 403, the gateway automatically:

1. Invalidates the cached auth token
2. Fetches a fresh token from the auth provider
3. Retries the request once with the new token

If the retry also fails, the error response is returned normally.

## Retries and timeouts

HTTP requests are retried on connection failures with **jittered**
exponential backoff. Because the WAMP handler runs inline in the
dealer's caller process, every sleep stalls the dispatch path — so each
individual wait is hard-capped well below the per-procedure timeout.

Backoff for retry attempt `n` (1-based) is:

```
max(FLOOR, rand:uniform(min(BASE × 2^(n-1), CAP)))
```

| Constant | Value |
|---|---|
| `RETRY_BACKOFF_BASE_MS` | 50 |
| `RETRY_BACKOFF_FLOOR_MS` | 30 |
| `RETRY_BACKOFF_CAP_MS` | 200 |

So with the default 3 retries the worst-case total backoff is
`50 + 100 + 200 = 350 ms`, and each individual sleep is bounded at 200 ms.

`{error, pool_down}` short-circuits the retry loop — no backoff, no
sleep — because the pool's status only changes when the pool's own
asynchronous health check flips it back to `up`.

Default: 3 retries, 30 000 ms request timeout. Both are configurable
per service via `..retries` and `..timeout`.

## Observability

`bondy_http_connector_telemetry` declares every metric family via
`bondy_metrics` and attaches its own sink — no `bondy_router` dependency is
needed for these to appear on the Admin API's `/metrics` endpoint, since
`bondy_prometheus_collector` renders any declared family generically. See
`monitoring/grafana/dashboards/bondy-http-connector.json` for the bundled
dashboard.

### Telemetry events

All under the `[bondy, http_connector, ...]` prefix; metadata is always a
low-cardinality closed set (`service`, `outcome`, `result`, `status` —
never a raw identifier):

| Event | Measurements | Metadata |
|---|---|---|
| `request` | `duration` (ms) | `service, procedure_uri, outcome` |
| `retry` | `count` | `service, procedure_uri, attempt` |
| `token_cache` | `count` | `service, result` (`hit`\|`miss`) |
| `token_fetch` | `duration` (ms) | `service, outcome` |
| `token_refresh` | `count` | `service, outcome, trigger` (`preemptive`\|`reactive`) |
| `secret_resolution` | `count` | `service, outcome, phase` (`startup`\|`retry`) |
| `pool_status` | `count` | `service, status` (`up`\|`down`) |
| `liveness_probe` | `duration` (ms) | `service, outcome` |

### Prometheus metrics

| Metric | Type |
|---|---|
| `bondy_http_connector_requests_total{service, procedure_uri, outcome}` | counter |
| `bondy_http_connector_request_duration_milliseconds{service, procedure_uri}` | histogram |
| `bondy_http_connector_retries_total{service, procedure_uri}` | counter |
| `bondy_http_connector_token_cache_total{service, result}` | counter |
| `bondy_http_connector_token_fetch_total{service, outcome}` | counter |
| `bondy_http_connector_token_fetch_duration_milliseconds{service}` | histogram |
| `bondy_http_connector_token_refresh_total{service, outcome}` | counter |
| `bondy_http_connector_secret_resolution_total{service, outcome}` | counter |
| `bondy_http_connector_service_ready{service}` | gauge (1/0) |
| `bondy_http_connector_pool_status_changes_total{service, status}` | counter |
| `bondy_http_connector_pool_up{service}` | gauge (1/0) |
| `bondy_http_connector_liveness_probes_total{service, outcome}` | counter |
| `bondy_http_connector_liveness_probe_duration_milliseconds{service}` | histogram |

### Liveness probe and alarms

While a pool is `up`, a self-rearming timer (`..liveness.interval`) probes
`..liveness.path` on `base_url`. After `..liveness.failure_threshold`
consecutive failures the pool is marked `down` (the existing
`{error, pool_down}` fast-fail path, previously only reachable via the
startup check) and an OTP alarm is raised:
`alarm_handler:set_alarm({{http_connector_service_down, ServiceName}, Details})`.
Recovery requires `..liveness.success_threshold` consecutive successful
probes, at which point the pool flips back to `up` and
`alarm_handler:clear_alarm/1` is called. The alarm needs no new exposition
plumbing — it's counted by the existing `bondy_alarms` /
`bondy_alarm_active{alarm_id}` gauges (`bondy_prometheus_db`), already on
the cluster-overview dashboard.

## Build

    $ rebar3 compile
