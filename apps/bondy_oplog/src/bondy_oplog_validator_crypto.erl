%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_validator_crypto).
-behaviour(bondy_oplog_validator).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Cryptographic event validator for Byzantine-tolerant deployments.

The hash-chain + signature approach to detecting equivocation —
where a malicious origin signing two events with the same identity
produces a verifiable proof — is from Preston McCrary's *Canteen*
(UC Berkeley, 2022 — EECS-2022-160). We adapt it to a per-Origin chain
on the *signing* side; full strict-order verification on the receiving
side is deferred (see "Loose chain enforcement" below).

## Identity

Each replica has an Ed25519 key pair. The public key is the replica's
*Origin* (after `sha256` for fixed-size compactness). Two distinct
replicas cannot share an Origin without solving discrete-log on
Ed25519 — cryptographically infeasible.

Origin = `sha256(public_key)` (32 bytes).

## Per-event signature

`sign_event/2` populates two fields on outgoing events:

- `prev_hash` — SHA-256 of the previous event from the same Origin (or
  `<<0:256>>` for the first event). Forms a per-origin hash chain on
  the *signing* side.
- `signature` — Ed25519 signature over `canonical_payload(Event)`,
  which is a deterministic encoding of `(Key, Op, Meta, prev_hash)`.

`verify_event/2` recomputes the canonical payload, looks up the
Origin's public key, and verifies the Ed25519 signature.

## Loose chain enforcement

The chain bookkeeping is *signing-side only*. `verify_chain/3` checks
that `prev_hash` is present and well-formed but does not validate that
it points to the immediate predecessor — the validator behaviour
(`verify_event/2 -> ok | {error, _}`) does not provide a state-mutation
channel for stateful per-Origin verification. Equivocation remains
detectable when two valid signatures bind to the same
`{HLC, Origin, Seq}` (see below); strict per-Origin chain-order
verification is a future extension.

## Equivocation detection

If a Byzantine origin signs two events with the same `{HLC, Origin,
Seq}` but different `op`/`meta`/`prev_hash`, both signatures are
valid (they sign different statements with the same key). When two
honest replicas exchange these via anti-entropy, the strict-uniqueness
merger refuses to merge them — forcing the conflict to surface.

`detect_equivocation/2` is invoked by the consumer once it has two
suspect events; it returns `{equivocation, Proof}` where `Proof` is
both signed events. The proof is verifiable by any third party with
the offending Origin's public key.

## Configuration

`init/2` accepts:

| Key            | Default | Meaning |
|---|---|---|
| `keypair`      | `undefined` | `{PublicKey :: binary(), PrivateKey :: binary()}` — 32-byte and 64-byte respectively, as returned by `crypto:generate_key(eddsa, ed25519)`. Required for signing — `sign_event/2` raises `no_signing_keypair` when absent. |
| `peer_pubkeys` | `#{}` | `#{Origin :: binary() => PublicKey :: binary()}` — known peer public keys, including this replica's own. Required for verifying — origins absent from this map are rejected as `{unknown_origin, _}` unless `accept_unknown_origin` is set. |
| `accept_unknown_origin` | `false` | If `true`, events from unknown origins are accepted without signature verification (insecure; for staged rollouts only). |

## Trade-offs

- Signing adds ~80 µs per local append on commodity hardware (Ed25519
  signing is ~12 k ops/s/core).
- Verifying adds ~40 µs per remote receipt (Ed25519 verifying is
  ~30 k ops/s/core).
- Each event grows by 32 + 64 = 96 bytes (`prev_hash` + `signature`).
- Per-Origin chain state (`last_hash`) is held in the validator state
  on the signing side only.

These costs are appropriate for cluster-coordination workloads;
high-throughput per-message signing should batch at a higher layer.

## Snapshot refresh

The validator implements the optional `bondy_oplog_validator:refresh/1`
callback so operators can add or remove peer public keys (and flip
the `accept_unknown_origin` toggle) at runtime, without restarting
the subtree.

**What is refreshable**

