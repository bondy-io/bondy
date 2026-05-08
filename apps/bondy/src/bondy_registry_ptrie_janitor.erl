%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_registry_ptrie_janitor).

-include_lib("kernel/include/logger.hrl").

-moduledoc """
Periodic QSBR reclamation for a `bondy_registry_ptrie` handle.

This gen_server drives `bondy_registry_ptrie:reclaim/1` on a fixed cadence.
It runs at `low` priority and `hibernate`s between ticks so it never steals
scheduler time from the hot path.

One janitor per ptrie handle. The caller manages the lifecycle: in
production, `bondy_registry_partition` spawns one janitor per ptrie handle
in the store, linked, and respawns it on crash; in tests, suites use
`start_link/2` and `stop/1` directly.

The janitor does not trap exits — when its starter dies the link signal
terminates it cleanly (the ptrie's ETS tables die with the starter, so a
last-pass sweep would have nothing to reclaim).
""".

-behaviour(gen_server).


%% =============================================================================
%% MACROS AND RECORDS
%% =============================================================================

-define(DEFAULT_PERIOD_MS, 100).


-record(state, {
    handle              ::  bondy_registry_ptrie:handle(),
    period_ms           ::  pos_integer(),
    timer               ::  optional(reference()),
    total_reclaimed = 0 ::  non_neg_integer(),
    last_reclaimed  = 0 ::  non_neg_integer()
}).


%% =============================================================================
%% TYPES
%% =============================================================================

-type optional(T)   ::  T | undefined.
-type opts()        ::  #{
                            period_ms  => pos_integer(),
                            name       => atom()
                        }.

-export_type([opts/0]).


%% =============================================================================
%% EXPORTS
%% =============================================================================

%% API
-export([start_link/2]).
-export([stop/1]).
-export([sweep/1]).
-export([stats/1]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).


%% =============================================================================
%% API
%% =============================================================================


-doc """
Start a janitor for the given handle. Options:

  - `period_ms` (default `100`) — sweep interval.
  - `name`      — optional registered name.
""".
-spec start_link(
    Handle :: bondy_registry_ptrie:handle(),
    Opts   :: opts()
) -> {ok, pid()} | {error, term()}.

start_link(Handle, Opts) when is_map(Opts) ->
    case maps:get(name, Opts, undefined) of
        undefined ->
            gen_server:start_link(?MODULE, {Handle, Opts}, []);
        Name when is_atom(Name) ->
            gen_server:start_link({local, Name}, ?MODULE, {Handle, Opts}, [])
    end.


-doc """
Stop the janitor.
""".
-spec stop(Pid :: pid()) -> ok.

stop(Pid) ->
    gen_server:stop(Pid, normal, 5000).


-doc """
Trigger an immediate synchronous sweep. Returns the number of nodes
reclaimed. Intended for tests and operations tooling; the scheduled sweeps
handle normal operation.
""".
-spec sweep(Pid :: pid()) -> non_neg_integer().

sweep(Pid) ->
    gen_server:call(Pid, sweep, 30_000).


-doc """
Return accumulated statistics.
""".
-spec stats(Pid :: pid()) -> #{
    total_reclaimed := non_neg_integer(),
    last_reclaimed  := non_neg_integer(),
    period_ms       := pos_integer()
}.

stats(Pid) ->
    gen_server:call(Pid, stats, 5_000).


%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================


init({Handle, Opts}) ->
    process_flag(priority, low),
    Period = maps:get(period_ms, Opts, ?DEFAULT_PERIOD_MS),
    State = schedule(#state{
        handle = Handle,
        period_ms = Period
    }),
    {ok, State}.


handle_call(sweep, _From, S0) ->
    S1 = cancel_timer(S0),
    {Reclaimed, S2} = do_sweep(S1),
    S3 = schedule(S2),
    {reply, Reclaimed, S3};

handle_call(stats, _From, S) ->
    Reply = #{
        total_reclaimed => S#state.total_reclaimed,
        last_reclaimed  => S#state.last_reclaimed,
        period_ms       => S#state.period_ms
    },
    {reply, Reply, S};

handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.


handle_cast(_Msg, S) ->
    {noreply, S}.


handle_info({tick, Ref}, S = #state{timer = Ref}) ->
    {_, S1} = do_sweep(S),
    S2 = schedule(S1),
    {noreply, S2, hibernate};

handle_info({tick, _Stale}, S) ->
    %% Late tick from a cancelled timer; ignore.
    {noreply, S};

handle_info(_Msg, S) ->
    {noreply, S}.


terminate(_Reason, _S) ->
    ok.


%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
do_sweep(S) ->
    Reclaimed =
        try
            bondy_registry_ptrie:reclaim(S#state.handle)
        catch
            C:E:ST ->
                ?LOG_WARNING(#{
                    description => "ptrie janitor sweep raised",
                    class => C, reason => E, stacktrace => ST
                }),
                0
        end,
    S1 = S#state{
        last_reclaimed = Reclaimed,
        total_reclaimed = S#state.total_reclaimed + Reclaimed
    },
    {Reclaimed, S1}.


%% @private
schedule(S = #state{period_ms = Period}) ->
    Ref = erlang:make_ref(),
    _ = erlang:send_after(Period, self(), {tick, Ref}),
    S#state{timer = Ref}.


%% @private
cancel_timer(S = #state{timer = undefined}) ->
    S;
cancel_timer(S = #state{timer = Ref}) ->
    %% We use `make_ref` rather than the timer reference itself to tag
    %% ticks. Cancelling here means flushing any already-delivered tick
    %% from the mailbox (`handle_info({tick, _Stale}, S)` is the late-tick
    %% sink).
    S#state{timer = Ref}.
