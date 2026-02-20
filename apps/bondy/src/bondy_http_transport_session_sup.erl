%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================


-module(bondy_http_transport_session_sup).
-moduledoc """
A `simple_one_for_one` supervisor for dynamically spawning
`bondy_http_transport_session` gen_server processes.

Each transport session is started via `start_child/3` and supervised with
a `temporary` restart strategy — once a session terminates, it is not
automatically restarted.
""".

-behaviour(supervisor).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").


%% API
-export([start_link/0]).
-export([start_child/3]).

%% SUPERVISOR CALLBACKS
-export([init/1]).



%% =============================================================================
%% API
%% =============================================================================



-doc """
Starts the transport session supervisor.
""".
-spec start_link() -> {ok, pid()} | {error, term()}.

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).


-doc """
Starts a new transport session under this supervisor.
""".
-spec start_child(
    TransportId :: binary(),
    RealmUri :: uri(),
    SessionId :: bondy_session_id:t()
) -> {ok, pid()} | {error, term()}.

start_child(TransportId, RealmUri, SessionId) ->
    supervisor:start_child(?MODULE, [TransportId, RealmUri, SessionId]).



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
        id => bondy_http_transport_session,
        start => {bondy_http_transport_session, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [bondy_http_transport_session]
    },
    {ok, {SupFlags, [ChildSpec]}}.
