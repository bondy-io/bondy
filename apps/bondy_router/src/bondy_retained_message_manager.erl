%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_retained_message_manager).
-moduledoc """
Implements eviction amongst other things.
""".
-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-record(state, {}).

%% The two retention ceilings, as alarm id HEADS. Each alarm's id is
%% `{Head, RealmUri}`: the counters the ceilings are compared against are per
%% realm (`get_counters_ref/1`), so the condition is per realm and a node-wide
%% id would let one realm's recovery clear another realm's alarm.
-define(COUNT_LIMIT, retained_messages_count_limit).
-define(MEMORY_LIMIT, retained_messages_memory_limit).

-export([counters/1]).
-export([incr_counters/3]).
-export([decr_counters/3]).
-export([default_ttl/0]).
-export([get/2]).
-export([match/1]).
-export([match/4]).
-export([match/5]).
-export([max_memory/0]).
-export([max_message_size/0]).
-export([max_messages/0]).
-export([put/4]).
-export([put/5]).
-export([reconcile_limit_alarms/0]).
-export([start_link/0]).
-export([take/2]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_info/2]).

-export([terminate/2]).
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).

%% =============================================================================
%% API
%% =============================================================================

-spec get(Realm :: uri(), Topic :: uri()) ->
    bondy_retained_message:t() | undefined.

get(Realm, Topic) ->
    bondy_retained_message:get(Realm, Topic).

-spec take(Realm :: uri(), Topic :: uri()) ->
    bondy_retained_message:t() | undefined.

take(Realm, Topic) ->
    Msg = bondy_retained_message:take(Realm, Topic),
    ok = maybe_decr_counters(Realm, Msg),
    Msg.

-spec match(bondy_retained_message:continuation()) ->
    {[bondy_retained_message:t()] | bondy_retained_message:continuation()}
    | bondy_retained_message:eot().

match(Cont) ->
    bondy_retained_message:match(Cont).

-spec match(
    Realm :: uri(),
    Topic :: uri(),
    SessionId :: id(),
    Strategy :: binary()
) ->
    {[bondy_retained_message:t()], bondy_retained_message:continuation()}
    | bondy_retained_message:eot().

match(Realm, Topic, SessionId, Strategy) ->
    bondy_retained_message:match(Realm, Topic, SessionId, Strategy).

-spec match(
    Realm :: uri(),
    Topic :: uri(),
    SessionId :: id(),
    Strategy :: binary(),
    Opts :: bondy_retained_message:scan_opts()
) ->
    {[bondy_retained_message:t()], bondy_retained_message:continuation()}
    | bondy_retained_message:eot().

match(Realm, Topic, SessionId, Strategy, Opts0) ->
    bondy_retained_message:match(Realm, Topic, SessionId, Strategy, Opts0).

-spec put(
    Realm :: uri(),
    Topic :: uri(),
    Event :: wamp_event(),
    MatchOpts :: bondy_retained_message:match_opts()
) ->
    ok.

put(Realm, Topic, Event, MatchOpts) ->
    put(Realm, Topic, Event, MatchOpts, default_ttl()).

-spec put(
    Realm :: uri(),
    Topic :: uri(),
    Event :: wamp_event(),
    MatchOpts :: bondy_retained_message:match_opts(),
    TTL :: non_neg_integer() | undefined
) -> ok.

put(Realm, Topic, Event, MatchOpts, undefined) ->
    put(Realm, Topic, Event, MatchOpts, default_ttl());
