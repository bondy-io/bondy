%% =============================================================================
%% bondy_app -
%%
%% Copyright (c) 2016-2024 Leapsight. All rights reserved.
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
    %% We initialise the Bondy config, we need to make this call before
    %% starting tuplespace, partisan and plum_db. This is because we are
    %% modifying their application environments.
    ok = bondy_config:init(Args),

    %% We temporarily disable plum_db's AAE to avoid rebuilding hashtrees
    %% until we are ready to do it
    ok = suspend_pdb_aae(),

    %% Now that we have initialised the configuration we start the following
    %% dependencies
    _ = application:ensure_all_started(tuplespace, permanent),

    %% We do not need to start partisan since plum_db will do it
    _ = application:ensure_all_started(plum_db, permanent),

    %% Now that Partisan is up we can get our nodename
    ok = logger:update_primary_config(#{metadata => #{
        node => partisan:node(),
        router_vsn => vsn()
    }}),

    %% We wait for plum_db partitions to be up, we need to do this before
    %% we start the supervisor
    ok = maybe_wait_for_pdb_partitions(),

    %% Finally we start the supervisor
    case bondy_sup:start_link() of
        {ok, Pid} ->
            maybe
                %% Please do not change the order of this function calls
                %% unless, of course, you know exactly what you are doing.
                ok ?= setup_commons(),
                ok ?= bondy_sysmon_handler:add_handler(),
                ok ?= bondy_router_worker:start_pool(),
                ok ?= setup_event_handlers(),
                ok ?= configure_services(),
                ok ?= init_registry(),
                ok ?= setup_wamp_subscriptions(),
                %% We just start the admin API rest listeners [HTTP(S), WS(S)].
                %% This is to enable certain operations during startup i.e.
                %% liveness and readiness http probes.
                ok ?= start_admin_listeners(),
                %% We need to re-enable AAE (if it was enabled) so
                %% that hashtrees are build
                ok ?= restore_pdb_aae(),
                %% We conditionally wait for hashtrees to be built
                %% (this can be disabled via configuration)
                ok ?= maybe_wait_for_pdb_hashtrees(),
                %% We conditionally force a first AAE sync exchange
                %% (this can be disabled via configuration)
                ok ?= maybe_wait_for_pdb_aae_exchange(),
                %% Finally we allow clients to connect
                ok ?= start_public_listeners(),
                {ok, Pid}

            else
                {error, _} = Error ->
                    Error

            end;

        Error  ->
            Error
    end.


%% -----------------------------------------------------------------------------
%% @doc Application behaviour callback
%% @end
%% -----------------------------------------------------------------------------
prep_stop(_State) ->
    ok = bondy_config:set(status, shutting_down),

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
    ok = timer:sleep(timer:seconds(Secs)),

    %% We remove all session and their registrations and subscriptions, also
    %% broadcasting those to the other nodes.
    ok = bondy_router:stop(),

    ok = maybe_leave(),

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
setup_commons() ->
    ok.


%% @private
maybe_wait_for_pdb_partitions() ->
    case wait_for_partitions() of
        true ->
            %% We block until all partitions are initialised
            ?LOG_NOTICE(#{
                description =>
                    "Application master is waiting for plum_db partitions "
                    "to be initialised"
            }),
            plum_db_startup_coordinator:wait_for_partitions();
        false ->
            ok
    end.


%% @private
maybe_wait_for_pdb_hashtrees() ->
    case wait_for_pdb_hashtrees() of
        true ->
            %% We block until all hashtrees are built
            ?LOG_NOTICE(#{description =>
                "Application master is waiting for "
                "plum_db hashtrees to be built"
            }),
            plum_db_startup_coordinator:wait_for_hashtrees();

        false ->
            ok
    end,

    %% We stop the coordinator as it is a transcient worker
    plum_db_startup_coordinator:stop().


%% @private
maybe_wait_for_pdb_aae_exchange() ->
    %% When plum_db is included in a principal application, the latter can
    %% join the cluster before this phase and perform a first aae exchange
    case wait_for_pdb_aae_exchange() of
        true ->
            MyNode = partisan:node(),
            Members = partisan_plumtree_broadcast:broadcast_members(),

            case lists:delete(MyNode, Members) of
                [] ->
                    %% We have not yet joined a cluster, so we finish
                    ok;

                Peers ->
                    ?LOG_NOTICE(#{
                        description =>
                            "Application master is waiting for "
                            "plum_db AAE to perform an exchange"
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
wait_for_pdb_aae_exchange() ->
    plum_db_config:get(aae_enabled) andalso
    plum_db_config:get(wait_for_aae_exchange).


%% @private
wait_for_partitions() ->
    %% Waiting for hashtrees implies waiting for partitions
    plum_db_config:get(wait_for_partitions) orelse wait_for_pdb_hashtrees().


%% @private
wait_for_pdb_hashtrees() ->
    %% If aae is disabled the hastrees will never get build
    %% and we would block forever
    (
        plum_db_config:get(aae_enabled)
        andalso plum_db_config:get(wait_for_hashtrees)
    ) orelse wait_for_pdb_aae_exchange().


%% @private
configure_services() ->
    ?LOG_NOTICE(#{
        description =>
            "Configuring master and user realms from configuration file"
    }),

    ok = bondy_message_id:init(),

    %% We use bondy_realm:get/1 to force the creation of the bondy admin realm
    %% if it does not exist.
    _ = bondy_realm:get(?MASTER_REALM_URI),
    ok = bondy_realm:apply_config(),
    ok = bondy_http_gateway:apply_config().


