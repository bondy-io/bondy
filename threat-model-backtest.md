# Threat-model backtest — producer-side record

**Not part of the published deliverable.** This file holds the phase-3.6
corpus and routing table. It stays on the producer side: the model's §1.11
carries only de-identified worked examples, and §1.15 carries only the entries
that survived the rules in that section.

- **Model under test**: `threat-model.md`, `feature/mcp` @ `aab3fc5d` + working tree
- **Date**: 2026-08-29
- **Corpus**: 28 items in 12 clusters — **17 carry a real historical outcome**, 11 are synthesized to cover families with no recorded history.

## Corpus construction

The real items come from Bondy's internal eight-subsystem security review
(2026-07-15, re-validated 2026-07-16), whose durable records are no longer in
the tree. Each carries a known historical outcome: fixed, deferred, or ruled
acceptable. That makes it a genuine backtest rather than a self-consistency
check — the model was written before these were routed, and routing was done
blind against the document, not from memory of the findings.

The 11 synthesized items cover F2 (longpoll/SSE), F3 (decoder limits), F8
(storage), F9 (MCP, connectors), and F10 (admin), which have no recorded
finding history.
They are marked as synthesized and are **not** counted as historical evidence.

## Routing table

Legend: **hist** = actual historical outcome. **route** = disposition the model
assigns, blind. ✅ = consistent. ⚠️ = flagged for action.

| # | Cluster | Item (abbreviated) | Real? | hist | route | |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | serialization | Pre-auth BERT frame → `binary_to_term/1` without `[safe]` → atom exhaustion → node crash | real | fixed | `VALID` (P-WIRE-ATOM-SAFETY) | ✅ |
| 2 | serialization | Peer-shipped CRDT bytes decoded without `[safe]` | real | fixed | `VALID` (P-OWN-BYTES-RULE, condition (c) fails) | ✅ |
| 3 | serialization | Scanner: `binary_to_term/1` without `[safe]` in `bondy_oplog_crdt_*` | synth | — | `KNOWN-NON-FINDING (closed)` (KNF-OWN-BYTES) | ✅ |
| 4 | authn-forgery | Cross-realm auth via SSO-scoped token + username collision | real | fixed | `VALID` (P-ISSUER-TRUST) — **re-routed after the 2026-08-29 verification pass**; see *Revision 4* | ✅ |
| 5 | authn-forgery | JWT verification not algorithm-pinned | real | fixed | `VALID` (P-JWT-ALG-PINNED) | ✅ |
| 6 | authn-forgery | `exp` treated as duration + leeway extends validity; no `nbf` | real | open | `BY-DESIGN: property-disclaimed` **(closed)** — P-TOKEN-LIFETIME + D-TOKEN-NBF, after the Q31 ruling | ✅ |
| 7 | authn-leak | Username enumeration via distinct ABORT reason URIs | real | fixed | `VALID` (P-GENERIC-AUTH-FAILURE) | ✅ |
| 8 | authn-leak | Non-constant-time CRA/SCRAM comparison | real | **fixed 2026-08-30** | `VALID` — P-CONSTANT-TIME-COMPARE now covers both strategies. The backtest is what surfaced that CRA was broken too, which the draft had claimed was covered. | ✅ |
| 9 | authz | RBAC prefix grants match byte-wise, not component-wise | real | fixed | `VALID` (P-REALM-ISOLATION) — **re-routed after the verification pass**; see *Revision 4* | ✅ |
| 10 | authz | Per-session RBAC context stale; revocation not honoured on live sessions | real | fixed | `VALID` (P-REVOCATION-INVALIDATION) — **re-routed**; the disclaimer was over-broad, see *Revision 5* | ✅ |
| 11 | gateway | `basic`/`oidc` endpoints fall through to anonymous | real | fixed | `VALID` (P-GATEWAY-FAIL-CLOSED) | ✅ |
| 12 | gateway | Source IP derived from spoofable forwarding headers | real | fixed | `VALID` (P-PROXY-TRUST-BOUNDED) | ✅ |
| 13 | cluster | Peer plane unauthenticated and unencrypted by default | real | ruled acceptable | `OUT-OF-MODEL: adversary-not-in-scope (closed)` (§1.10 + D-PEER-PLANE) | ✅ |
| 14 | cluster | Replicated security cells merged without origin authentication | real | open, gated by #13 | `OUT-OF-MODEL: adversary-not-in-scope (closed)` (same) | ✅ |
| 15 | secrets | PBKDF2 default 10k iterations, capped at 65,536 | real | fixed | `VALID` (P-PASSWORD-KDF) | ✅ |
| 16 | secrets | Realm private signing keys stored unencrypted at rest | real | fixed (opt-in) | `VALID` (P-KEYRING-FAIL-CLOSED) — see *Revision 1* | ✅ |
| 17 | availability | No rate limiting on the router inbound path | real | fixed | `VALID` (P-AUTH-RATE-LIMITED) — see *Revision 2* | ✅ |
| 18 | defaults | Hardcoded admin credentials + admin API on 0.0.0.0 | real | fixed | `VALID` (P-SAFE-DEFAULTS) — see *Revision 3* | ✅ |
| 19 | defaults | Master realm grants `anonymous` `wamp.call` on all URIs | real | fixed | `VALID` (P-SAFE-DEFAULTS) | ✅ |
| 20 | transports | Longpoll session token guessable from observed ids | synth | — | `VALID` (P-SESSION-ID-ENTROPY) | ✅ |
| 21 | serialization | Deeply nested CBOR exhausts memory before the frame cap | synth | — | `BY-DESIGN: property-disclaimed` **(closed)** — no depth limit exists; work stays bounded by the frame cap | ✅ |
| 22 | mcp | Tool enumeration via `404` vs `403` differences | synth | — | `VALID` (P-MCP-INDISTINGUISHABLE) | ✅ |
| 23 | mcp | Client forges `_mcp_state` kwarg to impersonate the input channel | synth | — | `VALID` (P-MCP-STATE-SEALED) | ✅ |
| 24 | egress | Event payload injected into a Kafka consumer downstream | synth | — | `BY-DESIGN: property-disclaimed` **(closed)** — D-EGRESS-TAINT, maintainer-ruled. A mail *header* injection would instead route `VALID`. | ✅ |
| 25 | egress | Gateway `forward` target templated from request data → SSRF | synth | — | `BY-DESIGN: property-disclaimed` **(closed)** — D-GATEWAY-EGRESS; spec authorship is control-plane authority | ✅ |
| 26 | admin | Admin unix socket world-writable | synth | — | `VALID` (P-ADMIN-SOCKET-PERMS) — the socket is `0600` and the listener refuses to start otherwise | ✅ |
| 27 | availability | Pub/sub fan-out amplification from one publish | synth | — | `BY-DESIGN: property-disclaimed` **(closed)** — D-DOS-BEYOND-LIMITS keeps fan-out after the Q12 narrowing | ✅ |
| 28 | authn-leak | Scanner: `rand:uniform/1` generating a session identifier | synth | — | `KNOWN-NON-FINDING (closed)` (KNF-SESSION-ID) | ✅ |

