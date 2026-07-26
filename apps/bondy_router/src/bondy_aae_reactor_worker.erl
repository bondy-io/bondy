%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_aae_reactor_worker).
-moduledoc """
One shard of the AAE merge-reaction pool.

`bondy_aae_reactor` is the sole subscriber to the reacted-on bondy_db tables; it
receives every remote-merge event and, rather than running the reaction inline
(which serialised the whole node's anti-entropy side-effects through one
process), hashes the cell `Key` to a worker in the `?AAE_REACTOR_POOL` and casts
the reaction here. Same `Key` always hashes to the same worker, so a cell's
`set` and later `clear` stay ordered; distinct keys run concurrently across the
pool.

The worker is a thin executor: it forwards each cast to
`bondy_aae_reactor:apply_reaction/4` (where the reaction logic lives) inside a
`try` so a single malformed event cannot take the worker — and its queued
backlog — down. Reactions are best-effort AP: a dropped one is re-derived on the
next anti-entropy exchange.
""".
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("bondy.hrl").

-record(state, {
    index :: non_neg_integer()
}).

%% API
-export([start_link/1]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link(Index :: non_neg_integer()) ->
    {ok, pid()} | {error, term()}.

start_link(Index) ->
    gen_server:start_link(?MODULE, [Index], []).

%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

init([Index]) ->
    %% Register this worker under its pool name so the reactor can address it by
    %% `gproc_pool:pick_worker/2`.
    WorkerName = {?MODULE, Index},
    true = gproc_pool:connect_worker(?AAE_REACTOR_POOL, WorkerName),
    {ok, #state{index = Index}}.

handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State}.

handle_cast({react, Sub, Key, Op, Old}, State) ->
    ok = safe_react(Sub, Key, Op, Old),
    {noreply, State};
handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.

handle_info(Info, State) ->
    ?LOG_DEBUG(#{
        reason => unexpected_event,
        event => Info
    }),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Run one reaction without ever raising — a malformed peer event must not take
%% the worker (and its queued backlog) down.
safe_react(Sub, Key, Op, Old) ->
    try
        _ = bondy_aae_reactor:apply_reaction(Sub, Key, Op, Old),
        ok
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "AAE merge reaction failed",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace,
                key => Key
            }),
            ok
    end.
