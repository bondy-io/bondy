%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_bridge_relay_client_sup).

-behaviour(supervisor).

-include_lib("kernel/include/logger.hrl").

-define(CLIENT(Id, Args, Restart, Timeout), #{
    id => Id,
    start => {bondy_bridge_relay_client, start_link, Args},
    restart => Restart,
    shutdown => Timeout,
    type => worker,
    modules => [bondy_bridge_relay_client]
}).

%% API
-export([start_link/0]).
-export([start_child/1]).
-export([delete_child/1]).
-export([terminate_child/1]).


%% SUPERVISOR CALLBACKS
-export([init/1]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start_child(bondy_bridge_relay:t()) -> {ok, pid()} | {error, any()}.

start_child(Bridge) ->
    Id = maps:get(name, Bridge),
    %% We use a permanent restart as we offer an API to stop and remove
    %% children in bondy_bridge_relay_manager and we want to avoid an
    %% gen_server error log on termination.
    ChildSpec = ?CLIENT(Id, [Bridge], permanent, 5000),

    case supervisor:start_child(?MODULE, ChildSpec) of
        {ok, _} = OK ->
            OK;

        {error, already_present} ->
            ok = supervisor:delete_child(?MODULE, Id),
            start_child(Bridge);

        {error, _} = Error ->
            Error
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
terminate_child(Name) ->
    supervisor:terminate_child(?MODULE, Name).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
delete_child(Name) ->
    supervisor:delete_child(?MODULE, Name).


%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================



init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 20, % max restarts
        period => 60, % seconds
        auto_shutdown => never
    },
    {ok, {SupFlags, []}}.
