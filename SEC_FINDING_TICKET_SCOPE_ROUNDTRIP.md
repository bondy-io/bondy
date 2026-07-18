# Finding: ticket scope sentinels do not survive the JWT round-trip

**Status:** confirmed by experiment (2026-07-18)
**Branch:** `develop-bdb`
**Severity:** high — ticket revocation is ineffective under the default configuration;
ticket authentication is completely broken under the non-default configuration.
**Components:** `bondy_ticket`, `bondy_auth_scope`, `bondy_auth_transport_cookie`,
`bondy_wamp_json`

---

## 1. Summary

`bondy_ticket` encodes a ticket's `scope` into a signed JWT using atom sentinels
(`all`, `undefined`). Those atoms do not survive JSON encode/decode identically:

| Erlang value at issue | JSON | Erlang value at verify | Round-trips? |
|---|---|---|---|
| `undefined` | `null` | `undefined` | **yes** |
| `all` | `"all"` | `<<"all">>` | **no** |

`bondy_ticket:scope_type/1` and `store_key/3` pattern-match on the **atom** `all`.
After decoding, `client_id` and `device_id` are the **binary** `<<"all">>`, so both
functions take different clauses at verify time than they did at issue time. The
resulting storage key differs, and `bondy_ticket:lookup/3` therefore **never finds a
persisted ticket** — for any scope type.

This is invisible in normal operation only because
`security.ticket.allow_not_found` defaults to `on`, which makes `verify/1` fall back
to trusting the bare JWT signature.

## 2. Root cause

`bondy_config.erl:321` installs a project-specific JSON codec:

```erlang
ok = jose:json_module(bondy_wamp_json),
```

`bondy_wamp_json` maps `undefined <-> null`, so `undefined` survives. It has no such
mapping for `all`, which is emitted as the string `"all"` and decoded as `<<"all">>`.

`bondy_ticket:verify/1` (`:311-312`) decodes and then only atomises **keys**:

```erlang
{jose_jwt, Claims0} = jose_jwt:peek(Ticket),
Claims = bondy_utils:to_existing_atom_keys(Claims0),
```

`bondy_utils:to_existing_atom_keys/1` (`bondy_utils.erl:87-102`) recurses into nested
maps but converts keys only — values pass through untouched. No scope normalisation
happens anywhere on the verify path.

### 2.1 Divergence, traced

For a plain local ticket (`client_id`/`device_id` unset, so both are atom `all`):

| | issue | verify |
|---|---|---|
| scope | `#{realm => <<"com.foo">>, client_id => all, device_id => all}` | `#{realm => <<"com.foo">>, client_id => <<"all">>, device_id => <<"all">>}` |
| `scope_type/1` | clause 3 `#{client_id := all}` → `local` | falls through to clause 4 → `client_local` |
| `store_key/3` | clause 4 → `{Authid, <<"com.foo">>, <<>>}` | clause 1 → `{Authid, <<"all">>, <<>>}` |

Stored under one key, looked up under another → `{error, not_found}`.

For a client-scoped ticket the `store_key` agrees, but the cell holds a list and
`list_key/1` (`:698`) diverges instead — `{<<"com.foo">>, all}` at store vs
`{<<"com.foo">>, <<"all">>}` at lookup — so `lists:keyfind/3` misses.

Every persistent scope type is affected.

## 3. Proof

`security.ticket.allow_not_found` is `true` in the CT harness
(`bondy_ct.erl:589`), which masks the defect. Flipping it to `false` and re-running
the suite:

```
%%% bondy_auth_ticket_SUITE ==> local_scope: FAILED
Failure/Error: ?assertMatch({ok,_,_}, bondy_auth:authenticate(?WAMP_TICKET_AUTH, Ticket, undefined, Ctxt1))
%%% bondy_auth_ticket_SUITE ==> client_scope_with_id: FAILED
%%% bondy_auth_ticket_SUITE ==> ticket_auth_full_flow: FAILED
===> Failures occurred running tests: 3
```

