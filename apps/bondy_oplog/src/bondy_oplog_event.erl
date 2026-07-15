%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_event).

-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Event identity and event record helpers for the MST event-store
replication layer.

## Identity

An *event key* is a `{HLC, Origin, Seq}` triple that is globally unique
*by construction*:

- `HLC` — a 64-bit Hybrid Logical Clock value (see `bondy_oplog_hlc`).
- `Origin` — the opaque binary id of the creating replica.
- `Seq` — a per-Origin monotonic counter; never reused or rolled back.

The triple is stored as a 3-tuple so that `ets:ordered_set` sorts events
lexicographically: by HLC first (time order), then Origin (deterministic
tie-break across replicas), then Seq (per-origin sequence). This is also
the order in which events are delivered to the COG-Interpreter.

## Event payload

The `op` and `meta` fields are opaque to the replication layer. They
carry, respectively, the operation (the client's intention) and the
tier-specific causal metadata.

## Public surface

The `key/1` and `event/3` constructors hide the record internals. Modules
that import the header may pattern-match on the records directly.
""").

-type event_key() :: #bondy_oplog_event_key{}.
-type t() :: #bondy_oplog_event{}.
-type op() :: term().
-type meta() :: undefined | term().

-export_type([event_key/0]).
-export_type([t/0]).
-export_type([op/0]).
-export_type([meta/0]).

-export([key/3]).
-export([key_hlc/1]).
-export([key_origin/1]).
-export([key_seq/1]).
-export([compare_keys/2]).
-export([is_key/1]).
-export([new/3]).
-export([new/5]).
-export([key/1]).
-export([op/1]).
-export([meta/1]).
-export([prev_hash/1]).
-export([signature/1]).
-export([set_prev_hash/2]).
-export([set_signature/2]).
-export([min_key/0]).
-export([max_key_for_hlc/1]).

%% =============================================================================
%% API
%% =============================================================================

?DOC("""
Constructs an event key. The caller is responsible for ensuring the
`{HLC, Origin, Seq}` triple is fresh — typically this is done by
`bondy_oplog_instance` rather than the application.
""").
-spec key(bondy_oplog_hlc:hlc(), bondy_oplog_origin:t(), non_neg_integer()) ->
    event_key().

key(HLC, Origin, Seq) when
    is_integer(HLC),
    HLC >= 0,
    is_binary(Origin),
    is_integer(Seq),
    Seq >= 0
->
    #bondy_oplog_event_key{hlc = HLC, origin = Origin, seq = Seq}.

-spec key_hlc(event_key()) -> bondy_oplog_hlc:hlc().
key_hlc(#bondy_oplog_event_key{hlc = HLC}) -> HLC.

-spec key_origin(event_key()) -> bondy_oplog_origin:t().
key_origin(#bondy_oplog_event_key{origin = O}) -> O.

-spec key_seq(event_key()) -> non_neg_integer().
key_seq(#bondy_oplog_event_key{seq = S}) -> S.

?DOC("""
Three-way compare. Records compare element-wise in Erlang's term order;
this helper is provided so callers do not need to import the header.
""").
-spec compare_keys(event_key(), event_key()) -> lt | eq | gt.

compare_keys(A, B) when A =:= B -> eq;
compare_keys(A, B) when A < B -> lt;
compare_keys(_, _) -> gt.

-spec is_key(term()) -> boolean().
is_key(#bondy_oplog_event_key{}) -> true;
is_key(_) -> false.

?DOC("""
Constructs an event.
""").
-spec new(event_key(), op(), meta()) -> t().

new(#bondy_oplog_event_key{} = K, Op, Meta) ->
    #bondy_oplog_event{key = K, op = Op, meta = Meta}.

?DOC("""
Constructs an event with explicit `prev_hash` and `signature`.
Used by the crypto validator after signing.
""").
-spec new(
    event_key(),
    op(),
    meta(),
    PrevHash :: undefined | binary(),
    Signature :: undefined | binary()
) -> t().

new(#bondy_oplog_event_key{} = K, Op, Meta, PrevHash, Signature) ->
    #bondy_oplog_event{
        key = K,
        op = Op,
        meta = Meta,
        prev_hash = PrevHash,
        signature = Signature
    }.

-spec key(t()) -> event_key().
key(#bondy_oplog_event{key = K}) -> K.

-spec op(t()) -> op().
op(#bondy_oplog_event{op = Op}) -> Op.

-spec meta(t()) -> meta().
meta(#bondy_oplog_event{meta = M}) -> M.

-spec prev_hash(t()) -> undefined | binary().
prev_hash(#bondy_oplog_event{prev_hash = P}) -> P.

-spec signature(t()) -> undefined | binary().
signature(#bondy_oplog_event{signature = S}) -> S.

-spec set_prev_hash(t(), undefined | binary()) -> t().
set_prev_hash(#bondy_oplog_event{} = E, P) ->
    E#bondy_oplog_event{prev_hash = P}.

-spec set_signature(t(), undefined | binary()) -> t().
set_signature(#bondy_oplog_event{} = E, S) ->
    E#bondy_oplog_event{signature = S}.

?DOC("""
Returns the smallest possible event key. Useful as the lower bound for
range scans before any compaction watermark has been established.
""").
-spec min_key() -> event_key().

min_key() ->
    #bondy_oplog_event_key{hlc = 0, origin = <<>>, seq = 0}.

?DOC("""
Returns a sentinel key that is greater than every event key with the
given HLC. Useful as an exclusive upper bound for range scans.

Since the term order on tuples falls back to element-wise comparison
and `<<255, ...>>` of any length is larger than any practical Origin,
this sentinel is correct for any Origin shorter than 256 bytes — which
covers every documented Origin format (16-byte UUID, 32-byte SHA-256).
""").
-spec max_key_for_hlc(bondy_oplog_hlc:hlc()) -> event_key().

max_key_for_hlc(HLC) when is_integer(HLC), HLC >= 0 ->
    %% 256 bytes of 0xFF dominates any Origin we accept.
    Sentinel = binary:copy(<<255>>, 256),
    #bondy_oplog_event_key{
        hlc = HLC,
        origin = Sentinel,
        seq = 16#FFFFFFFFFFFFFFFF
    }.