put(Realm, Topic, Event, MatchOpts, TTL) ->
    case bondy_retained_message:size(Event) =< max_message_size() of
        true ->
            case exceeded(Realm) of
                [] ->
                    try
                        bondy_retained_message:put(
                            Realm, Topic, Event, MatchOpts, TTL
                        )
                    catch
                        Class:Reason:Stacktrace ->
                            ?LOG_WARNING(#{
                                class => Class,
                                reason => Reason,
                                stacktrace => Stacktrace
                            }),
                            ok
                    end;
                [{Reason, _} | _] = Exceeded ->
                    %% Every ceiling that is over, not just the first: an
                    %% operator who raised `max_messages` while `max_memory`
                    %% was also over would otherwise see the alarm clear and
                    %% retention still refused.
                    ok = lists:foreach(
                        fun(E) -> raise(Realm, E, Event) end, Exceeded
                    ),
                    ?LOG_INFO(#{
                        description => "Cannot retain message",
                        reason => Reason,
                        realm_uri => Realm,
                        topic => Topic,
                        publication_id => Event#event.publication_id
                    }),
                    ok
            end;
        false ->
            ?LOG_INFO(#{
                description => "Cannot retain message",
                reason => max_size_limit,
                realm_uri => Realm,
                topic => Topic,
                publication_id => Event#event.publication_id
            }),
            ok
    end.

-doc """
The max size for an event message.
All events whose size exceeds this value will not be retained.
""".
max_message_size() ->
    bondy_config:get([wamp_message_retention, max_message_size]).

-doc """
Maximum space in memory used by retained messages.
Once the max has been reached no more events will be stored.
A value of 0 means no limit is enforced.
""".
max_memory() ->
    bondy_config:get([wamp_message_retention, max_memory]).

-doc """
Maximum number of messages that can be store in a Bondy node.
Once the max has been reached no more events will be stored.
A value of 0 means no limit is enforced.
""".
max_messages() ->
    bondy_config:get([wamp_message_retention, max_messages]).

-doc """
Default TTL for retained messages.
""".
default_ttl() ->
    bondy_config:get([wamp_message_retention, default_ttl]).

-spec counters(Realm :: uri()) -> #{messages => integer(), memory => integer()}.

counters(Realm) ->
    Ref = get_counters_ref(Realm),
    #{
        messages => counters:get(Ref, 1),
        memory => counters:get(Ref, 2)
    }.

incr_counters(Realm, N, Size) ->
    Ref = get_counters_ref(Realm),
    ok = counters:add(Ref, 1, N),
    counters:add(Ref, 2, Size).

decr_counters(Realm, N, Size) ->
    Ref = get_counters_ref(Realm),
    ok = counters:sub(Ref, 1, N),
    counters:sub(Ref, 2, Size).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

init([]) ->
    %% Per-realm count / memory counters are maintained inline at the local
    %% write sites (`bondy_retained_message:put` / `take` / eviction). Syncing
    %% the counters for remotely-replicated changes (which arrive as anti-entropy
    %% merges, never as local writes) needs a remote-counter reactor that is
    %% deferred until bondy_db anti-entropy reconciles the counters.
    ok = init_evictor(),

    {ok, #state{}}.

handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State}.

handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.

handle_info(Info, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Info
    }),
    {noreply, State}.

terminate(normal, _State) ->
    ok;
terminate(shutdown, _State) ->
    ok;
terminate({shutdown, _}, _State) ->
    ok;
terminate(_Reason, _State) ->
    %% TODO publish metaevent
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% The retention ceilings evaluated against one realm's counters, as
%% `[{AlarmHead, Limit}]` — empty when the realm is within both.
%%
%% This is the ONE definition of the condition. `put/5` raises from it and
%% `reconcile_limit_alarms/0` clears from it, so the alarm cannot state that a
%% realm is over its ceiling while the write path is retaining its messages.
%%
%% A limit of `0` means no limit, as `max_memory/0`'s doc says. It is SKIPPED
%% rather than compared against: `Val > 0` reads every non-empty realm as over
%% its ceiling, which is the opposite of what the key promises. Pinned by
%% `bondy_retained_message_SUITE:a_zero_memory_limit_means_no_limit`.
%% `wamp.message_retention.max_messages` is `pos_integer`-validated in
%% `schema/bondy.schema` and cannot reach 0 through configuration; the guard
%% covers both rather than only the key that can.
exceeded(Realm) ->
    #{messages := N, memory := Mem} = counters(Realm),
    [
        {Head, Limit}
     || {Head, Val, Limit} <- [
            {?COUNT_LIMIT, N, max_messages()},
            {?MEMORY_LIMIT, Mem, max_memory()}
        ],
        Limit > 0,
        Val > Limit
    ].

