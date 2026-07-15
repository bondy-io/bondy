<!--
SPDX-FileCopyrightText: 2016 - 2026 Leapsight
SPDX-License-Identifier: Apache-2.0
-->

# bondy_connect

An idiomatic, supervised, multi-session **WAMP client** for the Bondy
ecosystem. It is the replacement for the legacy `wamp_client` (which wrapped
`awre`), built fresh on Bondy's mature, router-independent WAMP building blocks
(`bondy_wamp`, `bondy_wamp_cryptosign`, `bondy_wamp_cra`, `bondy_regulator`,
`bondy_stdlib`).

`bondy_connect` is a client only — it has **no dependency on the `bondy` router
application** and can be embedded by external consumers via rebar3
`git_subdir`.

## Status



## Roles & capabilities (target)

- Roles: caller, callee, publisher, subscriber.
- Transports: WAMP raw socket (TCP/TLS/UDS), WebSocket (gun), in-VM local.
- Auth: anonymous, cryptosign, WAMP-CRA, ticket/password (SCRAM-ready).
- One connection ⇒ one session/realm; many connections concurrently.
- Per-call timeouts, CANCEL/INTERRUPT, progressive results; reconnect with
  re-REGISTER/re-SUBSCRIBE replay; isolated, load-regulated handler execution.
