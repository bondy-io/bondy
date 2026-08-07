%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_registry_meta).
-moduledoc """
The distributed helper behind the **WAMP Meta API** registration/subscription
introspection procedures (`wamp.*.list|match|lookup|get|count_*` and their
paginated `bondy.*` counterparts) — the read side of the registry, as opposed
to the routing side (`bondy_registry`).

This is deliberately WAMP-meta-specific, not a general API: its values
are `wamp_meta` external maps (`bondy_registry_entry:to_external/2`), produced
on the node that owns the entry so full records never cross the wire.

Under RIB routing a node holds full entries only for its LOCAL
registrations/subscriptions; remote ones exist here only as RIB summaries. So
"list/match the entries of a realm" cannot be answered from one node — it is a
distributed query. This module runs that query:

- **`list/3` / `match/4`** — sequential **node-at-a-time** keyset pagination.
  The coordinator walks a stable-sorted node set — the local node plus only the
  nodes the RIB says hold a matching entry (realm-scoped for `list`, uri-scoped
  for `match`), so it never contacts a peer that could only answer empty —
  filling each page from one node's local registry before moving to the next;
  the opaque `bondy_pagination` cursor carries the remaining node list and the
  intra-node keyset position (the last `EntryId`). Best-effort AP: the local
  node's entries are visible at once, a peer's once its RIB stubs converge; a
  node unreachable at page time contributes nothing; membership drift between
  pages skips/omits rather than failing.

  These are **streaming enumerations**, so partiality is silent BY DESIGN: an
  unreachable node's entries are dropped and the page still reports
  `has_more => false` when the walk ends. This is deliberate and differs from
  `get/3` (below), which is a *definitive point query* and so distinguishes
  `not_found` from `unavailable`. A "here is a page" answer is understood as
  best-effort; a "the entry does not exist" answer must not lie.

- **`page_members/4`** — the same walk with a different projection: each value
  is the `{node, session_id}` of a callee/subscriber rather than the entry
  itself. Backs `bondy.registration.callee.list`.

- **`count/3`** — answered from RIB summaries alone (local matches plus the sum
  of the per-node summary `count`s), with no fan-out.

- **`get/3`** — a bare id has no URI, so the RIB cannot target it; a *parallel*
  broadcast over all cluster nodes returns the first hit, or `unavailable`
  (never a false `not_found`) if a node holding the entry could not be reached.

The module is also a per-node `partisan_gen_server`: a coordinator pages a peer
by calling `{?MODULE, PeerNode}`, and the peer answers `handle_call({page, …})`
from its own local registry. The node-local leg reads full entries
(`bondy_registry:list_local/4` / `bondy_registry:match/4`), never the RIB.
""".

-behaviour(partisan_gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_db_tables.hrl").

%% Bumped whenever the cursor payload encoding or the node-walk order changes,
%% so a cursor minted by an older release is rejected as stale rather than
%% paged wrongly.
-define(SCHEMA_VSN, 1).
-define(FP_BYTES, 16).
%% Per-node request timeout for the distributed legs. The overall get-by-id
%% deadline (`?GET_DEADLINE`) is a backstop above it: every worker replies
%% within `?NODE_TIMEOUT` (a partisan call always returns or times out), so the
%% backstop only fires if a worker process dies without answering.
-define(NODE_TIMEOUT, 5000).
-define(GET_DEADLINE, 10000).
%% Sentinel `Query` for `list` (whole realm) vs a URI for `match`.
-define(ALL, '$all').

%% Defaults for the page/result limits, overridable via `bondy_config`
%% `[registry, meta, *]`. The engine owns these so both WAMP adapters read one
%% source rather than each hard-coding the key and ceiling.
-define(DEFAULT_PAGE_SIZE, 100).
-define(MAX_PAGE_SIZE, 1000).
-define(MAX_RESULTS, 1000).

-type entry_type() :: bondy_registry_entry:entry_type().
-type page_opts() :: #{
    limit := pos_integer(),
    cursor => binary() | undefined
}.

