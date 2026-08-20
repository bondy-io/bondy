# Mailpit

A real SMTP relay on localhost that keeps every message instead of delivering
it, and serves them over an HTTP API. Used by two things:

- `apps/bondy_mail/test/bondy_mail_mailpit_SUITE.erl`, the `bondy_mail`
  integration suite.
- The *Sending email with the SMTP bridge* tutorial, which is written against
  this stack so that it is executable rather than illustrative.

```bash
just mailpit          # or: cd examples/mailpit && docker compose up -d
just mailpit-clean
```

| | SMTP | Web UI and API | Transport | Auth |
| --- | --- | --- | --- | --- |
| `mailpit` | 1025 | <http://localhost:8025> | plain, STARTTLS | none |
| `mailpit-tls` | 1465 | <http://localhost:8026> | implicit TLS | `bondy` / `s3cret` |

Two instances because one Mailpit process serves one SMTP listener, and the
three transports Bondy speaks cannot share it: making the listener
implicit-TLS is what stops a `plain` or `starttls` client connecting to it.

## Certificates

`docker compose up` regenerates a certificate authority and a `localhost`
server certificate signed by it, into `certs/` (git-ignored). Both Mailpit
instances present the server certificate; anything verifying it points at
`certs/ca.pem`:

```
mail.relay.local.transport = starttls
mail.relay.local.tls.verify = verify_peer
mail.relay.local.tls.cacertfile = ./examples/mailpit/certs/ca.pem
```

An authority and a leaf, rather than one self-signed certificate, because a
self-signed leaf is refused as `selfsigned_peer` however trusted it is — so a
single certificate could not be used to exercise `verify_peer` at all.

## What this stack cannot tell you

Mailpit accepts every message and verifies almost nothing, and its certificate
is one generated here and then trusted here. It cannot exercise a public
certificate chain, a provider's own `EHLO` capabilities, or a real greylisting
`4xx` against the retry budget.

Those need a real relay. `apps/bondy_mail/test/bondy_mail_live_SUITE.erl` runs
against one, reading its details from `.env` at the repository root; it skips
when they are absent.
