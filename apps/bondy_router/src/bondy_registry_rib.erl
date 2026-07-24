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
peer ever writes our cells). After a restart the echo can be stale — peers
still hold cells for registrations that died with the previous incarnation —
so instead of ignoring it we re-derive the summary from the local members
table: the fresh write (or clear) dominates by HLC and the correction
replicates back out.

### Concurrency model

The registry write path runs in the **caller's** process (the partition pid
only locates the store slice), so summary maintenance cannot read-modify-write
shared state inline. Instead:

1. The hot path performs an **atomic row op** on the partition's members table
   (an `ordered_set` holding one row per live local entry, keyed
   `{Type, Realm, Policy, Uri, Created, EntryId}`), then
2. casts a **recompute** for the summary key to the owning partition server
   (`bondy_registry_partition:async_execute/3`) — the per-realm serialisation
   point. Each recompute re-derives the cell from the members table at
   execution time, so queued recomputes are idempotent and the last one wins
   with the final truth.

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
-export([on_remote_set/3]).
-export([recompute/5]).
-export([stub_nodes/4]).
-export([subscription_nodes/3]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Hook called by `bondy_registry_partition` after an entry has been successfully
added to the store. A no-op unless the RIB is enabled and `Entry` is local.
Inserts the entry's members row (atomic) and schedules a serialised summary
recompute on the partition server.
""".
-spec on_entry_added(Partition :: pid(), Tab :: ets:tab(), Entry :: entry()) ->
    ok.

on_entry_added(Partition, Tab, Entry) ->
    case is_active(Entry) of
        true ->
            true = ets:insert(Tab, member(Entry)),
            ok = safe_metric(gauge, #{
                name => bondy_registry_rib_members, delta => 1
            }),
            schedule_recompute(Partition, Tab, Entry);
        false ->
            ok
    end.

-doc """
Hook called by `bondy_registry_partition` after an entry has been successfully
removed from the store. A no-op unless the RIB is enabled and `Entry` is
local. Deletes the entry's members row (atomic) and schedules a serialised
summary recompute on the partition server.
""".
-spec on_entry_removed(
    Partition :: pid(), Tab :: ets:tab(), Entry :: entry()
) -> ok.

on_entry_removed(Partition, Tab, Entry) ->
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
            schedule_recompute(Partition, Tab, Entry);
        false ->
            ok
    end.

-doc """
Re-derives this node's RIB cell for `(Type, RealmUri, Policy, Uri)` from the
members table and applies it: `{set, Summary}` while local entries exist,
`clear` when the last one is gone.

Runs inside the partition server (via `async_execute`) — the per-realm
serialisation point — and therefore MUST be total: any failure is logged,
never raised (a crash would take the partition server down).
""".
-spec recompute(
    Tab :: ets:tab(),
    Type :: entry_type(),
    RealmUri :: uri(),
    Policy :: binary(),
    Uri :: uri()
) -> ok.

recompute(Tab, Type, RealmUri, Policy, Uri) ->
    try
        Table = db_table(Type),
        Key = cell_key(RealmUri, Policy, Uri),

        case members(Tab, Type, RealmUri, Policy, Uri) of
            [] ->
                %% A 1→0 reachability transition always propagates
                %% immediately (never damped), and only clears a live cell:
                %% queued recomputes for one key are idempotent, so
                %% re-clearing an already-cleared (or absent) cell would
                %% only churn the op-log with no state change.
                ok = damp_forget(Key),
                case bondy_db:read(Table, RealmUri, Key) of
                    {error, not_found} ->
                        ok;
                    _ ->
                        %% Live — or a transient read error, where clearing
                        %% is the safe side (a skipped clear might never be
                        %% retried; a redundant one is idempotent).
                        bondy_db:apply(Table, RealmUri, Key, clear)
                end;
            Rows ->
                maybe_damped_set(
                    Tab,
                    Table,
                    Type,
                    RealmUri,
                    Policy,
                    Uri,
                    Key,
                    summary(Type, Rows)
                )
        end
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Failed to recompute registry RIB cell",
                type => Type,
                realm_uri => RealmUri,
                match_policy => Policy,
                uri => Uri,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ok
    end.

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
the remote `(Type, Realm, Policy, Uri, Node)`. Cells naming this node are
ignored (an owner never stubs itself). MUST be total — called from the AAE
merge reactor.
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
                    stub_insert(
                        {Type, RealmUri, Policy, Uri, Node}, Summary
                    )
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
schedule_recompute(Partition, Tab, Entry) ->
    bondy_registry_partition:async_execute(
        Partition,
        fun ?MODULE:recompute/5,
        [
            Tab,
            bondy_registry_entry:type(Entry),
            bondy_registry_entry:realm_uri(Entry),
            bondy_registry_entry:match_policy(Entry),
            bondy_registry_entry:uri(Entry)
        ]
    ).

%% @private
%% All live local rows for the summary key, in ascending `Created` order (an
%% `ordered_set` select with a bound key prefix is a bounded traversal, and
%% results come back in key order). Returns `[{Created, Invoke}]`.
members(Tab, Type, RealmUri, Policy, Uri) ->
    MS = [
        {
            {?MEMBER_KEY(Type, RealmUri, Policy, Uri, '$1', '_'), '$2'},
            [],
            [{{'$1', '$2'}}]
        }
    ],
    ets:select(Tab, MS).

%% @private
%% Write the (re)derived summary, applying update damping (route-flap
%% control) when configured. Reachability transitions — a cell being
%% created (0→1) — always write immediately, as does any change to a
%% selection-relevant field (`invoke`, `earliest`). Only updates confined
%% to `count` / `latest` on an already-live cell are dampable: at most one
%% such write per window, with a trailing recompute (deferred on the
%% partition server, so it serialises like every other) carrying the final
%% value. `reconcile` writes only when the stored value differs, so queued
%% recomputes stay idempotent either way. Runs in the partition server —
%% `self()` is the partition.
maybe_damped_set(Tab, Table, Type, RealmUri, Policy, Uri, Key, Summary) ->
    Window = damping_window_ms(),
    Dampable =
        Window > 0 andalso
            case bondy_db:read(Table, RealmUri, Key) of
                {ok, {Old, _}} when is_map(Old) ->
                    maps:without([count, latest], Old) =:=
                        maps:without([count, latest], Summary);
                _ ->
                    false
            end,
    case Dampable of
        false ->
            ok = damp_note_write(Window, Key),
            bondy_db:reconcile(Table, RealmUri, Key, Summary);
        true ->
            Now = erlang:monotonic_time(millisecond),
            case damp_state(Key) of
                {LastWrite, false} when Now - LastWrite < Window ->
                    %% Suppress, and arm ONE trailing recompute at window
                    %% expiry so the final value always lands.
                    ok = safe_metric(counter, #{
                        name => bondy_registry_rib_damping_suppressions_total
                    }),
                    ok = bondy_registry_partition:execute_after(
                        Window - (Now - LastWrite),
                        self(),
                        fun ?MODULE:recompute/5,
                        [Tab, Type, RealmUri, Policy, Uri]
                    ),
                    damp_mark_pending(Key, LastWrite);
                {LastWrite, true} when Now - LastWrite < Window ->
                    %% Suppressed and the trailing recompute is already
                    %% armed — it will pick up the latest truth.
                    ok = safe_metric(counter, #{
                        name => bondy_registry_rib_damping_suppressions_total
                    });
                _ ->
                    %% Outside the window (or no damp state): write through.
                    ok = damp_note_write(Window, Key),
                    bondy_db:reconcile(Table, RealmUri, Key, Summary)
            end
    end.

%% @private
%% Damping window (`registry.rib.damping`), `0` = off.
damping_window_ms() ->
    application:get_env(bondy_router, registry_rib_damping, 0).

%% @private
%% Per-key damp state `{LastWriteMs, TrailingArmed}`, in a global named
%% table. Single-writer per key: every recompute for a realm runs in that
%% realm's partition server.
-define(DAMP_TAB, bondy_registry_rib_damp).

damp_state(Key) ->
    case ets:whereis(?DAMP_TAB) of
        undefined ->
            undefined;
        _ ->
            case ets:lookup(?DAMP_TAB, Key) of
                [{_, LastWrite, Pending}] -> {LastWrite, Pending};
                [] -> undefined
            end
    end.

%% @private
%% Stamp an actual cell write. Only maintained while damping is on — with
%% a zero window the table is never created and lookups stay no-ops.
damp_note_write(0, _) ->
    ok;
damp_note_write(_Window, Key) ->
    Tab = ensure_damp_table(),
    true = ets:insert(Tab, {Key, erlang:monotonic_time(millisecond), false}),
    ok.

%% @private
damp_mark_pending(Key, LastWrite) ->
    Tab = ensure_damp_table(),
    true = ets:insert(Tab, {Key, LastWrite, true}),
    ok.

%% @private
damp_forget(Key) ->
    case ets:whereis(?DAMP_TAB) of
        undefined ->
            ok;
        _ ->
            true = ets:delete(?DAMP_TAB, Key),
            ok
    end.

%% @private
%% Created on first use, claimed via the table manager so it survives its
%% creating partition's restart.
ensure_damp_table() ->
    case ets:whereis(?DAMP_TAB) of
        undefined ->
            {ok, Tab} = bondy_table_manager:add_or_claim(?DAMP_TAB, [
                set,
                {keypos, 1},
                named_table,
                public,
                {read_concurrency, true},
                {write_concurrency, true}
            ]),
            Tab;
        Tab ->
            Tab
    end.

%% @private
%% The replicated cell value. Rows arrive in ascending `Created` order, so
%% earliest/latest are the ends.
summary(registration, [{Earliest, Invoke} | _] = Rows) ->
    {Latest, _} = lists:last(Rows),
    #{
        invoke => Invoke,
        count => length(Rows),
        earliest => Earliest,
        latest => Latest
    };
summary(subscription, Rows) ->
    #{count => length(Rows)}.

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
%% our own past writes (no peer ever writes our cells). After a restart the
%% echo can be stale: peers still hold cells for registrations that died
%% with the previous incarnation. Re-derive the summary from the local
%% members table — the live truth — via the partition-serialised recompute:
%% it re-asserts the correct value or clears the stale cell, and the fresh
%% write dominates by HLC and replicates back out. MUST be total — called
%% from the AAE merge reactor.
self_heal(Type, RealmUri, Policy, Uri) ->
    try
        Partition = bondy_registry_partition:pick(RealmUri),
        case bondy_registry_partition:store(Partition) of
            undefined ->
                ok;
            Store ->
                Tab = bondy_registry_store:rib_members_tab(Store),
                bondy_registry_partition:async_execute(
                    Partition,
                    fun ?MODULE:recompute/5,
                    [Tab, Type, RealmUri, Policy, Uri]
                )
        end
    catch
        Class:Reason ->
            ?LOG_WARNING(#{
                description => "Failed to schedule registry RIB self-heal",
                type => Type,
                realm_uri => RealmUri,
                match_policy => Policy,
                uri => Uri,
                class => Class,
                reason => Reason
            }),
            ok
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
    case bondy_registry_partition:store(RealmUri) of
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
%% peer cell.
cell_nodes(Type, RealmUri) ->
    Table = db_table(Type),
    {ok, Rows} = bondy_db:list(Table, RealmUri),
    lists:foldl(
        fun
            ({Key, Summary, _Hlc}, Acc) when is_map(Summary) ->
                case decode_cell_key(Key) of
                    {ok, {_Realm, Policy, Uri, Node}} ->
                        K = {Type, Policy, Uri},
                        maps:update_with(
                            K, fun(Ns) -> [Node | Ns] end, [Node], Acc
                        );
                    error ->
                        Acc
                end;
            (_, Acc) ->
                Acc
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
