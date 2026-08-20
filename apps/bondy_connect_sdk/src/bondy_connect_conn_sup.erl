%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_conn_sup).

-moduledoc """
Per-connection supervisor — the unit of fate-sharing (`one_for_all`): the
connection process and its handler-worker supervisor live and die together. If
the connection dies, in-flight handlers are torn down and rebuilt cleanly; if
the handler supervisor dies, the connection is restarted so the plumbing stays
consistent.

`handler_sup` is started **before** the connection so the connection can locate
it. Transient: a user disconnect (normal stop) stays down; a crash is restarted.
""".

-behaviour(supervisor).

-export([start_link/1]).
-export([connection/1]).
-export([handler_sup/1]).
-export([init/1]).

-spec start_link(Config :: map()) -> supervisor:startlink_ret().
start_link(Config) ->
    supervisor:start_link(?MODULE, [Config]).

-doc "The connection (gen_statem) pid under this supervisor.".
-spec connection(pid()) -> pid() | undefined.
connection(SupPid) ->
    child_pid(SupPid, connection).

-doc "The handler-worker supervisor pid under this supervisor.".
-spec handler_sup(pid()) -> pid() | undefined.
handler_sup(SupPid) ->
    child_pid(SupPid, handler_sup).

-spec init([map()]) ->
    {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([Config]) ->
    SupFlags = #{
        strategy => one_for_all,
        intensity => 5,
        period => 10
    },
    ChildSpecs = [
        #{
            id => handler_sup,
            start => {bondy_connect_handler_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [bondy_connect_handler_sup]
        },
        #{
            id => connection,
            start => {bondy_connect_connection, start_link, [Config, self()]},
            restart => transient,
            shutdown => 5000,
            type => worker,
            modules => [bondy_connect_connection]
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
child_pid(SupPid, Id) ->
    case lists:keyfind(Id, 1, supervisor:which_children(SupPid)) of
        {Id, Pid, _Type, _Mods} when is_pid(Pid) -> Pid;
        _ -> undefined
    end.
