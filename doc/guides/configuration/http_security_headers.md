# HTTP Security Headers

Bondy provides per-listener configuration for CORS (Cross-Origin Resource Sharing) and standard HTTP security response headers. These settings apply to all four HTTP listeners:

| Listener | Config prefix | Description |
|---|---|---|
| `api_gateway.http` | `bondy.api_gateway_http` | Public HTTP |
| `api_gateway.https` | `bondy.api_gateway_https` | Public HTTPS |
| `admin_api.http` | `bondy.admin_api_http` | Admin HTTP |
| `admin_api.https` | `bondy.admin_api_https` | Admin HTTPS |

Every key documented below exists for each of these four prefixes. The examples use `api_gateway.http` but the same keys are available under all four prefixes.

## CORS

CORS headers are set on every response from a listener (not just `OPTIONS` preflight requests). This ensures browsers can make cross-origin requests to Bondy-managed APIs, WAMP transports (SSE, long-poll), OIDC endpoints, and OAuth2 token endpoints.

### Configuration keys

#### `<prefix>.cors.enabled`

Enables or disables CORS headers on this listener. When `off`, no `Access-Control-*` headers are emitted.

```
api_gateway.http.cors.enabled = on
```

Default: `on`

#### `<prefix>.cors.allowed_origins`

Controls which origins are permitted to make cross-origin requests. Three modes are supported:

**Wildcard** (default) -- allows any origin. Forces `Access-Control-Allow-Credentials` to `false` (per the Fetch specification, credentials cannot be used with a wildcard origin):

```
api_gateway.http.cors.allowed_origins = *
```

**Explicit allowlist** -- a comma-separated list of origins. Only requests whose `Origin` header matches one of these values will receive CORS headers. Requests from unlisted origins receive no `Access-Control-Allow-Origin` header at all, which causes the browser to block the response. When a match is found, `Access-Control-Allow-Credentials` is set to `true` and a `Vary: Origin` header is added.

Entries can be exact origins or wildcard subdomain patterns using the `*.` prefix:

```
api_gateway.http.cors.allowed_origins = https://app.example.com, https://admin.example.com
```

```
api_gateway.http.cors.allowed_origins = *.example.com, https://other.com
```

A wildcard pattern like `*.example.com` matches any subdomain (e.g. `https://app.example.com`, `https://staging.example.com`) but does **not** match the bare domain `https://example.com` itself. The exact requesting origin is always reflected back in the `Access-Control-Allow-Origin` header -- the `*.` is purely a server-side config convenience.

