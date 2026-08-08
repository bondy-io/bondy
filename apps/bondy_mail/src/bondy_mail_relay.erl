%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_relay).

-moduledoc """
Owns one configured relay.

Holds the validated relay record -- including its resolved credential, which
lives here and nowhere else -- and reports the relay's health. It performs no
SMTP itself: delivery happens in `bondy_mail_worker`, so that a stalled relay
cannot block whatever is asking about it.

Registered under `{via, gproc, {n, l, {bondy_mail_relay, Name}}}`, so a relay
is addressed by name rather than by pid and survives a restart from the
caller's point of view.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("bondy_mail.hrl").

-record(state, {
    relay :: #bondy_mail_relay{},
    %% Traffic state. Separate from the alarm, which clears only after a
    %% success threshold so a flapping relay does not flap the page.
    %% `up` from the start, and there is no third state. A configured relay is
    %% usable until something says otherwise -- which is the same fail-open
    %% rule recovery follows -- and an `unknown` that nothing ever observes is
    %% a value that only shows up in a dashboard legend.
    status = up :: up | down,
    consec_failures = 0 :: non_neg_integer(),
    consec_successes = 0 :: non_neg_integer(),
    last_error :: optional(any())
}).

-type info() :: #{
    name := binary(),
    transport := plain | starttls | tls,
    status := up | down,
    from := optional(binary())
}.

-export_type([info/0]).

%% API
-export([config/1]).
-export([info/1]).
-export([name/1]).
-export([report/2]).
-export([start_link/1]).

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

-doc "Start a relay process for `Relay`.".
-spec start_link(Relay :: #bondy_mail_relay{}) -> {ok, pid()} | {error, any()}.

start_link(#bondy_mail_relay{name = Name} = Relay) ->
    gen_server:start_link(name(Name), ?MODULE, [Relay], []).

-doc "Return the `gproc` name under which the relay `Name` is registered.".
-spec name(Name :: binary()) -> {via, module(), any()}.

name(Name) when is_binary(Name) ->
    {via, gproc, {n, l, {?MODULE, Name}}}.

-doc """
Return the relay's configuration record.

Read from the caller's process: the record is immutable for the life of the
relay, so this does not go through the relay process and cannot be delayed by
one that is busy.
""".
-spec config(Name :: binary()) ->
    {ok, #bondy_mail_relay{}} | {error, no_such_relay}.

config(Name) when is_binary(Name) ->
    bondy_mail_config:relay(Name).

-doc """
Return what is safe to tell a caller about this relay.

Deliberately narrow: name, transport, status and default sender. Never the
host, the username or the credential.
""".
-spec info(Name :: binary()) -> {ok, info()} | {error, no_such_relay}.

info(Name) when is_binary(Name) ->
    try
        gen_server:call(name(Name), info, 5000)
    catch
        exit:{noproc, _} ->
            {error, no_such_relay};
        exit:{normal, _} ->
            {error, no_such_relay}
    end.

-doc """
Report the outcome of one delivery attempt.

A cast, and deliberately so: this is called from a worker that has just
finished with a relay, and making it wait for this process would put the health
bookkeeping on the delivery path it exists to describe. A lost report costs one
sample.

