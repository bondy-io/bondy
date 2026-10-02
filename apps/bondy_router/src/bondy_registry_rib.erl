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

A merged cell that names THIS node is an echo of a reading this node wrote,
possibly in an earlier incarnation whose sessions are gone. The node answers
every echo with its current reading (`restate/4`), so the readings its peers
hold are replaced rather than corrected. It answers every echo, not only one
its own cell disagrees with: the peers route by stubs its cell says nothing
about (`proofs/tla/RibAbs.tla`; `RibAbs_Shipped` holds, `RibAbs_HealOnAbsent`
and `RibAbs_HealOnForeignTop` do not).

### Readings

A cell's count is the owner's latest READING of its live local entries,
`{Stamp, Count}`, carried by `bondy_oplog_crdt_owned_reading`: the reading
with the highest stamp wins, whichever origin wrote it, so nothing is ever
corrected by arithmetic. A registration cell is a `bondy_oplog_crdt_struct`
(`bondy_namespace_catalog`'s `?RIB_REGISTRATION_SCHEMA`) whose `count` is a
reading beside the `invoke`, `earliest` and `latest` registers; a
subscription cell is a bare reading.

The registry write path runs in the caller's process, and so does RIB
maintenance, with no serialisation point. The partition's members table (an
`ordered_set`) holds one row per live local entry and one counter row per
`(Type, Realm, Policy, Uri)` group. A writer changes both rows, then takes a
stamp from this node's RIB clock (a `bondy_hlc`, created by `init/0`),
then reads the group's counter, and writes that reading asynchronously.
Because the stamp follows the writer's own row op and precedes its read, the
highest-stamped reading carries the count after every row op stamped before
it, however concurrent writers interleave
(`bondy_registry_rib_test`'s concurrent-writer test). A later incarnation's
readings outrank an earlier one's as long as the node's wall clock has not
gone back, across the restart, past the last stamp it issued
(`proofs/tla/RibReading.tla`: `RibReading_WallAhead` holds,
`RibReading_WallStepBack` does not).

There is no explicit cell clear when the local group empties: a reading of
`0` is the signal (read-side consumers treat `count =:= 0` as not routable),
and the cell is discarded by `stabilize/2` once causally stable.

Remote entries never touch this module: their owner maintains their cells and
they reach this node via AAE merge.

### Departure: reclaiming a node's cells and stubs

Single-writer keying would leave a departed node's routing state immortal if
nothing acted: only the owner writes its cells, and the owner is gone.

So reclamation hangs off **retirement**, not plain membership loss.
Membership removal alone is reversible and
`m:bondy_oplog_origin_retirement` is explicit that a returning node is handed
back the same origin; deleting a merged cell on that signal would leave no
tombstone, this node's frontier already claims those events, AAE would never
re-ship them, and the returning node's routing would be silently blackholed
until it rewrote its own cells. Retirement bans the origin, which is the only
signal under which dropping the local copy is permanent by construction
rather than by hope.

**The cell.** `m:bondy_oplog_origin_retirement` computes the dead-origin
complement and `bondy_oplog_cell_utils:reap/4` reaps them from every bucket
whose carrier exports `reap_origins/2`. Both RIB carriers do: the
registration struct through a `force_reap` policy on every field of
`?RIB_REGISTRATION_SCHEMA`, and the subscription reading through its own
licence. Reaping leaves no reading, the count reads `0`, and the discard
described above removes the cell (`bondy_rib_reclamation_cluster_SUITE`).
The reap writes a value-preserving frame, so until the discard the stored
value still shows the last count.

**The stub.** A `stabilize/2` discard is not an apply, so it fires no merge
event, and `stub_delete/1` is otherwise reachable only from
`on_remote_set/3` (a merged `count = 0`) and `on_remote_clear/2` — both of
which need a merge event for a key nobody but the departed node may write.
So the stub needs its own trigger, and `reap_orphan_stubs/1` on
`bondy_registry`'s periodic sweep is it. A stub is deleted when its backing
cell is GONE, never merely because its node left the membership: removal is
reversible, and dropping a returning node's stub would blackhole its routing
until it happened to rewrite a cell. The cell's absence is the membership
signal already laundered through retirement, so it is the safe one.

That also means the trigger cannot be the membership event itself. The cell
disappears strictly later — after the reap zeroes it and stabilization
discards it — so a one-shot on membership change would run exactly when the
answer is still "the cell is there". It has to retry, which is what a sweep
does. What the membership set IS good for is scoping: only nodestrings
absent from it are candidates, so the common case costs one match-spec scan
of the stub table and no cell reads.

Until the cell has stabilized away, a departed node stays in
`subscription_nodes/3`
(one wasted relay per matching PUBLISH), in `realm_nodestrings/2` (the meta
API walk keeps it as a target) and in `bondy_registry:has_matches/3` (a
topic only it subscribed to still reads as having demand).
`m:bondy_dealer` is the exception and was never exposed: its node stage
drops unreachable candidates at selection time (`prefer_reachable/2`, a
preference so it can never empty a routable set) with the `rib_exclude`
retry covering the residual race. That is a guard, not reclamation.

`check/1` is blind to the whole problem by construction — a departed node
sits in `stub_truth_nodes/1` (expected) and `cell_nodes/2` (actual) alike,
so the two views agree and report no divergence.
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_db_tables.hrl").

%% The members table holds one row per live local entry and one row per
%% group counting them; the two key shapes differ in size, so a pattern on
%% either never matches the other.
-define(MEMBER_KEY(Type, RealmUri, Policy, Uri, Created, EntryId),
    {Type, RealmUri, Policy, Uri, Created, EntryId}
).
-define(GROUP_KEY(Type, RealmUri, Policy, Uri), {Type, RealmUri, Policy, Uri}).

-define(CLOCK, {?MODULE, clock}).

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
-export([init/0]).
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
-export([restore/0]).
-export([realms/0]).
-export([reap_orphan_stubs/1]).
-export([stub_nodes/4]).
-export([subscription_nodes/3]).

-ifdef(TEST).
%% Exposes the read-path reshape helper for a direct unit test of its
%% shaping logic, decoupled from constructing real CRDT state via the
%% full write path.
-export([reshape_summary/2]).

-ifdef(TEST).
-export([decode_cell_key/1]).
-endif.
-endif.

%% =============================================================================
%% API
%% =============================================================================

-doc """
Creates this node's RIB stamp clock, once per VM; a later call keeps the
clock that exists. Called by `bondy_registry_sup` before the registry
partitions start, so every writer stamps from the same clock.
""".
-spec init() -> ok.

init() ->
    case persistent_term:get(?CLOCK, undefined) of
        undefined -> persistent_term:put(?CLOCK, bondy_hlc:new());
        _ -> ok
    end.

-doc """
Hook called by `bondy_registry_partition` after an entry has been successfully
added to the store. A no-op unless the RIB is enabled and `Entry` is local, or
when the entry is already counted. Inserts the entry's members row, counts it
in its group, and writes the group's reading.
""".
-spec on_entry_added(Partition :: pid(), Tab :: ets:tab(), Entry :: entry()) ->
    ok.

on_entry_added(_Partition, Tab, Entry) ->
    case is_active(Entry) andalso ets:insert_new(Tab, {member_key(Entry)}) of
        true ->
            ok = safe_metric(gauge, #{
                name => bondy_registry_rib_members, delta => 1
            }),
            Group = group_key(Entry),
            _ = ets:update_counter(Tab, Group, {2, 1}, {Group, 0}),
            apply_added(Tab, Entry);
        false ->
            ok
    end.

