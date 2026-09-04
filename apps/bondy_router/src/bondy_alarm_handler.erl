%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_alarm_handler).
-moduledoc """
A replacement for OTP's default `alarm_handler`.

An alarm is a statement about a condition that is true *now*. It is identified
by its id: raising one that is already raised is a restatement, not a second
alarm.

## The record

State is a map of `id() => alarm()`. An `alarm()` carries a `severity`
(`warning | major | critical`), a `class`, structured `details`, and the
`raised_at` / `updated_at` timestamps. `raised_at` survives restatement, so
"how long has this been up" is answerable — pinned by
`restatement_with_new_content_preserves_raised_at_test`.

Two ways in:

- `alarm_handler:set_alarm({Id, Desc})` and `alarm_handler:clear_alarm(Id)` —
  the raw OTP calls, and the ONLY spelling for the 2-tuple form. This module
  deliberately exports no 1-arity wrapper: it would be byte-identical to OTP's
  (`gen_event:notify(alarm_handler, …)`), and a second spelling of one
  operation is how half the tree ends up calling each. It also matters for
  layering — `bondy_oplog` and `bondy_mail` raise alarms without depending on
  `bondy_router` (see `bondy_oplog_applier.erl`), which only the OTP call
  allows.
- `set_alarm/2` — the same plus an options map. This IS this module's, because
  OTP has no such call. The 3-tuple it sends passes through
  `alarm_handler:set_alarm/1` unchanged (sasl-4.4 `alarm_handler.erl:103`), so
  a producer outside `bondy_router` can send one too.

`severity`, `class` and `affects_ready` come from three sources in order: an
explicit valid option, then the `bondy_alarm_catalogue` entry for the id, then
`major` / `node` / `false`. Every producer in the tree raises through the OTP
2-tuple, so in practice the catalogue is what classifies them — which is the
point: the judgement lives in one reviewable table rather than at nine raise
sites. An id the catalogue does not declare still lands, with the constants.

`get_alarms/0` keeps returning OTP-shaped `{Id, Desc}` pairs. It is a
projection of the record, not a second store; `list/0` returns the alarms
themselves. Its five callers (`bondy_cluster_topology`, `bondy_prometheus_db`,
`bondy_mcp_gateway` and two test suites) are unaffected by the richer record —
pinned by `get_alarms_projection_is_two_tuples_test`.

## Readiness

An alarm may declare `affects_ready => true`, meaning "while this condition
holds, do not send this node traffic". `affects_ready/0` folds the active
alarms into the single boolean `bondy_app:is_ready/0` consumes. The flag is
per-alarm and NOT derived from `severity`: an unreachable upstream connector is
`major` and must not pull the node out of the load balancer, while a failed
durable store is `major` and must.

`affects_ready/0` is total — before the handler is installed, and after it is
removed or has crashed, it reads as `false`. That is not a fallback for a
signal that would otherwise survive: a handler crash is repaired by
`bondy_event_handler_watcher`, which re-installs with
`add_sup_handler(alarm_handler, bondy_alarm_handler, [])`, so `init([])` runs
and the alarm set is empty either way. Answering NOT READY on an unreadable
handler would therefore flap the node out of rotation without preserving any
signal. Conditions that must survive a handler crash are not published as
alarms at all — see `bondy_namespace_catalog:set_main_failed/1`, which records
its state in `persistent_term` and only mirrors it as an alarm.

**`affects_ready/0` does not call this handler.** `/ready` is polled per
node per second by every load balancer in front of it, and a `gen_event:call`
serializes that poll behind whatever else the shared `alarm_handler` manager
is doing — including handlers this module does not own. So the boolean is
PUBLISHED on every transition into a one-element `atomics` array and read
lock-free.

The array's REF is written to a persistent term at most once per node
(`ready_ref/0`); the boolean is never. `persistent_term:put/2` scans every
process holding a reference to the term it replaces, so a value that changes
must not live there — a flapping alarm would put a node-wide GC on the raise
path, which is a worse defect than the call this removes. Storing a mutable
cell's ref once and mutating the cell is the shape
`bondy_retained_message_manager:get_counters_ref/1` already uses.

No catalogue entry declares `affects_ready => true` today, so this whole path
carries a `false` in every shipped configuration and is exercised only by
tests — see `bondy_alarm_catalogue:list/0`'s doc. That is worth knowing before
trusting it: the first real declarer is the one that will find its bugs.

`handle_call(affects_ready, State)` remains as the ORACLE the published
boolean is a cache of: it recomputes from the alarm map, and
`published_readiness_matches_the_handler_test` asserts the two agree across a
sequence of transitions.

One consequence is worth stating, because the previous `gen_event:call`
concealed it: raising an alarm is a CAST, so a raise and a readiness read are
NOT ordered. `/ready` can answer READY for as long as the raise sits in this
handler's mailbox. That window is bounded by the mailbox and invisible to
anyone but a caller that just raised — `/ready` is polled on the order of a
second — but it is why `bondy_app_readiness_test` has to synchronise before
asserting, and it would be wrong to make `set_alarm/2` synchronous to remove
it: a producer reporting a problem must never block on the alarm subsystem.

## History

A bounded ring of the last #{?HISTORY_MAX} transitions, newest first, per node.
Not replicated and not persisted: a node restart legitimately starts from a
re-detected present.

**A restatement that changes nothing is not a transition** and does not enter
the ring, and produces no `bondy.alarm.updated`. Pinned by
`identical_restatement_records_no_history_test` and, end to end, by
`bondy_alarm_api_SUITE:only_a_real_change_publishes_an_update`.

This is load-bearing rather than tidy, but not because any producer currently
depends on it: every producer in the tree gates its own raise on a flag
(`bondy_oplog_responder`'s `Alarmed orelse`, `bondy_oplog_applier`'s
`drain_stalled`, `bondy_oplog_origin_bans`'s `alarmed`), so none of them
restates in a loop today. The rule is what makes that gating an OPTIMISATION
rather than a correctness requirement — a producer that drops its flag, or a
new one that never had one, cannot evict the ring or flood the topics.

The ring is a flap budget, not a time budget — an alarm oscillating on a
3-second probe fills it in five minutes. It is a convenience for an operator
who is already looking, never the audit record: every transition is also
logged, and Prometheus holds the durable series.

## Correlation

`onset_trace_id` is the W3C trace id of the occurrence that RAISED the
condition, and it survives restatement exactly as `raised_at` does. The name
carries the labelling the design asks for: an alarm up for an hour pointing at
an hour-old trace is only misleading if the field does not say which occurrence
it names.

Most alarms will not have one, and that is a property of the tree rather than
an omission here: Bondy has no ambient trace context — a trace rides in a
message's `'_traceparent'` option — and seven of the nine catalogued producers
are background probes, appliers and sweepers with no request to inherit from.
The field is absent there rather than filled with a freshly minted id, which
would correlate with nothing.

## Topics

Each transition is handed to `bondy_event_manager` as
`{[bondy, alarm, raised | updated | cleared], Alarm}`, which
`bondy_event_wamp_publisher` turns into the matching `bondy.alarm.*` WAMP
topic in the master realm, subject to demand. The same three transitions feed
the ring and the topics, so a subscriber's view and `history/0` cannot
disagree.

Emission never fails and never blocks: see `emit/2`.
""".
-behaviour(gen_event).