With the harness default (`true`) all 13 tests pass. The suite is green because the
fallback path is exercised, not because lookup works.

Instrumenting `do_issue/2` and `verify/1` and running `local_scope` shows the
divergence directly — same ticket, same session, no revocation involved:

```
=== TICKET-PROBE (issue) ===
  issued scope : #{realm => <<"com.example.test.auth_ticket">>,
                   client_id => all, device_id => all}
  scope_type   : local
  store_key    : {<<"user_1">>,<<"com.example.test.auth_ticket">>,<<>>}

=== TICKET-PROBE (verify) ===
  decoded scope : #{realm => <<"com.example.test.auth_ticket">>,
                    client_id => <<"all">>, device_id => <<"all">>}
  scope_type    : client_local
  lookup_key    : {<<"user_1">>,<<"all">>,<<>>}
  lookup result : {error,not_found}
```

Round-trip demonstrated directly against the configured codec:

```erlang
ok = jose:json_module(bondy_wamp_json),
%% enc(all)   : {"scope":{"realm":"all","client_id":"all","device_id":"all"}}
%% enc(undef) : {"scope":{"realm":null,"client_id":"all","device_id":"all"}}
%% dec(all)   : #{<<"realm">> => <<"all">>, ...}      %% atom lost
%% dec(undef) : #{<<"realm">> => undefined, ...}      %% atom preserved
```

## 4. Impact

**Under the default (`security.ticket.allow_not_found = on`, `schema/bondy.schema:953-957`):**
`verify/1` never resolves the stored copy and always falls back to trusting the
signature. Consequently `bondy_ticket:revoke/1,3` and `revoke_all/*` have **no effect
on authentication** — they delete a record that `verify/1` would never have read. A
revoked ticket keeps authenticating until it expires (default TTL 30 days,
`bondy_ct.erl:594`). The `persistence` config keys are likewise inert for verification.

**Under `security.ticket.allow_not_found = off`:** ticket authentication fails
outright for every scope type. An operator hardening this setting to obtain strict
revocation semantics — the natural reading of the schema doc — disables ticket auth.

Both positions of the flag are broken; the flag currently selects which of the two
failures you get.

### 4.1 Mode matrix

The relaxed/strict distinction is real and the strict-mode logic (`:337-353`) is
written correctly — it verifies the signature and then requires the stored copy to
match, which is exactly what makes revocation enforceable. The defect is that the
store check can never succeed, so the strict branch rejects live tickets on the same
`{error, not_found}` path a revoked ticket would take.

| mode | intended behaviour | actual behaviour |
|---|---|---|
| relaxed (`allow_not_found = on`, default) | JWT signature only; revocation knowingly not enforced | as intended — a revoked ticket still authenticates |
| strict (`off`) | JWT signature **and** store match; revocation enforced | **every** ticket rejected, revoked or not |

Revocation is therefore unobservable in either position: relaxed cannot reject a
revoked ticket, strict cannot accept a live one. Note this scopes the fix — the strict
path needs no redesign, only a normalised scope so the lookup key matches the stored
key.

## 5. Secondary defects found alongside

1. **Two sentinels for one concept.** `bondy_ticket:do_issue/2:526` emits `undefined`
   for the SSO wildcard; `bondy_oauth_token.erl:191-203` emits `all` for the identical
   concept and routes it through `bondy_auth_scope:new/3`. `bondy_ticket`'s non-client
   branch (`:613-625`) builds the scope map inline and bypasses that constructor.

2. **`scope_type/1` does not recognise `undefined`.** `#{realm => undefined,
   client_id => all}` misses the `realm := all` clauses and falls to `local`, so
   `authorize/2` (`:537`) checks `bondy.ticket.scope.local` instead of
   `bondy.ticket.scope.sso`. A user granted only local-ticket permission can mint an
   SSO-wide ticket. `is_persistent/1` also reads the wrong config key.