-doc """
Hook called by `bondy_registry_partition` after an entry has been successfully
removed from the store. A no-op unless the RIB is enabled and `Entry` is
local, or when its members row is already gone, so removing one entry twice
counts it once (`bondy_registry_rib_test`'s "a redundant removal does not
decrement twice"). Otherwise uncounts it and writes the group's reading.
""".
-spec on_entry_removed(
    Partition :: pid(), Tab :: ets:tab(), Entry :: entry()
) -> ok.

on_entry_removed(_Partition, Tab, Entry) ->
    case is_active(Entry) andalso ets:take(Tab, member_key(Entry)) of
        [_] ->
            ok = safe_metric(gauge, #{
                name => bondy_registry_rib_members, delta => -1
            }),
            ok = uncount(Tab, group_key(Entry)),
            write_reading(Tab, Entry, remove);
        _ ->
            ok
    end.

%% @private
%% Total, like every write here: a RIB write failing is logged and must not
%% fail the entry add or remove it accompanies.

apply_added(Tab, Entry) ->
    case bondy_registry_entry:type(Entry) of
        registration ->
            Created = bondy_registry_entry:created(Entry),
            Invoke = bondy_registry_entry:get_option(
                invoke, Entry, ?INVOKE_SINGLE
            ),
            write(Tab, Entry, add, [
                {apply, invoke, {set, Invoke}},
                {apply, earliest, {set, Created}},
                {apply, latest, {set, Created}}
            ]);
        subscription ->
            write_reading(Tab, Entry, add)
    end.

