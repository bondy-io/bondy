%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_regulator_sup).
-moduledoc """
Top supervisor for the `bondy_regulator` application.
""".

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_all,
        intensity => 5,
        period => 10
    },
    ChildSpecs = [
        #{
            id => bondy_regulator_rate_limit,
            start => {bondy_regulator_rate_limit, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [bondy_regulator_rate_limit]
        },
        %% Keyed + GC'd layer over the buckets above (owns its registry ETS).
        %% Started after the bucket store it depends on (one_for_all order).
        #{
            id => bondy_rate_limiter,
            start => {bondy_rate_limiter, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [bondy_rate_limiter]
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions
