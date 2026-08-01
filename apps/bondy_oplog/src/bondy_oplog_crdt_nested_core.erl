%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt_nested_core).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Shared **two-level add-wins-with-nesting** engine, used by
`bondy_oplog_crdt_aw_map` and `bondy_oplog_crdt_aw_set` to let a
dynamic-key entry's *value* itself be another CRDT's converged state,
rather than an opaque term.

## Why this exists

Both consumers share the identical shape `entries() :: #{OuterKey =>
dot_store()}`, `dot_store() :: #{dot() => value()}` — a key/element is
present iff its dot-store is non-empty, and a remove drops exactly the
dots its writer observed
(`bondy_oplog_crdt_aw_core:drop_observed/2`), leaving concurrent
(un-observed) writes as surviving siblings. That machinery is entirely
value-agnostic — `drop_observed/2` only ever inspects the *dot* (the
map key), never the value — so it already prunes a nested sub-op's dot
on a concurrent remove exactly as it prunes a flat value's dot today,
with no changes needed there. What this module adds is the *nested*
value itself: a value of `{sub, SubMod, Hlc, SubOp}` is replayed, on
read, through `SubMod`'s own `interpret_cog/2` — the same convergence
kernel every `bondy_oplog_crdt` module already implements — rather than
being stored as an opaque flat term.

## Restriction: tier_0 sub-CRDTs only

`SubMod` MUST be a `causal_tier() =:= tier_0` module (`pn_counter`,
`lww_register`, `max_register`, `min_register`, `g_counter`, ...). A
tier_0 sub-CRDT's `interpret_cog/2` needs only each sub-op's HLC to
linearize correctly (`bondy_oplog_crdt.erl`'s tier definitions), and
that HLC is already sitting in the parent's own dot/event key — no
nested causal-context (version-vector) threading is required.
Recursive tier_2-in-tier_2 nesting is a real but separately-scoped
extension, not attempted here.

## Type consistency

A key/element's `SubMod` is fixed by its first nested write — mixing a
flat `put/5` and `put_nested/7` on the same live key, or changing
`SubMod` on a live key, is a caller error and raises `{badarg, _}`: a
silent type mix would corrupt `nested_value/2`'s replay, which assumes
every surviving entry at a key shares one `SubMod`.
""").

-export([nested_value/2]).
-export([put/5]).
-export([put_nested/7]).
-export([rmv/3]).
-export([sub_mod/1]).

-type dot() :: bondy_oplog_crdt_aw_core:dot().
-type outer_key() :: term().
-type flat_value() :: term().
-type sub_value() :: {sub, module(), bondy_oplog_hlc:hlc(), term()}.
-type value() :: flat_value() | sub_value().
-type dot_store() :: #{dot() => value()}.
-type entries() :: #{outer_key() => dot_store()}.

-export_type([entries/0, dot_store/0, value/0, sub_value/0]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Put a flat value `V` at key `K`: drop every dot the writer's `Ctx`
observed, then add `V` under the operation's own `Dot`. Raises
`{badarg, {nested_key, K}}` if `K` currently holds nested sub-ops —
mixing flat and nested writes on the same key is a caller error.
""".
-spec put(
    Entries :: entries(),
    K :: outer_key(),
    Dot :: dot(),
    Ctx :: bondy_oplog_crdt_aw_core:vv(),
    V :: flat_value()
) -> entries().

put(Entries, K, Dot, Ctx, V) ->
    DS0 = maps:get(K, Entries, #{}),
    DS1 = bondy_oplog_crdt_aw_core:drop_observed(DS0, Ctx),
    sub_mod(DS1) =:= undefined orelse error({badarg, {nested_key, K}}),
    Entries#{K => DS1#{Dot => V}}.

-doc """
Put a sub-operation `SubOp` (targeting sub-CRDT `SubMod`) at key `K`:
drop every dot the writer's `Ctx` observed, then add the tagged
sub-operation under the operation's own `Dot`. Raises `{badarg,
{sub_mod_mismatch, K, Expected, Got}}` if `K` already holds sub-ops for
a *different* `SubMod`, or `{badarg, {flat_key, K}}` if `K` currently
holds a flat (non-nested) value.
""".
-spec put_nested(
    Entries :: entries(),
    K :: outer_key(),
    Dot :: dot(),
    Ctx :: bondy_oplog_crdt_aw_core:vv(),
    SubMod :: module(),
    Hlc :: bondy_oplog_hlc:hlc(),
    SubOp :: term()
) -> entries().

put_nested(Entries, K, Dot, Ctx, SubMod, Hlc, SubOp) ->
    DS0 = maps:get(K, Entries, #{}),
    DS1 = bondy_oplog_crdt_aw_core:drop_observed(DS0, Ctx),
    ok = check_sub_mod(DS1, K, SubMod),
    Entries#{K => DS1#{Dot => {sub, SubMod, Hlc, SubOp}}}.

-doc """
Observed-remove at key `K`: drop every dot the writer's `Ctx` observed
(flat or nested, uniformly — `drop_observed/2` never inspects the
value). Drops `K` from `Entries` entirely once its dot-store empties.
""".
-spec rmv(
    Entries :: entries(),
    K :: outer_key(),
    Ctx :: bondy_oplog_crdt_aw_core:vv()
) -> entries().

rmv(Entries, K, Ctx) ->
    DS0 = maps:get(K, Entries, #{}),
    DS1 = bondy_oplog_crdt_aw_core:drop_observed(DS0, Ctx),
    case map_size(DS1) of
        0 -> maps:remove(K, Entries);
        _ -> Entries#{K => DS1}
    end.

-doc """
The `SubMod` a dot-store's surviving entries were written with, or
`undefined` if it holds no nested entries (empty, or all flat values).
Every surviving entry at a key is guaranteed to share one `SubMod` —
`put_nested/7` rejects any write that would violate this.
""".
-spec sub_mod(dot_store()) -> module() | undefined.

sub_mod(DotStore) ->
    case [M || {sub, M, _, _} <- maps:values(DotStore)] of
        [M | _] -> M;
        [] -> undefined
    end.

-doc """
The sub-CRDT's converged value at a key: replay every surviving
`{sub, SubMod, Hlc, SubOp}` entry, in `{Hlc, Origin, Seq}` order, through
`SubMod:interpret_cog/2` starting from `SubMod:init/0`, then
`SubMod:to_value/1`. Requires no callback beyond what every
`bondy_oplog_crdt` module already exports.
""".
-spec nested_value(SubMod :: module(), DotStore :: dot_store()) -> term().

nested_value(SubMod, DotStore) ->
    Events = [
        bondy_oplog_event:new(
            bondy_oplog_event:key(Hlc, Origin, Seq), SubOp, undefined
        )
     || {{Origin, Seq}, {sub, _, Hlc, SubOp}} <- maps:to_list(DotStore)
    ],
    State = SubMod:interpret_cog(Events, SubMod:init()),
    SubMod:to_value(State).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
check_sub_mod(DS, K, SubMod) ->
    case sub_mod(DS) of
        undefined when map_size(DS) =:= 0 -> ok;
        undefined -> error({badarg, {flat_key, K}});
        SubMod -> ok;
        Other -> error({badarg, {sub_mod_mismatch, K, Other, SubMod}})
    end.
