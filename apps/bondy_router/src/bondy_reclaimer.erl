%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_reclaimer).
-moduledoc """
A `m:gen_server` that periodically reclaims storage holding state that can no
longer be used — expired OAuth2 tokens and the like.

This is the *scheduler* only. It owns no reclamation logic: each sweep is a
function on the module that owns the data, run through `bondy_jobs` so it is
load-regulated alongside every other background job rather than competing with
request traffic from a private process.

## Why there is no leader

Each sweep partitions its own work by `bondy:is_owner/1`, so every node reclaims
only the realms it owns under Rendezvous hashing and no election, quorum or
coordination is involved. That is not merely cheaper than a leader — it is what
makes the sweeps *correct*, because it leaves exactly one writer per realm (see
`bondy_oauth_token:cleanup/0`).

The cost is that during a membership change two nodes may briefly claim the same
realm, or neither. Both are tolerable precisely because a sweep is idempotent
and best-effort: running twice reclaims the same cells, and skipping a round
leaves the work for the next one. Nothing irreversible may be scheduled here.

## Interval and jitter

Sweeps are cold — nothing waits on them — so the interval is long by default. It
is jittered because every node schedules independently from the same configured
value: without jitter a cluster restarted together would sweep in lockstep
forever, concentrating scan load into the same instant on every node.

One exception to the long interval: a round `bondy_jobs` refuses outright —
because its queue is full — is logged and retried in minutes rather than hours.
The queue is fullest under load, which is when there is most to reclaim, so
letting a shed round wait for the next scheduled one is the wrong way round. The
retry is bounded by the configured interval, so a short interval never gets a
slower retry than a success.
""".
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("bondy.hrl").

%% The reclamation sweeps, in the order they run. `Name` is what appears in the
%% logs; `MFA` is enqueued on `bondy_jobs`.
-define(SWEEPS, [
    {oauth_tokens, {bondy_oauth_token, cleanup, []}},
    {tickets, {bondy_ticket, cleanup, []}}
]).

-define(DEFAULT_INTERVAL, timer:hours(6)).

%% How soon a round comes back when the job queue refused it. Short, because
%% the condition is transient by nature and the work is waiting; not
%% configurable, because it is a recovery detail rather than a policy an
%% operator has a view on. See delay/1 for the upper bound.
-define(RETRY_INTERVAL, timer:minutes(5)).

%% The fraction of the interval by which each scheduled sweep is randomly
%% brought forward, so independently-scheduling nodes drift apart instead of
%% converging on the same instant.
-define(JITTER_RATIO, 0.25).

-record(state, {
    timer_ref :: optional(reference())
}).

%% API
-export([start_link/0]).
-export([sweep/0]).