%% @private
init_registry() ->
    case bondy_registry:init_trie() of
        ok ->
            ok;
        {error, Reason} ->
            exit(Reason)
    end.


%% @private
start_admin_listeners() ->
    %% The /ping (liveness) and /metrics paths will now go live
    %% The /ready (readiness) path will now go live but will return false as
    %% bondy_config:get(status) will return `initialising'
    ?LOG_NOTICE(#{description => "Starting Admin API listeners"}),
    bondy_http_gateway:start_admin_listeners().


%% @private
start_public_listeners() ->
    ?LOG_NOTICE(#{description => "Starting listeners"}),
    %% Now that the registry has been initialised we can initialise
    %% the remaining listeners for clients to connect
    %% WAMP TCP listeners
    ok = bondy_wamp_tcp:start_listeners(),

    %% WAMP Websocket and REST Gateway HTTP listeners
    %% @TODO We need to separate the /ws path into another listener/port number
    ok = bondy_http_gateway:start_listeners(),

    %% We flag the status, the HTTP /ready path will now return true.
    ok = bondy_config:set(status, ready),

    %% Bondy Router Bridge Relay (server) connection listeners
    ok = bondy_bridge_relay_manager:start_listeners(),

    %% Bondy Router Bridge Relay (client) connections
    ok = bondy_bridge_relay_manager:start_bridges().


%% @private
setup_event_handlers() ->
    %% We replace the default OTP signal handler with ours
    _ = gen_event:swap_handler(
        erl_signal_server,
        {erl_signal_handler, []},
        {bondy_signal_handler, []}
    ),

    %% We replace the default OTP alarm handler with ours
    _ = bondy_event_manager:swap_watched_handler(
        alarm_handler, {alarm_handler, normal}, {bondy_alarm_handler, []}
    ),

    %% An event handler that republishes some internal events to WAMP
    _ = bondy_event_manager:add_watched_handler(
        bondy_event_wamp_publisher, []
    ),

    _ = bondy_event_manager:add_watched_handler(bondy_prometheus, []),

    %% We subscribe to partisan up and down events and republish them
    partisan_peer_service:on_up('_', fun(Node) ->
        bondy_event_manager:notify({[bondy, cluster, connection, up], Node})
    end),

    partisan_peer_service:on_down('_', fun(Node) ->
        bondy_event_manager:notify({[bondy, cluster, connection, down], Node})
    end),

    % Used for debugging
    % _ = bondy_event_manager:add_watched_handler(
    %     bondy_event_logger, []
    % ),
    % _ = plum_db_events:add_handler(
    %     bondy_event_logger, []
    % ),

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
suspend_pdb_aae() ->
    case application:get_env(plum_db, aae_enabled, true) of
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
restore_pdb_aae() ->
    case application:get_env(plum_db, priv_aae_enabled, false) of
        true ->
            %% plum_db should have started so we call plum_db_config
            ok = plum_db_config:set(aae_enabled, true),
            ?LOG_NOTICE(#{
                description => "Active anti-entropy (AAE) re-enabled"
            }),
            ok;
        false ->
            ok
    end.


suspend_listeners() ->
    %% We stop accepting new connections on all listeners.
    %% Existing connections are unaffected.

    ?LOG_NOTICE(#{
        description =>
            "Suspending HTTP(S) and WS(S) client listeners. "
            "No new connections will be accepted from now on."
    }),
    ok = bondy_http_gateway:suspend_listeners(),

    ?LOG_NOTICE(#{description =>
        "Suspending TCP(TLS) client listeners. "
        "No new connections will be accepted from now on."
    }),
    ok = bondy_wamp_tcp:suspend_listeners(),

    ?LOG_NOTICE(#{description =>
        "Suspending Bridge Relay listeners. "
        "No new connections will be accepted from now on."
    }),
    ok = bondy_bridge_relay_manager:suspend_listeners().


stop_listeners() ->
    %% We force all listeners to stop.
    %% All existing connections will be terminated.

    ?LOG_NOTICE(#{
        description =>
            "Terminating all client HTTP(S) and WS(S) client connections."
        }),
    ok = bondy_http_gateway:stop_listeners(),

    ?LOG_NOTICE(#{
        description => "Terminating all TCP(TLS) client connections."
    }),
    ok = bondy_wamp_tcp:stop_listeners(),

    ?LOG_NOTICE(#{
        description => "Terminating all Bridge Relay connections."
    }),
    ok = bondy_bridge_relay_manager:stop_listeners().


maybe_leave() ->
    case bondy_config:get(automatic_leave, false) of
        true ->
            ?LOG_NOTICE(#{
                description => "Leaving Bondy cluster.",
                automatic_leave => true
            }),
            partisan_peer_service:leave();
        false ->
            ok
    end.