3. **`bondy_auth_scope:new/3` rejects `undefined`.** Its spec says
   `optional(binary())` but its guard (`bondy_auth_scope.erl:38-41`) requires
   `is_binary(X) orelse X == all`. `bondy_ticket:598` passes `undefined` on the
   client-ticket path → `function_clause`, swallowed by `issue/2`'s catch-all
   (`:297`) into `{error, function_clause}`. Client-SSO tickets cannot be issued.

4. **`matches_realm/2` does not recognise `undefined`** (`bondy_auth_scope.erl:82`).
   Only `bondy_oauth_jwt.erl:86` calls it, and that path sees token scopes (which use
   `all`), so tickets do not reach it today. Latent.

5. **Expired tickets are never reaped — the reaper is a stub.**
   `bondy_ticket:remove_expired/0` is exported (`:240`) but its entire body is:

   ```erlang
   remove_expired() ->
       ok.
   ```

   It has no `-spec` and no `-doc`, unlike every other exported function in the module
   — it was never implemented. So this is not merely "no caller": there is nothing to
   call. Ticket rows accumulate indefinitely in the `bondy_ticket` table, including
   rows for tickets that expired long ago (max lifetime 30 days —
   `expiry_time`/`max_expiry_time` both default to `30d` in `schema/bondy.schema:873,885`,
   and `expiry_time_secs/1` hard-caps at the max). The SSO rows orphaned by the fix in
   §7 will therefore not self-clean either.

   Adjacent gap: `revoke_all/3` (`:485`) is `error(not_implemented)`. `revoke/3`,
   `revoke_all/1` and `revoke_all/2` are implemented, all via
   `bondy_db:apply(Table, RealmUri, Key, clear)`.

   Designing the reaper is **not** a matter of adding a timer: every node holds a
   replica of every ticket, so a naive per-node reaper has N nodes independently
   issuing `clear` for the same keys. Whether that converges quietly or produces
   anti-entropy churn depends on bondy_db's delete/merge semantics and on whether AAE
   compares content digests or an applied-frontier version vector. This caused cyclic
   AAE under plum_db. Requires research plus a multi-node cluster test before
   implementation — see `bondy_ct:start_cluster/2` for the existing 3-node harness.

6. **`bondy_auth_scope:normalize/1` has no production callers** — only its own eunit
   tests — while `bondy_ticket` carries a private near-duplicate, `normalise_scope/1`
   (`:689`). Consolidate.

## 5a. Third consequence: client-ticket issuance was entirely broken

Found while implementing the fix. `bondy_ticket:scope/3`'s client-ticket branch
guards against nesting with:

```erlang
{ok, #{scope := #{client_id := Val}}} when Val =/= all ->
    throw({invalid_request, "Nested tickets are not allowed"});
```

`Val` comes from the decoded client ticket, so for a non-client-scoped ticket it was
`~"all"`, which satisfies `Val =/= all`. The guard therefore fired for **every**
`client_ticket`, making the entire Client-Local / Client-SSO issuance flow
unreachable — the documented flow in §86-106 of the module doc could never succeed.

Two CT assertions had been written against this behaviour and were pinning it:

- `bondy_auth_ticket_SUITE:local_scope` expected `"Nested tickets are not allowed"`
  where the correct rejection is `"Self-granting ticket not allowed"` (U1's own local
  ticket has `client_id = all`, so it is not nested — it is self-granted).
- `bondy_auth_ticket_SUITE:client_scope_with_ticket` expected an error from what is,
  by the test's own name and by the module doc, the **happy path** for Client-Local
  scope. It now asserts successful issuance plus a genuinely nested ticket being
  rejected.

## 6. Why "just switch `undefined` to `all`" is the wrong fix