%% The source-defined payload carried inside the bondy_pagination cursor is
%% `#{nodes := [node()], after_id := id() | undefined}` — the frozen remaining
%% node list (head = current) and the intra-node keyset position.

-export_type([page_opts/0]).

%% API
-export([count/3]).
-export([count_members/3]).
-export([default_page_size/0]).
-export([get/3]).
-export([list/3]).
-export([list_members/3]).
-export([page_members/4]).
-export([match/4]).
-export([max_page_size/0]).
-export([max_results/0]).

%% LIFECYCLE
-export([child_spec/0]).
-export([start_link/0]).

%% PARTISAN_GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
A cluster-wide keyset page of the entries of `Type` in `RealmUri`, in
node-then-`EntryId` order. `Opts` is a `t:page_opts/0`: `limit` (required) and
`cursor` (the wire binary from a prior page's `next`, or absent for the first
page). Returns `{ok, bondy_pagination:result_set()}` whose `values` are the
external entry maps (`bondy_registry_entry:to_external/2`, `wamp_meta`), or
`{error, stale | malformed}` for a bad cursor.
""".
-spec list(
    Type :: entry_type(),
    RealmUri :: uri(),
    Opts :: page_opts()
) ->
    {ok, bondy_pagination:result_set()} | {error, stale | malformed}.

list(Type, RealmUri, Opts) ->
    do_page(Type, RealmUri, ?ALL, entry, Opts).

-doc """
As `list/3`, but restricted to the entries whose registered/subscribed URI
matches `Uri` according to each entry's match policy (the meta `match`
operation). Same page shape and cursor discipline as `list/3`.
""".
-spec match(
    Type :: entry_type(),
    RealmUri :: uri(),
    Uri :: uri(),
    Opts :: page_opts()
) ->
    {ok, bondy_pagination:result_set()} | {error, stale | malformed}.

match(Type, RealmUri, Uri, Opts) when is_binary(Uri) ->
    do_page(Type, RealmUri, Uri, entry, Opts).

-doc """
The cluster-wide number of entries of `Type` matching `Uri` in `RealmUri`,
answered from RIB summaries without any fan-out: the local match count plus the
sum of the per-node summary counts. Best-effort AP — the sum may transiently
disagree with an enumerated `match` page under churn.
""".
-spec count(
    Type :: entry_type(),
    RealmUri :: uri(),
    Uri :: uri()
) -> {ok, non_neg_integer()}.

count(Type, RealmUri, Uri) when is_binary(Uri) ->
    Local = length(local_match(Type, RealmUri, Uri)),
    Remote = lists:sum([
        maps:get(count, Summary, 0)
     || {_Node, Summary} <-
            bondy_registry_rib:match_summaries(Type, RealmUri, Uri)
    ]),
    {ok, Local + Remote}.

-doc """
The number of callees (`registration`) / subscribers (`subscription`) for the
entry identified by `Id`, cluster-wide. `Id` is first resolved to its
procedure/topic URI (a broadcast `get/3`), then counted as `count/3` for that
URI: the members whose registration/subscription matches it (routing demand),
which for a plain exact registration is exactly its callee count. Best-effort AP.

Backs the WAMP `count_callees` / `count_subscribers` meta procedures. Returns
`{error, not_found}` when `Id` exists on no reachable node, or `{error,
unavailable}` when a node could not be reached to confirm the id's absence.
""".
-spec count_members(
    Type :: entry_type(),
    RealmUri :: uri(),
    Id :: id()
) -> {ok, non_neg_integer()} | {error, not_found | unavailable}.

count_members(Type, RealmUri, Id) ->
    with_resolved_uri(Type, RealmUri, Id, fun(Uri) ->
        count(Type, RealmUri, Uri)
    end).

-doc """
The WAMP session ids of the callees (`registration`) / subscribers
(`subscription`) for the entry identified by `Id`, cluster-wide. `Id` is resolved
to its URI (a broadcast `get/3`); then every node the RIB says holds a matching
entry is asked for its LOCAL member session ids and the union is returned. The
session ids themselves are never replicated (only summary counts are), so they
are gathered from each owner on demand. Best-effort AP: an unreachable node's
members are silently omitted.

