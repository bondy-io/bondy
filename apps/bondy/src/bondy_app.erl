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
-include_lib("kernel/include/logger.hrl").
-include("bondy.hrl").



-export([prep_stop/1]).
-export([start/2]).
-export([status/0]).
-export([stop/0]).
-export([stop/1]).
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
status() ->
    #{
        vsn => vsn(),
        status => bondy_config:get(status)
    }.


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
    % dbg:tracer(), dbg:p(all,c),
    % dbg:tpl(gen_event, server_update, []),
    application:stop(partisan),
    % application:unload(partisan),

    %% We initialised the Bondy app config
    ok = bondy_config:init(Args),


    logger:set_application_level(partisan, info),

    %% We temporarily disable plum_db's AAE to avoid rebuilding hashtrees
    %% until we are ready to do it
    ok = suspend_aae(),

    _ = application:ensure_all_started(tuplespace, permanent),
    _ = application:ensure_all_started(plum_db, permanent),

    case bondy_sup:start_link() of
        {ok, Pid} ->
            %% Please do not change the order of this function calls
            %% unless, of course, you know exactly what you are doing.
            ok = bondy_router_worker:start_pool(),
            ok = setup_event_handlers(),
            ok = maybe_wait_for_plum_db_partitions(),
            ok = configure_services(),
            ok = init_registry(),
            ok = setup_wamp_subscriptions(),
            ok = start_admin_listeners(),
            ok = restore_aae(),
            ok = maybe_wait_for_plum_db_hashtrees(),
            ok = maybe_wait_for_aae_exchange(),
            ok = start_public_listeners(),
            {ok, Pid};
        Other  ->
            Other
    end.


%% -----------------------------------------------------------------------------
%% @doc Application behaviour callback
%% @end
%% -----------------------------------------------------------------------------
prep_stop(_State) ->
    ok = bondy_config:set(status, shutting_down),

    ?LOG_NOTICE(#{description => "Initiating shutdown"}),

    ok = suspend_listeners(),

    %% We ask the router to shutdown.
    %% This will send a goodbye to all sessions
    ?LOG_NOTICE(#{
        description => "Shutting down all existing client sessions."
    }),
    ok = bondy_router:pre_stop(),

    %% We sleep for a while to allow all sessions to terminate gracefully
    Secs = bondy_config:get(shutdown_grace_period, 5),

    ?LOG_NOTICE(#{
        description => "Awaiting for client sessions to gracefully terminate",
        timer_secs => Secs
    }),
    ok = timer:sleep(Secs * 1000),

    %% We remove all session and their registrations and subscriptions, also
    %% broadcasting those to the other nodes.
    ok = bondy_router:stop(),

    ok = stop_listeners().


%% -----------------------------------------------------------------------------
%% @doc Application behaviour callback
%% @end
%% -----------------------------------------------------------------------------
stop(_State) ->
    ?LOG_NOTICE(#{description => "Shutdown finished"}),
    ok.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
maybe_wait_for_plum_db_partitions() ->
    case wait_for_partitions() of
        true ->
            %% We block until all partitions are initialised
            ?LOG_NOTICE(#{
                description => "Application master is waiting for plum_db partitions to be initialised"
            }),
            plum_db_startup_coordinator:wait_for_partitions();
        false ->
            ok
    end.


%% @private
maybe_wait_for_plum_db_hashtrees() ->
    case wait_for_hashtrees() of
        true ->
            %% We block until all hashtrees are built
            ?LOG_NOTICE(#{
                description => "Application master is waiting for plum_db hashtrees to be built"
            }),
            plum_db_startup_coordinator:wait_for_hashtrees();
        false ->
            ok
    end,

    %% We stop the coordinator as it is a transcient worker
    plum_db_startup_coordinator:stop().


%% @private
maybe_wait_for_aae_exchange() ->
    %% When plum_db is included in a principal application, the latter can
    %% join the cluster before this phase and perform a first aae exchange
    case wait_for_aae_exchange() of
        true ->
            MyNode = plum_db_peer_service:mynode(),
            Members = partisan_plumtree_broadcast:broadcast_members(),

            case lists:delete(MyNode, Members) of
                [] ->
                    %% We have not yet joined a cluster, so we finish
                    ok;
                Peers ->
                    ?LOG_NOTICE(#{
                        description => "Application master is waiting for plum_db AAE to perform exchange"
                    }),
                    %% We are in a cluster, we randomnly pick a peer and
                    %% perform an AAE exchange
                    [Peer|_] = lists_utils:shuffle(Peers),
                    %% We block until the exchange finishes successfully
                    %% or with error, we finish anyway
                    _ = plum_db:sync_exchange(Peer),
                    ok
            end;
        false ->
            ok
    end.


%% @private
wait_for_aae_exchange() ->
    plum_db_config:get(aae_enabled) andalso
    plum_db_config:get(wait_for_aae_exchange).


%% @private
wait_for_partitions() ->
    %% Waiting for hashtrees implies waiting for partitions
    plum_db_config:get(wait_for_partitions) orelse wait_for_hashtrees().


%% @private
wait_for_hashtrees() ->
    %% If aae is disabled the hastrees will never get build
    %% and we would block forever
    (
        plum_db_config:get(aae_enabled)
        andalso plum_db_config:get(wait_for_hashtrees)
    ) orelse wait_for_aae_exchange().


