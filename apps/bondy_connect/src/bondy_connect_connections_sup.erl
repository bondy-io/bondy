%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_connections_sup).

-moduledoc """
Dynamic supervisor (`simple_one_for_one`) of per-connection supervisors
(`bondy_connect_conn_sup`), one child per connection. Children are transient,
so a user disconnect (normal) stays down while a crash is restarted.
""".

-behaviour(supervisor).

-export([start_link/0]).
-export([start_connection/1]).
-export([stop_connection/1]).
-export([init/1]).

-define(SERVER, ?MODULE).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-doc "Start a per-connection supervisor for a validated config.".
-spec start_connection(Config :: map()) -> {ok, pid()} | {error, term()}.
start_connection(Config) ->
    supervisor:start_child(?SERVER, [Config]).

-doc "Stop a per-connection supervisor.".
-spec stop_connection(pid()) -> ok | {error, term()}.
stop_connection(ConnSupPid) ->
    supervisor:terminate_child(?SERVER, ConnSupPid).

-spec init([]) ->
    {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 10,
        period => 10
    },
    ChildSpecs = [
        #{
            id => bondy_connect_conn_sup,
            start => {bondy_connect_conn_sup, start_link, []},
            restart => transient,
            shutdown => infinity,
            type => supervisor,
            modules => [bondy_connect_conn_sup]
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.