> **Cross-subdomain OIDC deployments:** When the SPA and Bondy are on different
> subdomains, use an explicit allowlist (or wildcard subdomain pattern) so that
> `Access-Control-Allow-Credentials` is set to `true`. You must also configure
> `cookie_domain` and `cookie_same_site` in the OIDC provider config -- see the
> [Web Developer OIDC Guide](../../../_spec/web_developer_oidc_guide.md#cross-origin-deployments-eg-safari--sse).

**Auto** -- derives the allowed origin from the incoming request's own scheme, host, and port (`Scheme://Host[:Port]`). This is effectively "same-origin only" and is useful when the frontend application is served from the same domain as the API. Default ports (80 for HTTP, 443 for HTTPS) are omitted:

```
api_gateway.http.cors.allowed_origins = auto
```

Default: `*`

#### `<prefix>.cors.allowed_methods`

The value for the `Access-Control-Allow-Methods` response header. A comma-separated list of HTTP methods.

```
api_gateway.http.cors.allowed_methods = GET,HEAD,OPTIONS,POST,PUT,PATCH,DELETE
```

Default: `GET,HEAD,OPTIONS,POST,PUT,PATCH,DELETE`

#### `<prefix>.cors.allowed_headers`

The value for the `Access-Control-Allow-Headers` response header. A comma-separated list of header names that the client is allowed to send.

```
api_gateway.http.cors.allowed_headers = origin,x-requested-with,content-type,accept,authorization,accept-language,x-csrf-token
```

Default: `origin,x-requested-with,content-type,accept,authorization,accept-language,x-csrf-token`

#### `<prefix>.cors.max_age`

The value (in seconds) for the `Access-Control-Max-Age` response header. This tells the browser how long to cache the preflight response.

```
api_gateway.http.cors.max_age = 86400
```

Default: `86400` (24 hours)

### Example: production HTTPS listener

```
api_gateway.https.cors.enabled = on
api_gateway.https.cors.allowed_origins = https://app.example.com, https://admin.example.com
api_gateway.https.cors.allowed_methods = GET,HEAD,OPTIONS,POST,PUT,PATCH,DELETE
api_gateway.https.cors.allowed_headers = origin,x-requested-with,content-type,accept,authorization
api_gateway.https.cors.max_age = 86400
```

### API Gateway spec override

When using the API Gateway with JSON specification files, CORS headers defined in the spec's `response.on_result.headers` or `response.on_error.headers` (via MOPS expressions) take precedence over the listener-level CORS configuration. If the spec does not define an `access-control-allow-origin` header, the listener CORS configuration is used as a fallback.

This means you can use the listener configuration as a project-wide default and override it per-endpoint in specific API specs when needed.

## Security Headers

Static security headers are computed once at listener startup and cached for the lifetime of the listener. They are set on every HTTP response.

### Configuration keys

#### `<prefix>.security_headers.enabled`

Enables or disables all security headers on this listener. When `off`, none of the headers below are emitted.

```
api_gateway.http.security_headers.enabled = on
```

Default: `on`

#### `<prefix>.security_headers.hsts`

The value for the `Strict-Transport-Security` header. This header tells browsers to only access the server over HTTPS, preventing protocol downgrade attacks.

Set to an empty string to disable.

```
api_gateway.https.security_headers.hsts = max-age=31536000; includeSubDomains
```

Default: `max-age=31536000; includeSubDomains` for HTTPS listeners, empty (disabled) for HTTP listeners.

> **Note:** HSTS is only meaningful on HTTPS listeners. Setting it on an HTTP listener has no practical effect since the header is ignored by browsers when received over a plain HTTP connection.

#### `<prefix>.security_headers.frame_options`

The value for the `X-Frame-Options` header. This header prevents the page from being rendered in a frame, iframe, or object, mitigating clickjacking attacks.

Common values:

- `DENY` -- the page cannot be displayed in a frame at all
- `SAMEORIGIN` -- the page can only be displayed in a frame on the same origin

Set to an empty string to disable.

```
api_gateway.http.security_headers.frame_options = SAMEORIGIN
```

Default: `SAMEORIGIN`

#### `<prefix>.security_headers.content_type_options`

The value for the `X-Content-Type-Options` header. Setting this to `nosniff` prevents browsers from MIME-sniffing the response content type, which can prevent certain XSS attacks.

Set to an empty string to disable.

```
api_gateway.http.security_headers.content_type_options = nosniff
```

Default: `nosniff`

#### `<prefix>.security_headers.content_security_policy`

The value for the `Content-Security-Policy` header. CSP provides a defence-in-depth mechanism against XSS and data injection attacks by declaring which content sources the browser should trust.

Set to an empty string to disable (default).

```
api_gateway.http.security_headers.content_security_policy = default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'
```

Default: empty (disabled)

> **Note:** CSP policies are highly application-specific. Audit your application's actual asset sources (CDNs, fonts, third-party scripts, API endpoints) before enabling this in production to avoid breaking functionality.

## Server Header

#### `<prefix>.server_header`

Controls the `Server` response header. This can be used to suppress infrastructure information disclosure.

- `bondy` -- emits `bondy/<version>` (default)
- An empty string -- suppresses the header entirely
- Any other value -- emits that value verbatim

```
api_gateway.http.server_header = bondy
```

Default: `bondy`

> **Note:** If Bondy is behind a load balancer (e.g. AWS ALB), the load balancer may add its own `Server` header. Suppressing it at the Bondy level will not affect the load balancer's header. Use load balancer configuration (e.g. ALB custom response header rules) to handle that separately.

## Full example

A production-ready configuration for a public HTTPS listener:

```
## CORS -- restrict to known frontend origins
api_gateway.https.cors.enabled = on
api_gateway.https.cors.allowed_origins = https://app.example.com
api_gateway.https.cors.allowed_methods = GET,HEAD,OPTIONS,POST,PUT,PATCH,DELETE
api_gateway.https.cors.allowed_headers = origin,x-requested-with,content-type,accept,authorization
api_gateway.https.cors.max_age = 86400

## Security headers
api_gateway.https.security_headers.enabled = on
api_gateway.https.security_headers.hsts = max-age=31536000; includeSubDomains
api_gateway.https.security_headers.frame_options = DENY
api_gateway.https.security_headers.content_type_options = nosniff
api_gateway.https.security_headers.content_security_policy = default-src 'self'; frame-ancestors 'none'

## Suppress server version
api_gateway.https.server_header =
```

## Generating a default configuration file

To generate a complete `bondy.conf` file with all settings and their defaults:

```bash
make conf
```

This creates `config/bondy.conf.defaults` which can be used as a starting point for your configuration.