Backs the WAMP `list_callees` / `list_subscribers` meta procedures. Returns
`{error, not_found}` / `{error, unavailable}` from the resolving `get/3` as for
`count_members/3`.
""".
-spec list_members(
    Type :: entry_type(),
    RealmUri :: uri(),
    Id :: id()
) -> {ok, [id()]} | {error, not_found | unavailable}.

list_members(Type, RealmUri, Id) ->
    with_resolved_uri(Type, RealmUri, Id, fun(Uri) ->
        {ok, gather_members(Type, RealmUri, Uri)}
    end).

-doc """
As `list_members/3`, but addressed by URI rather than by entry id, and pairing
each session id with the node that holds it — `{Nodestring, SessionId}`.

`Uri` is either a procedure/topic URI (members whose entry matches it) or the
atom `all` (every member in the realm).

Same cursor discipline, node walk and `page_opts()` as `list/3` and `match/4` —
this is the same keyset walk with a different projection, not a second
mechanism. `Query` is a procedure/topic URI (members whose entry matches it) or
the atom `all` (every member in the realm).

Values are `#{node => Nodestring, session_id => Id}`. The node is the point:
`list_members/3` returns a bare union of session ids because its caller (the
spec-frozen WAMP `list_callees`) takes ids alone, whereas
`bondy.registration.callee.list` reports where each callee lives. Under
write-only RIB the ids are not replicated — only summary counts are — so each
owner is asked for its own.

Two consequences of paging an ENTRY-keyed walk, both deliberate:

- **A page may hold fewer than `limit` values.** Entries with no session (a
  callback or internal registration) have no callee to report and are dropped
  from the projection. They still consume their place in the walk, so the
  cursor stays correct; only the page is shorter.
- **Dedup is per page, not global.** A session holding several matching
  registrations appears once per page it lands in, and can recur across pages.
  Deduplicating globally would need a session-keyed cursor, which the
  registry's id-ordered enumeration cannot provide. For a de-duplicated set
  scoped to ONE registration, use `list_members/3`.
""".
-spec page_members(
    Type :: entry_type(),
    RealmUri :: uri(),
    Query :: uri() | all,
    Opts :: page_opts()
) ->
    {ok, bondy_pagination:result_set()} | {error, stale | malformed}.

page_members(Type, RealmUri, all, Opts) ->
    do_page(Type, RealmUri, ?ALL, callee, Opts);
page_members(Type, RealmUri, Uri, Opts) when is_binary(Uri) ->
    do_page(Type, RealmUri, Uri, callee, Opts).

-doc "Default page size for the `bondy.*` paginated procedures.".
-spec default_page_size() -> pos_integer().

default_page_size() ->
    bondy_config:get([registry, meta, default_page_size], ?DEFAULT_PAGE_SIZE).

-doc "Ceiling page size for the `bondy.*` paginated procedures.".
-spec max_page_size() -> pos_integer().

max_page_size() ->
    bondy_config:get([registry, meta, max_page_size], ?MAX_PAGE_SIZE).

-doc """
Ceiling for the bounded (non-paginated) `wamp.*` enumerations: beyond it a
`wamp.*` list/match returns `{error, too_many_results}` and the caller is
steered to the paginated `bondy.*` family.
""".
-spec max_results() -> pos_integer().

max_results() ->
    bondy_config:get([registry, meta, max_results], ?MAX_RESULTS).

-doc """
The external form of the entry of `Type` with `Id` in `RealmUri`, resolved
cluster-wide. A bare id carries no owner and the RIB is keyed by URI, so the id
cannot be targeted; this is a **parallel** broadcast over the cluster node set
that returns the first node's hit — a not-found (or a slow node) costs one
round-trip, not the sum. Best-effort AP: an unreachable node is skipped.

Ids are drawn independently per node from a 53-bit uniform range, so a
cross-node collision is possible (astronomically unlikely); under one, the
first responder wins. Making ids cluster-unique (node-tagged) would remove both
the ambiguity and the broadcast — see `_design/REGISTRY_META_API.md`.