%% @private
write_reading(Tab, Entry, Action) ->
    write(Tab, Entry, Action, []).

%% @private
%% The stamp is taken after the caller's row op and before the count is read,
%% so the highest-stamped reading carries the count after every row op that
%% preceded it (`bondy_registry_rib_test`'s concurrent-writer test).
write(Tab, Entry, Action, Extra) ->
    Type = bondy_registry_entry:type(Entry),
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Policy = bondy_registry_entry:match_policy(Entry),
    Uri = bondy_registry_entry:uri(Entry),
    write_cell(Tab, Type, RealmUri, Policy, Uri, Action, Extra).

%% @private
%% Async (no read-your-writes barrier): nothing on the entry path reads the
%% cell, and a barrier would make every REGISTER/SUBSCRIBE wait for the
%% registry drain's backlog.
write_cell(Tab, Type, RealmUri, Policy, Uri, Action, Extra) ->
    try
        Stamp = bondy_hlc:now(persistent_term:get(?CLOCK)),
        Count = ets:lookup_element(
            Tab, ?GROUP_KEY(Type, RealmUri, Policy, Uri), 2, 0
        ),
        Table = db_table(Type),
        Key = cell_key(RealmUri, Policy, Uri),
        Result =
            case {Type, Extra} of
                {registration, _} ->
                    Ops = [{apply, count, {set, {Stamp, Count}}} | Extra],
                    bondy_db:apply_batch_async(Table, RealmUri, Key, Ops);
                {subscription, []} ->
                    bondy_db:apply_async(
                        Table, RealmUri, Key, {set, {Stamp, Count}}
                    )
            end,
        log_rib_error(Result, Action, Type, RealmUri, Policy, Uri)
    catch
        Class:Reason:Stacktrace ->
            log_rib_exception(
                Class, Reason, Stacktrace, Action, Type, RealmUri, Policy, Uri
            )
    end.

%% @private
%% A group whose count reaches 0 loses its row; `match_delete` leaves a row a
%% concurrent add has already counted again.
uncount(Tab, Group) ->
    case ets:update_counter(Tab, Group, {2, -1, 0, 0}, {Group, 0}) of
        0 ->
            true = ets:match_delete(Tab, {Group, 0}),
            ok;
        _ ->
            ok
    end.

%% @private
log_rib_error(ok, _Action, _Type, _RealmUri, _Policy, _Uri) ->
    ok;
log_rib_error({error, Reason}, Action, Type, RealmUri, Policy, Uri) ->
    ?LOG_ERROR(#{
        description => "Failed to write a registry RIB reading",
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
        description => "Failed to write a registry RIB reading",
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
Reaction to a merged RIB cell (`{set, Summary}`). A peer's cell upserts its
stub, or drops it when `Summary`'s `count` is `0`, the only signal an emptied
group sends; every stub reader (`stub_nodes/4`, `match_stubs/2`,
`subscription_nodes/3`) relies on that. A cell naming this node is restated
(`restate/4`). MUST be total — called from the AAE merge reactor.
""".
-spec on_remote_set(
    Type :: entry_type(), Key :: binary(), Summary :: map()
) -> ok.

on_remote_set(Type, Key, Summary) when is_map(Summary) ->
    case decode_cell_key(Key) of
        {ok, {RealmUri, Policy, Uri, Node}} ->
            case bondy_config:nodestring() of
                Node ->
                    restate(Type, RealmUri, Policy, Uri);
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
Reaction to a RIB cell removal (`clear`): drops a peer's stub, or restates a
cell naming this node. The key is self-contained (realm included), so no
tombstone resolution is needed. MUST be total — called from the AAE merge
reactor.
""".
-spec on_remote_clear(Type :: entry_type(), Key :: binary()) -> ok.

on_remote_clear(Type, Key) ->
    case decode_cell_key(Key) of
        {ok, {RealmUri, Policy, Uri, Node}} ->
            case bondy_config:nodestring() of
                Node ->
                    restate(Type, RealmUri, Policy, Uri);
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
- a bootstrapping node's OWN cells hold readings of its previous
  incarnation's registrations and subscriptions, which died with it; the
  node restates each one with its current reading, which outranks them.

Implemented by replaying each installed cell through `on_remote_set/3`, which
restates an own-node cell and upserts or drops a peer cell's stub under the
`count = 0`-means-removed rule.

Idempotent in effect: a streamed snapshot notifies a table once per batch;
`stub_insert` is an upsert, and a repeated restatement writes the same count
under a later stamp. MUST be total — called from the AAE reactor.

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
entry point for `kind = rib`). A merged op is one field's write, not the
summary, so this reads the cell's CURRENT converged value, reshapes it
(`reshape_summary/2` — the generic CRDT modules' raw `to_value/1` is not
quite the summary shape read-side consumers expect: registration's raw
struct value may omit never-written `earliest`/`latest` fields), and
dispatches exactly as `on_remote_set/3` does (`count = 0` there is
equivalent to a clear). A cell that is gone by the time it is read
(reaped, or discarded by `stabilize/2`) is handled as `on_remote_clear/2`:
this node restates its own cell, and drops a peer's stub, whose licence is
the cell being gone. MUST be total — called from the AAE merge reactor.
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
                        on_remote_clear(Type, Key)
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
Drops this realm's stub rows that have no backing cell in the local
projection — the reclamation half that the cell reap cannot do itself.

A departed node's cell is removed by the membership-driven origin reap
(`m:bondy_oplog_origin_retirement`), and that is a local `stabilize` discard,
not an apply — so no merge event fires and `on_remote_clear/2` never runs.
The stub would otherwise outlive the cell it summarises, which is the half
that actually matters: every routing read path consults the stubs, not the
cells.

Absence of the cell is a sound signal here, which is the whole reason this
can be a sweep rather than a second membership subscriber:

- an ordinary teardown (the owner unregistering its last entry) reaches the
  peers as a merged `count = 0`, and `on_remote_set/3` drops the stub THEN —
  before the emptied cell is ever discarded, so it never presents as an
  orphan;
- a stub is never inserted before its cell exists, because
  `bondy_oplog_cell_apply` publishes merge events only after the cells of the
  batch are applied (`publish_merges/2`), so the add direction has no window
  where a live stub looks orphaned.

Fail-closed: if either projection cannot be listed, NOTHING is reaped. A
transient read failure must never be allowed to empty the routing view — the
cost of skipping a pass is one stale stub for another interval, the cost of
getting it wrong is a black-holed realm.

Returns the number of stubs dropped. Pinned by
`bondy_rib_reclamation_cluster_SUITE`.
""".
-spec reap_orphan_stubs(RealmUri :: uri()) -> non_neg_integer().

reap_orphan_stubs(RealmUri) ->
    case ets:whereis(?STUBS_TAB) of
        undefined ->
            0;
        _ ->
            lists:sum([
                prune_cellless_stubs(RealmUri, Node)
             || Node <- departed_stub_nodes(RealmUri)
            ])
    end.

%% @private
%% The nodestrings this realm holds stubs for that are no longer cluster
%% members. Membership is only the FILTER, never the licence to delete: a
%% removal is reversible, and dropping a returning node's stub would
%% blackhole its routing until it happened to rewrite a cell (this node's
%% frontier already claims its existing events, so AAE re-ships nothing).
%% What licenses a delete is the backing cell being gone, checked per key in
%% `prune_cellless_stubs/2`.
%%
%% Scoping to non-members is what keeps this affordable. The predecessor
%% listed EVERY cell of BOTH RIB tables per realm to diff against the stub
%% keys; `bondy_db:list/2` pages through `bondy_oplog_core:range_all/5`,
%% which scatters to every shard and truncates after merging, so it costs
%% O(cells x shards) decodes. Measured on the Fly fleet at 190,984
%% subscription cells: 43.5s for ONE table, every sweep. Here the common
%% case — nobody has departed — is one C-side match-spec scan returning a
%% handful of nodestrings, and no cell read at all.
departed_stub_nodes(RealmUri) ->
    MS = [{{{'_', RealmUri, '_', '_', '$1'}, '_'}, [], ['$1']}],
    Live = live_nodestrings(),
    [
        Node
     || Node <- lists:usort(ets:select(?STUBS_TAB, MS)),
        not lists:member(Node, Live)
    ].

%% @private
%% Current members as nodestrings, including this node — a stub naming us
%% would be an echo, never an orphan.
live_nodestrings() ->
    [
        atom_to_binary(Node, utf8)
     || Node <- partisan_membership:node_names()
    ] ++ [bondy_config:nodestring()].

%% @private
%% Deletes `Node`'s stubs in this realm whose backing cell is gone, and
%% returns how many. The cell is read per key rather than enumerated: the
%% match spec bounds the work to one departed node's rows, so this is a
%% point read per row that is already a deletion candidate.
%%
%% The cell disappears strictly LATER than the membership change that made
%% the node a candidate — it goes when the dead-origin reap has zeroed it and
%% `stabilize/2` has discarded it, which needs causal stability. So this is
%% expected to find nothing on its first pass or several, and it is on the
%% periodic sweep precisely because it must retry. A membership-triggered
%% one-shot would run exactly when the answer is still "the cell is there".
prune_cellless_stubs(RealmUri, Node) ->
    MS = [
        {{{'$1', RealmUri, '$2', '$3', Node}, '_'}, [], [
            {{'$1', RealmUri, '$2', '$3', Node}}
        ]}
    ],
    lists:foldl(
        fun(StubKey, Acc) ->
            case cell_is_gone(StubKey) of
                true ->
                    _ = stub_delete(StubKey),
                    Acc + 1;
                false ->
                    Acc
            end
        end,
        0,
        ets:select(?STUBS_TAB, MS)
    ).

%% @private
%% Whether the cell a stub summarises is absent from the local projection.
%% Fail-closed: anything other than a definite `not_found` — an unreadable
%% table, an unprovisioned type — leaves the stub alone, because this answer
%% decides a DELETION.
cell_is_gone({Type, RealmUri, Policy, Uri, Node}) ->
    try
        Table = db_table(Type),
        Key = term_to_binary({RealmUri, Policy, Uri, Node}),
        bondy_db:read(Table, RealmUri, Key) == {error, not_found}
    catch
        _:_ ->
            false
    end.

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
member_key(Entry) ->
    ?MEMBER_KEY(
        bondy_registry_entry:type(Entry),
        bondy_registry_entry:realm_uri(Entry),
        bondy_registry_entry:match_policy(Entry),
        bondy_registry_entry:uri(Entry),
        bondy_registry_entry:created(Entry),
        bondy_registry_entry:id(Entry)
    ).

%% @private
group_key(Entry) ->
    ?GROUP_KEY(
        bondy_registry_entry:type(Entry),
        bondy_registry_entry:realm_uri(Entry),
        bondy_registry_entry:match_policy(Entry),
        bondy_registry_entry:uri(Entry)
    ).

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
%% `[safe]` decode: the raw key was `term_to_binary`'d on the WRITING node
%% (`cell_key/1`) and travels verbatim, so a merge event hands us
%% peer-encoded bytes — the C-2 peer-bytes rule applies. Legitimate keys
%% are all-binary 4-tuples, so `[safe]` refuses nothing legitimate; it
%% keeps a malformed peer key from interning arbitrary atoms (falsifier:
%% `peer_key_with_unknown_atom_rejected_without_interning_test`).
decode_raw_cell_key(Raw) ->
    try binary_to_term(Raw, [safe]) of
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
%% A merged cell naming this node is an echo of a reading it wrote, possibly
%% in an earlier incarnation, so it answers with its current reading, which
%% outranks every reading stamped before it. Skipped while the partition
%% store is unreadable: the live count is then unknown, and writing 0 would
%% advertise the erasure of this node's live entries.
%%
%% MUST be total — called from the AAE merge reactor.
restate(Type, RealmUri, Policy, Uri) ->
    case store(RealmUri) of
        undefined ->
            ok;
        Store ->
            Tab = bondy_registry_store:rib_members_tab(Store),
            write_cell(Tab, Type, RealmUri, Policy, Uri, restate, [])
    end.

-doc """
Writes this node's current RIB cell for every group it holds live entries
for: the group's reading and, for a registration, its invoke policy and the
creation times of its first and last entries. Called by
`bondy_namespace_catalog` after every open of the `registry` DB, which starts
empty. MUST be total.
""".
-spec restore() -> ok.

restore() ->
    try
        lists:foreach(
            fun({_, Partition}) ->
                case bondy_registry_partition:store(Partition) of
                    undefined ->
                        ok;
                    Store ->
                        restore(
                            Store, bondy_registry_store:rib_members_tab(Store)
                        )
                end
            end,
            bondy_registry:partitions()
        )
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description =>
                    "Failed to restore this node's registry RIB cells",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            })
    end.

%% @private
restore(Store, Tab) ->
    Groups = ets:select(Tab, [
        {{?GROUP_KEY('$1', '$2', '$3', '$4'), '_'}, [], [
            {{'$1', '$2', '$3', '$4'}}
        ]}
    ]),
    lists:foreach(
        fun({Type, RealmUri, Policy, Uri}) ->
            Extra = registration_fields(
                Store, Tab, Type, RealmUri, Policy, Uri
            ),
            write_cell(Tab, Type, RealmUri, Policy, Uri, restore, Extra)
        end,
        Groups
    ).

%% @private
%% Members rows sort by creation time within a group, so its first and last
%% rows bound it.
registration_fields(Store, Tab, registration, RealmUri, Policy, Uri) ->
    MS = [
        {{?MEMBER_KEY(registration, RealmUri, Policy, Uri, '$1', '$2')}, [], [
            {{'$1', '$2'}}
        ]}
    ],
    case ets:select(Tab, MS, 1) of
        {[{Earliest, Id}], _} ->
            {[{Latest, _}], _} = ets:select_reverse(Tab, MS, 1),
            Bounds = [
                {apply, earliest, {set, Earliest}},
                {apply, latest, {set, Latest}}
            ],
            case
                bondy_registry_store:lookup(
                    Store, registration, RealmUri, Id, #{}
                )
            of
                {ok, Entry} ->
                    Invoke = bondy_registry_entry:get_option(
                        invoke, Entry, ?INVOKE_SINGLE
                    ),
                    [{apply, invoke, {set, Invoke}} | Bounds];
                {error, not_found} ->
                    Bounds
            end;
        '$end_of_table' ->
            []
    end;
registration_fields(_Store, _Tab, subscription, _RealmUri, _Policy, _Uri) ->
    [].

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
    %% See `store/1` for why an unreadable pool yields `undefined`.
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
                    {?MEMBER_KEY('$1', RealmUri, '$2', '$3', '_', '_')},
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
%% `earliest`/`latest` registers (normalised to `undefined` here).
%% Subscription's carrier is a bare reading
%% (`bondy_oplog_crdt_owned_reading`), so its raw value is an INTEGER, not a
%% map at all. Called immediately after every raw read/list, before any
%% `#{count := _}`-shaped pattern match.
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
