%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_worker_sup).

-moduledoc """
Supervises one relay's pool of `bondy_mail_worker` processes.

`one_for_one`: a worker that dies takes its queued messages with it, but the
others keep delivering. That is the right trade for mail, which is not durable
by design -- the alternative, restarting the whole pool, would lose every
worker's queue rather than one.
""".

-behaviour(supervisor).

-include("bondy_mail.hrl").

%% API
-export([start_link/1]).

%% SUPERVISOR CALLBACKS
-export([init/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc "Start the worker supervisor for `Relay`.".
-spec start_link(Relay :: #bondy_mail_relay{}) -> {ok, pid()} | {error, any()}.

start_link(#bondy_mail_relay{name = Name} = Relay) ->
    supervisor:start_link(name(Name), ?MODULE, [Relay]).

%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================

-doc false.
init([#bondy_mail_relay{} = Relay]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },
    Children = [
        child_spec(Relay, Index)
     || Index <- lists:seq(1, Relay#bondy_mail_relay.pool_size)
    ],
    {ok, {SupFlags, Children}}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Where this supervisor is registered.
name(Name) when is_binary(Name) ->
    {via, gproc, {n, l, {?MODULE, Name}}}.

%% @private
child_spec(Relay, Index) ->
    #{
        id => Index,
        start => {bondy_mail_worker, start_link, [Relay, Index]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [bondy_mail_worker]
    }.