`{error, not_found}` is returned only when **every** targeted node answered
definitively absent. If any node was unreachable or timed out — so its absence
could not be confirmed — the result is `{error, unavailable}` rather than a
false "not found": the entry may exist on the node we could not reach.
""".
-spec get(
    Type :: entry_type(),
    RealmUri :: uri(),
    Id :: id()
) -> {ok, map()} | {error, not_found} | {error, unavailable}.

get(Type, RealmUri, Id) ->
    scatter_get(Type, RealmUri, Id, all_nodes()).

%% =============================================================================
%% LIFECYCLE
%% =============================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.

start_link() ->
    partisan_gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec child_spec() -> supervisor:child_spec().

child_spec() ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

%% =============================================================================
%% PARTISAN_GEN_SERVER CALLBACKS
%% =============================================================================

init([]) ->
    {ok, #{}}.

-doc """
The peer leg of the distributed walk. **Spawn-and-go**: the local read runs in a
short-lived worker that answers via `partisan_gen_server:reply/2`, so this
responder's mailbox frees immediately and requests from every coordinator run
concurrently — a serial responder would funnel the node's whole incoming
introspection rate through one process. The coordinator side is functional (it
runs in the calling request process); only this peer receiver is a process,
because with disterl off a cross-node request must reach a REGISTERED name.
""".
handle_call({page, Type, RealmUri, Query, AfterId, Need}, From, State) ->
    %% The pre-projection message, still sent by every `list`/`match` walk and
    %% by peers running an older release.
    _ = spawn(fun() ->
        partisan_gen_server:reply(
            From,
            peer_reply(fun() ->
                local_page(Type, RealmUri, Query, entry, AfterId, Need)
            end)
        )
    end),
    {noreply, State};
handle_call({page, Type, RealmUri, Query, Kind, AfterId, Need}, From, State) ->
    _ = spawn(fun() ->
        partisan_gen_server:reply(
            From,
            peer_reply(fun() ->
                local_page(Type, RealmUri, Query, Kind, AfterId, Need)
            end)
        )
    end),
    {noreply, State};
handle_call({get, Type, RealmUri, Id}, From, State) ->
    _ = spawn(fun() ->
        partisan_gen_server:reply(
            From, peer_reply(fun() -> local_get(Type, RealmUri, Id) end)
        )
    end),
    {noreply, State};
handle_call({members, Type, RealmUri, Uri}, From, State) ->
    _ = spawn(fun() ->
        partisan_gen_server:reply(
            From, peer_reply(fun() -> local_members(Type, RealmUri, Uri) end)
        )
    end),
    {noreply, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

%% @private
%% Wrap a peer-side read as the `{ok, _}` a coordinator expects; a raised error
%% becomes `{error, _}` so the coordinator sees a definite failure (→ empty page
%% for `page`, `unavailable` for `get`) rather than waiting out its timeout.
peer_reply(Fun) ->
    try
        {ok, Fun()}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_WARNING(#{
                description => "registry meta peer read raised",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {error, Reason}
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% The `cursor := _` clause MUST come first: a map pattern matches on a subset
%% of keys, so `#{limit := Limit}` also matches a map that carries `cursor`. If
%% it came first it would re-match its own defaulted output and loop forever.
do_page(Type, RealmUri, Query, Kind, #{limit := Limit, cursor := Cursor}) when
    is_integer(Limit) andalso Limit > 0
->
    %% `Kind` is part of the fingerprint so a cursor minted by
    %% `bondy.registration.callee.list` can never be resumed by
    %% `bondy.registration.list` for the same realm and query: the walks agree
    %% but the projections do not, and the caller would silently get the other
    %% procedure's values.
    Fingerprint = fingerprint(Type, RealmUri, Query, Kind),
    case resume(Fingerprint, Type, RealmUri, Query, Cursor) of
        {ok, Nodes, AfterId} ->
            %% Over-fetch one past the page so `has_more` needs no count.
            Tagged = collect(
                Type, RealmUri, Query, Kind, Nodes, AfterId, Limit + 1, []
            ),
            {ok, finalize(Fingerprint, Kind, Nodes, Tagged, Limit)};
        {error, _} = Error ->
            Error
    end;
do_page(Type, RealmUri, Query, Kind, #{limit := Limit} = Opts) when
    is_integer(Limit) andalso Limit > 0
->
    do_page(Type, RealmUri, Query, Kind, Opts#{cursor => undefined}).

%% @private
%% First page: freeze the node set. Resume: decode the cursor and read back the
%% frozen remaining node list and the intra-node keyset position.
resume(_Fingerprint, Type, RealmUri, Query, undefined) ->
    {ok, node_set(Type, RealmUri, Query), undefined};
resume(Fingerprint, _Type, _RealmUri, _Query, Bin) when is_binary(Bin) ->
    case bondy_pagination:decode_cursor(Fingerprint, Bin) of
        {ok, Cursor} ->
            #{nodes := Nodes, after_id := AfterId} =
                bondy_pagination:payload(Cursor),
            {ok, Nodes, AfterId};
        {error, _} = Error ->
            Error
    end.

%% @private
%% Walk `Nodes` in order, pulling up to the remaining `Need` items from each,
%% tagging every item with its source node, until `Need` items are gathered or
%% the nodes run out. A node returning fewer than asked is exhausted, so the
%% walk advances to the next node from its start. Result is newest-first while
%% building (reversed on return) so it ends in node-then-id order.
collect(_Type, _RealmUri, _Query, _Kind, _Nodes, _AfterId, Need, Acc) when
    Need =< 0
->
    lists:reverse(Acc);
collect(_Type, _RealmUri, _Query, _Kind, [], _AfterId, _Need, Acc) ->
    lists:reverse(Acc);
collect(Type, RealmUri, Query, Kind, [Node | Rest], AfterId, Need, Acc) ->
    Items = node_page(Type, RealmUri, Query, Kind, Node, AfterId, Need),
    Acc1 = lists:foldl(fun(Item, A) -> [{Node, Item} | A] end, Acc, Items),
    case length(Items) < Need of
        true ->
            collect(
                Type,
                RealmUri,
                Query,
                Kind,
                Rest,
                undefined,
                Need - length(Items),
                Acc1
            );
        false ->
            lists:reverse(Acc1)
    end.

%% @private
node_page(Type, RealmUri, Query, Kind, Node, AfterId, Need) ->
    case Node =:= partisan:node() of
        true ->
            local_page(Type, RealmUri, Query, Kind, AfterId, Need);
        false ->
            remote_page(Type, RealmUri, Query, Kind, Node, AfterId, Need)
    end.

%% @private
%% Best-effort: an unreachable or erroring peer contributes an empty page rather
%% than failing the whole query.
%%
%% `entry` keeps the original 6-element message so a peer running an older
%% release still answers the pre-existing `list`/`match` procedures; only the
%% new `callee` projection uses the wider tag, and only it degrades (to an
%% empty contribution) against a peer that does not know it.
remote_page(Type, RealmUri, Query, Kind, Node, AfterId, Need) ->
    Target = {?MODULE, Node},
    Msg =
        case Kind of
            entry -> {page, Type, RealmUri, Query, AfterId, Need};
            _ -> {page, Type, RealmUri, Query, Kind, AfterId, Need}
        end,
    try partisan_gen_server:call(Target, Msg, [{timeout, ?NODE_TIMEOUT}]) of
        {ok, Items} when is_list(Items) ->
            Items;
        _ ->
            []
    catch
        exit:_ ->
            []
    end.

%% @private
%% This node's leg: `{Id, External}` pairs of `Type` in `RealmUri`, ascending by
%% `EntryId`, up to `Need`, strictly past `AfterId`. `list` (Query = `?ALL`) is a
%% bounded ordered-ETS keyset select; `match` materialises the (small) local
%% matched set and slices it by id.
local_page(Type, RealmUri, ?ALL, Kind, AfterId, Need) ->
    Entries = bondy_registry:list_local(Type, RealmUri, AfterId, Need),
    [external_pair(E, Kind) || E <- Entries];
local_page(Type, RealmUri, Uri, Kind, AfterId, Need) when is_binary(Uri) ->
    %% `match` has no id-ordered index, so the local matched set is materialised
    %% and sliced per page — O(local matches) per page. That cardinality is the
    %% registrations/subscriptions for ONE uri (bounded by the invocation
    %% policy: 1 for `single`, the callee count for a shared registration), so
    %% it is cheap in practice; only a very-high-fanout shared registration pays
    %% a per-page cost. Filter by the keyset bound BEFORE sorting so later pages
    %% sort a smaller set.
    Matches = local_match(Type, RealmUri, Uri),
    Seeked =
        case AfterId of
            undefined ->
                Matches;
            _ ->
                [E || E <- Matches, bondy_registry_entry:id(E) > AfterId]
        end,
    Sorted = lists:sort(
        fun(A, B) ->
            bondy_registry_entry:id(A) =< bondy_registry_entry:id(B)
        end,
        Seeked
    ),
    [external_pair(E, Kind) || E <- lists:sublist(Sorted, Need)].

%% @private
%% The `callee` projection carries the session id only; the NODE is added by
%% `values/2` from the walk's own tag, which is where it is known. Sessionless
%% entries (callback / internal registrations) project to `undefined` rather
%% than being filtered here: dropping them would shorten this leg, and `collect`
%% reads a short leg as "node exhausted" and would skip the rest of its entries.
external_pair(Entry, entry) ->
    {
        bondy_registry_entry:id(Entry),
        bondy_registry_entry:to_external(Entry, wamp_meta)
    };
external_pair(Entry, callee) ->
    Member =
        case bondy_registry_entry:session_id(Entry) of
            SessionId when is_binary(SessionId) ->
                bondy_session_id:to_external(SessionId);
            _ ->
                undefined
        end,
    {bondy_registry_entry:id(Entry), Member}.

%% @private
%% This node's local matched entries for `Uri` as a plain entry list. Reads only
%% local full entries.
local_match(Type, RealmUri, Uri) ->
    extract_entries(bondy_registry:match(Type, RealmUri, Uri, #{})).

%% @private
%% Normalise every documented shape of the routing match return to an entry
%% list: subscription `{[entry()], [node()]}` (bare) or `{{[entry()], [node()]},
%% cont}` (paged); registration `[entry()]` (bare) or `{[entry()], cont}`
%% (paged); `?EOT`. The nested-tuple clause MUST precede the `{Entries, _}` one
%% (a paged subscription's outer element is a tuple, not a list).
extract_entries(?EOT) ->
    [];
extract_entries({{Entries, Nodes}, _Cont}) when
    is_list(Entries) andalso is_list(Nodes)
->
    Entries;
extract_entries({Entries, _}) when is_list(Entries) ->
    Entries;
extract_entries(Entries) when is_list(Entries) ->
    Entries.

%% @private
%% Resolve `Id` to its URI via the broadcast `get/3`, then apply `Fun(Uri)`.
%% `get/3`'s `not_found` / `unavailable` are propagated unchanged.
with_resolved_uri(Type, RealmUri, Id, Fun) ->
    case get(Type, RealmUri, Id) of
        {ok, External} ->
            Fun(maps:get(uri, External));
        {error, _} = Error ->
            Error
    end.

%% @private
%% The union of every RIB-targeted node's LOCAL member session ids for `Uri`,
%% node-at-a-time (the same uri-scoped node set as a `match` walk). Best-effort:
%% an unreachable node contributes none.
gather_members(Type, RealmUri, Uri) ->
    PerNode = [
        node_members(Type, RealmUri, Uri, Node)
     || Node <- node_set(Type, RealmUri, Uri)
    ],
    lists:usort(lists:append(PerNode)).

%% @private
node_members(Type, RealmUri, Uri, Node) ->
    case Node =:= partisan:node() of
        true ->
            local_members(Type, RealmUri, Uri);
        false ->
            remote_members(Type, RealmUri, Uri, Node)
    end.

%% @private
%% Best-effort: an unreachable or erroring peer contributes an empty member list.
remote_members(Type, RealmUri, Uri, Node) ->
    Target = {?MODULE, Node},
    Msg = {members, Type, RealmUri, Uri},
    try partisan_gen_server:call(Target, Msg, [{timeout, ?NODE_TIMEOUT}]) of
        {ok, Members} when is_list(Members) ->
            Members;
        _ ->
            []
    catch
        exit:_ ->
            []
    end.

%% @private
%% This node's local member session ids for `Uri`: the WAMP session id of each
%% local matching entry that has a session. Internal / callback entries have no
%% session and are skipped.
local_members(Type, RealmUri, Uri) ->
    lists:filtermap(
        fun(Entry) ->
            case bondy_registry_entry:session_id(Entry) of
                SessionId when is_binary(SessionId) ->
                    {true, bondy_session_id:to_external(SessionId)};
                _ ->
                    false
            end
        end,
        local_match(Type, RealmUri, Uri)
    ).

%% @private
%% Parallel broadcast: query every node at once and take the first hit, so a
%% not-found (or one slow node) costs a single round-trip's latency, not the
%% sum. The work runs in a throwaway middleman — stray late replies land in its
%% mailbox and die with it, never polluting the caller's. The caller only spawns
%% (never links) the middleman, so a worker/middleman crash can never kill the
%% caller (the WAMP request process); it just times out to `unavailable`.
scatter_get(Type, RealmUri, Id, Nodes) ->
    Caller = self(),
    Mid = spawn(fun() -> get_middleman(Caller, Type, RealmUri, Id, Nodes) end),
    receive
        {Mid, Result} ->
            Result
    after ?GET_DEADLINE ->
        {error, unavailable}
    end.

%% @private
%% Fan the per-node queries out as LINKED workers and collect the first hit.
%% Linking means a worker crash fails the get fast (the caller times out to
%% `unavailable`) instead of hanging a pending slot to the deadline, and dead
%% workers can't outlive the middleman. The middleman MONITORS the caller: if it
%% goes away (client disconnect / cancel), the middleman exits abnormally, which
%% reaps its linked workers — no orphaned partisan calls linger under load.
get_middleman(Caller, Type, RealmUri, Id, Nodes) ->
    MonRef = erlang:monitor(process, Caller),
    Ref = make_ref(),
    Self = self(),
    _ = [
        spawn_link(fun() ->
            Self ! {Ref, node_get(Type, RealmUri, Id, Node)}
        end)
     || Node <- Nodes
    ],
    Caller ! {Self, await_get(Ref, MonRef, length(Nodes), false)}.

%% @private
%% Return `not_found` only when EVERY node answered definitively absent; if any
%% node could not confirm (unreachable / timeout / unexpected), the entry may
%% exist where we could not look, so the honest answer is `unavailable`.
await_get(_Ref, _Mon, 0, false) ->
    {error, not_found};
await_get(_Ref, _Mon, 0, true) ->
    {error, unavailable};
await_get(Ref, Mon, Pending, AnyUnavailable) ->
    receive
        {Ref, {found, External}} ->
            {ok, External};
        {Ref, not_found} ->
            await_get(Ref, Mon, Pending - 1, AnyUnavailable);
        {Ref, unavailable} ->
            await_get(Ref, Mon, Pending - 1, true);
        {'DOWN', Mon, process, _Pid, _Reason} ->
            %% The caller is gone; abandon so the linked workers are reaped.
            exit(caller_gone)
    after ?GET_DEADLINE ->
        %% A node never answered — treat as unconfirmed, not absent.
        {error, unavailable}
    end.

%% @private
node_get(Type, RealmUri, Id, Node) ->
    case Node =:= partisan:node() of
        true ->
            local_get(Type, RealmUri, Id);
        false ->
            remote_get(Type, RealmUri, Id, Node)
    end.

%% @private
local_get(Type, RealmUri, Id) ->
    case bondy_registry:lookup(Type, RealmUri, Id) of
        {ok, Entry} ->
            {found, bondy_registry_entry:to_external(Entry, wamp_meta)};
        {error, not_found} ->
            not_found
    end.

%% @private
%% `{found, _}` / `not_found` are definitive answers from the peer; a peer we
%% could not reach (exit) or an unexpected reply is `unavailable` — its absence
%% is unconfirmed, so it must not read as a definitive `not_found`.
remote_get(Type, RealmUri, Id, Node) ->
    Target = {?MODULE, Node},
    Msg = {get, Type, RealmUri, Id},
    try partisan_gen_server:call(Target, Msg, [{timeout, ?NODE_TIMEOUT}]) of
        {ok, {found, _} = Found} ->
            Found;
        {ok, not_found} ->
            not_found;
        _ ->
            unavailable
    catch
        exit:_ ->
            unavailable
    end.

%% @private
%% Take the page and, when more remain, mint the resume cursor from the last
%% in-page item: its node (and the frozen node suffix from there) plus its id.
finalize(_Fingerprint, Kind, _Nodes, Tagged, Limit) when
    length(Tagged) =< Limit
->
    bondy_pagination:result(values(Kind, Tagged), undefined);
finalize(Fingerprint, Kind, Nodes, Tagged, Limit) ->
    Page = lists:sublist(Tagged, Limit),
    {ResumeNode, {ResumeId, _External}} = lists:nth(Limit, Tagged),
    Remaining = lists:dropwhile(fun(N) -> N =/= ResumeNode end, Nodes),
    Payload = #{nodes => Remaining, after_id => ResumeId},
    Next = bondy_pagination:new_cursor(Fingerprint, Payload),
    bondy_pagination:result(values(Kind, Page), Next).

%% @private
%% The `callee` projection is where the walk's node tag is finally used, and
%% where sessionless entries are dropped — so a page can be shorter than
%% `limit` while `has_more` stays true. `usort` deduplicates a session holding
%% several matching registrations WITHIN the page; across pages it can recur
%% (see `page_members/4`).
values(entry, Tagged) ->
    [External || {_Node, {_Id, External}} <- Tagged];
values(callee, Tagged) ->
    lists:usort([
        #{node => atom_to_binary(Node, utf8), session_id => SessionId}
     || {Node, {_Id, SessionId}} <- Tagged, SessionId =/= undefined
    ]).

%% @private
%% The node set for a list/match walk: the local node plus ONLY the nodes the
%% RIB says hold a matching entry (realm-scoped for `list`, uri-scoped for
%% `match`), so the walk skips peers that could only answer empty. A node never
%% stubs itself, so unioning the local node in is exactly the full owner set.
node_set(Type, RealmUri, ?ALL) ->
    with_local(rib_nodes(bondy_registry_rib:realm_nodestrings(Type, RealmUri)));
node_set(Type, RealmUri, Uri) when is_binary(Uri) ->
    Nodestrings = [
        Nodestring
     || {Nodestring, _Summary} <-
            bondy_registry_rib:match_summaries(Type, RealmUri, Uri)
    ],
    with_local(rib_nodes(Nodestrings)).

%% @private
%% All connected cluster nodes — the target set for get-by-id, which the RIB
%% cannot narrow (a bare id has no URI to look up).
all_nodes() ->
    lists:usort([partisan:node() | partisan:nodes()]).

%% @private
with_local(Nodes) ->
    lists:usort([partisan:node() | Nodes]).

%% @private
%% Nodestrings (the RIB stub identity) -> node atoms. A cluster node's atom
%% always exists (it is or was connected), so a nodestring that fails to resolve
%% names a node this VM has never seen and is safely dropped (best-effort).
rib_nodes(Nodestrings) ->
    lists:foldl(
        fun(Nodestring, Acc) ->
            try binary_to_existing_atom(Nodestring, utf8) of
                Node -> [Node | Acc]
            catch
                error:badarg -> Acc
            end
        end,
        [],
        Nodestrings
    ).

%% @private
fingerprint(Type, RealmUri, Query, Kind) ->
    Full = crypto:hash(
        sha256, term_to_binary({?SCHEMA_VSN, Type, RealmUri, Query, Kind})
    ),
    binary:part(Full, 0, ?FP_BYTES).
