%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_subscribers_sup).
-behaviour(supervisor).
-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-define(CHILD(Id, Type, Args, Restart, Timeout), #{
    id => Id,
    start => {Id, start_link, Args},
    restart => Restart,
    shutdown => Timeout,
    type => Type,
    modules => [Id]
}).

%% API
-export([start_link/0]).
-export([start_subscriber/5]).
-export([terminate_subscriber/1]).


%% SUPERVISOR CALLBACKS
-export([init/1]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start_subscriber(id(), uri(), map(), uri(), map() | function()) ->
    {ok, pid()} | {error, any()}.

start_subscriber(Id, RealmUri, Opts, Topic, Fun) when is_function(Fun, 2) ->
    supervisor:start_child(?MODULE, [Id, RealmUri, Opts, Topic, Fun]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
terminate_subscriber(Subscriber) when is_pid(Subscriber)->
    supervisor:terminate_child(?MODULE, Subscriber).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).



%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================



init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 5, % max restarts
        period => 10, % seconds
        auto_shutdown => never
    },
    Children = [
        ?CHILD(bondy_subscriber, worker, [], transient, 5000)
    ],

    {ok, {SupFlags, Children}}.




%% =============================================================================
%% PRIVATE
%% =============================================================================


