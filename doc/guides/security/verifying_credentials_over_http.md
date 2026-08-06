# Verifying Credentials over HTTP

Bondy exposes an endpoint that answers one question: *is this caller
authenticated, and who are they?* It exists so that a reverse proxy can gate
content on a Bondy identity without itself understanding JWTs, realms or key
rotation.

The motivating case is an NGINX server serving a static site next to Bondy. A
user signs in to a web application through Bondy — over OIDC, or over WAMP — and
NGINX needs to decide whether to serve them the site. With `auth_request`, NGINX
needs exactly one thing: a URL that answers `2xx` for yes and `401` for no.

## Enabling the endpoint

The endpoint is mounted automatically for every API Gateway specification that
declares an `oidc` or an `oauth2` security scheme. It is bound to that
specification's realm, host and base path:

| Security scheme | Path |
| --- | --- |
| `oidc` | `<base_path>/oidc/verify` |
| `oauth2` | `<base_path>/oauth/verify` |

Override the path with the `verify_path` key of the security object, the same
way `token_path` overrides the OAuth2 token endpoint:

```json
"security": {
  "type": "oidc",
  "provider": "keycloak",
  "verify_path": "/oidc/check"
}
```

An API version does not need to declare any paths of its own. A specification
whose only purpose is to expose the security scheme endpoints is a valid and
useful thing to write:

```json
{
  "id": "com.example.docs",
  "host": "_",
  "realm_uri": "com.example",
  "variables": {
    "oidc": { "type": "oidc", "provider": "keycloak" }
  },
  "defaults": { "security": "{{variables.oidc}}", "schemes": ["https"] },
  "versions": {
    "1.0.0": { "base_path": "/docs", "paths": {} }
  }
}
```

> #### Path shadowing {: .warning}
>
> The default paths are two segments deep on purpose. Routes are matched in
> ascending path order and the first match wins, so an API path such as `/:id`
> would shadow a one-segment `/verify`. Keep `verify_path` at two or more
> segments unless you are sure no binding path can collide with it.

## Presenting a credential

`GET` (or `HEAD`), with the credential in one of the following, in order of
precedence:

1. `Authorization: Bearer <credential>`
2. `X-Bondy-Ticket: <ticket>`
3. the `bondy_ticket_<RealmUri>` cookie set by the OIDC authorization code flow

The first source carrying a value is the one verified — there is no fallback to
a later source if it turns out to be invalid.

Both a Bondy ticket and an OAuth2 access token are accepted; they are told apart
by their claims and routed to the matching verifier.

> #### The ticket cookie is HttpOnly {: .info}
>
> A browser application cannot read the cookie Bondy sets during the OIDC flow.
> An application that needs to present a ticket explicitly — the `X-Bondy-Ticket`
> or `Authorization` forms above — should obtain one from the
> `bondy.ticket.issue` WAMP procedure.

## Responses

A valid credential answers `200`, with the identity both as JSON and as response
headers. The headers exist so a proxy can propagate the identity upstream:

| Header | Meaning |
| --- | --- |
| `x-bondy-authid` | the authenticated user |
| `x-bondy-authrealm` | the realm that issued the credential |
| `x-bondy-realm` | the realm the credential was verified against |
| `x-bondy-authroles` | comma-separated roles |
| `x-bondy-authmethod` | the method behind the credential, e.g. `oidcrp` |
| `x-bondy-expires-at` | expiry, epoch seconds |

```json
{
  "active": true,
  "authid": "alice",
  "authrealm": "com.example",
  "realm": "com.example",
  "authroles": ["staff"],
  "authmethod": "oidcrp",
  "scope": {"realm": "com.example", "client_id": "all", "device_id": "all"},
  "issued_at": 1754400000,
  "expires_at": 1754403600,
  "expires_in": 3600
}
```