%% GEN_SERVER CALLBACKS
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([init/1]).
-export([terminate/2]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Starts the reclamation scheduler.
""".
-spec start_link() -> {ok, pid()} | {error, any()}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Runs every sweep now, out of band, without disturbing the schedule.

Intended for operators and tests. Asynchronous: the sweeps are enqueued on
`bondy_jobs` exactly as a scheduled round would be, so this exercises the same
path rather than a shortcut around it.
""".
-spec sweep() -> ok.

sweep() ->
    gen_server:cast(?MODULE, sweep).

%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

init([]) ->
    %% No sweep at boot: a node that has just joined has not yet converged on
    %% membership, so its ownership view is at its least trustworthy exactly
    %% when it starts.
    {ok, schedule(#state{})}.

handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State}.

handle_cast(sweep, State) ->
    %% Reported but not rescheduled. This entry point is documented as running
    %% out of band "without disturbing the schedule", and bringing the next
    %% scheduled round forward because an ad-hoc one was shed would disturb it.
    ok = log_shed(enqueue_sweeps()),
    {noreply, State};
handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.

handle_info({timeout, Ref, scheduled_sweep}, #state{timer_ref = Ref} = State) ->
    Shed = enqueue_sweeps(),
    ok = log_shed(Shed),
    {noreply, schedule(Shed, State#state{timer_ref = undefined})};
handle_info({timeout, _StaleRef, scheduled_sweep}, State) ->
    %% A timer cancelled by a reschedule that fired anyway.
    {noreply, State};
handle_info(Info, State) ->
    ?LOG_DEBUG(#{
        reason => unexpected_event,
        event => Info
    }),
    {noreply, State}.

terminate(_Reason, #state{timer_ref = Ref}) when is_reference(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok;
terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
schedule(State) ->
    schedule([], State).

%% @private
%% A round that enqueued cleanly waits the configured interval. A round that
%% was shed comes back sooner, because waiting six hours after noticing that
%% nothing was reclaimed would make noticing pointless.
%%
%% Repeating a round in which only some sweeps were shed is safe, and the
%% moduledoc already says why: a sweep is idempotent and best-effort, so
%% running one twice re-scans and reclaims the same cells.
schedule(Shed, State) ->
    case is_enabled() of
        true ->
            Ref = erlang:start_timer(delay(Shed), self(), scheduled_sweep),
            State#state{timer_ref = Ref};
        false ->
            State#state{timer_ref = undefined}
    end.

%% @private
delay([]) ->
    next_interval();
delay(_Shed) ->
    %% Never longer than a clean round would wait. An operator who configured a
    %% short interval must not be given a slower retry than a success, which is
    %% what a fixed constant alone would do.
    min(jittered(?RETRY_INTERVAL), next_interval()).

%% @private
next_interval() ->
    jittered(
        bondy_config:get([security, reclamation, interval], ?DEFAULT_INTERVAL)
    ).

%% @private
%% The interval minus a random slice of up to `?JITTER_RATIO` of it, so nodes
%% that scheduled together drift apart. Applied to the retry interval too, and
%% for the same reason: a cluster whose job queues filled at the same moment
%% must not then retry in lockstep.
jittered(Interval) ->
    Jitter = round(Interval * ?JITTER_RATIO),
    Interval - rand:uniform(max(1, Jitter)).

%% @private
is_enabled() ->
    bondy_config:get([security, reclamation, enabled], true).

%% @private
%% Each sweep is a separate job: one that fails must not prevent the others
%% from running, and `bondy_jobs` regulates them independently.
%%
%% Answers the sweeps that could not be enqueued at all, which is not the same
%% as a sweep that ran and failed -- `run/2` handles that. A full job queue is
%% the expected reason, and discarding it (as this used to) is worse than it
%% looks: the queue is fullest under load, which is exactly when there is most
%% to reclaim, and the next round is six hours away.
enqueue_sweeps() ->
    lists:filtermap(
        fun({Name, MFA}) ->
            case bondy_jobs:enqueue(fun() -> run(Name, MFA) end) of
                ok -> false;
                {error, Reason} -> {true, {Name, Reason}}
            end
        end,
        ?SWEEPS
    ).

%% @private
%% Once per round rather than once per sweep, and never rate-limited: a round
%% happens a handful of times a day, so there is nothing here to throttle and a
%% warning an operator can trust to always appear is worth more than one that
%% might have been suppressed.
log_shed([]) ->
    ok;
log_shed(Shed) ->
    ?LOG_WARNING(#{
        description =>
            "Storage reclamation sweeps could not be enqueued and did not "
            "run. The job queue is full.",
        sweeps => [Name || {Name, _} <- Shed],
        reasons => lists:usort([Reason || {_, Reason} <- Shed])
    }),
    ok.

%% @private
run(Name, {M, F, A}) ->
    Start = erlang:monotonic_time(millisecond),

    try apply(M, F, A) of
        Stats ->
            ?LOG_INFO(#{
                description => "Storage reclamation sweep finished",
                sweep => Name,
                duration_ms => erlang:monotonic_time(millisecond) - Start,
                stats => Stats
            })
    catch
        Class:Reason:Stacktrace ->
            %% Logged and swallowed: the job pool must not be told a background
            %% sweep is a fault, and the next round retries anyway.
            ?LOG_ERROR(#{
                description => "Storage reclamation sweep failed",
                sweep => Name,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            })
    end,
    ok.
