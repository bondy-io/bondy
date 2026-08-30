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

`bondy.alarm.history` does NOT fan out. D2 makes the ring explicitly per-node,
and merging rings from several nodes would need their clocks ordered — a
question this design has not ruled on. The reply names its node.

## Everything is made encodable

A producer's description or detail value can be any term — the HTTP connector
puts `reason => LastError` in its description, and that has been seen holding
tuples. Anything not directly representable is rendered with `~p` rather than
allowed to reach the encoder, because a JSON encoder raising here would take
down the caller's session while reporting on a fault elsewhere. Pinned by
`bondy_alarm_api_test:non_encodable_terms_are_rendered_test`.
""".
-behaviour(bondy_wamp_api).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_uris.hrl").

%% Total budget for the whole fan-out, not per node. A member that has not
%% answered by then is reported silent rather than made to hold up the reply:
%% the operator asking what is wrong is usually asking BECAUSE a node is
%% unwell, and that is the worst moment to block on it.
-define(FANOUT_TIMEOUT, 5000).

-export([handle_call/3]).

-export([to_external/1]).

%% The fan-out target, called on every member by `cluster_alarms/0`.
-export([local_alarms/0]).

%% Rendering is exported for the eunit module, which pins the encodability
%% contract above without standing up a session.
-export([render_alarm/1]).
-export([render_entry/1]).
-export([render_event/1]).
-export([wire_id/1]).

%% =============================================================================
%% API
%% =============================================================================

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
    {reply, result(M, [cluster_alarms()])};
handle_call(?BONDY_ALARM_GET, #call{} = M, Ctxt) ->
    [WireId] = bondy_wamp_api_utils:admin_call_args(M, Ctxt, 1),
    %% The same envelope as `list`, filtered. An alarm id can be raised on
    %% several nodes at once, so `get` answers WHERE the condition holds, and a
    %% miss is an ordinary empty result rather than an error: with a non-empty
    %% `silent` set "no node reports it" is genuinely uncertain, and an error
    %% would state the opposite. Filtering here rather than on each member
    %% keeps one remote entry point; an alarm list is single digits.
    {reply, result(M, [filtered(cluster_alarms(), WireId)])};
handle_call(?BONDY_ALARM_HISTORY, #call{} = M, Ctxt) ->
    [] = bondy_wamp_api_utils:admin_call_args(M, Ctxt, 0),
    Events = [render_event(E) || E <- bondy_alarm_handler:history()],
    {reply, result(M, [#{~"node" => nodestring(), ~"events" => Events}])};
handle_call(?BONDY_ALARM_CATALOGUE, #call{} = M, Ctxt) ->
    [] = bondy_wamp_api_utils:admin_call_args(M, Ctxt, 0),
    Entries = [render_entry(E) || E <- bondy_alarm_catalogue:list()],
    {reply, result(M, [#{~"entries" => Entries}])};
handle_call(_, #call{} = M, _) ->
    E = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, E}.

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
    Rendered = maps:fold(
        fun(K, V, Acc) -> Acc#{key(K) => encodable(V)} end,
        #{},
        maps:without([id], Alarm)
    ),
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
    Rendered = maps:fold(
        fun(K, V, Acc) -> Acc#{key(K) => encodable(V)} end,
        #{},
        maps:without([id], Event)
    ),
    Rendered#{~"id" => wire_id(Id)}.

-doc """
A catalogue entry as a WAMP-encodable map.
""".
-spec render_entry(bondy_alarm_catalogue:entry()) -> map().

render_entry(#{id_pattern := Pattern} = Entry) ->
    Rendered = maps:fold(
        fun(K, V, Acc) -> Acc#{key(K) => encodable(V)} end,
        #{},
        maps:without([id_pattern], Entry)
    ),
    Rendered#{~"id_pattern" => wire_id(Pattern)}.

-doc """
The wire form of an alarm id: an atom becomes its name, a tuple becomes a list.
""".
-spec wire_id(term()) -> binary() | list().

wire_id(Id) when is_tuple(Id) ->
    [encodable(E) || E <- tuple_to_list(Id)];
wire_id(Id) ->
    encodable(Id).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% The cluster view. The local answer is taken directly and never travels, so
%% it survives a Partisan failure that makes every peer silent.
cluster_alarms() ->
    Local = local_alarms(),
    Members = partisan_membership:node_names(),
    Peers = Members -- [partisan:node()],
    envelope([Local | peer_answers(Peers)], [partisan:node() | Peers]).

%% @private
%% A peer that produced no answer is silent — which is what the envelope
%% already means — so the failure of the fan-out as a whole needs no branch of
%% its own beyond returning nothing. `multicall/5`'s own `BadNodes` is
%% discarded rather than trusted: `silent` is computed as the complement of
%% what actually arrived, so a node cannot fall out of both sets.
peer_answers([]) ->
    [];
peer_answers(Peers) ->
    try
        {Replies, _BadNodes} = partisan_rpc:multicall(
            Peers, ?MODULE, local_alarms, [], ?FANOUT_TIMEOUT
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

%% @private
key(K) when is_atom(K) -> atom_to_binary(K, utf8);
key(K) when is_binary(K) -> K;
key(K) -> printed(K).

%% @private
%% Total by construction: every term has an encodable image, and the last
%% clause is what stops an unexpected one reaching the encoder.
encodable(V) when is_binary(V) -> V;
encodable(V) when is_number(V) -> V;
encodable(V) when is_boolean(V) -> V;
encodable(V) when is_atom(V) -> atom_to_binary(V, utf8);
encodable(V) when is_map(V) ->
    maps:fold(fun(K, X, Acc) -> Acc#{key(K) => encodable(X)} end, #{}, V);
encodable(V) when is_list(V) ->
    case is_string(V) andalso unicode:characters_to_binary(V) of
        B when is_binary(B) -> B;
        _ -> [encodable(E) || E <- V]
    end;
encodable(V) ->
    printed(V).

%% @private
%% A charlist renders as a string rather than as an array of code points. The
%% ambiguity is inherent to Erlang and unresolvable in general; this resolves
%% it the way a reader expects, and a list of small integers that was NOT text
%% is the price. The empty list stays a list, because `[]` far more often means
%% "no elements" than "empty string".
is_string([]) ->
    false;
is_string(L) ->
    lists:all(fun is_char/1, L).

%% @private
is_char(C) when is_integer(C) ->
    C == 9 orelse C == 10 orelse C == 13 orelse
        (C >= 32 andalso C < 16#D800) orelse
        (C > 16#DFFF andalso C < 16#110000);
is_char(_) ->
    false.

%% @private
printed(V) ->
    iolist_to_binary(io_lib:format("~p", [V])).
