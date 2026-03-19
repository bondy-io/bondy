%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================


-module(bondy_oidc_provider_sup).
-moduledoc """
A `simple_one_for_one` supervisor for `oidcc_provider_configuration_worker`
processes.

Each worker caches and refreshes OIDC provider metadata (JWKS, endpoints) for
a specific (realm, provider) pair.
""".

-behaviour(supervisor).


%% API
-export([start_link/0]).
-export([start_child/1]).

%% SUPERVISOR CALLBACKS
-export([init/1]).



%% =============================================================================
%% API
%% =============================================================================



-doc false.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).


-doc """
Starts a new `oidcc_provider_configuration_worker` child.

`Args` is the argument list passed to
`oidcc_provider_configuration_worker:start_link/1`.
""".
-spec start_child(Args :: map()) -> supervisor:startchild_ret().

start_child(Args) when is_map(Args) ->
    supervisor:start_child(?MODULE, [Args]).



%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================



init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 5,
        period => 10,
        auto_shutdown => never
    },

    ChildSpec = #{
        id => oidcc_provider_configuration_worker,
        start => {oidcc_provider_configuration_worker, start_link, []},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [oidcc_provider_configuration_worker]
    },

    {ok, {SupFlags, [ChildSpec]}}.