-include_lib("kernel/include/logger.hrl").

%% The ring holds transitions, not time. See the moduledoc.
-define(HISTORY_MAX, 100).
%% The persistent-term key holding the readiness `atomics` REF. See the
%% moduledoc: the ref is written once, the boolean lives in the array.
-define(READY_KEY, {?MODULE, affects_ready}).
-define(DEFAULT_SEVERITY, major).
-define(DEFAULT_CLASS, node).

-record(state, {
    alarms = #{} :: #{id() => alarm()},
    %% Newest first, paired with its length so a push never walks the list.
    history = {0, []} :: {non_neg_integer(), [event()]},
    %% The next `seq` to stamp. Strictly increasing for the life of the
    %% handler, so the ring has a stable keyset key — see `push/2`.
    seq = 1 :: pos_integer()
}).

-type id() :: term().
-type severity() :: warning | major | critical.
-type class() :: node | cluster | realm | integration.

-type alarm() :: #{
    id := id(),
    description := term(),
    severity := severity(),
    class := class(),
    affects_ready := boolean(),
    details := map(),
    realm_uri => binary(),
    onset_trace_id => binary(),
    raised_at := integer(),
    updated_at := integer()
}.

-type event() :: #{
    action := raised | updated | cleared,
    id := id(),
    severity := severity(),
    at := integer(),
    %% Strictly increasing per node, newest = highest. `at` is a millisecond
    %% timestamp and is neither unique nor monotonic, so it cannot be a
    %% pagination key; this can. Assigned by `push/2`, the one place an event
    %% enters the ring.
    seq := pos_integer()
}.

