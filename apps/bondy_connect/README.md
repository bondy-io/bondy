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



## Supported WAMP features

`bondy_connect` only advertises a feature in `HELLO.Details.roles` when it
actually implements the corresponding behaviour end to end (advertise ==
handle) -- see `bondy_connect_config.erl`.

### Authentication

* [x] Anonymous
* [x] Cryptosign
* [x] Ticket
* [x] WAMP-CRA
* [ ] WAMP-SCRAM

### Advanced RPC features (caller / callee)

* [x] Call Canceling
* [x] Call Timeouts
* [x] Caller Identification
* [x] Pattern-based Registration
* [x] Shared Registration
* [x] Registration Revocation -- handles an unsolicited `UNREGISTERED` from
      the router: drops the *established* registration but keeps the
      *declared* one, which replays on the next reconnect
* [x] Progressive Call Results -- as caller (`call_async/5` with
      `receive_progress => true`) and as callee (the `progress` fun injected
      into the handler details)
* [ ] Progressive Calls -- deferred (streaming call **arguments** from
      caller to callee)
* [ ] Call Retries (WIP -- `CALL.Options.retries` is accepted and forwarded
      on the wire, but neither the client nor the Dealer currently act on it)
* [ ] Sharded Registration

### Advanced Pub/Sub features (publisher / subscriber)

* [x] Pattern-based Subscription
* [x] Publisher Identification
* [x] Publisher Exclusion
* [x] Subscriber Black- and Whitelisting
* [x] Event Retention -- `get_retained` forwarded on `SUBSCRIBE`
* [ ] Payload Passthru Mode
* [ ] Subscription Revocation
* [ ] Sharded Subscription

### WAMP Transports

* [x] RawSocket (TCP)
* [x] RawSocket (TLS)
* [x] RawSocket (Unix Domain Socket)
* [x] WebSocket (via `gun`)
* [x] In-VM local (no socket, same node)
* [ ] E2E encryption

### Transport Serialization

* [x] JSON
* [x] Msgpack
* [x] CBOR

## Roles & capabilities

- Roles: caller, callee, publisher, subscriber.
- One connection ⇒ one session/realm; many connections concurrently.
- Reconnect with re-REGISTER/re-SUBSCRIBE replay of *declared* entries;
  session-scoped state established after connecting (e.g. a revocation) does
  not survive a reconnect.
- Isolated, load-regulated handler execution.