| Field | Refreshable | Why |
|---|---|---|
| `peer_pubkeys` | yes | Used by `verify_event/2` on the applier; rotating the map adds/removes trusted peers. |
| `accept_unknown_origin` | yes | Verify-side toggle; safe to flip at runtime. |
| `keypair` | **no** | `sign_event/2` runs on the instance gen_server, not the applier. The applier's snapshot is verify-only; rotating its `keypair` would have no effect. Signing-key rotation requires a subtree restart. |
| `last_hash` | **no** | Signing-side per-Origin chain tail; mutates on every local append. Rotating it would corrupt the chain. |

**Operator flow**

```erlang
%% 1. Publish the new config under the per-instance key.
application:set_env(
    bondy_oplog,
    {validator_crypto, InstanceId},
    #{peer_pubkeys => NewPubkeys}  %% or accept_unknown_origin, or both
),

%% 2. Trigger the refresh. The applier reads the env, swaps the
%%    snapshot, and emits the
%%    `[bondy_oplog, applier, validator_refresh]` telemetry event.
ok = bondy_oplog_instance:refresh_validator(InstanceId, key_rotation).
```

**Semantics:**

- Refresh **merges** the pushed map into the current state: keys
  present in the pushed map replace their counterparts; keys absent
  are preserved. Operators rotating only `peer_pubkeys` need not
  re-push `accept_unknown_origin`.
- `refresh/1` returns `{error, no_refreshed_config}` if no env key
  is set, or `{error, invalid_refreshed_config}` if the value is
  not a map. The applier logs and keeps the previous snapshot.
- In-flight `verify_event/2` calls that captured the old snapshot
  continue to use it (see `bondy_oplog_applier` moduledoc).
