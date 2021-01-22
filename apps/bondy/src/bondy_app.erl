%% =============================================================================
%% bondy_app -
%%
%% Copyright (c) 2016-2021 Leapsight. All rights reserved.
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

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_app).
-behaviour(application).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_meta_api.hrl").


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
    ok = suspend_aae(),

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
%% @doc Application behaviour callback.
%% The order in which this function is called with the different phases is
%% defined in the bondy_app.src file.
%% @end
%% -----------------------------------------------------------------------------
start_phase(init_db_partitions, normal, []) ->
    %% The application master will call this same phase in plum_db
    %% we do nothing here.
    %% plum_db will initialise its partitions from disk.
    ok;

start_phase(init_admin_listeners, normal, []) ->
    %% We start just the admin API rest listeners (HTTP/HTTPS, WS/WSS).
    %% This is to enable certain operations during startup i.e. liveness and
    %% readiness http probes.
    %% The /ping (liveness) and /metrics paths will now go live
    %% The /ready (readyness) path will now go live but will return false as
    %% bondy_config:get(status) will return `initialising'
    bondy_rest_gateway:start_admin_listeners();

start_phase(configure_features, normal, []) ->
    ok = bondy_realm:apply_config(),
    %% ok = bondy_oauth2:apply_config(),
    ok = bondy_rest_gateway:apply_config(),
    ok;

start_phase(init_registry, normal, []) ->
    bondy_registry:init();

start_phase(init_db_hashtrees, normal, []) ->
    ok = restore_aae(),
    %% The application master will call this same phase in plum_db
    %% we do nothing here.
    %% plum_db will calculate the Active Anti-entropy hashtrees.
    ok;

start_phase(aae_exchange, normal, []) ->
    %% The application master will call this same phase in plum_db
    %% we do nothing here.
    %% plum_db will try to perform an Active Anti-entropy exchange.
    ok;

start_phase(init_listeners, normal, []) ->
    %% Now that the registry has been initialised we can initialise
    %% the remaining listeners for clients to connect
    %% WAMP TCP listeners
    ok = bondy_wamp_rs_connection_handler:start_listeners(),
    %% WAMP Websocket and REST Gateway HTTP listeners
    %% @TODO We need to separate the /ws path into another listener/port number
    ok = bondy_rest_gateway:start_listeners(),
    %% We flag the status, the /ready path will now return true.
    ok = bondy_config:set(status, ready),
    ok.


%% -----------------------------------------------------------------------------
%% @doc Application behaviour callback
%% @end
%% -----------------------------------------------------------------------------
prep_stop(_State) ->
    ok = bondy_config:set(status, shutting_down),
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



%% -----------------------------------------------------------------------------
%% @private
%% @doc A utility function that we use to extract the version name that is
%% injected by the bondy.app.src configuration file.
%% @end
%% -----------------------------------------------------------------------------
setup_env(Args) ->
    case lists:keyfind(vsn, 1, Args) of
        {vsn, Vsn} ->
            ok = bondy_config:set(status, initialising),
            application:set_env(bondy, vsn, Vsn);
        false ->
            ok
    end.


%% @private
setup_bondy_realm() ->
    %% We use get/2 to force the creation of the bondy admin realm
    %% if it does not exist.
    _ = bondy_realm:get(?BONDY_REALM_URI),
    ok.


%% @private
setup_partisan() ->
    %% We add the wamp_peer_messages channel to the configured channels
    Channels0 = partisan_config:get(channels, []),
    ok = partisan_config:set(channels, [wamp_peer_messages | Channels0]),
    bondy_config:set(wamp_peer_channel, wamp_peer_messages).


%% @private
setup_event_handlers() ->
    %% We replace the default OTP alarm handler with ours
    _ = bondy_event_manager:swap_watched_handler(
        alarm_handler, {alarm_handler, normal}, {bondy_alarm_handler, []}
    ),
    _ = bondy_event_manager:add_watched_handler(
        bondy_wamp_meta_event_handler, []
    ),
    _ = bondy_event_manager:add_watched_handler(bondy_prometheus, []),
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
        fun bondy_rest_gateway_api_handler:handle_event/2
    ),
    _ = bondy:subscribe(
        ?BONDY_PRIV_REALM_URI,
        Opts,
        ?USER_DELETED,
        fun bondy_rest_gateway_api_handler:handle_event/2
    ),
    _ = bondy:subscribe(
        ?BONDY_PRIV_REALM_URI,
        Opts,
        ?USER_UPDATED,
        fun bondy_rest_gateway_api_handler:handle_event/2
    ),
    _ = bondy:subscribe(
        ?BONDY_PRIV_REALM_URI,
        Opts,
        ?PASSWORD_CHANGED,
        fun bondy_rest_gateway_api_handler:handle_event/2
    ),
    ok.


%% @private
suspend_aae() ->
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


%% @private
restore_aae() ->
    case application:get_env(plum_db, priv_aae_enabled, false) of
        true ->
            ok = plum_db_config:set(aae_enabled, true),
            _ = lager:info("Active anti-entropy (AAE) re-enabled"),
            ok;
        false ->
            ok
    end.


%% @private
stop_router_services() ->
    _ = lager:info("Initiating shutdown"),

    %% We stop accepting new connections on HTTP/S and WS/S
    _ = lager:info(
        "Suspending HTTP/S and WS/S listeners. "
        "No new connections will be accepted."
    ),
    ok = bondy_rest_gateway:suspend_listeners(),

    %% We stop accepting new connections on TCP/TLS
    _ = lager:info(
        "Suspending TCP/TLS listeners. "
        "No new connections will be accepted."
    ),
    ok = bondy_wamp_rs_connection_handler:suspend_listeners(),

    %% We ask the router to shutdown. This will send a goodbye to all sessions
    _ = lager:info("Shutting down all WAMP sessions."),
    ok = bondy_router:shutdown(),

    %% We sleep for a while to allow all sessions to terminate gracefully
    Secs = bondy_config:get(shutdown_grace_period, 5),
    _ = lager:info(
        "Awaiting ~p secs for WAMP sessions to gracefully terminate",
        [Secs]
    ),
    ok = timer:sleep(Secs * 1000),

    %% We force the HTTP/S and WS/S connections to stop
    _ = lager:info("Terminating all HTTP/S and WS/S connections"),
    ok = bondy_rest_gateway:stop_listeners(),

    %% We force the TCP/TLS connections to stop
    _ = lager:info("Terminating all TCP/TLS connections"),
    ok = bondy_wamp_rs_connection_handler:stop_listeners(),

    _ = lager:info("Shutdown finished"),
    ok.