%% @private
%% One literal id per ceiling rather than one function taking the head as an
%% argument: `bondy_alarm_catalogue_test` reads which alarm each site raises
%% out of the abstract code, and an id assembled from a variable head reads as
%% `{'_', '_'}` — which is not the pattern the catalogue declares.
%%
%% `details` carries the effective ceiling and NOTHING that changes per
%% publication. `bondy_alarm_handler:content/1` compares `details` to decide
%% whether a restatement is a transition, so a live count here would make every
%% publication over the ceiling an `updated` event and evict the history ring —
%% the failure `a_later_publication_does_not_relabel_the_alarm` guards.
%%
%% The onset trace is the publication that first tripped the ceiling.
%% `bondy_broker:make_event_details/3` passes `?WAMP_TRACE_ATTRS` through from
%% the PUBLISH options verbatim (pinned by
%% `bondy_trace_context_SUITE:same_node_publish_trace_context`), so it is
%% already in the EVENT and nothing has to be threaded here. `undefined` is
%% dropped by `bondy_alarm_handler:optional/1`, which keeps `onset_trace_id`
%% only when it is a binary, so an untraced publication leaves the field ABSENT
%% rather than carrying a minted id that would correlate with nothing —
%% `an_untraced_publication_leaves_the_alarm_uncorrelated` is the falsifier.
raise(Realm, {?COUNT_LIMIT, Limit}, Event) ->
    bondy_alarm_handler:set_alarm(
        {
            {?COUNT_LIMIT, Realm},
            <<"The number of retained messages has reached the system limit.">>
        },
        #{
            realm_uri => Realm,
            details => #{limit => Limit},
            onset_trace_id => onset_trace_id(Event)
        }
    );
raise(Realm, {?MEMORY_LIMIT, Limit}, Event) ->
    bondy_alarm_handler:set_alarm(
        {
            {?MEMORY_LIMIT, Realm},
            <<"The memory allocation for retained messages has reached the system limit.">>
        },
        #{
            realm_uri => Realm,
            details => #{limit => Limit},
            onset_trace_id => onset_trace_id(Event)
        }
    ).