""").

-record(state, {
    %% Captured at `init/2` and reused by `refresh/1` to look up
    %% the operator-pushed rotation payload in the application env.
    instance_id :: binary(),
    keypair :: undefined | {binary(), binary()},
    peer_pubkeys :: #{binary() => binary()},
    accept_unknown_origin :: boolean(),
    %% Per-Origin tail of the hash chain. Signing-side only — the
    %% hash of the last event we've signed for our own Origin. Used
    %% to seed `prev_hash` on the next local sign.
    last_hash :: #{binary() => binary()}
}).

-define(GENESIS_HASH, <<0:256>>).
-define(HASH_ALGO, sha256).

-export([init/2]).
-export([sign_event/2]).
-export([verify_event/2]).
-export([detect_equivocation/2]).
-export([refresh/1]).

%% =============================================================================
%% bondy_oplog_validator CALLBACKS
%% =============================================================================

init(InstanceId, Opts) when is_binary(InstanceId), is_map(Opts) ->
    {ok, #state{
        instance_id = InstanceId,
        keypair = maps:get(keypair, Opts, undefined),
        peer_pubkeys = maps:get(peer_pubkeys, Opts, #{}),
        accept_unknown_origin = maps:get(accept_unknown_origin, Opts, false),
        last_hash = #{}
    }}.

sign_event(_Event, #state{keypair = undefined}) ->
    error(no_signing_keypair);
sign_event(Event, #state{} = State) ->
    Key = bondy_oplog_event:key(Event),
    Origin = bondy_oplog_event:key_origin(Key),
    PrevHash = maps:get(Origin, State#state.last_hash, ?GENESIS_HASH),
    EventWithPrev = bondy_oplog_event:set_prev_hash(Event, PrevHash),
    {_PubKey, PrivKey} = State#state.keypair,
    Signature = crypto:sign(
        eddsa,
        ?HASH_ALGO,
        canonical_payload(EventWithPrev),
        [PrivKey, ed25519]
    ),
    Signed = bondy_oplog_event:set_signature(EventWithPrev, Signature),
    %% Advance our own chain tail.
    NewLastHash = (State#state.last_hash)#{
        Origin => event_hash(Signed)
    },
    {Signed, State#state{last_hash = NewLastHash}}.

verify_event(Event, #state{} = State) ->
    Key = bondy_oplog_event:key(Event),
    Origin = bondy_oplog_event:key_origin(Key),
    case maps:find(Origin, State#state.peer_pubkeys) of
        error when State#state.accept_unknown_origin ->
            ok;
        error ->
            {error, {unknown_origin, Origin}};
        {ok, PubKey} ->
            verify_with_key(Event, Origin, PubKey, State)
    end.

detect_equivocation(E1, E2) ->
    K1 = bondy_oplog_event:key(E1),
    K2 = bondy_oplog_event:key(E2),
    case K1 =:= K2 of
        false ->
            ok;
        true ->
            S1 = bondy_oplog_event:signature(E1),
            S2 = bondy_oplog_event:signature(E2),
            case S1 =:= S2 of
                true ->
                    %% Bit-identical events. Not equivocation;
                    %% legitimate idempotent re-receive.
                    ok;
                false ->
                    {equivocation, #{
                        origin => bondy_oplog_event:key_origin(K1),
                        event_one => E1,
                        event_two => E2
                    }}
            end
    end.

%% Refreshes the verification-side fields of the state from the
%% operator-pushed application env key
%% `{validator_crypto, InstanceId}` under the `bondy_mst`
%% application. Fields present in the pushed map replace their
%% counterparts in the current state; fields absent are kept.
%%
%% Only `peer_pubkeys` and `accept_unknown_origin` are refreshable
%% — see the "Snapshot refresh" section of the moduledoc for why
%% `keypair` and `last_hash` cannot be rotated through this path.
refresh(#state{instance_id = InstanceId} = State) ->
    case application:get_env(bondy_oplog, {validator_crypto, InstanceId}) of
        undefined ->
            {error, no_refreshed_config};
        {ok, NewOpts} when is_map(NewOpts) ->
            {ok, State#state{
                peer_pubkeys = maps:get(
                    peer_pubkeys, NewOpts, State#state.peer_pubkeys
                ),
                accept_unknown_origin = maps:get(
                    accept_unknown_origin,
                    NewOpts,
                    State#state.accept_unknown_origin
                )
            }};
        {ok, _Bad} ->
            {error, invalid_refreshed_config}
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
verify_with_key(Event, Origin, PubKey, State) ->
    Sig = bondy_oplog_event:signature(Event),
    case Sig of
        undefined ->
            {error, missing_signature};
        _ ->
            Payload = canonical_payload(Event),
            case
                crypto:verify(
                    eddsa,
                    ?HASH_ALGO,
                    Payload,
                    Sig,
                    [PubKey, ed25519]
                )
            of
                false ->
                    {error, invalid_signature};
                true ->
                    %% Signature checks; now validate the chain.
                    verify_chain(Event, Origin, State)
            end
    end.

%% @private
%% Loose chain check (see module doc): `prev_hash` must be present and
%% well-formed but is not validated against any per-Origin tail. A
%% stateful, strict verifier is a future extension.
verify_chain(Event, _Origin, _State) ->
    case bondy_oplog_event:prev_hash(Event) of
        undefined -> {error, missing_prev_hash};
        Bin when is_binary(Bin) -> ok
    end.

%% @private
%% Deterministic encoding for signing. `key`, `op`, `meta`, `prev_hash`
%% all hashed in. Excludes `signature` itself (we are computing it).
canonical_payload(Event) ->
    Key = bondy_oplog_event:key(Event),
    Op = bondy_oplog_event:op(Event),
    Meta = bondy_oplog_event:meta(Event),
    PrevHash = bondy_oplog_event:prev_hash(Event),
    erlang:term_to_binary(
        {Key, Op, Meta, PrevHash},
        [{minor_version, 2}]
    ).

%% @private
%% Hash of a fully-signed event (key + payload + signature). This is
%% what subsequent events on the same chain reference as `prev_hash`.
event_hash(Event) ->
    Sig = bondy_oplog_event:signature(Event),
    crypto:hash(
        ?HASH_ALGO,
        <<(canonical_payload(Event))/binary, Sig/binary>>
    ).
