%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_handler_sup).

-moduledoc """
Per-connection `simple_one_for_one` supervisor of isolated handler workers
(`bondy_connect_handler`) — one short-lived worker per callee `INVOCATION` and
per subscriber `EVENT`.

Workers are `temporary` (a finished or crashed worker is never restarted by the
supervisor — the connection observes completion/death via its own monitor) and
linked to this supervisor, so a crashing user fun is contained here and cannot
reach the connection.

`start_worker/2` is the connection's entry point; it returns the worker pid so
the connection can `erlang:monitor/2` it.
""".

-behaviour(supervisor).

-export([start_link/0]).
-export([start_worker/2]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link(?MODULE, []).

-doc "Start a worker for `Job` under `SupPid`. Returns the worker pid.".
-spec start_worker(pid(), map()) -> {ok, pid()} | {error, term()}.
start_worker(SupPid, Job) when is_map(Job) ->
    supervisor:start_child(SupPid, [Job]).

-spec init([]) ->
    {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 100,
        period => 1
    },
    ChildSpec = #{
        id => bondy_connect_handler,
        start => {bondy_connect_handler, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [bondy_connect_handler]
    },
    {ok, {SupFlags, [ChildSpec]}}.