Anything else answers `401` with `{"active": false, ...}`. There are deliberately
only two outcomes: NGINX `auth_request` reads `401` and `403` as a denial and
turns every other non-2xx into a `500` for the end user, so conditions that are
arguably server-side — an unknown realm, an internal failure — are still
reported as `401`, with the real cause in Bondy's log.

Note that this differs from RFC 7662 token introspection, which answers `200`
with `"active": false` for a bad token. A proxy would read that as *allow*.

## What is verified

Signature, expiry and revocation, plus the checks Bondy applies when a WAMP
session is opened:

- the credential's scope covers the realm, **and** its issuer is trusted by that
  realm — the scope check alone is not enough, because an SSO-scoped credential
  matches every realm
- the user still exists and is enabled
- the realm still allows connections
- for access tokens, the `token_version` gate

Authorization is out of scope. The endpoint reports who the caller is, not what
they may do; gate on `x-bondy-authroles` in the proxy if you need more.

> #### Logout only closes the gate if revocation is enforced {: .warning}
>
> Logging out revokes the ticket, but `security.ticket.allow_not_found` defaults
> to `on`, which makes verification fall back to trusting the signature when the
> stored copy is gone. A logged-out ticket therefore keeps verifying until it
> expires — and an OIDC ticket's lifetime is the greater of the configured
> ticket expiry and the IdP refresh token's TTL, which can be days.
>
> Set `security.ticket.allow_not_found = off` if the gate must close on logout.
> The trade-off is that a node which has not yet replicated a freshly issued
> ticket will reject it until anti-entropy catches up.

## NGINX

### The browser holds the cookie

`auth_request` forwards the original request's headers, so the browser's cookie
reaches Bondy without any extra work. The subrequest carries no body, so
`proxy_pass_request_body` is turned off.

```nginx
location /docs/ {
    auth_request /_bondy_verify;

    auth_request_set $authid    $upstream_http_x_bondy_authid;
    auth_request_set $authroles $upstream_http_x_bondy_authroles;
    proxy_set_header X-User     $authid;
    proxy_set_header X-Roles    $authroles;

    root /var/www;
}

location = /_bondy_verify {
    internal;
    proxy_pass              http://bondy:18080/docs/oidc/verify;
    proxy_pass_request_body off;
    proxy_set_header        Content-Length "";
}

# Send an unauthenticated visitor to the login flow rather than a bare 401.
error_page 401 = @login;
location @login {
    return 302 https://bondy.example.com/docs/oidc/login?redirect_uri=$request_uri;
}
```

> #### The cookie must reach the docs host {: .warning}
>
> Bondy sets the ticket cookie without a `Domain` attribute unless the OIDC
> provider is configured with `cookie_domain`, which makes it host-only for
> whichever host served the OIDC callback. If the site sits on a different
> hostname the browser will never send the cookie and every request will be
> denied. Set `cookie_domain` to a parent domain both hosts share — and note
> that this widens where the cookie is sent.

### The application holds the ticket

A WAMP application that obtained a ticket from `bondy.ticket.issue` sends it to
NGINX explicitly. Pass it through as a header — `auth_request` subrequests carry
no body, so a JSON body cannot be relayed this way:

```nginx
location = /_bondy_verify {
    internal;
    proxy_pass              http://bondy:18080/docs/oidc/verify;
    proxy_pass_request_body off;
    proxy_set_header        Content-Length "";
    proxy_set_header        X-Bondy-Ticket $http_x_bondy_ticket;
}
```

### Caching

Responses carry `Cache-Control: no-store` and a `Vary` over every credential
source. To let NGINX cache verification results, opt in explicitly with
`proxy_cache` plus `proxy_ignore_headers Cache-Control`, and keep the cache
short — a cached `200` outlives revocation and disablement by its own TTL.

## CORS

The endpoint emits no `Access-Control-Allow-*` headers, so a browser will not
let a foreign origin read the identity of a user whose cookie it can nonetheless
cause to be sent. It is meant to be called by a proxy, server to server. For the
same reason it requires no CSRF token: the request is safe, and a proxy has none
to send.