## Disposition histogram

Two runs are shown: the original phase-3.6 pass, and a re-route after the
2026-08 maintainer rulings and code-verification pass answered 30 of the 31
open questions.

| Disposition | Original | After rulings |
| --- | --- | --- |
| `VALID` | 13 | **18** |
| `VALID-HARDENING` | 0 | **1** |
| `escalated` (route correct, licensing claim unratified) | 8 | **0** |
| `BY-DESIGN: property-disclaimed` **(closed)** | 0 | **5** |
| `OUT-OF-MODEL: adversary-not-in-scope` **(closed)** | 2 | 2 |
| `KNOWN-NON-FINDING` **(closed)** | 2 | 2 |
| `MODEL-GAP` | 2 | **0** |

- **Share that closes outright**: 9 of 28 = **32%**, up from 14%. That rise is the point of the exercise: before the rulings the model knew the right route but lacked the authority to use it, so it escalated instead.
- **Escalations went to zero.** Every disposition is now licensed by a **documented** or **maintainer** claim.
- **`MODEL-GAP`s went to zero.** Both became real contract statements rather than silences.
- **Fail-safe figure — historically-fixed items routing to a closing disposition: 0.** Unchanged, and still the number that matters. Every one of the 13 historically-fixed items routes `VALID`. The five `BY-DESIGN` closes are items the project either left open deliberately (6) or that were synthesized (21, 24, 25, 27); the two adversary closes are the peer-plane pair, ruled a supported posture conditioned on network isolation.

## Revisions the backtest forced

Three items initially routed to `MODEL-GAP` or to a wrong close. Each was fixed
by **narrowing or adding a claim**, never by widening a disclaimer to reach a
close.

**Revision 1 — D-AT-REST-PLAINTEXT over-closed item 16.** The disclaimer as
first written closed any report that key material sits in plaintext. But the
historical finding was *"there is no way to encrypt these keys"*, and that is
now false. Closing it would have answered a fixed defect with "by design". The
Conditions cell was narrowed so the disclaimer covers exactly one claim — that
the shipped **default** is plaintext — while "plaintext despite `master_key`
being set" and "no mechanism exists" both route `VALID` via
P-KEYRING-FAIL-CLOSED.

