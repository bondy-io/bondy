%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_alarm_api).
-moduledoc """
`bondy_wamp_api` implementation exposing the alarm subsystem as read-only WAMP
procedures: `bondy.alarm.list`, `.get`, `.history` and `.catalogue`.

Read-only by construction — there is no acknowledge, no silence and no clear.
An alarm states a condition that is true now; clearing one without fixing the
condition would make the surface lie, and silencing is the operator's job in
Alertmanager, not Bondy's.

## Master realm only

All four go through `bondy_wamp_api_utils:admin_call_args/3`, so a session in a
tenant realm is refused. It is the no-realm validator family: none of these
procedures takes a realm argument — `get` takes an alarm id — so the realm-first
one would read the caller's own realm URI as that id whenever the call arrived
one argument short. A `class = realm` alarm still carries its `realm_uri`, but
that field NAMES the affected tenant for an operator; it is not a scope granting
that tenant access.

The `bondy.alarm.{raised,updated,cleared}` topics
(`bondy_event_wamp_publisher`) are published in the master realm for the same
reason, and carry `to_external/1` — the rendering this module's replies carry.

## Registered nowhere

`bondy.*` is dispatched statically by `bondy_dealer` to `bondy_wamp_api`, which
routes the `bondy.alarm.` prefix here. Authorisation is the ordinary
`bondy_rbac:authorize(<<"wamp.call">>, Uri, Ctxt)` the dealer applies to every
call before dispatch, so these procedures are grantable and revocable like any
other.

## The wire form of an alarm id

Ids are Erlang terms — `bondy_db_main_unavailable`, or
`{mail_relay_down, <<"smtp">>}`. On the wire an atom id becomes its name and a
tuple id becomes a list, so the pair above is `["mail_relay_down", "smtp"]`.

`bondy.alarm.get` compares the RENDERED id rather than decoding the argument
back into a term. That is deliberate: decoding would mean calling
`binary_to_atom/2` on caller-supplied input, and the atom table is not
garbage-collected. The cost is that two ids differing only in whether an element
is an atom or a binary would render alike; no producer raises such a pair.

## The cluster view is a fan-out, not a replicated store

`bondy.alarm.list` and `.get` answer for the whole cluster by calling
`local_alarms/0` on every member. Alarm state is never replicated: one of the
alarms is raised when the durable store is unavailable, so a subsystem that
needed that store in order to report on it would have a hole exactly where it
is most needed.

The reply says which nodes answered and which did not. `alarms: []` with
`silent: []` means the cluster is clean; `alarms: []` with `silent: ["n2"]`
means n2 was not heard from and nothing is known about it. A caller that cannot
tell those apart eventually pages on the wrong one.

Three properties, each held by structure rather than by care, and each pinned
in `bondy_alarm_cluster_SUITE` — which needs a second node, because on one node
the reply is identical whether the fan-out works or is absent:

- **The local node's alarms never depend on the fan-out.** They are read
  directly and prepended, so a total Partisan failure still answers for this
  node and reports every peer silent.
- **`answered` and `silent` partition the membership.** `answered` is derived
  from the replies actually received, never from the transport's own bad-node
  bookkeeping; `silent` is the remainder. No member can fall out of both.
- **Membership is read lock-free.** `partisan_membership:node_names/0` is an
  ETS read, where `partisan_peer_service:members/0` is a
  `gen_server:call(..., infinity)` — an unbounded wait on the very process a
  cluster fault would block. Connected peers (`partisan:nodes/0`) would be the
  wrong set for the opposite reason: a member that is DOWN would vanish from the
  reply rather than appear as silent, and the vanished node is usually the
  interesting one. Removing the fan-out fails all four cases; targeting
  connected peers instead of members fails the stopped-peer case.

One part of `envelope/2` is NOT covered: replies are filtered to known members,
so a peer answering with a node name nobody asked about is dropped and its real
name reported silent. That needs a divergent peer to exercise and no test
produces one.

## `bondy.alarm.history` walks the cluster ONE NODE AT A TIME

D2 makes the ring explicitly per-node, and the design once concluded from that
that history could not be a cluster-wide answer: merging rings from several
nodes would need their clocks ordered, which nothing here can do. The walk
sidesteps that rather than solving it. It never MERGES: it drains this node's
ring, then the next member's, then the next, and CONCATENATES. Two transitions
from different nodes are never compared, so no cross-node clock ordering is
asserted and none is needed. Each event names the node that recorded it.

The walk order is this node first, then the peers sorted, so it is stable
across pages while the membership is, and the common case costs nothing: a
caller asking for 100 events on a node whose ring holds 100 never contacts a
peer at all.

**A page is bounded in TIME as well as in size.** The whole page shares one
`?FANOUT_TIMEOUT`, and a caller's `CALL.Options._deadline` caps that. Whatever
is left of the budget is the timeout for the next node, so a walk over n
unreachable peers costs one budget rather than n. A page whose budget runs out
stops early and its cursor resumes at the nodes it did not get to, so nothing
is skipped; the first node of a page is always contacted, so a page can be cut
short but never emptied, and paging always advances.

**A node that leaves mid-walk is dropped, not reported.** A cursor names the
nodes still to walk, and they are intersected with the membership when it is
resumed. Nothing failed — history is never replicated, so a departing node
takes its ring with it — and the position the cursor held in that node's ring
is dropped with it, because a sequence number means nothing on another node's
ring.

**`not_reached` accumulates.** A node the walk ASKED and did not hear from is
named, and stays named on every later page — the set rides in the cursor, so
the last page of a walk states the whole truth about it. That is the same
distinction `list` draws with `silent`: a node that could not be asked is not a
node that answered "nothing". Nodes the budget merely deferred are NOT in it —
they are asked on the next page, and a set that named them would have to un-name
them later, which an accumulated set cannot do.

## Everything is made encodable

A producer's description or detail value can be any term — the HTTP connector
puts `reason => LastError` in its description, and that has been seen holding
tuples. Anything not directly representable is rendered with `~p` rather than
allowed to reach the encoder, because a JSON encoder raising here would take
down the caller's session while reporting on a fault elsewhere.

The rule itself is `bondy_wamp_api_utils:encodable/1`, shared with
`bondy_task_api`: one map that must survive the encoder, expressed once. This
module's tests still own it — `bondy_alarm_api_test` covers every clause
through the three renderings below, including the charlist and empty-list
readings.
""".
-behaviour(bondy_wamp_api).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_uris.hrl").

