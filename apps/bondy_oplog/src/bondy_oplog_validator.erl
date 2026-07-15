%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_validator).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Behaviour for the pluggable event validator.

The library wires `sign_event/2` on local appends and `verify_event/2`
on remote receipts; consumers configure the validator per instance
(see `bondy_oplog_instance:start_link/2` opts).

Two implementations ship with the library:

- `bondy_oplog_validator_trust` — no-op; suitable for closed
  trusted clusters.
- `bondy_oplog_validator_crypto` — Ed25519 signing with
  per-Origin hash chain; suitable for Byzantine-tolerant deployments.

`detect_equivocation/2` is invoked when a peer-received event collides
with an already-known event under the same `{HLC, Origin, Seq}`. The
trust implementation returns `ok`; the crypto implementation returns
`{equivocation, Proof}` when the two events constitute proof that the
Origin signed contradictory statements.

## Verifier state lifetime

The per-instance applier process captures a read-only snapshot of the
validator state at its `init/1` (`bondy_oplog_applier:init/1`) and
reuses that snapshot to verify every peer-received event. `verify_event/2`
is therefore called *off* the instance gen_server, with a state value
that may be older than the state currently held by any other consumer.

**Contract for implementations:** `verify_event/2` MUST be safe to run
with a snapshot of `State` that is stale relative to wall-clock — i.e.
all data that affects the accept/reject decision must be derived from
the event itself plus values present in `State` at applier-snapshot
time. There is no mechanism for the applier to observe later state
mutations *implicitly*.

## Snapshot refresh

Implementations that need runtime rotation/revocation (e.g. adding a
peer's public key without restarting the subtree) MAY export the
optional `refresh/1` callback. Operators trigger the refresh via
`bondy_oplog_instance:refresh_validator/1`, which asks the applier to
call `Mod:refresh(OldState)` and, on `{ok, NewState}`, atomically swap
its in-process snapshot.

- Implementations that do *not* export `refresh/1` are treated as
  "snapshot never refreshes" — `refresh_validator/1` is a no-op for
  those instances (a debug log is emitted).
- Refresh is **never automatic**: the only way to rotate a snapshot
  is the operator-facing API (or a validator implementation that
  wraps a config-server and casts the refresh on config-change).
- In-flight remote-event verifications that captured the *old*
  snapshot before the cast was processed continue to verify against
  that old snapshot — there is no mid-flight swap.

**Implementation contract for `refresh/1`:**

The applier handles the refresh cast on its main gen_server loop, so
`refresh/1` MUST be fast and synchronous — typical bound is a few
milliseconds. While it runs, the applier is not draining the WAL and
is not dispatching remote-event verifies, so a slow callback directly
adds drain latency.

If the refresh needs to pull from a remote source (config-server,
KMS, etc.), do the fetch outside `refresh/1` and have `refresh/1`
read from a cached snapshot maintained by a separate process —
typically the same process that fires the
`bondy_oplog_instance:refresh_validator/1` cast on config-change.
""").

-callback init(InstanceId :: binary(), Opts :: map()) ->
    {ok, State :: term()} | {error, Reason :: term()}.

-callback sign_event(Event :: bondy_oplog_event:t(), State :: term()) ->
    {SignedEvent :: bondy_oplog_event:t(), NewState :: term()}.

-callback verify_event(Event :: bondy_oplog_event:t(), State :: term()) ->
    ok | {error, Reason :: term()}.

-callback detect_equivocation(
    E1 :: bondy_oplog_event:t(),
    E2 :: bondy_oplog_event:t()
) -> ok | {equivocation, Proof :: term()}.

-callback refresh(State :: term()) ->
    {ok, NewState :: term()} | {error, Reason :: term()}.

%% Optional capability advertisement: return `true` only if
%% `sign_event/2` is a pure function of its arguments — i.e. it
%% returns the same `{SignedEvent, State}` for the same `{Event,
%% State}` and **never mutates** any external state (in the
%% callback module or process state). Validators that advertise
%% `is_stateless() -> true` are eligible for the lock-free
%% `bondy_oplog_instance:append_fast/2,3` path which signs in the
%% caller's process using a cached, immutable validator state. The
%% default (callback absent) is `false` — signing is routed
%% through the instance gen_server so the validator can mutate its
%% state safely.
-callback is_stateless() -> boolean().

-optional_callbacks([detect_equivocation/2, refresh/1, is_stateless/0]).
