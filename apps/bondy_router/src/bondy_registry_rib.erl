%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_registry_rib).
-moduledoc """
Maintains this node's cells in the registry RIB (Routing Information Base) —
the replicated routing summaries that advertise which URIs this node can
serve, without shipping the full `#entry{}` records.

For every `(Realm, MatchPolicy, Uri)` with at least one live **local** entry,
the node owns one replicated cell per registry type:

- registrations — `#{invoke, count, earliest, latest}`: the shared invocation
  policy, the number of live local callees (the selection weight), and the
  creation-time bounds (for `first`/`last` selection).
- subscriptions — `#{count}`: pure reachability (the broker delivers one
  event copy per node; no per-entry attributes are needed).

keyed `{RealmUri, MatchPolicy, Uri, Nodestring}`. Only this node ever writes
cells carrying its nodestring, so no two writers ever target the same key and
`lww` resolution is exact. The realm rides inside the key (although the
bucket already isolates it) so a merge-event reaction — which receives only
`(Key, Op)`, with no value on a `clear` — is self-contained.

### Remote side: stubs

Peers' cells reach this node via AAE merge; `bondy_aae_reactor` delegates
them here (`on_remote_set/3` / `on_remote_clear/2`), maintaining the node's
**stub store**: one row per remote `(Type, Realm, Policy, Uri, Node)` with
the summary as value. Under `read`/`write` mode the stubs ARE the remote
routing view: the dealer discovers remote callees via `match_stubs/2` and
the broker discovers remote subscriber nodes via `subscription_nodes/3`.
`check/1` compares the summary view against the ground truth per realm and
reports any divergence.

A merged cell that names THIS node is an echo of our own past writes (no
peer ever writes our cells). After an ungraceful restart the echo can be
stale — peers still hold cells for registrations that died with the
previous incarnation and never got an `on_entry_removed` — so a boot-time
step (not a merge-event reaction; see `bondy_registry_rib_boot`) corrects
each cell this node owns back to reality.

### Concurrency model

The registry write path runs in the **caller's** process (the partition
pid only locates the store slice) — the same is true of RIB maintenance.
`count`, `invoke`, `earliest` and `latest` are per-field CRDTs
(registration: `bondy_oplog_crdt_struct`, registered directly with its
schema as `crdt_opts` — see `bondy_namespace_catalog`'s
`?RIB_REGISTRATION_SCHEMA`; subscription: a bare
`bondy_oplog_crdt_pn_counter`), not one opaque summary blob, so an
entry add/remove writes a small, targeted, **lock-free** delta directly
from the caller — `{inc, 1}` /`{inc, -1}` on `count`, `{set, Created}`
on the `earliest`/`latest` min/max ratchets (adds only: removals never
shrink the lifetime watermarks, which is what keeps the cell a scalar
per field) — with no
read-modify-write, no per-realm dispatch, and no serialisation point:
concurrent writers to the same cell simply converge, the same way the
entry/ptrie writes they accompany already do. The atomic row op on the
partition's members table (an `ordered_set` holding one row per live
local entry, keyed `{Type, Realm, Policy, Uri, Created, EntryId}`) is
kept only as `check/1`'s ground truth — it is no longer read to derive
anything written to the cell.

There is no explicit cell clear when the local group empties: `count`
settling to `0` is the only signal (read-side consumers treat
`count =:= 0` as not routable), and a `count = 0` cell is later
physically reclaimed by `stabilize/2` (registration:
`bondy_oplog_crdt_struct`'s generic `stabilize_zero`-policy discard on
`count`; subscription: `bondy_oplog_crdt_pn_counter`'s own unconditional
discard-at-zero) once causally stable — mirroring how
`bondy_oplog_crdt_dw_flag` already reclaims a permanently-disabled flag
cell.

Remote entries never touch this module: their owner maintains their cells and
they reach this node via AAE merge.
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_db_tables.hrl").

%% One row per live local entry; the summary for a `(Type, Realm, Policy,
%% Uri)` is derived by an ordered prefix scan over these rows.
-define(MEMBER_KEY(Type, RealmUri, Policy, Uri, Created, EntryId),
    {Type, RealmUri, Policy, Uri, Created, EntryId}
).

%% One row per remote RIB cell this node has merged, keyed
%% {Type, Realm, Policy, Uri, Nodestring} with the summary as value. A
%% global named table claimed by `bondy_aae_reactor` at init
%% (ensure_stubs_table/0) so it survives a reactor restart.
-define(STUBS_TAB, bondy_registry_rib_stubs).

-type entry() :: bondy_registry_entry:t().
-type entry_type() :: bondy_registry_entry:entry_type().
-type divergence() :: {
    {entry_type(), Policy :: binary(), uri()},
    #{full_entries := [binary()], rib := [binary()]}
}.

-export_type([divergence/0]).

%% API
-export([check/1]).
-export([ensure_stubs_table/0]).
-export([match_stubs/2]).
-export([match_summaries/3]).
-export([realm_nodestrings/2]).
-export([on_entry_added/3]).
-export([on_entry_removed/3]).
-export([on_remote_clear/2]).
-export([on_remote_merge/2]).
-export([on_remote_set/3]).
-export([rebuild/1]).
-export([realms/0]).
-export([stub_nodes/4]).
-export([subscription_nodes/3]).

-ifdef(TEST).
%% Exposes the read-path reshape helper for a direct unit test of its
%% shaping logic, decoupled from constructing real CRDT state via the
%% full write path.
-export([reshape_summary/2]).
-endif.

%% =============================================================================
%% API
%% =============================================================================

-doc """
Hook called by `bondy_registry_partition` after an entry has been successfully
added to the store. A no-op unless the RIB is enabled and `Entry` is local.
Inserts the entry's members row (atomic, kept only as `check/1`'s ground
truth) and applies a small, targeted, lock-free CRDT delta directly —
no partition dispatch, no serialisation point.
""".
-spec on_entry_added(Partition :: pid(), Tab :: ets:tab(), Entry :: entry()) ->
    ok.

on_entry_added(_Partition, Tab, Entry) ->
    case is_active(Entry) of
        true ->
            true = ets:insert(Tab, member(Entry)),
            ok = safe_metric(gauge, #{
                name => bondy_registry_rib_members, delta => 1
            }),
            apply_added(Entry);
        false ->
            ok
    end.

-doc """
Hook called by `bondy_registry_partition` after an entry has been successfully
removed from the store. A no-op unless the RIB is enabled and `Entry` is
local. Deletes the entry's members row (atomic, kept only as `check/1`'s
ground truth) and applies a small, targeted, lock-free CRDT delta
directly — no partition dispatch, no serialisation point.
""".
-spec on_entry_removed(
    Partition :: pid(), Tab :: ets:tab(), Entry :: entry()
) -> ok.

on_entry_removed(_Partition, Tab, Entry) ->
    case is_active(Entry) of
        true ->
            {Key, _} = member(Entry),
            %% `take` so the occupancy gauge only moves when a row
            %% actually existed (a redundant removal must not drift it).
            case ets:take(Tab, Key) of
                [] ->
                    ok;
                [_] ->
                    ok = safe_metric(gauge, #{
                        name => bondy_registry_rib_members, delta => -1
                    })
            end,
            apply_removed(Entry);
        false ->
            ok
    end.

-doc """
Applies the CRDT delta for a newly-added local entry directly from the
caller's process: `count` `{inc, 1}`, `invoke` `{set, Invoke}` and the
`earliest`/`latest` ratchets `{set, Created}` for a registration; a bare
counter `{inc, 1}` for a subscription (its table has no
`invoke`/`earliest`/`latest` fields — it is a bare
`bondy_oplog_crdt_pn_counter`, not a struct). MUST be total: any
failure is logged, never raised — a RIB write failing must not fail the
entry add/remove it accompanies.
""".
-spec apply_added(Entry :: entry()) -> ok.

apply_added(Entry) ->
    Type = bondy_registry_entry:type(Entry),
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Policy = bondy_registry_entry:match_policy(Entry),
    Uri = bondy_registry_entry:uri(Entry),

    try
        Table = db_table(Type),
        Key = cell_key(RealmUri, Policy, Uri),

        Result =
            case Type of
                registration ->
                    Created = bondy_registry_entry:created(Entry),
                    Invoke = bondy_registry_entry:get_option(
                        invoke, Entry, ?INVOKE_SINGLE
                    ),
                    %% Async (no read-your-writes barrier): nothing reads
                    %% the cell on the entry-add path — local routing
                    %% truth is the trie/members table, written above,
                    %% and the replicated summary view is eventually
                    %% consistent via AE by design. The synchronous
                    %% barrier made every REGISTER/SUBSCRIBE pay the
                    %% registry drain's whole backlog under load (the
                    %% fleet-scale subscribe-latency collapse).
                    bondy_db:apply_batch_async(Table, RealmUri, Key, [
                        {apply, count, {inc, 1}},
                        {apply, invoke, {set, Invoke}},
                        {apply, earliest, {set, Created}},
                        {apply, latest, {set, Created}}
                    ]);
                subscription ->
                    bondy_db:apply_async(Table, RealmUri, Key, {inc, 1})
            end,
        log_rib_error(Result, add, Type, RealmUri, Policy, Uri)
    catch
        Class:Reason:Stacktrace ->
            log_rib_exception(
                Class, Reason, Stacktrace, add, Type, RealmUri, Policy, Uri
            )
    end.

-doc """
Applies the CRDT delta for a removed local entry — the causal dual of
`apply_added/1`: `count` `{inc, -1}` for a registration (`invoke` is
untouched — a stable per-group value, it self-corrects on the group's
next add if it ever changes; `earliest`/`latest` are untouched by
design — they are monotone ratchets recording the group's lifetime
creation-time watermarks, so removals never shrink them, which is what
bounds the cell to a scalar per field instead of one element plus one
tombstone per entry ever added); a bare counter `{inc, -1}` for a
subscription. MUST be total, same contract as `apply_added/1`.
""".
-spec apply_removed(Entry :: entry()) -> ok.

apply_removed(Entry) ->
    Type = bondy_registry_entry:type(Entry),
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Policy = bondy_registry_entry:match_policy(Entry),
    Uri = bondy_registry_entry:uri(Entry),

    try
        Table = db_table(Type),
        Key = cell_key(RealmUri, Policy, Uri),

        Result =
            case Type of
                registration ->
                    %% Async — same rationale as `apply_added/1`.
                    bondy_db:apply_async(
                        Table, RealmUri, Key, {apply, count, {inc, -1}}
                    );
                subscription ->
                    bondy_db:apply_async(Table, RealmUri, Key, {inc, -1})
            end,
        log_rib_error(Result, remove, Type, RealmUri, Policy, Uri)
    catch
        Class:Reason:Stacktrace ->
            log_rib_exception(
                Class, Reason, Stacktrace, remove, Type, RealmUri, Policy, Uri
            )
    end.

%% @private
log_rib_error(ok, _Action, _Type, _RealmUri, _Policy, _Uri) ->
    ok;
log_rib_error({error, Reason}, Action, Type, RealmUri, Policy, Uri) ->
    ?LOG_ERROR(#{
        description => "Failed to apply registry RIB delta",
        action => Action,
        type => Type,
        realm_uri => RealmUri,
        match_policy => Policy,
        uri => Uri,
        reason => Reason
    }),
    ok.

%% @private
log_rib_exception(
    Class, Reason, Stacktrace, Action, Type, RealmUri, Policy, Uri
) ->
    ?LOG_ERROR(#{
        description => "Failed to apply registry RIB delta",
        action => Action,
        type => Type,
        realm_uri => RealmUri,
        match_policy => Policy,
        uri => Uri,
        class => Class,
        reason => Reason,
        stacktrace => Stacktrace
    }),
    ok.

-doc """
Claims the stub store (a global named table) so it survives a reactor
restart. Called by `bondy_aae_reactor` at init.
""".
-spec ensure_stubs_table() -> ets:tab().

ensure_stubs_table() ->
    Opts = [
        ordered_set,
        {keypos, 1},
        named_table,
        public,
        {read_concurrency, true},
        {write_concurrency, true}
    ],
    {ok, Tab} = bondy_table_manager:add_or_claim(?STUBS_TAB, Opts),
    Tab.

-doc """
Reaction to a peer's RIB cell merge (`{set, Summary}`): upserts the stub for
the remote `(Type, Realm, Policy, Uri, Node)` — unless `Summary`'s `count`
is `0`, treated exactly like an explicit `clear` (drops any existing
stub instead). There is no explicit whole-cell clear any more (see the
migration plan's "Cell removal" note): `count` settling to `0` is the
only signal an emptied group ever sends, so the stub store has to
recognise it as equivalent to removal itself, at the single write point,
so every stub-store reader (`stub_nodes/4`, `match_stubs/2`,
`subscription_nodes/3`) stays free of needing this check itself. Cells
naming this node are ignored (an owner never stubs itself). MUST be
total — called from the AAE merge reactor.
""".
-spec on_remote_set(
    Type :: entry_type(), Key :: binary(), Summary :: map()
) -> ok.

on_remote_set(Type, Key, Summary) when is_map(Summary) ->
    case decode_cell_key(Key) of
        {ok, {RealmUri, Policy, Uri, Node}} ->
            case bondy_config:nodestring() of
                Node ->
                    self_heal(Type, RealmUri, Policy, Uri);
                _ ->
                    case maps:get(count, Summary, 0) of
                        0 ->
                            stub_delete({Type, RealmUri, Policy, Uri, Node});
                        _ ->
                            stub_insert(
                                {Type, RealmUri, Policy, Uri, Node}, Summary
                            )
                    end
            end;
        error ->
            ok
    end;
on_remote_set(_, _, _) ->
    ok.

-doc """
Reaction to a peer's RIB cell removal (`clear`): drops the stub. The key is
self-contained (realm included), so no tombstone resolution is needed. MUST
be total — called from the AAE merge reactor.
""".
-spec on_remote_clear(Type :: entry_type(), Key :: binary()) -> ok.

on_remote_clear(Type, Key) ->
    case decode_cell_key(Key) of
        {ok, {RealmUri, Policy, Uri, Node}} ->
            case bondy_config:nodestring() of
                Node ->
                    self_heal(Type, RealmUri, Policy, Uri);
                _ ->
                    stub_delete({Type, RealmUri, Policy, Uri, Node})
            end;
        error ->
            ok
    end.

-doc """
Rebuilds everything this module DERIVES from `Table`'s projection, for every
realm, after a catalogue-snapshot bootstrap installed that projection
wholesale.

Needed because the snapshot install path emits no per-cell merge event, and
both of this module's repair paths hang off those events alone:

- the stub store is in-memory ETS written only by `on_remote_set/3` and
  `on_remote_clear/2`, and it is what `subscription_nodes/3` and
  `match_stubs/2` — the cross-node PUBLISH forwarding set and the remote
  callee resolution — actually read. A node that bootstraps without it does
  not forward to its peers at all;
- `self_heal/4` is reachable only from those same two functions, and a
  bootstrapping node's OWN cells are the summaries of its PREVIOUS
  incarnation's registrations and subscriptions. Those sessions and sockets
  died with the node. Until their `count` is driven back to the (now zero)
  local truth, every peer keeps routing to this node for URIs it no longer
  serves — so correcting them is the load-bearing half, not a tidy-up.

Implemented by replaying each installed cell through `on_remote_set/3`, which
already routes an own-node cell to `self_heal/4` and a peer cell to
`stub_insert`/`stub_delete` under the `count = 0`-means-removed rule. No new
convention, and one write point stays one write point.

Idempotent: a streamed snapshot notifies a table once per batch, `stub_insert`
is an upsert, and `self_heal/4` is a no-op once the counts agree. MUST be
total — called from the AAE reactor.

Covers every realm with cells in the table, including realms this node has no
realm record for. It folds the TABLE (`bondy_db:fold_all/4`) rather than
enumerating `bondy_realm:list/0`: realms are themselves replicated state in
`main`, and nothing orders the `main` bootstrap before the `registry` one, so
deriving the realm set from the realm registry made this rebuild silently skip
cells depending on which bootstrap won the race (MEASURED 2026-08-22: the same
plain restart passed or failed run to run). The data is its own index.
""".
-spec rebuild(Table :: atom()) -> ok.

rebuild(Table) ->
    Type = table_type(Table),
    Fun = fun(Row, ok) -> rebuild_cell(Type, Row) end,
    try bondy_db:fold_all(db_table(Type), Fun, ok, #{}) of
        {ok, ok} ->
            ok;
        {error, Reason} ->
            ?LOG_WARNING(#{
                description => "Registry RIB rebuild after bootstrap failed",
                table => Table,
                reason => Reason
            }),
            ok
    catch
        Class:Reason:Stacktrace ->
            ?LOG_WARNING(#{
                description => "Registry RIB rebuild after bootstrap failed",
                table => Table,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ok
    end.

-doc """
Every realm that has RIB cells on this node, derived from the DATA rather than
from `bondy_realm:list/0`.

`check/1` is per-realm by contract, so its caller has to supply the realm set —
and taking that set from the realm registry makes the consistency gate blind in
exactly the case it exists to catch: a node holding cells for a realm whose
realm record has not replicated yet reports no divergence, because the sweep
never looks at that realm. The gauge then reads 0 while the stub view is
missing and routing is wrong.

Splits the storage key on the FIRST NUL, which is exact: `bondy_db` enforces
NUL-free realm URIs (`assert_nul_free_realm/1`), while a key's own bytes are
preserved verbatim after the separator. Cheaper than `decode_cell_key/1` here,
which would deserialise a whole term per cell just to read its realm.
""".
-spec realms() -> [uri()].

realms() ->
    Fun = fun({Key, _Value, _Hlc}, Acc) ->
        case binary:split(Key, <<0>>) of
            [Realm, _Rest] -> sets:add_element(Realm, Acc);
            _ -> Acc
        end
    end,
    Set = lists:foldl(
        fun(Type, Acc) ->
            try bondy_db:fold_all(db_table(Type), Fun, Acc, #{}) of
                {ok, Acc1} -> Acc1;
                {error, _} -> Acc
            catch
                _:_ -> Acc
            end
        end,
        sets:new([{version, 2}]),
        [registration, subscription]
    ),
    lists:sort(sets:to_list(Set)).

%% @private
%% One cell, replayed through the same reaction a live merge would take.
%%
%% `fold_all/4` yields the STORAGE key (`<<Realm, 0, RawKey>>`), which
%% `decode_cell_key/1` already accepts — it is the form a merge event
%% delivers — so no unfolding is needed and `on_remote_set/3` stays the single
%% write point.
%%
%% Total by contract: one undecodable or unreshapeable cell must not abandon
%% the rest of the table.
rebuild_cell(Type, {Key, RawValue, _Hlc}) ->
    try reshape_summary(Type, RawValue) of
        Summary when is_map(Summary) ->
            on_remote_set(Type, Key, Summary);
        _ ->
            ok
    catch
        _:_ ->
            ok
    end.

%% @private
table_type(?BONDY_DB_REGISTRATION_RIB_TAB) -> registration;
table_type(?BONDY_DB_SUBSCRIPTION_RIB_TAB) -> subscription.

-doc """
Reaction to ANY peer merge event for a RIB cell (`bondy_aae_reactor`'s only
entry point for `kind = rib`). The per-field CRDT write path emits many
small ops (`{apply, count, {inc, _}}`, a bare `{inc, _}`, ...), none of
which alone represents "the current summary" — unlike the pre-migration
whole-blob `lww_register` cell, where the merge op directly carried the
new value. Reads the cell's CURRENT converged value instead, reshapes it
(`reshape_summary/2` — the generic CRDT modules' raw `to_value/1` is not
quite the summary shape read-side consumers expect: registration's raw
struct value may omit never-written `earliest`/`latest` fields;
subscription's raw `pn_counter` value is a bare
integer, not a map), and dispatches exactly as `on_remote_set/3` already
does (`count = 0` there is already equivalent to a clear, so this needs
no separate clear case — the write path never emits an explicit
clear op either, see the moduledoc's "Concurrency model"). A cell that
does not exist (never written, or fully
reclaimed by `stabilize/2`) is a no-op: there is nothing for the stub
store to reflect. MUST be total — called from the AAE merge reactor.
""".
-spec on_remote_merge(Type :: entry_type(), Key :: binary()) -> ok.

on_remote_merge(Type, Key) ->
    try
        Table = db_table(Type),
        case decode_cell_key(Key) of
            {ok, {RealmUri, _Policy, _Uri, _Node} = Decoded} ->
                %% `Key` as delivered by a merge event may be the
                %% realm-folded wire form (`decode_cell_key/1` accepts
                %% both); `bondy_db:read/3` folds the realm into the key
                %% itself, so it needs the RAW (unfolded) key — the same
                %% canonical `term_to_binary/1` shape `cell_key/3`
                %% produces for a self-addressed cell, reconstructed here
                %% for the peer's.
                RawKey = term_to_binary(Decoded),
                case bondy_db:read(Table, RealmUri, RawKey) of
                    {ok, {Value, _Hlc}} ->
                        on_remote_set(Type, Key, reshape_summary(Type, Value));
                    {error, not_found} ->
                        ok
                end;
            error ->
                ok
        end
    catch
        Class:Reason:Stacktrace ->
            log_rib_exception(
                Class,
                Reason,
                Stacktrace,
                on_remote_merge,
                Type,
                undefined,
                undefined,
                undefined
            )
    end.

-doc """
The remote nodes advertising `(Type, RealmUri, Policy, Uri)`, with their
summaries: `[{Nodestring, Summary}]`. Returns `[]` before the stub store
exists.
""".
-spec stub_nodes(
    Type :: entry_type(),
    RealmUri :: uri(),
    Policy :: binary(),
    Uri :: uri()
) -> [{binary(), map()}].

stub_nodes(Type, RealmUri, Policy, Uri) ->
    case ets:whereis(?STUBS_TAB) of
        undefined ->
            [];
        _ ->
            MS = [
                {
                    {{Type, RealmUri, Policy, Uri, '$1'}, '$2'},
                    [],
                    [{{'$1', '$2'}}]
                }
            ],
            ets:select(?STUBS_TAB, MS)
    end.

-doc """
The remote registration stubs whose registered pattern matches `ProcUri`,
grouped per matching `(Pattern, Policy)` in match-policy precedence order:
exact first, then prefix patterns most-specific-first, then wildcard. Each
group is `{Pattern, Policy, [{Nodestring, Summary}]}` — the node-stage
candidates for the routing decision.
""".
-spec match_stubs(RealmUri :: uri(), ProcUri :: uri()) ->
    [{uri(), binary(), [{binary(), map()}]}].

match_stubs(RealmUri, ProcUri) ->
    Exact =
        case stub_nodes(registration, RealmUri, ?EXACT_MATCH, ProcUri) of
            [] -> [];
            Ns -> [{ProcUri, ?EXACT_MATCH, Ns}]
        end,
    Prefix = match_pattern_stubs(
        registration, RealmUri, ProcUri, ?PREFIX_MATCH
    ),
    Wildcard = match_pattern_stubs(
        registration, RealmUri, ProcUri, ?WILDCARD_MATCH
    ),
    Exact ++ Prefix ++ Wildcard.

-doc """
All remote stub summaries whose registered/subscribed pattern matches `Uri`,
flattened to `{Nodestring, Summary}` pairs across every match policy (exact,
prefix, wildcard). Uniform over both entry types. Used by the meta API's
`count` path to sum per-node counts (`maps:get(count, Summary)`) without
contacting any peer.
""".
-spec match_summaries(
    Type :: entry_type(), RealmUri :: uri(), Uri :: uri()
) -> [{binary(), map()}].

match_summaries(Type, RealmUri, Uri) ->
    Exact = stub_nodes(Type, RealmUri, ?EXACT_MATCH, Uri),
    Prefix = [
        NS
     || {_P, _Pol, Ns} <-
            match_pattern_stubs(Type, RealmUri, Uri, ?PREFIX_MATCH),
        NS <- Ns
    ],
    Wildcard = [
        NS
     || {_P, _Pol, Ns} <-
            match_pattern_stubs(Type, RealmUri, Uri, ?WILDCARD_MATCH),
        NS <- Ns
    ],
    Exact ++ Prefix ++ Wildcard.

-doc """
The distinct remote nodestrings holding at least one entry of `Type` in
`RealmUri`, from the stub store (a node never stubs itself, so the owning node
adds its own). This is the realm-scoped node target for the meta API's
whole-realm `list`, so the distributed walk contacts only nodes that can
contribute rather than every cluster peer. Returns `[]` before the stub store
exists.
""".
-spec realm_nodestrings(Type :: entry_type(), RealmUri :: uri()) ->
    [binary()].

realm_nodestrings(Type, RealmUri) ->
    case ets:whereis(?STUBS_TAB) of
        undefined ->
            [];
        _ ->
            MS = [
                {
                    {{Type, RealmUri, '_', '_', '$1'}, '_'},
                    [],
                    ['$1']
                }
            ],
            lists:usort(ets:select(?STUBS_TAB, MS))
    end.

-doc """
The remote nodes with at least one subscription matching `TopicUri` — the
broker's forwarding set: one PUBLISH is relayed per node and the receiving
node matches, filters and delivers locally. All match policies are consulted
unless `MatchOpts` pins `match` to a single policy (the broker does so when
pattern-based subscription is disabled). Per-session attributes (`eligible`
/ `exclude`) cannot be evaluated against a summary; the receiving node
applies them, so the set can only over-forward, never under-deliver.
""".
-spec subscription_nodes(
    RealmUri :: uri(), TopicUri :: uri(), MatchOpts :: map()
) -> [node()].

subscription_nodes(RealmUri, TopicUri, MatchOpts) ->
    Exact = [
        N
     || {N, _} <- stub_nodes(subscription, RealmUri, ?EXACT_MATCH, TopicUri)
    ],
    Pattern =
        case maps:get(match, MatchOpts, '_') of
            ?EXACT_MATCH ->
                [];
            _ ->
                [
                    N
                 || {_Pattern, _Policy, Ns} <-
                        match_pattern_stubs(
                            subscription, RealmUri, TopicUri, ?PREFIX_MATCH
                        ) ++
                            match_pattern_stubs(
                                subscription,
                                RealmUri,
                                TopicUri,
                                ?WILDCARD_MATCH
                            ),
                    {N, _} <- Ns
                ]
        end,
    lists:usort([binary_to_atom(N, utf8) || N <- Exact ++ Pattern]).

-doc """
The RIB consistency gate: compares, per `(Type, Policy, Uri)` in `RealmUri`,
the node set derivable from the ground truth with the node set derivable
from the RIB summary cells (this node's own plus every merged peer cell,
read from the local projection). Returns `[]` when the two views agree —
the precondition for routing on summaries — or one divergence per
disagreeing key.

Full entries never replicate, so the ground truth is what this node can
attest: its own members table (which must agree with its own cells) and its
stub store (which must agree with the merged peer cells).
""".
-spec check(RealmUri :: uri()) -> [divergence()].

check(RealmUri) ->
    Expected = maps:merge_with(
        fun(_, A, B) -> A ++ B end,
        member_nodes(RealmUri),
        stub_truth_nodes(RealmUri)
    ),
    Actual = maps:merge_with(
        fun(_, A, B) -> A ++ B end,
        cell_nodes(registration, RealmUri),
        cell_nodes(subscription, RealmUri)
    ),
    Keys = lists:usort(maps:keys(Expected) ++ maps:keys(Actual)),
    lists:filtermap(
        fun(K) ->
            E = lists:usort(maps:get(K, Expected, [])),
            A = lists:usort(maps:get(K, Actual, [])),
            E =/= A andalso
                {true, {K, #{full_entries => E, rib => A}}}
        end,
        Keys
    ).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% RIB maintenance applies only to local entries — remote owners maintain
%% their own cells, which reach this node via AAE merge.
is_active(Entry) ->
    bondy_registry_entry:is_local(Entry).

%% @private
%% The members row for an entry. `Invoke` is carried on registration rows so
%% the summary needs no further lookups (all live rows for a URI share one
%% policy — the registry rejects a mismatching invoke at registration time);
%% `undefined` for subscriptions.
member(Entry) ->
    Type = bondy_registry_entry:type(Entry),
    Key = ?MEMBER_KEY(
        Type,
        bondy_registry_entry:realm_uri(Entry),
        bondy_registry_entry:match_policy(Entry),
        bondy_registry_entry:uri(Entry),
        bondy_registry_entry:created(Entry),
        bondy_registry_entry:id(Entry)
    ),
    Invoke =
        case Type of
            registration ->
                bondy_registry_entry:get_option(
                    invoke, Entry, ?INVOKE_SINGLE
                );
            subscription ->
                undefined
        end,
    {Key, Invoke}.

%% @private
%% The cell key. Carries this node's nodestring — the single-writer
%% discriminator: only this node ever writes cells that name it, so
%% concurrent writers to one key cannot exist. Carries the realm too
%% (redundantly with the bucket) so a merge-event reaction can decode
%% everything it needs from the key alone, even on a `clear`.
cell_key(RealmUri, Policy, Uri) ->
    term_to_binary({RealmUri, Policy, Uri, bondy_config:nodestring()}).

%% @private
%% Decodes a cell key back to `{Realm, Policy, Uri, Node}`. Two wire forms
%% reach us: the raw key (external term format, first byte 131) — what
%% `bondy_db:list/2` returns after recovering the caller's keys — and the
%% realm-folded form `<<Realm, 0, RawKey>>` that a merge event delivers (the
%% realm URI is NUL-free and never starts with byte 131, so the first byte
%% discriminates).
decode_cell_key(<<131, _/binary>> = Key) ->
    decode_raw_cell_key(Key);
decode_cell_key(Key) when is_binary(Key) ->
    case binary:split(Key, <<0>>) of
        [_Realm, Raw] ->
            decode_raw_cell_key(Raw);
        _ ->
            error
    end;
decode_cell_key(_) ->
    error.

%% @private
decode_raw_cell_key(Raw) ->
    try binary_to_term(Raw) of
        {RealmUri, Policy, Uri, Node} = Decoded when
            is_binary(RealmUri) andalso
                is_binary(Policy) andalso
                is_binary(Uri) andalso
                is_binary(Node)
        ->
            {ok, Decoded};
        _ ->
            error
    catch
        _:_ ->
            error
    end.

%% @private
stub_insert(StubKey, Summary) ->
    case ets:whereis(?STUBS_TAB) of
        undefined ->
            ok;
        _ ->
            IsNew = not ets:member(?STUBS_TAB, StubKey),
            true = ets:insert(?STUBS_TAB, {StubKey, Summary}),
            IsNew andalso
                safe_metric(gauge, #{
                    name => bondy_registry_rib_stub_cells,
                    label => #{type => element(1, StubKey)},
                    delta => 1
                }),
            ok
    end.

%% @private
stub_delete(StubKey) ->
    case ets:whereis(?STUBS_TAB) of
        undefined ->
            ok;
        _ ->
            case ets:take(?STUBS_TAB, StubKey) of
                [] ->
                    ok;
                [_] ->
                    safe_metric(gauge, #{
                        name => bondy_registry_rib_stub_cells,
                        label => #{type => element(1, StubKey)},
                        delta => -1
                    })
            end
    end.

%% @private
%% A cell naming THIS node merged in from a peer — necessarily an echo of
%% our own past writes (no peer ever writes our cells). This only happens
%% in practice when our local copy is behind what a peer holds, which —
%% since no other node ever writes our cells — means we are freshly
%% booted and re-syncing from peers who still hold our pre-restart data.
%%
%% Corrects `count` back to the true local count via one corrective
%% delta; needs nothing else, since a fresh write dominates by HLC and
%% replicates back out regardless of how many origins contributed to the
%% stale value historically.
%%
%% `earliest`/`latest` need no restart handling at all: they are
%% monotone ratchet registers over the group's lifetime creation times
%% (per-value, not per-origin state), so pre-restart values simply
%% remain as valid watermarks of the group's history — exactly the
%% ratchet semantics the removals path already relies on.
%%
%% MUST be total — called from the AAE merge reactor.
self_heal(Type, RealmUri, Policy, Uri) ->
    try
        Table = db_table(Type),
        case local_count(Type, RealmUri, Policy, Uri) of
            unknown ->
                %% The partition store is not readable yet (boot, or a
                %% realm whose partition has not been provisioned). We
                %% cannot tell "this node owns nothing here" from "we
                %% cannot see what this node owns", and the two demand
                %% OPPOSITE actions: the first wants `count` driven to 0,
                %% the second wants no write at all. Treating unknown as 0
                %% — which this did before — writes a corrective delta of
                %% `-ReplicatedCount` for every cell it walks, and that
                %% delta REPLICATES: a live instance would broadcast the
                %% erasure of its own live registrations cluster-wide.
                %% Skipping is always safe: the next merge event, or the
                %% next bootstrap rebuild, re-runs this with a readable
                %% store.
                ok;
            {ok, LocalCount} ->
                do_self_heal(
                    Type, Table, RealmUri, Policy, Uri, LocalCount
                )
        end
    catch
        Class:Reason:Stacktrace ->
            log_rib_exception(
                Class,
                Reason,
                Stacktrace,
                self_heal,
                Type,
                RealmUri,
                Policy,
                Uri
            )
    end.

%% @private
%% The corrective write, once the local count is KNOWN. Split out so the
%% unknown-store case above can be read at a glance.
do_self_heal(Type, Table, RealmUri, Policy, Uri, LocalCount) ->
    Key = cell_key(RealmUri, Policy, Uri),
    case bondy_db:read(Table, RealmUri, Key) of
        {error, not_found} ->
            ok;
        {ok, {Value, _Hlc}} ->
            #{count := ReplicatedCount} = reshape_summary(Type, Value),
            case LocalCount - ReplicatedCount of
                0 ->
                    ok;
                Delta ->
                    %% registration's table is struct-based (tier_2): the
                    %% `count` field takes a scoped
                    %% `{apply, count, {inc, _}}` op, not the bare
                    %% `{inc, _}` subscription's bare pn_counter table
                    %% takes directly.
                    Op =
                        case Type of
                            registration -> {apply, count, {inc, Delta}};
                            subscription -> {inc, Delta}
                        end,
                    log_rib_error(
                        bondy_db:apply(Table, RealmUri, Key, Op),
                        self_heal,
                        Type,
                        RealmUri,
                        Policy,
                        Uri
                    )
            end
    end.

%% @private
%% The count of live local rows for `(Type, RealmUri, Policy, Uri)` in the
%% partition's members table (`check/1`'s ground truth, kept purely for
%% that purpose since the write path stopped deriving anything from it —
%% see the moduledoc's "Concurrency model").
%%
%% Returns `unknown` — NOT 0 — when the realm's partition store is not
%% readable. `self_heal/4` turns this count into a REPLICATED corrective
%% delta, so reporting an unreadable store as "owns nothing" is the
%% difference between a no-op and broadcasting the erasure of every
%% registration this node owns. The two callers must decide, so the
%% ambiguity is returned rather than resolved here.
local_count(Type, RealmUri, Policy, Uri) ->
    %% `store/1` resolves the realm through the registry's gproc pool, which
    %% RAISES when the pool is not up (early boot) rather than returning
    %% `undefined`. Both mean the same thing here — the local truth is not
    %% readable — so both must yield `unknown`. Letting the raise escape
    %% would reach `self_heal/4`'s catch-all and log a full exception report
    %% PER CELL, which `rebuild/1` turns into one report per cell in the
    %% projection.
    case store(RealmUri) of
        undefined ->
            unknown;
        Store ->
            Tab = bondy_registry_store:rib_members_tab(Store),
            MS = [
                {
                    {?MEMBER_KEY(Type, RealmUri, Policy, Uri, '_', '_'), '_'},
                    [],
                    [true]
                }
            ],
            {ok, ets:select_count(Tab, MS)}
    end.

%% @private
%% `bondy_registry_partition:store/1`, with an unreadable pool reported the
%% same way as an unprovisioned one.
store(RealmUri) ->
    try
        bondy_registry_partition:store(RealmUri)
    catch
        _:_ -> undefined
    end.

%% @private
%% Stubs of `Type` and pattern policy `Policy` whose pattern matches `Uri`,
%% grouped per pattern, most-specific (longest) pattern first.
%% The select is bound on (type, realm, policy); the residual pattern-match
%% (byte-prefix / wildcard components) is not expressible in a match spec,
%% so it runs over the realm's remote patterns — a small set by design.
match_pattern_stubs(Type, RealmUri, Uri, Policy) ->
    case ets:whereis(?STUBS_TAB) of
        undefined ->
            [];
        _ ->
            MS = [
                {
                    {{Type, RealmUri, Policy, '$1', '$2'}, '$3'},
                    [],
                    [{{'$1', '$2', '$3'}}]
                }
            ],
            Rows = ets:select(?STUBS_TAB, MS),
            Matching = [
                {Pattern, Node, Summary}
             || {Pattern, Node, Summary} <- Rows,
                bondy_wamp_uri:match(Uri, Pattern, Policy)
            ],
            ByPattern = lists:foldl(
                fun({Pattern, Node, Summary}, Acc) ->
                    maps:update_with(
                        Pattern,
                        fun(Ns) -> [{Node, Summary} | Ns] end,
                        [{Node, Summary}],
                        Acc
                    )
                end,
                #{},
                Matching
            ),
            [
                {Pattern, Policy, maps:get(Pattern, ByPattern)}
             || Pattern <- lists:sort(
                    fun(A, B) -> byte_size(A) >= byte_size(B) end,
                    maps:keys(ByPattern)
                )
            ]
    end.

%% @private
%% The node set per (Type, Policy, Uri) derivable from this node's members
%% table: every key with at least one live local entry maps to this node.
%% The realm's members all live in one partition slice (partitions hash on
%% the realm).
member_nodes(RealmUri) ->
    %% Same pool-may-raise caveat as `local_count/4`; see `store/1`.
    %% NOTE (not changed here, deliberately): an unreadable store still
    %% yields `#{}`, so `check/1` reports every cell as divergent rather than
    %% reporting "cannot tell". That inflates
    %% `bondy_registry_rib_divergences` while the pool is down. Correcting it
    %% means deciding what the gauge should say when ground truth is
    %% unreadable, which is a semantics call, not a bug fix.
    case store(RealmUri) of
        undefined ->
            #{};
        Store ->
            Tab = bondy_registry_store:rib_members_tab(Store),
            Self = bondy_config:nodestring(),
            MS = [
                {
                    {?MEMBER_KEY('$1', RealmUri, '$2', '$3', '_', '_'), '_'},
                    [],
                    [{{'$1', '$2', '$3'}}]
                }
            ],
            lists:foldl(
                fun(K, Acc) -> maps:put(K, [Self], Acc) end,
                #{},
                ets:select(Tab, MS)
            )
    end.

%% @private
%% The node set per (Type, Policy, Uri) derivable from the stub store: what
%% this node believes about its peers, which the merged peer cells in the
%% projection must mirror.
stub_truth_nodes(RealmUri) ->
    case ets:whereis(?STUBS_TAB) of
        undefined ->
            #{};
        _ ->
            MS = [
                {
                    {{'$1', RealmUri, '$2', '$3', '$4'}, '_'},
                    [],
                    [{{'$1', '$2', '$3', '$4'}}]
                }
            ],
            lists:foldl(
                fun({Type, Policy, Uri, Node}, Acc) ->
                    maps:update_with(
                        {Type, Policy, Uri},
                        fun(Ns) -> [Node | Ns] end,
                        [Node],
                        Acc
                    )
                end,
                #{},
                ets:select(?STUBS_TAB, MS)
            )
    end.

%% @private
%% The node set per (Type, Policy, Uri) derivable from the RIB summary
%% cells in the local projection — this node's own cells plus every merged
%% peer cell. A `count = 0` row (an emptied group not yet physically
%% reclaimed by `stabilize/2` — see the migration plan's "Cell removal"
%% note) is excluded: it is not routable, so it must not count as a live
%% node here either.
cell_nodes(Type, RealmUri) ->
    Table = db_table(Type),
    {ok, Rows} = bondy_db:list(Table, RealmUri),
    lists:foldl(
        fun({Key, RawValue, _Hlc}, Acc) ->
            try reshape_summary(Type, RawValue) of
                #{count := 0} ->
                    Acc;
                Summary when is_map(Summary) ->
                    case decode_cell_key(Key) of
                        {ok, {_Realm, Policy, Uri, Node}} ->
                            K = {Type, Policy, Uri},
                            maps:update_with(
                                K, fun(Ns) -> [Node | Ns] end, [Node], Acc
                            );
                        error ->
                            Acc
                    end
            catch
                _:_ ->
                    Acc
            end
        end,
        #{},
        Rows
    ).

%% @private
%% Record a metric without ever raising: several callers here are total by
%% contract (reactor reactions, the partition-serialised recompute), and a
%% metrics hiccup must never take them down.
safe_metric(Type, Spec) ->
    try
        case Type of
            counter -> bondy_metrics:counter(Spec);
            gauge -> bondy_metrics:gauge(Spec)
        end
    catch
        _:_ ->
            ok
    end.

%% @private
%% Reshapes a table's raw CRDT `to_value/1` projection into the summary map
%% every consumer expects. Both RIB tables register the generic CRDT
%% toolkit modules directly (no per-use-case wrapper — see
%% `bondy_namespace_catalog`'s `?RIB_REGISTRATION_SCHEMA`), so their raw
%% projected value is not quite the shape read-side consumers want:
%% registration's raw `bondy_oplog_crdt_struct` value already has the
%% schema fields as top-level keys but may omit never-written
%% `earliest`/`latest` registers (normalised to `undefined` here);
%% subscription's raw `bondy_oplog_crdt_
%% pn_counter` value is a bare integer, not a map at all. Called
%% immediately after every raw read/list, before any `#{count := _}`-
%% shaped pattern match.
-spec reshape_summary(entry_type(), term()) -> map().

reshape_summary(registration, #{count := Count, invoke := Invoke} = Value) ->
    %% `earliest`/`latest` are schema fields (min/max ratchet registers)
    %% so they are already scalars in the raw value; an unwritten
    %% register projects as `undefined`, which is also the summary's
    %% "never had an entry" shape — no derivation left to do.
    #{
        invoke => Invoke,
        count => Count,
        earliest => maps:get(earliest, Value, undefined),
        latest => maps:get(latest, Value, undefined)
    };
reshape_summary(subscription, Count) when is_integer(Count) ->
    #{count => Count}.

%% @private
db_table(registration) ->
    db_table_for(?BONDY_DB_REGISTRATION_RIB_TAB);
db_table(subscription) ->
    db_table_for(?BONDY_DB_SUBSCRIPTION_RIB_TAB).

%% @private
db_table_for(Name) ->
    case bondy_namespace_catalog:table(Name) of
        undefined ->
            error({registry_not_provisioned, Name});
        Table ->
            Table
    end.
