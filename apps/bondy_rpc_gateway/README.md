bondy_rpc_gateway
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

## Service configuration

Services are defined in the `bondy_rpc_gateway` application environment
under the `services` key. Each service maps one or more WAMP procedures
to upstream HTTP endpoints.

```erlang
#{
    name       => <<"billing">>,
    base_url   => <<"https://billing.example.com/api">>,
    auth_mod   => bondy_rpc_gateway_auth_generic,
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

rpc_gateway.services.billing.base_url = https://billing.example.com/api
rpc_gateway.services.billing.prefix = /billing
rpc_gateway.services.billing.auth_mod = generic
rpc_gateway.services.billing.timeout = 15s
rpc_gateway.services.billing.retries = 2

## ---------------------------------------------------------------
## Connection pool
## ---------------------------------------------------------------

rpc_gateway.services.billing.pool.size = 25
rpc_gateway.services.billing.pool.checkout_timeout = 5s
rpc_gateway.services.billing.pool.connect_timeout = 8s
rpc_gateway.services.billing.pool.idle_timeout = 5m
rpc_gateway.services.billing.pool.recv_timeout = 60s
rpc_gateway.services.billing.pool.follow_redirect = off
rpc_gateway.services.billing.pool.max_redirect = 5

## ---------------------------------------------------------------
## Auth: token acquisition (fetch)
## ---------------------------------------------------------------

rpc_gateway.services.billing.auth.fetch.method = post
rpc_gateway.services.billing.auth.fetch.url = https://idp.example.com/token
rpc_gateway.services.billing.auth.fetch.body_encoding = form
rpc_gateway.services.billing.auth.fetch.token_path = access_token
rpc_gateway.services.billing.auth.fetch.expires_in_path = expires_in
# rpc_gateway.services.billing.auth.fetch.error_path = error.message

## Token request body key-value pairs
rpc_gateway.services.billing.auth.fetch.body.grant_type = client_credentials
rpc_gateway.services.billing.auth.fetch.body.client_id = {{client_id}}
rpc_gateway.services.billing.auth.fetch.body.client_secret = {{client_secret}}

## Optional: HTTP Basic auth on the token request itself
# rpc_gateway.services.billing.auth.fetch.basic_auth.username = {{client_id}}
# rpc_gateway.services.billing.auth.fetch.basic_auth.password = {{client_secret}}

## ---------------------------------------------------------------
## Auth: token placement on forwarded requests (apply)
## ---------------------------------------------------------------

rpc_gateway.services.billing.auth.apply.placement = header
rpc_gateway.services.billing.auth.apply.name = Authorization
rpc_gateway.services.billing.auth.apply.format = Bearer {{token}}

## ---------------------------------------------------------------
## Auth: variable bindings for {{var}} interpolation
## ---------------------------------------------------------------

rpc_gateway.services.billing.auth.vars.client_id = my-app
rpc_gateway.services.billing.auth.vars.client_secret = s3cret

## ---------------------------------------------------------------
## Auth: token cache
## ---------------------------------------------------------------

rpc_gateway.services.billing.auth.cache.default_ttl = 1h
rpc_gateway.services.billing.auth.cache.refresh_margin = 2m

## ---------------------------------------------------------------
## Auth: external secrets (optional, overrides static vars)
## ---------------------------------------------------------------

# rpc_gateway.services.billing.auth.secrets.provider = aws_sm
# rpc_gateway.services.billing.auth.secrets.secret_id = /integrations/credentials/billing
# rpc_gateway.services.billing.auth.secrets.region = sa-east-1
#
# rpc_gateway.services.billing.auth.secrets.vars.client_id.field = AUTHORIZATION_HEADER
# rpc_gateway.services.billing.auth.secrets.vars.client_id.transform = basic_username
#
# rpc_gateway.services.billing.auth.secrets.vars.client_secret.field = AUTHORIZATION_HEADER
# rpc_gateway.services.billing.auth.secrets.vars.client_secret.transform = basic_password

## ---------------------------------------------------------------
## WAMP procedure mappings
## ---------------------------------------------------------------

rpc_gateway.services.billing.procedures.get_invoice.uri = com.billing.get_invoice
rpc_gateway.services.billing.procedures.get_invoice.realm = realm1
rpc_gateway.services.billing.procedures.get_invoice.method = get
rpc_gateway.services.billing.procedures.get_invoice.path = /invoices/{{id}}

rpc_gateway.services.billing.procedures.create_invoice.uri = com.billing.create_invoice
rpc_gateway.services.billing.procedures.create_invoice.realm = realm1
rpc_gateway.services.billing.procedures.create_invoice.method = post
rpc_gateway.services.billing.procedures.create_invoice.path = /invoices
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

All keys are prefixed with `rpc_gateway.services.$service`.

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

HTTP requests are retried on connection failures with exponential backoff:

| Attempt | Backoff |
|---|---|
| 1 | 0 ms (immediate) |
| 2 | 300 ms |
| 3 | 600 ms |
| 4 | 1200 ms |

Default: 3 retries, 30 000 ms timeout. Both are configurable per service.

## Build

    $ rebar3 compile
