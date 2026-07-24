%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_registry_meta).
-moduledoc """
The distributed engine behind the **WAMP Meta API** registration/subscription
introspection procedures (`wamp.*.list|match|lookup|get|count_*` and their
paginated `bondy.*` counterparts) — the read side of the registry, as opposed
to the routing side (`bondy_registry`).

This is deliberately WAMP-meta-specific, not a general query engine: its values
are `wamp_meta` external maps (`bondy_registry_entry:to_external/2`), produced
on the node that owns the entry so full records never cross the wire.

Under write-only RIB routing a node holds full entries only for its LOCAL
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
-export([default_page_size/0]).
-export([get/3]).
-export([list/3]).
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
    do_page(Type, RealmUri, ?ALL, Opts).

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
    do_page(Type, RealmUri, Uri, Opts).

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
The peer leg of the distributed walk: page THIS node's local registry and
reply with `{Id, External}` pairs in ascending `EntryId` order.
""".
handle_call({page, Type, RealmUri, Query, AfterId, Need}, _From, State) ->
    {reply, {ok, local_page(Type, RealmUri, Query, AfterId, Need)}, State};
handle_call({get, Type, RealmUri, Id}, _From, State) ->
    {reply, {ok, local_get(Type, RealmUri, Id)}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

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
do_page(Type, RealmUri, Query, #{limit := Limit, cursor := Cursor}) when
    is_integer(Limit) andalso Limit > 0
->
    Fingerprint = fingerprint(Type, RealmUri, Query),
    case resume(Fingerprint, Type, RealmUri, Query, Cursor) of
        {ok, Nodes, AfterId} ->
            %% Over-fetch one past the page so `has_more` needs no count.
            Tagged = collect(
                Type, RealmUri, Query, Nodes, AfterId, Limit + 1, []
            ),
            {ok, finalize(Fingerprint, Nodes, Tagged, Limit)};
        {error, _} = Error ->
            Error
    end;
do_page(Type, RealmUri, Query, #{limit := Limit} = Opts) when
    is_integer(Limit) andalso Limit > 0
->
    do_page(Type, RealmUri, Query, Opts#{cursor => undefined}).

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
collect(_Type, _RealmUri, _Query, _Nodes, _AfterId, Need, Acc) when Need =< 0 ->
    lists:reverse(Acc);
collect(_Type, _RealmUri, _Query, [], _AfterId, _Need, Acc) ->
    lists:reverse(Acc);
collect(Type, RealmUri, Query, [Node | Rest], AfterId, Need, Acc) ->
    Items = node_page(Type, RealmUri, Query, Node, AfterId, Need),
    Acc1 = lists:foldl(fun(Item, A) -> [{Node, Item} | A] end, Acc, Items),
    case length(Items) < Need of
        true ->
            collect(
                Type,
                RealmUri,
                Query,
                Rest,
                undefined,
                Need - length(Items),
                Acc1
            );
        false ->
            lists:reverse(Acc1)
    end.

%% @private
node_page(Type, RealmUri, Query, Node, AfterId, Need) ->
    case Node =:= partisan:node() of
        true ->
            local_page(Type, RealmUri, Query, AfterId, Need);
        false ->
            remote_page(Type, RealmUri, Query, Node, AfterId, Need)
    end.

%% @private
%% Best-effort: an unreachable or erroring peer contributes an empty page rather
%% than failing the whole query.
remote_page(Type, RealmUri, Query, Node, AfterId, Need) ->
    Target = {?MODULE, Node},
    Msg = {page, Type, RealmUri, Query, AfterId, Need},
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
local_page(Type, RealmUri, ?ALL, AfterId, Need) ->
    Entries = bondy_registry:list_local(Type, RealmUri, AfterId, Need),
    [external_pair(E) || E <- Entries];
local_page(Type, RealmUri, Uri, AfterId, Need) when is_binary(Uri) ->
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
    [external_pair(E) || E <- lists:sublist(Sorted, Need)].

%% @private
external_pair(Entry) ->
    {
        bondy_registry_entry:id(Entry),
        bondy_registry_entry:to_external(Entry, wamp_meta)
    }.

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
finalize(_Fingerprint, _Nodes, Tagged, Limit) when length(Tagged) =< Limit ->
    bondy_pagination:result(values(Tagged), undefined);
finalize(Fingerprint, Nodes, Tagged, Limit) ->
    Page = lists:sublist(Tagged, Limit),
    {ResumeNode, {ResumeId, _External}} = lists:nth(Limit, Tagged),
    Remaining = lists:dropwhile(fun(N) -> N =/= ResumeNode end, Nodes),
    Payload = #{nodes => Remaining, after_id => ResumeId},
    Next = bondy_pagination:new_cursor(Fingerprint, Payload),
    bondy_pagination:result(values(Page), Next).

%% @private
values(Tagged) ->
    [External || {_Node, {_Id, External}} <- Tagged].

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
fingerprint(Type, RealmUri, Query) ->
    Full = crypto:hash(
        sha256, term_to_binary({?SCHEMA_VSN, Type, RealmUri, Query})
    ),
    binary:part(Full, 0, ?FP_BYTES).