**Revision 2 — no property covered *absence* of rate limiting (item 17).** The
model had only D-RATE-LIMIT-FAILOPEN, which would have closed "credential
stuffing is unbounded" as disclaimed. Added **P-AUTH-RATE-LIMITED**, which
claims the limiter *is consulted* on the auth path, and drew the line
explicitly: "this path never consults the limiter" is `VALID`; "the limiter
admitted my request because it failed open" is disclaimed.

**Revision 3 — no property covered shipped defaults (items 18, 19).** Both
routed `MODEL-GAP`: P-AUTHZ-DEFAULT-DENY was not violated, because a grant did
exist — it was simply far too broad. Added **P-SAFE-DEFAULTS**, scoped to the
default configuration of a fresh install and explicitly not to a deployment the
operator has since opened up.

**Also corrected, though not a routing failure:** item 12 exposed a factual
error in the draft. §1.6, §1.13, and §1.14 M3 all described proxy-header trust
as unbounded and told the operator to set `trusted_proxies` for safety. Reading
`bondy_http_proxy_protocol.erl:80-95` showed the opposite — with no
`trusted_proxies` configured, no peer is trusted and a spoofed header cannot
move `source_ip`. The draft had been written from a stale recollection of the
pre-fix state. All three sections were rewritten, and P-PROXY-TRUST-BOUNDED was
added.

**Revision 4 — the verification pass re-routed items 4 and 9 from `escalated` to
`VALID`.** Both hung on `P-REALM-ISOLATION` being an unratified candidate. Reading
`bondy_wamp_uri:match/3` showed prefix matching is component-boundary based and
falsifier-pinned by two suites, so the property is now **documented**. Reading
`bondy_realm:is_trusted_issuer/2` showed the cross-realm issuer hole is closed
too, which is a *different* mechanism from URI matching — item 4 had been routed
against the wrong property. It now cites `P-ISSUER-TRUST`.

**Revision 5 — `D-REVOCATION-IMMEDIACY` was over-broad and would have closed item
10 once ratified.** The draft disclaimed immediacy outright on the strength of a
300-second refresh interval. The moduledoc and `invalidate_sessions_on/2` show
the interval is a *backstop*: every grant and revoke invalidates the node's
cached contexts, and the session re-resolves on its next authorization. The
disclaimer was narrowed to the **cross-node** window only, and the local
behaviour promoted to `P-REVOCATION-INVALIDATION`. Had this shipped unrevised, a
future Q14 answer of "yes, disclaim it" would have turned a fixed defect into a
`BY-DESIGN` close.

**Also corrected by the pass, outside the routing table:** §1.5 claimed Bondy
spawns no child processes. An exhaustive `grep -rn "os:cmd\|open_port" apps/*/src/`
found two `spawn_executable` sites, both cryptosign signing helpers. The claim
was inverted, and the inventory row now says so.

## Remaining MODEL-GAPs

Both are genuine silences, not routing failures, and both now have questions.
Neither was patched with a disclaimer, because the safe direction is not
obviously the intended one:

- **Item 8 — timing side channels in credential comparison.** → **Q30**.
- **Item 6 — token lifetime and leeway semantics.** → **Q31**.

## Coverage by component family

| Family | Items | Real | Note |
| --- | --- | --- | --- |
| F1 session/protocol | 1 | 0 | Thin. Amplification only. |
| F2 transports | 1 | 0 | Synthesized only. |
| F3 serialization | 4 | 2 | Strongest cluster. |
| F4 authentication | 6 | 5 | Strong. |
| F5 authorization | 2 | 2 | Both escalate on Q15/Q14. |
| F6 gateway | 3 | 2 | Good. |
| F7 cluster | 2 | 2 | Both close on the peer-plane adversary row. |
| F8 storage | 2 | 1 | Adequate. |
| F9 egress/MCP | 4 | 0 | **No history** — MCP is new. Synthesized only. |
| F10 admin | 1 | 0 | **Weakest.** One synthesized item; Q19 open. |

F10 and F9 are the coverage gaps. They are new surfaces with no finding
history, so no corpus exists to sample. Re-run the backtest for these families
once real reports accumulate.

## §1.15 feed

Only two entries qualified for §1.15, and only after the section's own rules
were applied:

- **KNF-OWN-BYTES** — recurring, discharged by a property in the document (P-OWN-BYTES-RULE), names a symptom and attack class, and its component set matches. Admitted.
- **KNF-SESSION-ID** — same, discharged by P-SESSION-ID-ENTROPY. Admitted, with an explicit condition that a report treating the *external* id as a secret is a real finding, not a match.

**Rejected for §1.15**, deliberately: items 13 and 14 (peer plane) recur
constantly and are closed every time, which makes them tempting. They were kept
out because their close is an `OUT-OF-MODEL: adversary-not-in-scope` route.
§1.15 is first in the precedence order, so listing them there would promote a
scope decision above the scope check that should make it.
