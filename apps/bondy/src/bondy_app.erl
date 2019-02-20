%% =============================================================================
%% bondy_app -
%%
%% Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%    http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%% =============================================================================
-module(bondy_app).
-behaviour(application).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy_security.hrl").


-export([start/2]).
-export([stop/1]).
-export([stop/0]).
-export([start_phase/3]).
-export([prep_stop/1]).
-export([vsn/0]).




%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc A convenience function. Calls `init:stop/0`
%% @end
%% -----------------------------------------------------------------------------
stop() ->
    init:stop().


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec vsn() -> list().
vsn() ->
    bondy_config:get(vsn, "undefined").



%% =============================================================================
%% APPLICATION BEHAVIOUR CALLBACKS
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Application behaviour callback
%% @end
%% -----------------------------------------------------------------------------
start(_Type, Args) ->
    %% We initialise the environment
    ok = setup_env(Args),
    %% We initialise the config, caching all values as code
    ok = bondy_config:init(),
    %% We temporarily disable plum_db's AAE to avoid rebuilding hashtrees
    %%  until we are ready
    ok = disable_aae(),
    %% We setup partisan options
    ok = setup_partisan(),

    case bondy_sup:start_link() of
        {ok, Pid} ->
            ok = init_bondy_realm(),
            ok = setup_event_handlers(),
            ok = bondy_router_worker:start_pool(),
            ok = bondy_cli:register(),
            ok = setup_internal_subscriptions(),
            %% After we return, OTP will call start_phase/3 based on
            %% bondy.app.src/start_phases
            {ok, Pid};
        Other  ->
            Other
    end.


%% -----------------------------------------------------------------------------
%% @doc Application behaviour callback
%% @end
%% -----------------------------------------------------------------------------
start_phase(init_admin_listeners = Name, normal, []) ->
    _ = lager:info("Executing application start phase '~p'", [Name]),
    %% We start just the admin API rest listeners (HTTP/HTTPS, WS/WSS).
    %% This is to enable operations during startup and also heartbeats
    %% e.g. K8s liveness probe.
    bondy_api_gateway:start_admin_listeners();

start_phase(configure_features = Name, normal, []) ->
    _ = lager:info("Executing application start phase '~p'", [Name]),
    ok = bondy_realm:apply_config(),
    %% ok = bondy_oauth2:apply_config(),
    ok = bondy_api_gateway:apply_config(),
    ok;

start_phase(init_registry = Name, normal, []) ->
    _ = lager:info("Executing application start phase '~p'", [Name]),
    %% In previous versions of Bondy we piggy backed on a disk-only version of
    %% plum_db to get registry synchronisation across the cluster.
    %% During the previous registry initialisation no client should be
    %% connected.
    %% This was a clean way of avoiding new registrations interfiering with
    %% the registry restore and cleanup.
    %%
    %% Starting from bondy 0.8.0 and the migration to plum_db 0.2.0 we no
    %% longer store the registry on disk, but we restore everything from the
    %% network. However, we kept this step as it is clean and allows us to do
    %% some validations and preparations.
    %% TODO consider forcing an AAE exchange here to get a the registry in sync
    %% with the cluster before init_listeners
    bondy_registry:init();

start_phase(restore_aae_config = Name, normal, []) ->
    _ = lager:info("Executing application start phase '~p'", [Name]),
    {ok, Enabled} = application:get_env(plum_db, priv_aae_enabled),
    ok = plum_db_config:set(aae_enabled, Enabled),
    ok;

start_phase(init_listeners = Name, normal, []) ->
    _ = lager:info("Executing application start phase '~p'", [Name]),
    %% Now that the registry has been initialised we can initialise
    %% the remaining HTTP, WS and TCP listeners for clients to connect
    ok = bondy_wamp_raw_handler:start_listeners(),
    ok = bondy_api_gateway:start_listeners(),
    ok.


%% -----------------------------------------------------------------------------
%% @doc Application behaviour callback
%% @end
%% -----------------------------------------------------------------------------
prep_stop(_State) ->
    stop_router_services().


%% -----------------------------------------------------------------------------
%% @doc Application behaviour callback
%% @end
%% -----------------------------------------------------------------------------
stop(_State) ->
    ok.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
disable_aae() ->
    _ = lager:info("Temporarily disabling plum_db AAE"),
    Enabled = plum_db_config:get(aae_enabled, true),
    ok = application:set_env(plum_db, priv_aae_enabled, Enabled),
    ok = plum_db_config:set(aae_enabled, false),
    ok.


%% @private
setup_env(Args) ->
    case lists:keyfind(vsn, 1, Args) of
        {vsn, Vsn} ->
            application:set_env(bondy, vsn, Vsn);
        false ->
            ok
    end.

%% @private
init_bondy_realm() ->
    _ = bondy_realm:get(?BONDY_REALM_URI, ?BONDY_REALM),
    ok.


%% @private
setup_partisan() ->
    %% We add the wamp_peer_messages channel to the configured channels
    Channels0 = partisan_config:get(channels, []),
    partisan_config:set(channels, [wamp_peer_messages | Channels0]).


%% @private
stop_router_services() ->
    _ = lager:info("Initiating shutdown"),
    %% We stop accepting new connections on HTTP/Websockets
    ok = bondy_api_gateway:suspend_listeners(),
    %% We stop accepting new connections on TCP/TLS
    ok = bondy_wamp_raw_handler:suspend_listeners(),

    %% We ask the router to shutdown which will send a goodbye to all sessions
    ok = bondy_router:shutdown(),

    %% We sleep for a minute to allow all sessions to terminate gracefully
    Time = bondy_config:get(graceful_shutdown, 5000),
    _ = lager:info(
        "Awaiting ~p secs for clients graceful shutdown.",
        [trunc(Time/1000)]
    ),
    ok = timer:sleep(Time),
    _ = lager:info("Terminating all client connections"),

    %% We force the HTTP/WS connections to stop
    ok = bondy_api_gateway:stop_listeners(),
    %% We force the TCP and TLS connections to stop
    ok = bondy_wamp_raw_handler:stop_listeners(),
    ok.


%% @private
setup_event_handlers() ->
    _ = bondy_event_manager:swap_watched_handler(
        alarm_handler, {alarm_handler, normal}, {bondy_alarm_handler, []}),
    _ = bondy_event_manager:add_watched_handler(bondy_prometheus, []),
    _ = bondy_event_manager:add_watched_handler(bondy_wamp_meta_events, []),
    ok.


%% TODO moved this into each app when we finish restructuring
setup_internal_subscriptions() ->
    Opts = #{match => <<"exact">>},
    bondy:subscribe(
        ?BONDY_PRIV_REALM_URI,
        Opts,
        ?USER_ADDED,
        fun bondy_api_gateway_wamp_handler:handle_event/2
    ),
    _ = bondy:subscribe(
        ?BONDY_PRIV_REALM_URI,
        Opts,
        ?USER_DELETED,
        fun bondy_api_gateway_wamp_handler:handle_event/2
    ),
    bondy:subscribe(
        ?BONDY_PRIV_REALM_URI,
        Opts,
        ?USER_UPDATED,
        fun bondy_api_gateway_wamp_handler:handle_event/2
    ),
    bondy:subscribe(
        ?BONDY_PRIV_REALM_URI,
        Opts,
        ?PASSWORD_CHANGED,
        fun bondy_api_gateway_wamp_handler:handle_event/2
    ),
    ok.
