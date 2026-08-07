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
    ok = enqueue_sweeps(),
    {noreply, State};
handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.

handle_info({timeout, Ref, scheduled_sweep}, #state{timer_ref = Ref} = State) ->
    ok = enqueue_sweeps(),
    {noreply, schedule(State#state{timer_ref = undefined})};
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
    case is_enabled() of
        true ->
            Ref = erlang:start_timer(next_interval(), self(), scheduled_sweep),
            State#state{timer_ref = Ref};
        false ->
            State#state{timer_ref = undefined}
    end.

%% @private
%% The configured interval minus a random slice of up to `?JITTER_RATIO` of it,
%% so nodes that scheduled together drift apart.
next_interval() ->
    Interval = bondy_config:get(
        [security, reclamation, interval], ?DEFAULT_INTERVAL
    ),
    Jitter = round(Interval * ?JITTER_RATIO),
    Interval - rand:uniform(max(1, Jitter)).

%% @private
is_enabled() ->
    bondy_config:get([security, reclamation, enabled], true).

%% @private
%% Each sweep is a separate job: one that fails must not prevent the others
%% from running, and `bondy_jobs` regulates them independently.
enqueue_sweeps() ->
    _ = [
        bondy_jobs:enqueue(fun() -> run(Name, MFA) end)
     || {Name, MFA} <- ?SWEEPS
    ],
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
