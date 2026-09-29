%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_stdlib_sup).

-behaviour(supervisor).

-moduledoc """
Top-level supervisor of `bondy_stdlib`. Its one child is
`bondy_table_manager`, the process that owns ETS tables on behalf of
others (and is their heir), so a table outlives the process that uses it
and survives that process's restart.

The restart intensity is deliberately low: the manager holds every table
it was ever asked to own, and a restart of it deletes them all
(`bondy_table_manager:terminate/2`). It has no dependencies and no
side-effects of its own, so it should effectively never restart.
""".

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

-spec start_link() -> supervisor:startlink_ret().

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 2,
        period => 10
    },
    Children = [
        #{
            id => bondy_table_manager,
            start => {bondy_table_manager, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [bondy_table_manager]
        }
    ],
    {ok, {SupFlags, Children}}.
