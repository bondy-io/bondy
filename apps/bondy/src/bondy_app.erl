%% =============================================================================
%% bondy_app -
%%
%% Copyright (c) 2016-2019 Ngineo Limited t/a Leapsight. All rights reserved.
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
%% @doc A convenience function. Calls `init:stop/0'
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
    %% We temporarily disable plum_db's AAE to avoid rebuilding hashtrees
    %% until we are ready to do it
    ok = disable_aae(),

    case bondy_sup:start_link() of
        {ok, Pid} ->
            %% Please do not change the order of this function calls
            %% unless, of course, you know exactly what you are doing.
            ok = bondy_router_worker:start_pool(),
            ok = bondy_cli:register(),
            ok = setup_bondy_realm(),
            ok = setup_event_handlers(),
            ok = setup_wamp_subscriptions(),
            ok = setup_partisan(),
            %% After we return, OTP will call start_phase/3 based on
            %% the order established in the start_phases in bondy.app.src
            {ok, Pid};
        Other  ->
            Other
    end.


%% -----------------------------------------------------------------------------
%% @doc Application behaviour callback
%% @end
%% -----------------------------------------------------------------------------
start_phase(init_admin_listeners, normal, []) ->
    %% We start just the admin API rest listeners (HTTP/HTTPS, WS/WSS).
    %% This is to enable certain operations during startup i.e. heartbeats
    %% and external liveness probe e.g. K8s
    bondy_api_gateway:start_admin_listeners();

start_phase(configure_features, normal, []) ->
    ok = bondy_realm:apply_config(),
    %% ok = bondy_oauth2:apply_config(),
    ok = bondy_api_gateway:apply_config(),
    ok;

start_phase(init_registry, normal, []) ->
    %% In previous versions of Bondy we piggy backed on a disk-only version of
    %% plum_db to get registry synchronisation across the cluster.
    %% During the previous registry initialisation no client should be
    %% connected. This was a clean way of avoiding new registrations
    %% interfiering with the registry restore and cleanup.
    %% Starting from bondy 0.8.0 and the migration to plum_db 0.2.0 we no
    %% longer store the registry on disk, we restore everything from the
    %% network. However, we kept this step as it is clean and allows us to do
    %% some validations and preparations.
    bondy_registry:init();

start_phase(restore_aae_config, normal, []) ->
    ok = maybe_enable_aae(),
    %% TODO conditionally force an AAE exchange here to get a the
    %% registry in sync with the cluster before init_listeners
    ok;

start_phase(init_listeners, normal, []) ->
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
setup_env(Args) ->
    case lists:keyfind(vsn, 1, Args) of
        {vsn, Vsn} ->
            application:set_env(bondy, vsn, Vsn);
        false ->
            ok
    end.


%% @private
setup_bondy_realm() ->
    %% We do a get to force the creation of the bondy realm
    _ = bondy_realm:get(?BONDY_REALM_URI, ?BONDY_REALM),
    ok.


%% @private
setup_partisan() ->
    %% We add the wamp_peer_messages channel to the configured channels
    Channels0 = partisan_config:get(channels, []),
    partisan_config:set(channels, [wamp_peer_messages | Channels0]).


%% @private
setup_event_handlers() ->
    %% We replace the default OTP alarm handler with ours
    _ = bondy_event_manager:swap_watched_handler(
        alarm_handler, {alarm_handler, normal}, {bondy_alarm_handler, []}),
    _ = bondy_event_manager:add_watched_handler(bondy_prometheus, []),
    _ = bondy_event_manager:add_watched_handler(bondy_wamp_meta_events, []),
    ok.


%% -----------------------------------------------------------------------------
%% @private
%% @doc Sets up the internal WAMP subscriptions.
%% @end
%% -----------------------------------------------------------------------------
setup_wamp_subscriptions() ->
    %% TODO moved this into each app when we finish restructuring
    Opts = #{match => <<"exact">>},
    _ = bondy:subscribe(
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
    _ = bondy:subscribe(
        ?BONDY_PRIV_REALM_URI,
        Opts,
        ?USER_UPDATED,
        fun bondy_api_gateway_wamp_handler:handle_event/2
    ),
    _ = bondy:subscribe(
        ?BONDY_PRIV_REALM_URI,
        Opts,
        ?PASSWORD_CHANGED,
        fun bondy_api_gateway_wamp_handler:handle_event/2
    ),
    ok.


%% @private
disable_aae() ->
    case plum_db_config:get(aae_enabled, true) of
        true ->
            ok = application:set_env(plum_db, priv_aae_enabled, true),
            ok = plum_db_config:set(aae_enabled, false),
            _ = lager:info(
                "Temporarily disabled active anti-entropy (AAE) during initialisation"),
            ok;
        false ->
            ok
    end.

maybe_enable_aae() ->
    case application:get_env(plum_db, priv_aae_enabled, false) of
        true ->
            ok = plum_db_config:set(aae_enabled, true),
            _ = lager:info("Active anti-entropy (AAE) enabled");
        false ->
            ok
    end.


%% @private
stop_router_services() ->
    _ = lager:info("Initiating shutdown"),

    %% We stop accepting new connections on HTTP/S and WS/S
    _ = lager:info("Suspending HTTP/S and WS/S listeners"),
    ok = bondy_api_gateway:suspend_listeners(),

    %% We stop accepting new connections on TCP/TLS
    _ = lager:info("Suspending TCP/TLS listeners"),
    ok = bondy_wamp_raw_handler:suspend_listeners(),

    %% We ask the router to shutdown. This will send a goodbye to all sessions
    _ = lager:info("Shutting down all WAMP sessions"),
    ok = bondy_router:shutdown(),

    %% We sleep for a while to allow all sessions to terminate gracefully
    Secs = bondy_config:get(shutdown_grace_period),
    _ = lager:info(
        "Awaiting ~p secs for WAMP sessions to gracefully terminate",
        [Secs]
    ),
    ok = timer:sleep(Secs * 1000),

    %% We force the HTTP/S and WS/S connections to stop
    _ = lager:info("Terminating all HTTP/S and WS/S connections"),
    ok = bondy_api_gateway:stop_listeners(),

    %% We force the TCP/TLS connections to stop
    _ = lager:info("Terminating all TCP/TLS connections"),
    ok = bondy_wamp_raw_handler:stop_listeners(),

    _ = lager:info("Shutdown finished"),
    ok.