It is the natural-looking fix and it makes things worse. `all` is precisely the
sentinel that does **not** round-trip. Changing `do_issue/2` to emit `all` would leave
the store/lookup divergence fully intact while additionally breaking the one code path
that currently works — `bondy_auth_transport_cookie:validate_claims/3:94`, which tests
`Uri == undefined` and relies on the `undefined <-> null` mapping.

`undefined` is not an accident. It is the only wildcard that survives the JWT
round-trip under `bondy_wamp_json`.

## 7. Recommended fix

The sentinel choice is not the bug; the **absence of scope normalisation on decode**
is. Fix in this order:

1. **Normalise the scope in `bondy_ticket:verify/1`** immediately after
   `to_existing_atom_keys/1`, before `scope_type/1` and `lookup/3` are called. Cast
   `<<"all">> -> all` and `undefined -> all`. `bondy_auth_scope:cast/1`
   (`:116-118`) already implements the string case; promote it into a public
   `from_decoded/1` (or reuse `new/3`) and apply it to all three fields. This makes the
   lookup key match the stored key and is backward-compatible with already-persisted
   tickets, since those were stored under the atom-derived key.

2. **Relax `bondy_auth_scope:new/3`** to accept `undefined` (casting it to `all`), or
   correct its spec to match its guard. Then route `bondy_ticket:scope/3`'s non-client
   branch through it so tickets and tokens share one constructor.

3. **Accept `all` at every scope-realm check.** There are **two** open-coded
   `Uri == undefined` checks, not one: `bondy_auth_transport_cookie:validate_claims/3`
   **and** `bondy_auth_ticket:authenticate/4:84`. Both must be updated together —
   missing the second one makes every ticket authentication fail with
   `invalid_ticket`. Prefer delegating to `bondy_auth_scope:matches_realm/2`.

   No deprecation window is needed: normalisation happens inside `verify/1`, which is
   upstream of every consumer, so `undefined` can no longer reach either check once the
   fix lands. Stored SSO rows keyed under the old `{Authid, undefined, <<>>}` do orphan,
   but they are already unreachable today (that is the bug), and the relaxed default
   ignores the store — so nothing that works today stops working.

4. **Only then** align `do_issue/2` on `all`, which becomes safe once (1) is in place.

5. **Fix `scope_type/1`** so the SSO wildcard is classified `sso`, restoring the
   `bondy.ticket.scope.sso` authorisation check (secondary defect 2).

6. **Add regression coverage** that pins the round-trip: a test that issues, encodes,
   decodes and asserts `lookup/3` succeeds — with `allow_not_found = false`, so the
   fallback cannot mask a regression. Consider running the whole ticket suite under
   both flag positions.

## 8. Note on `is_trusted_issuer`

The realm boundary for a wildcard-scoped ticket is enforced entirely by
`bondy_realm:is_trusted_issuer/2` (`bondy_realm.erl:993`):

```erlang
is_trusted_issuer(RealmUri, AuthRealmUri) ->
    AuthRealmUri =:= RealmUri orelse AuthRealmUri =:= sso_realm_uri(RealmUri).
```

Effective reach is `{R : R == authrealm} ∪ {R : sso_realm_uri(R) == authrealm}`, and
this set is **late-bound** — recomputed at each verification from the target realm's
current configuration. Pointing a new realm at an SSO realm retroactively widens every
outstanding ticket issued under it. Relevant if a forward-auth/verification endpoint is
exposed: it will return 200 for realms that did not exist when the ticket was minted.

Note also that the issue-side gate reads a different field than the verify-side
boundary: `bondy_ticket:519` consults `bondy_rbac_user:sso_realm_uri(User)` (the
**user's** SSO realm) while `authrealm` derives from `bondy_realm:sso_realm_uri(Realm)`
(the **realm's**, `bondy_auth.erl:182`). A user with an SSO realm on a session realm
without one receives a wildcard-scoped ticket whose real reach is a single realm. It
fails closed, but the scope claim is inaccurate and it feeds defect 2.