%% @private
configure_services() ->
    ?LOG_NOTICE(#{
        description => "Configuring master and user realms from configuration file"
    }),
    %% We use bondy_realm:get/1 to force the creation of the bondy admin realm
    %% if it does not exist.
    _ = bondy_realm:get(?MASTER_REALM_URI),
    ok = bondy_realm:apply_config(),

    %% ok = bondy_oauth2:apply_config(),

    ok = bondy_http_gateway:apply_config(),
    ok.


%% @private
init_registry() ->
    bondy_registry:init_tries().


%% @private
start_admin_listeners() ->
    %% We start just the admin API rest listeners (HTTP/HTTPS, WS/WSS).
    %% This is to enable certain operations during startup i.e. liveness and
    %% readiness http probes.
    %% The /ping (liveness) and /metrics paths will now go live
    %% The /ready (readyness) path will now go live but will return false as
    %% bondy_config:get(status) will return `initialising'
    ?LOG_NOTICE(#{
        description => "Starting Admin API listeners"
    }),
    bondy_http_gateway:start_admin_listeners().


%% @private
start_public_listeners() ->
    ?LOG_NOTICE(#{
        description => "Starting listeners"
    }),
    %% Now that the registry has been initialised we can initialise
    %% the remaining listeners for clients to connect
    %% WAMP TCP listeners
    ok = bondy_wamp_tcp:start_listeners(),

    %% WAMP Websocket and REST Gateway HTTP listeners
    %% @TODO We need to separate the /ws path into another listener/port number
    ok = bondy_http_gateway:start_listeners(),

    %% Bondy Edge (server) downlink connection listeners
    ok = bondy_edge:start_listeners(),

    %% Bondy Edge (client) uplink connection
    ok = bondy_edge:start_uplinks(),

    %% We flag the status, the /ready path will now return true.
    ok = bondy_config:set(status, ready),
    ok.


%% @private
setup_event_handlers() ->
    %% We replace the default OTP alarm handler with ours
    _ = bondy_event_manager:swap_watched_handler(
        alarm_handler, {alarm_handler, normal}, {bondy_alarm_handler, []}
    ),

    %% An event handler that republishes some internal events to WAMP
    _ = bondy_event_manager:add_watched_handler(
        bondy_event_wamp_publisher, []
    ),

    % Used for debugging
    % _ = bondy_event_manager:add_watched_handler(
    %     bondy_event_logger, []
    % ),
    % _ = plum_db_events:add_handler(
    %     bondy_event_logger, []
    % ),

    _ = bondy_event_manager:add_watched_handler(bondy_prometheus, []),
    ok.


%% -----------------------------------------------------------------------------
%% @private
%% @doc Sets up some internal WAMP subscribers. These are processes supervised
%% by {@link bondy_subsribers_sup}.
%% @end
%% -----------------------------------------------------------------------------
setup_wamp_subscriptions() ->
    ok.


%% @private
suspend_aae() ->
    case plum_db_config:get(aae_enabled, true) of
        true ->
            ok = application:set_env(plum_db, priv_aae_enabled, true),
            ok = application:set_env(plum_db, aae_enabled, false),
            ?LOG_NOTICE(#{
                description => "Temporarily disabled active anti-entropy (AAE) during initialisation"
            }),
            ok;
        false ->
            ok
    end.


%% @private
restore_aae() ->
    case application:get_env(plum_db, priv_aae_enabled, false) of
        true ->
            %% plum_db should have started so we call plum_db_config
            ok = plum_db_config:set(aae_enabled, true),
            ?LOG_NOTICE(#{description => "Active anti-entropy (AAE) re-enabled"}),
            ok;
        false ->
            ok
    end.


suspend_listeners() ->
    %% We stop accepting new connections on HTTP/S and WS/S
    ?LOG_NOTICE(#{description =>
        "Suspending HTTP/S and WS/S client listeners. "
        "No new connections will be accepted."
    }),
    ok = bondy_http_gateway:suspend_listeners(),

    %% We stop accepting new connections on TCP/TLS
    ?LOG_NOTICE(#{description =>
        "Suspending TCP/TLS client listeners. "
        "No new connections will be accepted."
    }),
    ok = bondy_wamp_tcp:suspend_listeners(),

    %% We stop accepting new connections on TCP/TLS
    ?LOG_NOTICE(#{description =>
        "Suspending TCP/TLS Edge listeners. "
        "No new connections will be accepted."
    }),
    ok = bondy_edge:suspend_listeners().


stop_listeners() ->

    %% We force the HTTP/S and WS/S connections to stop
    ?LOG_NOTICE(#{description => "Terminating all client HTTP/S and WS/S client connections"}),
    ok = bondy_http_gateway:stop_listeners(),

    %% We force the TCP/TLS connections to stop
    ?LOG_NOTICE(#{description => "Terminating all TCP/TLS client connections"}),
    ok = bondy_wamp_tcp:stop_listeners(),

    %% We force the TCP/TLS connections to stop
    ?LOG_NOTICE(#{description => "Terminating all TCP/TLS Edge connections"}),
    ok = bondy_edge:stop_listeners().