`Outcome` is `ok`, or the `nature` of the failure. **Only `transient` counts
against health.** A `permanent` failure -- a rejected recipient, an oversized
message, a refused credential -- is the relay behaving correctly, and marking
it down for one would raise a page about a caller's mistake.
""".
-spec report(Name :: binary(), Outcome :: ok | permanent | transient) -> ok.

report(Name, Outcome) when
    is_binary(Name) andalso
        (Outcome == ok orelse Outcome == permanent orelse Outcome == transient)
->
    try
        gen_server:cast(name(Name), {report, Outcome})
    catch
        %% The relay was reconfigured away while a worker was still draining
        %% its queue. There is nothing left to tell.
        exit:{noproc, _} -> ok
    end.

%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

-doc false.
init([#bondy_mail_relay{} = Relay]) ->
    %% Without this the supervisor's shutdown kills this process outright and
    %% `terminate/2` never runs -- so a relay removed from the configuration
    %% would leave its alarm raised forever, with nothing left that could ever
    %% clear it. A `terminate/2` that is never called looks exactly like one
    %% that works.
    _ = process_flag(trap_exit, true),
    Name = Relay#bondy_mail_relay.name,
    ?LOG_INFO(#{
        description => "Mail relay started",
        relay => Name,
        transport => Relay#bondy_mail_relay.transport
    }),
    %% Publish the gauge now, before any traffic. `bondy_prometheus_collector`
    %% skips a declared family with no rows, so a relay that has not been used
    %% yet would be absent from the exposition entirely -- and an operator
    %% looking at a freshly booted node would see an empty relay table rather
    %% than a healthy one.
    ok = bondy_mail_telemetry:relay_status(Name, up),
    {ok, #state{relay = Relay}}.

-doc false.
handle_call(info, _From, #state{relay = Relay} = State) ->
    Info = #{
        name => Relay#bondy_mail_relay.name,
        transport => Relay#bondy_mail_relay.transport,
        status => State#state.status,
        from => Relay#bondy_mail_relay.from
    },
    {reply, {ok, Info}, State};
handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {noreply, State}.

-doc false.
handle_cast({report, permanent}, State) ->
    %% Says nothing about the relay. See report/2.
    {noreply, State};
handle_cast({report, ok}, State) ->
    {noreply, succeed(State)};
handle_cast({report, transient}, State) ->
    {noreply, fail(State)};
handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.

-doc false.
handle_info(Info, State) ->
    ?LOG_DEBUG(#{
        reason => unsupported_event,
        event => Info
    }),
    {noreply, State}.

-doc false.
terminate(_Reason, #state{relay = Relay}) ->
    %% A relay that is being removed cannot be down: leaving the alarm set
    %% would leave an operator paging about something that no longer exists.
    _ =
        catch alarm_handler:clear_alarm(
            {mail_relay_down, Relay#bondy_mail_relay.name}
        ),
    ok.

-doc false.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Recovery is fail-open: the relay is `up` again on the first success, because
%% a relay that is merely flaky should not be described as down a moment longer
%% than it is. Clearing the ALARM is gated separately by
%% `health.success_threshold`, so a relay that alternates does not alternate the
%% page while traffic resumes immediately.
succeed(#state{status = up} = State0) ->
    State = State0#state{
        consec_successes = State0#state.consec_successes + 1,
        consec_failures = 0
    },
    ok = maybe_clear_alarm(State),
    State;
succeed(#state{relay = Relay} = State0) ->
    Name = Relay#bondy_mail_relay.name,
    State = State0#state{
        status = up,
        consec_successes = State0#state.consec_successes + 1,
        consec_failures = 0,
        last_error = undefined
    },
    ?LOG_INFO(#{description => "Mail relay is up", relay => Name}),
    ok = bondy_mail_telemetry:relay_status(Name, up),
    ok = maybe_clear_alarm(State),
    State.

%% @private
%% One transient failure is not a down relay -- a single timeout happens to
%% healthy infrastructure -- so the transition waits for
%% `health.failure_threshold` consecutive ones.
fail(#state{relay = Relay} = State0) ->
    Failures = State0#state.consec_failures + 1,
    State = State0#state{consec_failures = Failures, consec_successes = 0},
    Threshold = Relay#bondy_mail_relay.health_failure_threshold,

    case State#state.status =/= down andalso Failures >= Threshold of
        true ->
            Name = Relay#bondy_mail_relay.name,
            ?LOG_WARNING(#{
                description => "Mail relay is down",
                relay => Name,
                consecutive_failures => Failures
            }),
            ok = bondy_mail_telemetry:relay_status(Name, down),
            ok = set_alarm(Name, Failures),
            State#state{status = down};
        false ->
            State
    end.

%% @private
%% A `{Tag, Name}` alarm id, following the convention the rest of Bondy uses,
%% so `bondy_alarm_active{alarm_id}` carries the relay without a second
%% dimension. The description names the relay and how it failed -- never the
%% host, and never the credential.
set_alarm(Name, Failures) ->
    Desc = #{relay => Name, consecutive_failures => Failures},
    _ = catch alarm_handler:set_alarm({{mail_relay_down, Name}, Desc}),
    ok.

%% @private
%% Idempotent: clearing an alarm that is not set is a harmless no-op, so this
%% can be called on every success once the threshold is reached.
maybe_clear_alarm(#state{relay = Relay, consec_successes = Successes}) ->
    case Successes >= Relay#bondy_mail_relay.health_success_threshold of
        true ->
            _ =
                catch alarm_handler:clear_alarm(
                    {mail_relay_down, Relay#bondy_mail_relay.name}
                ),
            ok;
        false ->
            ok
    end.
