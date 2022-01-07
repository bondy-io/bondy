%% =============================================================================
%%  bondy_prometheus - this module is used to configure the prometheus metrics
%%  and export the prometheus report.
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc
%%
%%
%% We follow https://prometheus.io/docs/practices/naming/
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_prometheus).
-behaviour(gen_event).
-behaviour(prometheus_collector).
-include_lib("kernel/include/logger.hrl").
-include_lib("prometheus/include/prometheus.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").

-record(state, {}).

-define(WAMP_MESSAGE_LABELS, [
    realm_type, node, protocol, transport, frame_type, encoding
]).


%% API
-export([report/0]).
-export([days_duration_buckets/0]).
-export([hours_duration_buckets/0]).
-export([minutes_duration_buckets/0]).
-export([seconds_duration_buckets/0]).
-export([milliseconds_duration_buckets/0]).
-export([microseconds_duration_buckets/0]).


%% PROMETHEUS_COLLECTOR CALLBACKS
-export([deregister_cleanup/1]).
-export([collect_mf/2]).


%% GEN_EVENT CALLBACKS
-export([init/1]).
-export([handle_event/2]).
-export([handle_call/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-import(prometheus_model_helpers, [create_mf/4]).


%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
report() ->
    prometheus_text_format:format().


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
days_duration_buckets() ->
    [0, 1, 2, 3, 4, 5, 10, 15, 30].

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
hours_duration_buckets() ->
    [0, 1, 2, 3, 4, 5, 10, 12, 24, 48, 72].


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
minutes_duration_buckets() ->
    [0, 1, 2, 3, 4, 5, 10, 15, 30].


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
seconds_duration_buckets() ->
    [0, 1, 2, 3, 4, 5, 10, 15, 20, 25, 30, 60, 90, 180, 300, 600, 1800, 3600].


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
milliseconds_duration_buckets() ->
    [
        0, 1, 2, 5, 10, 15,
        25, 50, 75, 100, 150, 200, 250, 300, 400,
        500, 750, 1000, 1500, 2000, 2500, 3000, 4000, 5000
    ].

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
microseconds_duration_buckets() ->
    [
        10, 25, 50, 100, 250, 500,
        1000, 2500, 5000, 10000, 25000, 50000, 100000, 250000, 500000,
        1000000, 2500000, 5000000, 10000000
    ].



%% =============================================================================
%% PROMETHEUS_COLLECTOR CALLBACKS
%% =============================================================================



deregister_cleanup(_) ->
    ok.


-spec collect_mf(
    prometheus_registry:registry(), prometheus_collector:callback()) -> ok.

collect_mf(_Registry, Callback) ->
  Metrics = collector_metrics(),
  EnabledMetrics = enabled_metrics(),
  [add_metric_family(Metric, Callback)
   || {Name, _, _, _}=Metric <- Metrics, metric_enabled(Name, EnabledMetrics)],
  ok.



%% =============================================================================
%% GEN_EVENT CALLBACKS
%% =============================================================================



init([]) ->
    ok = setup(),
    State = #state{},
    {ok, State}.


handle_event({socket_open, Procotol, Transport, _Peername}, State) ->
    Labels = get_socket_labels(Procotol, Transport),
    ok = prometheus_counter:inc(bondy_sockets_opened_total, Labels),
    ok = prometheus_gauge:inc(bondy_sockets_total, Labels),
    {ok, State};

handle_event({socket_closed, Procotol, Transport, _Peername, Secs}, State) ->
    Labels = get_socket_labels(Procotol, Transport),
    ok = prometheus_counter:inc(bondy_sockets_closed_total, Labels),
    ok = prometheus_gauge:dec(bondy_sockets_total, Labels),
    ok = prometheus_histogram:observe(
        bondy_socket_duration_seconds, Labels, Secs),
    {ok, State};

handle_event({socket_error, Procotol, Transport, _Peername}, State) ->
    Labels = get_socket_labels(Procotol, Transport),
    ok = prometheus_counter:inc(bondy_socket_errors_total, Labels),
    ok = prometheus_gauge:dec(bondy_sockets_total, Labels),
    {ok, State};

handle_event({session_opened, Session}, State) ->
    RealmUri = bondy_session:realm_uri(Session),
    Labels = get_session_labels(RealmUri),
    ok = prometheus_counter:inc(bondy_sessions_opened_total, Labels),
    ok = prometheus_gauge:inc(bondy_sessions_total, Labels),
    {ok, State};

handle_event({session_closed, Session, DurationSecs}, State) ->
    RealmUri = bondy_session:realm_uri(Session),
    Labels = get_session_labels(RealmUri),
    ok = prometheus_counter:inc(bondy_sessions_closed_total, Labels),
    ok = prometheus_gauge:dec(bondy_sessions_total, Labels),
    ok = prometheus_histogram:observe(
        bondy_session_duration_seconds, Labels, DurationSecs
    ),
    {ok, State};

handle_event({wamp, #abort{} = M, Ctxt}, State) ->
    ok = observe_message(bondy_wamp_abort_messages_total, M, [], Ctxt),
    {ok, State};

handle_event({wamp, #authenticate{} = M, Ctxt}, State) ->
    ok = observe_message(bondy_wamp_authenticate_messages_total, M, [], Ctxt),
    {ok, State};

handle_event({wamp, #call{procedure_uri = Val} = M, Ctxt}, State) ->
    ok = observe_message(bondy_wamp_call_messages_total, M, [Val], Ctxt),
    {ok, State};

handle_event({wamp, #cancel{} = M, Ctxt}, State) ->
    ok = observe_message(bondy_wamp_cancel_messages_total, M, [], Ctxt),
    {ok, State};

handle_event({wamp, #challenge{} = M, Ctxt}, State) ->
    ok = observe_message(bondy_wamp_challenge_messages_total, M, [], Ctxt),
    {ok, State};

handle_event({wamp, #error{error_uri = Val} = M, Ctxt}, State) ->
    ok = observe_message(bondy_wamp_error_messages_total, M, [Val], Ctxt),
    {ok, State};

handle_event({wamp, #event{} = M, Ctxt}, State) ->
    ok = observe_message(bondy_wamp_event_messages_total, M, [], Ctxt),
    {ok, State};

handle_event({wamp, #goodbye{} = M, Ctxt}, State) ->
    ok = observe_message(bondy_wamp_goodbye_messages_total, M, [], Ctxt),
    {ok, State};

handle_event({wamp, #hello{} = M, Ctxt}, State) ->
    ok = observe_message(bondy_wamp_hello_messages_total, M, [], Ctxt),
    {ok, State};

handle_event({wamp, #interrupt{} = M, Ctxt}, State) ->
    ok = observe_message(bondy_wamp_interrupt_messages_total, M, [], Ctxt),
    {ok, State};

handle_event({wamp, #invocation{} = M, Ctxt}, State) ->
    ok = observe_message(bondy_wamp_invocation_messages_total, M, [], Ctxt),
    {ok, State};

handle_event({wamp, #publish{topic_uri = Val} = M, Ctxt}, State) ->
    ok = observe_message(bondy_wamp_publish_messages_total, M, [Val], Ctxt),
    {ok, State};

handle_event({wamp, #published{} = M, Ctxt}, State) ->
    ok = observe_message(bondy_wamp_published_messages_total, M, [], Ctxt),
    {ok, State};

handle_event({wamp, #register{procedure_uri = Val} = M, Ctxt}, State) ->
    ok = observe_message(bondy_wamp_register_messages_total, M, [Val], Ctxt),
    {ok, State};

handle_event({wamp, #registered{} = M, Ctxt}, State) ->
    ok = observe_message(bondy_wamp_registered_messages_total, M, [], Ctxt),
    {ok, State};

handle_event({wamp, #result{} = M, Ctxt}, State) ->
    ok = observe_message(bondy_wamp_result_messages_total, M, [], Ctxt),
    {ok, State};

handle_event({wamp, #subscribe{topic_uri = Val} = M, Ctxt}, State) ->
    ok = observe_message(bondy_wamp_subscribe_messages_total, M, [Val], Ctxt),
    {ok, State};

handle_event({wamp, #subscribed{} = M, Ctxt}, State) ->
    ok = observe_message(bondy_wamp_subscribed_messages_total, M, [], Ctxt),
    {ok, State};

handle_event({wamp, #unregister{} = M, Ctxt}, State) ->
    ok = observe_message(bondy_wamp_unregister_messages_total, M, [], Ctxt),
    {ok, State};

handle_event({wamp, #unregistered{} = M, Ctxt}, State) ->
    ok = observe_message(bondy_wamp_unregistered_messages_total, M, [], Ctxt),
    {ok, State};

handle_event({wamp, #unsubscribe{} = M, Ctxt}, State) ->
    ok = observe_message(bondy_wamp_unsubscribe_messages_total, M, [], Ctxt),
    {ok, State};

handle_event({wamp, #unsubscribed{} = M, Ctxt}, State) ->
    ok = observe_message(bondy_wamp_unsubscribed_messages_total, M, [], Ctxt),
    {ok, State};

handle_event({wamp, #welcome{} = M, Ctxt}, State) ->
    ok = observe_message(bondy_wamp_welcome_messages_total, M, [], Ctxt),
    {ok, State};

handle_event({wamp, #yield{} = M, Ctxt}, State) ->
    ok = observe_message(bondy_wamp_yield_messages_total, M, [], Ctxt),
    {ok, State};

handle_event({send_error, Reason, M, Ctxt}, State) ->
    MessageType = element(1, M),
    Labels = [Reason, MessageType, get_labels_values(Ctxt)],
    ok = prometheus_counter:inc(bondy_send_errors_total, Labels),
    {ok, State};

handle_event(_Event, State) ->
    {ok, State}.


handle_call(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {reply, {error, {unsupported_call, Event}}, State}.


handle_info(_Info, State) ->
    {ok, State}.


terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



setup() ->
    ok = declare_metrics(),
    ok = declare_net_metrics(),
    ok = declare_session_metrics(),
    ok = declare_wamp_metrics(),
    ok = bondy_prometheus_cowboy_collector:setup(),
    Collectors = [
        prometheus_vm_memory_collector,
        prometheus_vm_statistics_collector,
        prometheus_vm_system_info_collector,
        oc_stat_exporter_prometheus
    ],
    _ = [prometheus_registry:register_collector(C) || C <- Collectors],
    ok.


get_labels(call) ->
    [procedure_uri | ?WAMP_MESSAGE_LABELS];

get_labels(error) ->
    [error_uri | ?WAMP_MESSAGE_LABELS];

get_labels(publish) ->
    [topic_uri | ?WAMP_MESSAGE_LABELS];

get_labels(register) ->
    [procedure_uri | ?WAMP_MESSAGE_LABELS];

get_labels(subscribe) ->
    [topic_uri | ?WAMP_MESSAGE_LABELS];

get_labels(_) ->
   ?WAMP_MESSAGE_LABELS.


%% @private
get_session_labels(RealmUri) ->
    [RealmUri, node_name()].


%% @private
get_socket_labels(Protocol, Transport) ->
    [
        node_name(),
        Protocol,
        Transport
    ].

%% @private
get_labels_values(Ctxt) ->
    {T, FT, E} = bondy_context:subprotocol(Ctxt),
    [
        get_realm_type(Ctxt),
        node_name(),
        wamp,
        T,
        FT,
        E
    ].


%% @private
get_realm_type(Ctxt) ->
    try bondy_context:realm_uri(Ctxt) of
        ?MASTER_REALM_URI -> master;
        _ -> user
    catch
        _:_ ->
            undefined
    end.


observe_message(Metric, M, LabelsValues, Ctxt) ->
    Size = erts_debug:flat_size(M) * 8,
    Labels = get_labels_values(Ctxt),
    AllLabels = lists:append(LabelsValues, Labels),
    ok = prometheus_counter:inc(bondy_wamp_messages_total, Labels),
    ok = prometheus_counter:inc(Metric, AllLabels),
    prometheus_histogram:observe(bondy_wamp_message_bytes, Labels, Size).


declare_metrics() ->
    _ = prometheus_counter:declare([
        {name, bondy_errors_total},
        {help,
            <<"The total number of errors in a bondy node since reset.">>},
        {labels, [reason | ?WAMP_MESSAGE_LABELS]}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_send_errors_total},
        {help,
            <<"The total number of router send errors in a bondy node since reset.">>},
        {labels, [reason, message_type | ?WAMP_MESSAGE_LABELS]}
    ]),
    ok.


declare_net_metrics() ->
    %% Sockets

    _ = prometheus_gauge:declare([
        {name, bondy_sockets_total},
        {help,
            <<"The number of active sockets on a bondy node.">>},
        {labels, [node, protocol, transport]}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_sockets_opened_total},
        {help,
            <<"The number of sockets opened on a bondy node since reset.">>},
        {labels, [node, protocol, transport]}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_sockets_closed_total},
        {help,
            <<"The number of sockets closed on a bondy node since reset.">>},
        {labels, [node, protocol, transport]}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_socket_errors_total},
        {help,
            <<"The number of socket errors on a bondy node since reset.">>},
        {labels, [node, protocol, transport]}
    ]),
    _ = prometheus_histogram:declare([
        {name, bondy_socket_duration_seconds},
        {buckets, seconds_duration_buckets()},
        {help,
            <<"A histogram of the duration of a socket.">>},
        {labels, [node, protocol, transport]}
    ]),

    %% Bytes

    _ = prometheus_counter:declare([
        {name, bondy_received_bytes},
        {help,
            <<"The total bytes received by a bondy node from clients since reset.">>},
        {labels, [node, protocol, transport, frame_type, encoding]}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_sent_bytes},
        {help,
            <<"The total bytes sent by a bondy node from clients  since reset.">>},
        {labels, [node, protocol, transport, frame_type, encoding]}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_cluster_received_bytes},
        {help,
            <<"The total bytes received by a bondy node from another node in the cluster since reset.">>},
        {labels, [node, protocol, transport, frame_type, encoding]}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_cluster_sent_bytes},
        {help,
            <<"The total bytes sent by a bondy node from another node in the cluster since reset.">>},
        {labels, [node, protocol, transport, frame_type, encoding]}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_cluster_dropped_bytes},
        {help,
            <<"The total bytes dropped by a bondy node from another node in the cluster since reset.">>},
        {labels, [node, protocol, transport, frame_type, encoding]}
    ]),

    ok.


declare_session_metrics() ->
    _ = prometheus_gauge:declare([
        {name, bondy_sessions_total},
        {help,
            <<"The number of active sessions on a bondy node since reset.">>},
        {labels, [realm_type, node]}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_sessions_opened_total},
        {help,
            <<"The number of sessions opened on a bondy node since reset.">>},
        {labels, [realm_type, node]}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_sessions_closed_total},
        {help,
            <<"The number of sessions closed on a bondy node since reset.">>},
        {labels, [realm_type, node]}
    ]),
    _ = prometheus_histogram:declare([
        {name, bondy_session_duration_seconds},
        {buckets, seconds_duration_buckets()},
        {help,
            <<"A histogram of the duration of sessions.">>},
        {labels, [realm_type, node]}
    ]),
    ok.

declare_wamp_metrics() ->
    _ = prometheus_counter:declare([
        {name, bondy_wamp_messages_total},
        {help,
            <<"The total number of wamp messages routed by a bondy node since reset.">>},
        {labels, ?WAMP_MESSAGE_LABELS}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_abort_messages_total},
        {help, <<"The total number of abort messages routed by a bondy node since reset.">>},
        {labels, get_labels(abort)}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_authenticate_messages_total},
        {help, <<"The total number of authenticate messages routed by a bondy node since reset.">>},
        {labels, get_labels(authenticate)}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_call_messages_total},
        {help, <<"The total number of call messages routed by a bondy node since reset.">>},
        {labels, get_labels(call)}
    ]),
    _ = prometheus_histogram:declare([
        {name, bondy_wamp_call_latency_milliseconds},
        {buckets, milliseconds_duration_buckets()},
        {help,
            <<"A histogram of routed RPC response latencies. This measurement reflects the time between the dealer processing a WAMP call message and the first response (WAMP result or error).">>},
        {labels, get_labels(call)}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_call_retries_total},
        {help, <<"The total number of retries for WAMP call.">>},
        {labels, get_labels(call)}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_cancel_messages_total},
        {help, <<"The total number of cancel messages routed by a bondy node since reset.">>},
        {labels, get_labels(cancel)}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_challenge_messages_total},
        {help, <<"The total number of challenge messages routed by a bondy node since reset.">>},
        {labels, get_labels(challenge)}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_error_messages_total},
        {help, <<"The total number of error messages routed by a bondy node since reset.">>},
        {labels, get_labels(error)}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_event_messages_total},
        {help, <<"The total number of event messages routed by a bondy node since reset.">>},
        {labels, get_labels(event)}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_goodbye_messages_total},
        {help, <<"The total number of goodbye messages routed by a bondy node since reset.">>},
        {labels, get_labels(goodbye)}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_hello_messages_total},
        {help, <<"The total number of hello messages routed by a bondy node since reset.">>},
        {labels, get_labels(hello)}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_interrupt_messages_total},
        {help, <<"The total number of interrupt messages routed by a bondy node since reset.">>},
        {labels, get_labels(interrupt)}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_invocation_messages_total},
        {help, <<"The total number of invocation messages routed by a bondy node since reset.">>},
        {labels, get_labels(invocation)}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_publish_messages_total},
        {help, <<"The total number of publish messages routed by a bondy node since reset.">>},
        {labels, get_labels(publish)}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_published_messages_total},
        {help, <<"The total number of published messages routed by a bondy node since reset.">>},
        {labels, get_labels(published)}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_register_messages_total},
        {help, <<"The total number of register messages routed by a bondy node since reset.">>},
        {labels, get_labels(register)}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_registered_messages_total},
        {help, <<"The total number of registered messages routed by a bondy node since reset.">>},
        {labels, get_labels(registered)}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_result_messages_total},
        {help, <<"The total number of result messages routed by a bondy node since reset.">>},
        {labels, get_labels(result)}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_subscribe_messages_total},
        {help, <<"The total number of subscribe messages routed by a bondy node since reset.">>},
        {labels, get_labels(subscribe)}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_subscribed_messages_total},
        {help, <<"The total number of subscribed messages routed by a bondy node since reset.">>},
        {labels, get_labels(subscribed)}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_unregister_messages_total},
        {help, <<"The total number of unregister messages routed by a bondy node since reset.">>},
        {labels, get_labels(unregister)}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_unregistered_messages_total},
        {help, <<"The total number of unregistered messages routed by a bondy node since reset.">>},
        {labels, get_labels(unregistered)}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_unsubscribe_messages_total},
        {help, <<"The total number of unsubscribe messages routed by a bondy node since reset.">>},
        {labels, get_labels(unsubscribe)}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_unsubscribed_messages_total},
        {help, <<"The total number of unsubscribed messages routed by a bondy node since reset.">>},
        {labels, get_labels(unsubscribed)}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_welcome_messages_total},
        {help, <<"The total number of welcome messages routed by a bondy node since reset.">>},
        {labels, get_labels(welcome)}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_yield_messages_total},
        {help, <<"The total number of yield messages routed by a bondy node since reset.">>},
        {labels, get_labels(yield)}
    ]),

    _ = prometheus_histogram:declare([
        {name, bondy_wamp_message_bytes},
        {help,
            <<"A summary of the size of the wamp messages received by a bondy node">>},
        {buckets, bytes_bucket()},
        {labels, ?WAMP_MESSAGE_LABELS}
     ]),
    ok.




node_name() ->
    bondy_config:node().


bytes_bucket() ->
    %% 0 to 8 Mbs
    [0, 1024, 1024*4, 1024*16, 1024*32, 1024*64, 1024*128, 1024*256, 1024*512, 1024*1024, 1024*1024*2, 1024*1024*4, 1024*1024*8].





%% =============================================================================
%% PRIVATE BONDY COLLECTOR
%% =============================================================================



%% @private
collector_metrics() ->
    lists:append([
        registry_metrics()
    ]).

%% @private
registry_metric(size, Labels, Value) ->
    Help = "The total number of elements in a trie.",
    {registry_trie_elements, gauge, Help, Labels, Value};

registry_metric(nodes, Labels, Value) ->
    Help = "The total number of modes in a trie.",
    {registry_trie_nodes, gauge, Help, Labels, Value};

registry_metric(memory, Labels, Value) ->
    Help = "The total number of modes in a trie.",
    {registry_trie_nodes, gauge, Help, Labels, Value}.


%% @private
registry_metrics() ->
    Info = bondy_registry:info(),
    L = [
        registry_metric(K, [{name, Name}], V)
        || {Name, PL} <- Info,  {K, V} <- PL, K =/= owner andalso K =/= heir
    ],
    [
        {registry_tries, gauge, "Registry tries count.", length(Info)}
        | L
    ].


%% Used by promethues METRIC_NAME macro
-define(METRIC_NAME_PREFIX, "bondy_").

%% @private
add_metric_family({Name, Type, Help, Metrics}, Callback) ->
    %% METRIC_NAME uses the METRIC_NAME_PREFIX
    Callback(create_mf(?METRIC_NAME(Name), Help, Type, Metrics)).

%% @private
enabled_metrics() ->
    application:get_env(prometheus, bondy_prometheus_metrics, all).


%% @private
metric_enabled(Name, Metrics) ->
    Metrics =:= all orelse lists:member(Name, Metrics).