%% @private
onset_trace_id(#event{details = Details}) when is_map(Details) ->
    bondy_telemetry:trace_id_of(Details);
onset_trace_id(_) ->
    undefined.

-doc """
Clear the retention-limit alarms of every realm that is no longer over its
ceiling.

Run by the eviction cycle once a minute; exported so a caller — a test, or an
operator at a remote shell — can force the re-evaluation rather than wait for
the next cycle. It only ever CLEARS: raising is the write path's job, because
only a refused publication proves the ceiling is being hit.
""".
-spec reconcile_limit_alarms() -> ok.

%% Re-evaluate the ceilings for every realm that currently holds a retention
%% alarm, and clear the ones whose condition has become false.
%%
%% The alarm handler is already the registry of what is believed true, so this
%% needs no second record of which realms are alarmed — and the walk is over
%% the raised alarms, which is empty on a healthy node.
%%
%% Clearing happens HERE, on the eviction cycle, rather than on the
%% counter-decrement path: a decrement is per message on both `take/2` and the
%% eviction sweep, so a `gen_event` cast per removed message would put the
%% shared `alarm_handler` manager in front of retention. The cost is latency —
%% a realm that drops back under its ceiling clears on the next cycle rather
%% than at the moment it does, which is the behaviour the operator
%% documentation already describes for every producer that probes on an
%% interval.
reconcile_limit_alarms() ->
    lists:foreach(fun reconcile_realm/1, alarmed_realms()).

%% @private
alarmed_realms() ->
    lists:usort([
        Realm
     || #{id := {Head, Realm}} <- bondy_alarm_handler:list(),
        Head == ?COUNT_LIMIT orelse Head == ?MEMORY_LIMIT
    ]).

%% @private
reconcile_realm(Realm) ->
    Exceeded = exceeded(Realm),
    ok = clear_count(Realm, lists:keymember(?COUNT_LIMIT, 1, Exceeded)),
    clear_memory(Realm, lists:keymember(?MEMORY_LIMIT, 1, Exceeded)).

%% @private
%% Literal ids, for the same reason `raise/3` has one clause per ceiling.
clear_count(_Realm, true) ->
    ok;
clear_count(Realm, false) ->
    alarm_handler:clear_alarm({?COUNT_LIMIT, Realm}).

%% @private
clear_memory(_Realm, true) ->
    ok;
clear_memory(Realm, false) ->
    alarm_handler:clear_alarm({?MEMORY_LIMIT, Realm}).

%% @private
init_evictor() ->
    Decr = fun(Realm, Msg) ->
        decr_counters(Realm, 1, bondy_retained_message:size(Msg))
    end,
    %% A `jobs` producer that returns is restarted IMMEDIATELY, and one that
    %% crashes never reaches the sleep below — so an eviction pass that raises
    %% spins as fast as the scheduler can respawn it. That is not theoretical:
    %% when the durable `main` DB fails to open, the catalogue boots with main
    %% idle (see `bondy_namespace_catalog:open_main_into/1`) and
    %% `bondy_retained_message:table/0` raises `retained_messages_not_provisioned`
    %% on every pass, producing hundreds of crashed processes per millisecond
    %% until the node's supervision tree gives out. Catch, log and sleep: a
    %% cycle that cannot run is a cycle to skip, not a reason to melt the node.
    Fun = fun() ->
        try bondy_retained_message:evict_expired('_', Decr) of
            N when N > 0 ->
                ?LOG_INFO(#{
                    description => "Evicted retained messages",
                    count => N
                });
            _ ->
                ok
        catch
            Class:Reason:Stacktrace ->
                ?LOG_ERROR(#{
                    description =>
                        "Error while evicting expired retained messages; "
                        "skipping this cycle",
                    class => Class,
                    reason => Reason,
                    stacktrace => Stacktrace
                })
        end,
        %% AFTER the sweep, so the counters it decremented are the ones the
        %% ceilings are re-evaluated against. Guarded separately for the reason
        %% above: a reconcile that raises must skip its cycle, not spin the
        %% producer.
        try
            reconcile_limit_alarms()
        catch
            RClass:RReason:RStacktrace ->
                ?LOG_ERROR(#{
                    description =>
                        "Error while reconciling retention limit alarms; "
                        "skipping this cycle",
                    class => RClass,
                    reason => RReason,
                    stacktrace => RStacktrace
                })
        end,
        %% We sleep for 60 secs (jobs standard min rate is 1/sec)
        timer:sleep(timer:seconds(60))
    end,

    ok = jobs:add_queue(bondy_retained_message_eviction, [
        {producer, Fun},
        {regulators, [
            {counter, [
                {limit, 1},
                {modifiers, [
                    {cpu, 10},
                    {memory, 10}
                ]}
            ]}
        ]}
    ]),

    ?LOG_NOTICE(#{description => "Retained message evictor initialised"}),
    ok.

%% @private
maybe_decr_counters(Realm, Msg) when is_tuple(Msg) ->
    decr_counters(Realm, 1, bondy_retained_message:size(Msg));
maybe_decr_counters(_, _) ->
    ok.

%% @private
get_counters_ref(Realm) ->
    case persistent_term:get({?MODULE, Realm, counters}, undefined) of
        undefined ->
            Ref = counters:new(2, [write_concurrency]),
            ok = persistent_term:put({?MODULE, Realm, counters}, Ref),
            Ref;
        Ref ->
            Ref
    end.