-export_type([alarm/0, event/0, severity/0, class/0]).

%% API
-export([affects_ready/0]).
-export([get_alarms/0]).
-export([history/0]).
-export([list/0]).
-export([set_alarm/2]).

%% GEN_EVENT CALLBACKS
-export([init/1]).
-export([handle_event/2]).
-export([handle_call/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Raise or restate an alarm, carrying `severity`, `class`, `affects_ready`,
`realm_uri`, `onset_trace_id` and `details`.

Unrecognised `severity`, `class` or `affects_ready` values fall back to
`major` / `node` / `false` rather than failing: a producer reporting a problem
must never be turned into a second problem. `severity` does NOT decide
readiness — `affects_ready` is a separate per-alarm declaration.

A `realm`-class alarm MUST carry its affected tenant in `realm_uri`, so a
consumer can attribute it without parsing the alarm id.

An app that must not depend on `bondy_router` raises the same alarm through
OTP's `alarm_handler:set_alarm/1` with a `{Id, Description, Opts}` 3-tuple:
OTP passes the term through unchanged and `handle_event/2` below accepts that
shape. This is the only supported way to reach these fields from outside.
""".
-spec set_alarm({id(), term()}, map()) -> ok.

set_alarm({Id, Desc}, Opts) when is_map(Opts) ->
    gen_event:notify(alarm_handler, {set_alarm, {Id, Desc, Opts}}).

-doc """
Active alarms as OTP-shaped `{Id, Description}` pairs, newest raise first.

A projection of the same record `list/0` returns, kept for the callers that
predate the record.
""".
-spec get_alarms() -> [{id(), term()}].

get_alarms() ->
    gen_event:call(alarm_handler, ?MODULE, get_alarms).

-doc """
Active alarms, newest raise first.
""".
-spec list() -> [alarm()].

list() ->
    gen_event:call(alarm_handler, ?MODULE, list).

-doc """
The last #{?HISTORY_MAX} transitions on this node, newest first.
""".
-spec history() -> [event()].

history() ->
    gen_event:call(alarm_handler, ?MODULE, history).

-doc """
Whether any active alarm declares `affects_ready => true`.

Total: an unreachable manager or an absent handler reads as `false`, for the
reason given in the moduledoc.
""".
-spec affects_ready() -> boolean().

affects_ready() ->
    %% Deliberately does NOT create the array: creating it is a
    %% `persistent_term:put/2`, and the readiness probe must never be the
    %% thing that triggers one. An absent ref means no handler has run yet,
    %% which reads as not blocking.
    case persistent_term:get(?READY_KEY, undefined) of
        undefined -> false;
        Ref -> atomics:get(Ref, 1) == 1
    end.

%% =============================================================================
%% GEN_EVENT CALLBACKS
%% =============================================================================

init([]) ->
    {ok, update_ready(#state{})};
init({[], {alarm_handler, Alarms}}) ->
    %% gen_event swap from the OTP default handler, invoked with
    %% `{alarm_handler, swap}` so its `terminate(swap, Alarms)` hands its
    %% alarm list over (sasl/alarm_handler.erl). Adopt it: alarms raised
    %% BEFORE the swap — e.g. `bondy_db_main_unavailable`, set by the
    %% namespace catalogue while bondy_sup is still starting — must survive
    %% into `get_alarms/0` (asserted by `bondy_degraded_boot_SUITE`).
    %%
    %% The OTP handler records no timestamps, so an adopted alarm's
    %% `raised_at` is the ADOPTION time, not the original raise. Adoption is
    %% recorded in the ring as `raised` because that is when this handler
    %% learned of it.
    {ok, update_ready(lists:foldl(fun adopt/2, #state{}, Alarms))};
init({[], _}) ->
    %% A swap with nothing to adopt: the old handler was absent (gen_event
    %% hands `error`) — e.g. the watcher re-installing this handler after a
    %% crash, when the OTP default is no longer registered.
    {ok, update_ready(#state{})}.

handle_event({set_alarm, {Id, Desc}}, State) ->
    do_set(Id, Desc, #{}, State);
handle_event({set_alarm, {Id, Desc, Opts}}, State) when is_map(Opts) ->
    do_set(Id, Desc, Opts, State);
handle_event({set_alarm, Other}, State) ->
    %% A raise this handler cannot key. It is DROPPED rather than allowed to
    %% crash the manager — a `function_clause` here costs the node EVERY alarm
    %% it holds, and the raise that ends the alarm subsystem should not be a
    %% misspelled one — but it is LOGGED, because silently dropping it leaves a
    %% producer reporting a fault that appears nowhere at all, with no evidence
    %% it ever tried. That is the failure this whole subsystem exists to
    %% prevent, one level down.
    ?LOG_WARNING(#{
        description =>
            "Ignored an alarm whose shape this handler cannot key. Expected "
            "`{Id, Description}` or `{Id, Description, Options :: map()}`.",
        alarm => Other
    }),
    {ok, State};
handle_event({clear_alarm, AlarmId}, State) ->
    do_clear(AlarmId, State);
handle_event(_Event, State) ->
    {ok, State}.

handle_call(get_alarms, State) ->
    Projection = [
        {Id, Desc}
     || #{id := Id, description := Desc} <- sorted(State)
    ],
    {ok, Projection, State};
handle_call(list, State) ->
    {ok, sorted(State), State};
handle_call(history, #state{history = {_, L}} = State) ->
    {ok, L, State};
handle_call(affects_ready, State) ->
    %% The ORACLE, recomputed from the alarm map. `affects_ready/0` does not
    %% come through here — it reads the published boolean — so this is what
    %% that publication is checked against.
    {ok, blocking(State), State};
handle_call(_, State) ->
    {ok, {error, bad_query}, State}.

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    %% Crash, removal or swap-out: publish NOT blocking, which is what an
    %% absent handler has always answered (see the moduledoc — a handler that
    %% cannot be read holds no signal to preserve, and draining on it would
    %% flap the node). A swap back in re-derives from `init/1`.
    ok = publish_ready(false).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Raising an id that is already raised is a RESTATEMENT. It is a transition
%% only when the alarm's CONTENT changed; an identical restatement leaves both
%% the alarm map and the ring untouched, so a caller that restates per event
%% cannot evict the ring or flood the log.
do_set(Id, Desc, Opts, #state{alarms = Alarms} = State) ->
    Now = erlang:system_time(millisecond),
    New = new_alarm(Id, Desc, Opts, Now),

    case maps:find(Id, Alarms) of
        {ok, Old} ->
            case content(Old) =:= content(New) of
                true ->
                    {ok, State};
                false ->
                    %% `raised_at` and `onset_trace_id` both belong to the
                    %% CONDITION, not to the last report of it, so both
                    %% survive every restatement. See `preserve_onset/2`.
                    Merged = preserve_onset(Old, New),
                    ?LOG_WARNING(#{
                        description => "Alarm updated",
                        alarm_id => Id,
                        alarm_description => Desc,
                        severity => maps:get(severity, Merged)
                    }),
                    {ok, record(Merged, updated, Now, State)}
            end;
        error ->
            ?LOG_WARNING(#{
                description => "Alarm set",
                alarm_id => Id,
                alarm_description => Desc,
                severity => maps:get(severity, New)
            }),
            {ok, record(New, raised, Now, State)}
    end.

%% @private
%% Clearing an alarm that was never raised is a no-op, and several callers do
%% it unconditionally on recovery. Only a real transition is logged and
%% ringed — without this an operator sees alarms raised and never sees them
%% resolve.
do_clear(Id, #state{alarms = Alarms} = State) ->
    case maps:take(Id, Alarms) of
        error ->
            {ok, State};
        {Alarm, Rest} ->
            ?LOG_NOTICE(#{
                description => "Alarm cleared",
                alarm_id => Id
            }),
            Event = #{
                action => cleared,
                id => Id,
                severity => maps:get(severity, Alarm),
                at => erlang:system_time(millisecond)
            },
            %% The alarm as it was when it cleared. A bare id would tell a
            %% subscriber that something resolved without telling it how
            %% urgent the thing had been, which is what decides whether the
            %% "resolved" notice is worth waking anyone for.
            ok = emit(cleared, Alarm),
            {ok, push(Event, update_ready(State#state{alarms = Rest}))}
    end.

%% @private
%% The two shapes `handle_event/2` accepts, because the OTP default handler
%% stores whatever term was raised: producers that start before `bondy_app`
%% swaps this handler in (the namespace catalogue, the oplog applier) raise
%% into OTP's list, and a rich alarm adopted as `_Other` would silently lose
%% its severity, class and details on every boot where it fired early.
adopt({Id, Desc}, State) ->
    {ok, NewState} = do_set(Id, Desc, #{}, State),
    NewState;
adopt({Id, Desc, Opts}, State) when is_map(Opts) ->
    {ok, NewState} = do_set(Id, Desc, Opts, State),
    NewState;
adopt(Other, State) ->
    %% Anything that cannot be keyed is dropped rather than crashing the
    %% handler mid-swap — a swap that fails leaves the node with NO alarm
    %% handler at all. Logged for the reason `handle_event/2`'s own clause
    %% gives, and it matters more here: an alarm raised before the swap and
    %% dropped at it is lost on EVERY boot where the condition fires early,
    %% which is exactly when a boot-time fault would be raising one.
    ?LOG_WARNING(#{
        description =>
            "Dropped an alarm with an unrecognised shape while adopting the "
            "previous handler's alarms.",
        alarm => Other
    }),
    State.

%% @private
new_alarm(Id, Desc, Opts, Now) ->
    Declared = declared(Id),
    Base = #{
        id => Id,
        description => Desc,
        severity => severity(Opts, Declared),
        class => class(Opts, Declared),
        affects_ready => affects_ready(Opts, Declared),
        details => details(Opts),
        raised_at => Now,
        updated_at => Now
    },
    maps:merge(Base, optional(Opts)).

%% @private
%% The catalogue entry for this id, or an empty map for an id it does not
%% declare. Resolved at RAISE time rather than at read time so the record has
%% one severity and one class, and no consumer has to know whether a field was
%% defaulted. A pure list walk over nine entries — safe on the boot path, where
%% alarms are raised before most of the node exists.
declared(Id) ->
    case bondy_alarm_catalogue:lookup(Id) of
        {ok, Entry} -> Entry;
        error -> #{}
    end.

%% @private
%% Everything except the timestamps: two alarms with equal content are the
%% same statement about the world, however often it is repeated.
content(Alarm) ->
    maps:without([raised_at, updated_at, onset_trace_id], Alarm).

%% @private
%% `raised_at` and `onset_trace_id` both describe the occurrence that RAISED
%% the condition, so a restatement carries neither forward: the first survives,
%% and a later occurrence's trace is discarded rather than overwriting it.
%%
%% This is why `content/1` ignores `onset_trace_id`. Were it compared, a
%% producer restating with a fresh trace would make every restatement a
%% transition — flooding the history ring and the `bondy.alarm.*` topics, which
%% is exactly what `identical_restatement_records_no_history_test` and
%% `only_a_real_change_publishes_an_update` forbid.
preserve_onset(Old, New) ->
    Merged = New#{raised_at := maps:get(raised_at, Old)},
    case maps:find(onset_trace_id, Old) of
        {ok, TraceId} -> Merged#{onset_trace_id => TraceId};
        error -> maps:remove(onset_trace_id, Merged)
    end.

%% @private
%% Three sources, in order: an explicit and VALID option, then the catalogue
%% entry, then the constant. An invalid option falls through to the catalogue
%% rather than to the constant — a producer that misspells a severity should
%% get the declared one, not `major`.
severity(#{severity := S}, _) when S == warning; S == major; S == critical ->
    S;
severity(_, #{severity := S}) ->
    S;
severity(_, _) ->
    ?DEFAULT_SEVERITY.

%% @private
class(#{class := C}, _) when
    C == node; C == cluster; C == realm; C == integration
->
    C;
class(_, #{class := C}) ->
    C;
class(_, _) ->
    ?DEFAULT_CLASS.

%% @private
%% Default `false`: an alarm takes the node out of rotation only by saying so.
%% A producer that raises without an opinion is reporting a condition, not
%% asking for the node to be drained — and the catalogue, not the raise site,
%% is where that judgement is recorded.
affects_ready(#{affects_ready := B}, _) when is_boolean(B) ->
    B;
affects_ready(_, #{affects_ready := B}) ->
    B;
affects_ready(_, _) ->
    false.

%% @private
details(#{details := D}) when is_map(D) ->
    D;
details(_) ->
    #{}.

%% @private
%% `realm_uri` and `onset_trace_id` are absent rather than `undefined` when not
%% supplied, so `content/1` equality does not depend on which spelling a
%% producer used.
optional(Opts) ->
    maps:filter(
        fun
            (realm_uri, V) -> is_binary(V);
            (onset_trace_id, V) -> is_binary(V);
            (_, _) -> false
        end,
        Opts
    ).

%% @private
%% Whether any active alarm asks for the node to be drained. Pure, so the
%% published boolean and `handle_call(affects_ready, _)` cannot disagree about
%% what they mean. `lists:any/2` short-circuits on the first blocking alarm.
blocking(#state{alarms = Alarms}) ->
    lists:any(fun(#{affects_ready := B}) -> B end, maps:values(Alarms)).

%% @private
%% Publishes `blocking/1` for `affects_ready/0` to read. Called on every path
%% that changes the alarm map, so the two cannot drift.
update_ready(State) ->
    ok = publish_ready(blocking(State)),
    State.

%% @private
publish_ready(Bool) ->
    atomics:put(
        ready_ref(),
        1,
        case Bool of
            true -> 1;
            false -> 0
        end
    ).

%% @private
%% Get-or-create the one-element array. Only handler-side code calls this, and
%% the handler is a single process, so the create is not racing itself; the
%% `persistent_term:put/2` therefore happens at most once per node lifetime,
%% and a handler re-install reuses the existing ref rather than minting one.
ready_ref() ->
    case persistent_term:get(?READY_KEY, undefined) of
        undefined ->
            Ref = atomics:new(1, [{signed, false}]),
            ok = persistent_term:put(?READY_KEY, Ref),
            Ref;
        Ref ->
            Ref
    end.

%% @private
record(Alarm, Action, Now, #state{alarms = Alarms} = State) ->
    Event = #{
        action => Action,
        id => maps:get(id, Alarm),
        severity => maps:get(severity, Alarm),
        at => Now
    },
    ok = emit(Action, Alarm),
    push(
        Event,
        update_ready(State#state{alarms = Alarms#{maps:get(id, Alarm) => Alarm}})
    ).

%% @private
%% Hands a transition to `bondy_event_manager`, whose
%% `bondy_event_wamp_publisher` turns it into the corresponding
%% `bondy.alarm.*` WAMP topic. Emitted for the SAME three transitions the
%% ring records, so a subscriber and `history/0` agree: an identical
%% restatement is not a transition and produces no event.
%%
%% Addressed by PID, never by the registered name. `gen_event:notify/2` on an
%% unregistered atom raises `badarg` — it is a bare `M ! Cmd` with no catch
%% (stdlib-8.0.3 `gen_event.erl:1605`; probed 2026-08-30) — and a raise here
%% would crash THIS handler, which `bondy_event_handler_watcher` re-installs
%% with `[]`, discarding every active alarm while reporting one. Sending to a
%% pid cannot raise: a dead pid drops the message silently (same probe). So
%% resolving the name first removes the failure mode rather than catching it.
%%
%% The manager is absent exactly when nothing could consume the event —
%% before `bondy_app:setup_event_handlers/0` installs both handlers, and in
%% unit tests that drive this module directly. Pinned by
%% `transitions_do_not_need_an_event_manager_test`.
emit(Action, Alarm) ->
    case erlang:whereis(bondy_event_manager) of
        undefined ->
            ok;
        Pid ->
            gen_event:notify(Pid, {[bondy, alarm, Action], Alarm})
    end.

%% @private
%% Newest first. The length is carried so the common push is O(1); the trim
%% runs only once the ring is full and is bounded by ?HISTORY_MAX.
%%
%% The `seq` is stamped HERE, and this is the only place an event enters the
%% ring, so no transition can be missing one. It exists to make the ring
%% pageable: `bondy.alarm.history` walks the cluster node-at-a-time and resumes
%% from "the events of this node with a seq below the last one I sent". An
%% offset would shift under a concurrent push and repeat an event; a `seq`
%% cannot, because a new event always takes a HIGHER one and so falls outside a
%% page already being walked downwards.
%%
%% Per node and per handler incarnation, never a cluster-wide sequence: it is a
%% position in THIS ring, and a handler restart legitimately starts from a
%% re-detected present (see the moduledoc on the ring not being persisted).
push(Event0, #state{seq = Seq} = State0) ->
    Event = Event0#{seq => Seq},
    State = State0#state{seq = Seq + 1},
    case State#state.history of
        {N, L} when N < ?HISTORY_MAX ->
            State#state{history = {N + 1, [Event | L]}};
        {_, L} ->
            State#state{
                history =
                    {?HISTORY_MAX, lists:sublist([Event | L], ?HISTORY_MAX)}
            }
    end.

%% @private
%% Newest raise first, ties broken by id so the order is total and the same on
%% every call — a map's iteration order is not.
sorted(#state{alarms = Alarms}) ->
    lists:sort(
        fun(A, B) -> sort_key(A) >= sort_key(B) end,
        maps:values(Alarms)
    ).

%% @private
sort_key(#{raised_at := T, id := Id}) ->
    {T, Id}.