%% Total budget for ONE REPLY's fan-out: the whole of `bondy.alarm.list`, and
%% one PAGE of `bondy.alarm.history`. A member that has not answered by then is
%% reported rather than made to hold up the reply: the operator asking what is
%% wrong is usually asking BECAUSE a node is unwell, and that is the worst
%% moment to block on it.
%%
%% It was per-NODE for the history walk until 2026-09-01, so a walk over n
%% unreachable peers took 5n seconds and reported nothing about them. What is
%% pinned on one node is that an unreachable peer is NAMED —
%% `bondy_alarm_api_SUITE:every_page_reports_the_nodes_it_did_not_reach`.
%% That the budget is SHARED rather than spent afresh per node needs two nodes
%% and a forced deadline to observe, and is not covered yet.
-define(FANOUT_TIMEOUT, 5000).
%% Binds a history cursor to the walk it was minted for. Bumped whenever the
%% cursor payload or the node-walk order changes, so a cursor from an older
%% release is rejected as stale rather than paged wrongly. v2 added the
%% `unreached` field.
-define(HISTORY_FP, ~"bondy_alarm_history_v2").
-define(HISTORY_PAGE_DEFAULT, 100).
-define(HISTORY_PAGE_MAX, 1000).

-export([handle_call/3]).

-export([to_external/1]).

%% The page-size bounds this procedure enforces. Exported so the MCP overlay
%% can DECLARE them (`bondy_mcp_sre_overlay`) instead of restating them: a
%% tool schema is prompt, and a `maximum` that has drifted from the clamp is a
%% lie told to an agent that has no way to check it.
-export([history_page_default/0]).
-export([history_page_max/0]).

%% The fan-out target, called on every member by `cluster_alarms/0`.
-export([local_alarms/0]).
-export([local_history/2]).

%% Rendering is exported for the eunit module, which pins the encodability
%% contract above without standing up a session.
-export([render_alarm/1]).
-export([render_entry/1]).
-export([render_event/1]).
-export([wire_id/1]).

%% =============================================================================
%% API
%% =============================================================================

-spec history_page_default() -> pos_integer().

history_page_default() ->
    ?HISTORY_PAGE_DEFAULT.

-spec history_page_max() -> pos_integer().

history_page_max() ->
    ?HISTORY_PAGE_MAX.

-spec handle_call(
    Proc :: uri(), M :: bondy_wamp_message:call(), Ctxt :: bondy_context:t()
) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined
    )}
    | {reply, wamp_result() | wamp_error()}
    | no_return().

handle_call(?BONDY_ALARM_LIST, #call{} = M, Ctxt) ->
    [] = bondy_wamp_api_utils:admin_call_args(M, Ctxt, 0),
    {reply, result(M, [cluster_alarms(call_deadline(M))])};
handle_call(?BONDY_ALARM_GET, #call{} = M, Ctxt) ->
    [WireId] = bondy_wamp_api_utils:admin_call_args(M, Ctxt, 1),
    %% The same envelope as `list`, filtered. An alarm id can be raised on
    %% several nodes at once, so `get` answers WHERE the condition holds, and a
    %% miss is an ordinary empty result rather than an error: with a non-empty
    %% `silent` set "no node reports it" is genuinely uncertain, and an error
    %% would state the opposite. Filtering here rather than on each member
    %% keeps one remote entry point; an alarm list is single digits.
    {reply, result(M, [filtered(cluster_alarms(call_deadline(M)), WireId)])};
handle_call(?BONDY_ALARM_HISTORY, #call{} = M, Ctxt) ->
    [] = bondy_wamp_api_utils:admin_call_args(M, Ctxt, 0),
    Limit = history_limit(M),
    %% ONE deadline for the whole call, read once. Each PAGE takes its own
    %% `?FANOUT_TIMEOUT` under it, which is why the pager is handed the call's
    %% deadline rather than a page's: a progressive stream is many pages and
    %% only the caller's own deadline bounds the lot.
    Deadline = call_deadline(M),
    Pager = fun(Cursor) -> history_page(Deadline, Limit, Cursor) end,
    case bondy_wamp_api_utils:wants_progress(M) of
        true ->
            %% The caller asked for progressive results, so it gets the whole
            %% walk as a stream and never handles a cursor. Same pager, so the
            %% two modes cannot disagree about what the history IS.
            case bondy_wamp_api_utils:stream_pages(M, Ctxt, Pager) of
                ok -> ok;
                {error, Reason} -> {reply, page_error(Reason, M)}
            end;
        false ->
            case decode_history_cursor(M) of
                {ok, Cursor} ->
                    case Pager(Cursor) of
                        {ok, Page} ->
                            Ext = maps:merge(
                                bondy_pagination:to_external(Page),
                                bondy_wamp_api_utils:page_extras(Page)
                            ),
                            {reply, result(M, [Ext])};
                        {error, Reason} ->
                            {reply, page_error(Reason, M)}
                    end;
                {error, Reason} ->
                    {reply, page_error(Reason, M)}
            end
    end;
handle_call(?BONDY_ALARM_CATALOGUE, #call{} = M, Ctxt) ->
    [] = bondy_wamp_api_utils:admin_call_args(M, Ctxt, 0),
    Entries = [render_entry(E) || E <- bondy_alarm_catalogue:list()],
    {reply, result(M, [#{~"entries" => Entries}])};
handle_call(_, #call{} = M, _) ->
    E = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, E}.

-doc """
One page of THIS node's alarm history: up to `Limit` transitions whose `seq` is
below `AfterSeq`, newest first.

The node-local leg of the cluster walk, and the one place a remote member is
asked for history. Events are rendered HERE, on the node that owns the ring, so
each carries its own `node` and no internal term crosses the wire — the same
rule `local_alarms/0` follows.

`AfterSeq` is `undefined` for the first page of a node. The ring is newest-first
and `seq` strictly increases, so "below `AfterSeq`" walks it downwards: a
transition recorded WHILE a walk is in progress takes a higher `seq` and is
simply not in it. An offset would have shifted under that push and repeated an
event.
""".
-spec local_history(
    AfterSeq :: pos_integer() | undefined, Limit :: pos_integer()
) ->
    {node(), [map()]}.

local_history(AfterSeq, Limit) ->
    Events = [
        render_event(E)
     || #{seq := Seq} = E <- bondy_alarm_handler:history(),
        AfterSeq == undefined orelse Seq < AfterSeq
    ],
    {partisan:node(), lists:sublist(Events, Limit)}.

-doc """
This node's active alarms, tagged with this node's name.

The RPC entry point of the fan-out, and the one place a remote member is asked
for anything. It is tagged rather than positional so a reply carries its own
provenance: `answered` is then read off the replies themselves and cannot drift
from whatever bookkeeping the transport does.
""".
-spec local_alarms() -> {node(), [map()]}.

local_alarms() ->
    {partisan:node(), [to_external(A) || A <- bondy_alarm_handler:list()]}.

-doc """
An alarm as it appears on every surface: the `bondy.alarm.list` and `.get`
replies, and the `bondy.alarm.{raised,updated,cleared}` event payloads.

One shape for both, deliberately — a subscriber and a poller parse the same
map, and an agent that reacts to an event can act on it without a follow-up
call.
""".
-spec to_external(bondy_alarm_handler:alarm()) -> map().

to_external(Alarm) ->
    %% Bound rather than written as `render_alarm(A)#{...}`: a map update
    %% cannot be applied directly to a function-call expression.
    Rendered = render_alarm(Alarm),
    Rendered#{~"node" => nodestring()}.

-doc """
An active alarm as a WAMP-encodable map.

A pure function of the alarm — the node it came from is stamped by the caller,
which is the only place that knows it. That matters for the cluster fan-out,
where the alarms in one reply come from several nodes.
""".
-spec render_alarm(bondy_alarm_handler:alarm()) -> map().

render_alarm(#{id := Id} = Alarm) ->
    Rendered = bondy_wamp_api_utils:encodable(maps:without([id], Alarm)),
    Rendered#{~"id" => wire_id(Id), ~"catalogue_id" => catalogue_id(Id)}.

%% @private
%% The JOIN KEY for the runbook. A raised alarm's id is concrete
%% (`{mail_relay_down, <<"smtp1">>}`) while its catalogue entry is a PATTERN
%% (`{mail_relay_down, '_'}`), so without this a consumer holding an alarm has
%% to re-implement `bondy_alarm_catalogue:matches/2` to find the entry that
%% names its `observe_with` refs and tasks — the one thing the runbook join exists
%% to spare it.
%%
%% `null` for an alarm no entry declares. That cannot happen for an alarm this
%% build raises (`bondy_alarm_catalogue_test` fails if it could) but an adopted
%% OTP alarm from before the swap, or one raised by a future producer, can
%% carry any term at all.
catalogue_id(Id) ->
    case bondy_alarm_catalogue:lookup(Id) of
        {ok, #{id_pattern := Pattern}} -> wire_id(Pattern);
        error -> null
    end.

-doc """
A history entry as a WAMP-encodable map.
""".
-spec render_event(bondy_alarm_handler:event()) -> map().

render_event(#{id := Id} = Event) ->
    Rendered = bondy_wamp_api_utils:encodable(maps:without([id], Event)),
    %% Stamped with the node, like an alarm is: history is a cluster-wide walk
    %% and a page mixes rings, so an event that did not name its own would be
    %% unattributable the moment it left the node that recorded it.
    Rendered#{~"id" => wire_id(Id), ~"node" => nodestring()}.

-doc """
A catalogue entry as a WAMP-encodable map.
""".
-spec render_entry(bondy_alarm_catalogue:entry()) -> map().

render_entry(#{id_pattern := Pattern} = Entry) ->
    Rendered = bondy_wamp_api_utils:encodable(
        maps:without([id_pattern], Entry)
    ),
    Rendered#{~"id_pattern" => wire_id(Pattern)}.

-doc """
The wire form of an alarm id: an atom becomes its name, a tuple becomes a list.
""".
-spec wire_id(term()) -> binary() | list().

wire_id(Id) when is_tuple(Id) ->
    [bondy_wamp_api_utils:encodable(E) || E <- tuple_to_list(Id)];
wire_id(Id) ->
    bondy_wamp_api_utils:encodable(Id).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% One page of the cluster-wide history walk.
%%
%% NODE-AT-A-TIME keyset pagination, the same shape `bondy_registry_meta` uses
%% for the registry — one pagination dialect across the API. The walk order is
%% this node first, then the peers sorted, so it is stable across pages while
%% the membership is.
%%
%% Filling from ONE node before moving on is what makes the common case free:
%% a caller asking for 100 events on a node whose ring holds 100 gets them
%% without a single peer being contacted. The peers are reached only if the
%% caller asks for the next page.
%%
%% A peer that cannot answer contributes nothing and the walk continues, but
%% it is NAMED — see `not_reached` on `page/3`.
history_page(Deadline, Limit, undefined) ->
    walk(history_nodes(), undefined, Limit, page_deadline(Deadline), []);
history_page(Deadline, Limit, Cursor) ->
    case bondy_pagination:payload(Cursor) of
        #{nodes := Nodes0, after_seq := After0, unreached := Unreached} ->
            {Nodes, After} = still_members(Nodes0, After0),
            walk(Nodes, After, Limit, page_deadline(Deadline), Unreached);
        _ ->
            {error, malformed}
    end.

%% @private
%% A cursor's remaining walk, restricted to nodes that are STILL members and
%% left in the cursor's order.
%%
%% A node that has LEFT is not `not_reached`. Nothing failed: alarm history is
%% never replicated (D2), so a departing node takes its ring with it and there
%% is nothing left to be unable to reach. Naming it would tell an operator to
%% go and look at a node that is gone.
%%
%% `AfterSeq` belongs to the HEAD node — it is a position in THAT node's ring —
%% so when the head is dropped the position goes with it. Carrying it onto the
%% next node would filter that node's ring by a sequence number minted on a
%% different one, silently skipping transitions instead of failing.
still_members(Nodes, After) ->
    still_members(Nodes, After, partisan_membership:node_names()).

%% @private
still_members([], After, _Members) ->
    {[], After};
still_members([Node | Rest], After, Members) ->
    case lists:member(Node, Members) of
        true ->
            {[Node | [N || N <- Rest, lists:member(N, Members)]], After};
        false ->
            still_members(Rest, undefined, Members)
    end.

%% @private
%% Each PAGE gets its own `?FANOUT_TIMEOUT`, and the caller's `_deadline` caps
%% the lot. The split is deliberate: a page is what a caller waits on, so
%% bounding the page is what bounds the wait, while a progressive stream of
%% many pages can only be bounded as a whole by a deadline the caller named.
page_deadline(Deadline) ->
    now_ms() + bondy_wamp_api_utils:budget(Deadline, ?FANOUT_TIMEOUT).

%% @private
call_deadline(#call{options = Opts}) when is_map(Opts) ->
    bondy_wamp_api_utils:deadline(Opts);
call_deadline(#call{}) ->
    infinity.

%% @private
remaining(Deadline) ->
    max(0, Deadline - now_ms()).

%% @private
now_ms() ->
    erlang:system_time(millisecond).

%% @private
history_nodes() ->
    Self = partisan:node(),
    [Self | lists:sort(partisan_membership:node_names() -- [Self])].

%% @private
%% One page of the walk.
%%
%% The FIRST node of a page is contacted unconditionally, and only later ones
%% are gated on the budget. That is what makes every page ADVANCE: a page that
%% contacted nobody would hand back the cursor it was given, and a caller
%% paging on that would make no progress at all. An expired deadline therefore
%% shortens a page; it cannot empty one.
%%
%% NOT COVERED, and now barely reachable. `stream_pages/3` settles as soon as
%% the deadline passes, so the progressive path can no longer ask for a page
%% whose budget is already spent, and a single-page call computes its budget
%% fresh — so reaching this needs more than `_deadline` milliseconds to elapse
%% between `call_deadline/1` and the walk. It is kept because the alternative
%% is a caller who can be handed its own cursor back, not because anything
%% here exercises it.
walk([], _After, _Limit, _Deadline, Unreached) ->
    %% Only reachable from a cursor naming no nodes, which this module never
    %% mints — `next/5` answers a walked-out list with a final page.
    {ok, page([], undefined, Unreached)};
walk([Node | Rest], After, Limit, Deadline, Unreached) ->
    visit(Node, Rest, After, Limit, [], Deadline, Unreached).

%% @private
visit(Node, Rest, After, Limit, Acc, Deadline, Unreached) ->
    Need = Limit - length(Acc),
    case node_history(Node, After, Need, remaining(Deadline)) of
        {error, _} ->
            %% Asked and could not answer. That is not the same as holding
            %% nothing, so it is named rather than counted as empty — and it
            %% stays named for the rest of the walk, because the walk moves
            %% past it and never asks again.
            next(Rest, Limit, Acc, Deadline, Unreached ++ [Node]);
        {ok, Events} when length(Events) < Need ->
            %% This node is exhausted; continue with the next from its newest.
            next(
                Rest, Limit, lists:reverse(Events) ++ Acc, Deadline, Unreached
            );
        {ok, Events} ->
            %% The page is full. Resume from THIS node — it may hold more, and
            %% asking is cheaper than being wrong about it.
            Acc1 = lists:reverse(Events) ++ Acc,
            done(Acc1, [Node | Rest], last_seq(Events), Unreached)
    end.

%% @private
next([], _Limit, Acc, _Deadline, Unreached) ->
    %% Every node walked: a final page, no cursor, and `not_reached` is now
    %% the whole truth about the walk.
    {ok, page(lists:reverse(Acc), undefined, Unreached)};
next([Node | Rest] = Nodes, Limit, Acc, Deadline, Unreached) ->
    case remaining(Deadline) of
        0 ->
            %% The budget is spent with nodes still to walk. The page stops
            %% here and its cursor resumes AT them, so nothing is skipped.
            %%
            %% They are deliberately NOT in `not_reached`: they were never
            %% asked, the next page asks them, and a set that named them could
            %% not also be the accumulated truth — a later page would have to
            %% REMOVE a node from it, which is the one thing an accumulated
            %% set cannot do.
            %%
            %% NOT COVERED on one node: naming them here passes every case in
            %% `bondy_alarm_api_SUITE` (mutation-checked 2026-09-01). Observing
            %% it needs the budget to expire with a peer still to walk, which
            %% needs a second node.
            done(Acc, Nodes, undefined, Unreached);
        _ ->
            visit(Node, Rest, undefined, Limit, Acc, Deadline, Unreached)
    end.

%% @private
%% A page that stops with nodes still to walk: `Acc` is reversed here, once.
done(Acc, Nodes, After, Unreached) ->
    {ok,
        page(
            lists:reverse(Acc), cursor(Nodes, After, Unreached), Unreached
        )}.

%% @private
cursor(Nodes, After, Unreached) ->
    bondy_pagination:new_cursor(
        ?HISTORY_FP,
        #{nodes => Nodes, after_seq => After, unreached => Unreached}
    ).

%% @private
%% A result set with the walk's own wire key on it.
%%
%% `not_reached` is the nodes this WALK asked and did not hear from, carried
%% forward in the cursor and therefore ACCUMULATING: every page states the
%% running total and the last page states the whole truth. It is on every page,
%% empty or not — a caller that saw the key only when something had gone wrong
%% would have to already know it existed to notice its absence.
%%
%% It is not `bondy.alarm.list`'s `silent`, and is not named that on purpose:
%% `silent` is one half of a PARTITION of the membership, and a walk in
%% progress has no such partition to offer — nodes it has not reached yet are
%% neither answered nor silent.
page(Values, Next, Unreached) ->
    Base = bondy_pagination:result(Values, Next),
    Base#{~"not_reached" => [atom_to_binary(N, utf8) || N <- Unreached]}.

%% @private
%% The local ring is read directly and never travels, so a Partisan failure
%% that makes every peer silent still answers for the node being asked — and
%% the local node can never be one of the unreached.
%%
%% `Timeout` is what is LEFT of the page's budget, not a fresh one per node.
node_history(Node, After, Limit, Timeout) ->
    case Node == partisan:node() of
        true ->
            {ok, element(2, local_history(After, Limit))};
        false ->
            try
                partisan_rpc:call(
                    Node, ?MODULE, local_history, [After, Limit], Timeout
                )
            of
                {_, Events} when is_list(Events) -> {ok, Events};
                Other -> {error, Other}
            catch
                Class:Reason -> {error, {Class, Reason}}
            end
    end.

%% @private
last_seq(Events) ->
    maps:get(~"seq", lists:last(Events)).

%% @private
history_limit(M) ->
    bondy_wamp_api_utils:page_limit(
        M, history_page_default(), history_page_max()
    ).

%% @private
%% A cursor this procedure did not mint is refused rather than ignored: paging
%% on from a position that means something else would silently skip or repeat
%% transitions, and a caller cannot tell which happened.
decode_history_cursor(M) ->
    case bondy_wamp_api_utils:page_cursor(M) of
        undefined ->
            {ok, undefined};
        Bin when is_binary(Bin) ->
            bondy_pagination:decode_cursor(?HISTORY_FP, Bin);
        _ ->
            {error, malformed}
    end.

%% @private
%% The caller asked for a bound and the walk reached it. `transient` and
%% `wamp.error.timeout`, because retrying with a larger `_deadline` — or with
%% `limit` low enough that a page fits inside the one they gave — is a
%% reasonable thing for the caller to do next.
%%
%% `stream_budget_exhausted`, the other way `stream_pages/3` refuses to finish,
%% deliberately does NOT get a clause: that one is a pager that never reports
%% `has_more => false`, which is a defect in this module rather than anything
%% the caller did, and it falls through to an internal error.
page_error(stream_deadline_exceeded, M) ->
    Error = bondy_error:new(timeout, #{
        message => ~"The alarm history walk ran out of time.",
        description =>
            <<
                "The stream did not finish within the `_deadline` this call "
                "set. The transitions already delivered are complete as far "
                "as they go; nothing after them was read."
            >>
    }),
    bondy_wamp_error:to_wamp(
        Error, ?CALL, bondy_wamp_message:request_id(M), #{}
    );
%% @private
%% A bad cursor is the caller's, not the node's.
page_error(Reason, M) when Reason == stale; Reason == malformed ->
    Error = bondy_error:new(invalid_argument, #{
        message => ~"Invalid pagination cursor.",
        description =>
            <<
                "The `cursor` argument is not a cursor this procedure minted, "
                "or was minted by an incompatible release. Restart from the "
                "first page by omitting it."
            >>,
        details => #{reason => Reason}
    }),
    bondy_wamp_error:to_wamp(
        Error, ?CALL, bondy_wamp_message:request_id(M), #{}
    );
page_error(Reason, M) ->
    bondy_wamp_api_utils:error(Reason, M).

%% @private
%% The cluster view. The local answer is taken directly and never travels, so
%% it survives a Partisan failure that makes every peer silent.
cluster_alarms(Deadline) ->
    Local = local_alarms(),
    Members = partisan_membership:node_names(),
    Peers = Members -- [partisan:node()],
    Timeout = bondy_wamp_api_utils:budget(Deadline, ?FANOUT_TIMEOUT),
    envelope([Local | peer_answers(Peers, Timeout)], [partisan:node() | Peers]).

%% @private
%% A peer that produced no answer is silent — which is what the envelope
%% already means — so the failure of the fan-out as a whole needs no branch of
%% its own beyond returning nothing. `multicall/5`'s own `BadNodes` is
%% discarded rather than trusted: `silent` is computed as the complement of
%% what actually arrived, so a node cannot fall out of both sets.
peer_answers([], _Timeout) ->
    [];
peer_answers(Peers, Timeout) ->
    try
        {Replies, _BadNodes} = partisan_rpc:multicall(
            Peers, ?MODULE, local_alarms, [], Timeout
        ),
        Replies
    catch
        _:_ -> []
    end.

%% @private
%% `answered` and `silent` PARTITION `Expected`: answered is filtered to known
%% members, silent is the remainder. Pinned by
%% `bondy_alarm_cluster_SUITE:answered_and_silent_partition_the_membership`.
envelope(Answers, Expected) ->
    Known = [{N, As} || {N, As} <- Answers, lists:member(N, Expected)],
    Answered = [N || {N, _} <- Known],
    #{
        ~"alarms" => lists:append([As || {_, As} <- Known]),
        ~"nodes" => #{
            ~"answered" => nodestrings(Answered),
            ~"silent" => nodestrings(Expected -- Answered)
        }
    }.

%% @private
%% The alarms this envelope holds for one id, the node sets untouched — the
%% `silent` set is what qualifies an empty result.
filtered(#{~"alarms" := Alarms} = Envelope, WireId) ->
    Envelope#{
        ~"alarms" := [A || A <- Alarms, maps:get(~"id", A) == WireId]
    }.

%% @private
result(#call{request_id = Id}, Args) ->
    bondy_wamp_message:result(Id, #{}, Args).

%% @private
%% `partisan_config` sets `nodestring` to `atom_to_binary(name, utf8)`
%% (partisan_config.erl:886), so this is the same string a member stamps on its
%% own alarms in `to_external/1` — the two are joinable.
nodestrings(Nodes) ->
    [atom_to_binary(N, utf8) || N <- lists:sort(Nodes)].

%% @private
nodestring() ->
    partisan:nodestring().
