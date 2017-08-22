%% =============================================================================
%%  Untitled-1 -
%%
%%  Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
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
%% We follow https://prometheus.io/docs/practices/naming/
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_prometheus).

-export([init/0]).
%% -export([update/1]).
%% -export([update/2]).

init() ->
    ok = node_metrics(),
    ok = net_metrics(),
    ok = wamp_metrics(),
    ok = prometheus_registry:register_collector(prometheus_vm_memory_collector),
    ok = prometheus_registry:register_collector(prometheus_vm_statistics_collector),
    prometheus_registry:register_collector(prometheus_vm_system_info_collector).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
%% -spec update(tuple()) -> ok.

%% update(Event) ->
%%     do_update(Event).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
%% -spec update(wamp_message:message(), bondy_context:context()) -> ok.

%% update(M, #{peer := {IP, _}} = Ctxt) ->
%%     Metric = to_metric_name(element(1, M))
%%     Size = erts_debug:flat_size(M) * 8,
%%     case Ctxt of
%%         #{realm_uri := Uri, session := S} ->
%%             Id = bondy_session:id(S),
%%             do_update({message, Id, Uri, IP, Type, Size});
%%         #{realm_uri := Uri} ->
%%             do_update({message, Uri, IP, Type, Size});
%%         _ ->
%%             do_update({message, IP, Type, Size})
%%     end.



%% =============================================================================
%% PRIVATE
%% =============================================================================



net_metrics() ->
    %% Sockets

    _ = prometheus_gauge:declare([
        {name, bondy_sockets_total},
        {help,
            <<"The number of active sockets on a bondy node.">>},
        {labels, [node, protocol, transport, frame_type, encoding]}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_sockets_opened_total},
        {help,
            <<"The number of sockets opened on a bondy node since reset.">>},
        {labels, [node, protocol, transport, frame_type, encoding]}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_sockets_closed_total},
        {help,
            <<"The number of sockets closed on a bondy node since reset.">>},
        {labels, [node, protocol, transport, frame_type, encoding]}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_socket_errors_total},
        {help,
            <<"The number of socket errors on a bondy node since reset.">>},
        {labels, [node, protocol, transport, frame_type, encoding]}
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


node_metrics() ->
    %% Counters
    _ = prometheus_histogram:declare([
            {name, bondy_session_duration},
            {buckets, microseconds_duration_buckets()},
            {labels, [db, type]},
            {help, ""},
            {duration_unit, seconds}]),
    ok.


wamp_metrics() ->
    _ = prometheus_counter:declare([
        {name, bondy_wamp_messages},
        {help,
            <<"The total number of wamp messages routed by a bondy node since reset.">>},
        {labels, [node, protocol, transport, frame_type, encoding]}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_abort_messages_total},
        {help, <<"The total number of abort messages routed by a bondy node since reset.">>},
        {labels, []}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_authenticate_messages_total},
        {help, <<"The total number of authenticate messages routed by a bondy node since reset.">>},
        {labels, []}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_call_messages_total},
        {help, <<"The total number of call messages routed by a bondy node since reset.">>},
        {labels, []}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_cancel_messages_total},
        {help, <<"The total number of cancel messages routed by a bondy node since reset.">>},
        {labels, []}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_challenge_messages_total},
        {help, <<"The total number of challenge messages routed by a bondy node since reset.">>},
        {labels, []}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_error_messages_total},
        {help, <<"The total number of error messages routed by a bondy node since reset.">>},
        {labels, []}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_event_messages_total},
        {help, <<"The total number of event messages routed by a bondy node since reset.">>},
        {labels, []}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_goodbye_messages_total},
        {help, <<"The total number of goodbye messages routed by a bondy node since reset.">>},
        {labels, []}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_hello_messages_total},
        {help, <<"The total number of hello messages routed by a bondy node since reset.">>},
        {labels, []}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_interrupt_messages_total},
        {help, <<"The total number of interrupt messages routed by a bondy node since reset.">>},
        {labels, []}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_invocation_messages_total},
        {help, <<"The total number of invocation messages routed by a bondy node since reset.">>},
        {labels, []}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_publish_messages_total},
        {help, <<"The total number of publish messages routed by a bondy node since reset.">>},
        {labels, []}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_published_messages_total},
        {help, <<"The total number of published messages routed by a bondy node since reset.">>},
        {labels, []}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_register_messages_total},
        {help, <<"The total number of register messages routed by a bondy node since reset.">>},
        {labels, []}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_registered_messages_total},
        {help, <<"The total number of registered messages routed by a bondy node since reset.">>},
        {labels, []}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_result_messages_total},
        {help, <<"The total number of result messages routed by a bondy node since reset.">>},
        {labels, []}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_subscribe_messages_total},
        {help, <<"The total number of subscribe messages routed by a bondy node since reset.">>},
        {labels, []}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_subscribed_messages_total},
        {help, <<"The total number of subscribed messages routed by a bondy node since reset.">>},
        {labels, []}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_unregister_messages_total},
        {help, <<"The total number of unregister messages routed by a bondy node since reset.">>},
        {labels, []}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_unregistered_messages_total},
        {help, <<"The total number of unregistered messages routed by a bondy node since reset.">>},
        {labels, []}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_unsubscribe_messages_total},
        {help, <<"The total number of unsubscribe messages routed by a bondy node since reset.">>},
        {labels, []}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_unsubscribed_messages_total},
        {help, <<"The total number of unsubscribed messages routed by a bondy node since reset.">>},
        {labels, []}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_welcome_messages_total},
        {help, <<"The total number of welcome messages routed by a bondy node since reset.">>},
        {labels, []}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_wamp_yield_messages_total},
        {help, <<"The total number of yield messages routed by a bondy node since reset.">>},
        {labels, []}
    ]),

    _ = prometheus_summary:declare([
        {name, bondy_wamp_message_received_bytes},
        {help,
            <<"A summary of the size of the wamp messages received by a bondy node">>},
        {buckets, bytes_bucket()},
        {labels, [node, protocol, transport, frame_type, encoding]}
     ]),
    _ = prometheus_summary:declare([
        {name, bondy_wamp_message_sent_bytes},
        {help,
            <<"A summary of the size of the wamp messages sent by a bondy node">>},
        {buckets, bytes_bucket()},
        {labels, [node, transport, frame_type, encoding]}
        ]),
    ok.


%% to_metric_name(abort) ->           bondy_wamp_abort_messages_total;
%% to_metric_name(authenticate) ->    bondy_wamp_authenticate_messages_total;
%% to_metric_name(call) ->            bondy_wamp_call_messages_total;
%% to_metric_name(cancel) ->          bondy_wamp_cancel_messages_total;
%% to_metric_name(challenge) ->       bondy_wamp_challenge_messages_total;
%% to_metric_name(error) ->           bondy_wamp_error_messages_total;
%% to_metric_name(event) ->           bondy_wamp_event_messages_total;
%% to_metric_name(goodbye) ->         bondy_wamp_goodbye_messages_total;
%% to_metric_name(hello) ->           bondy_wamp_hello_messages_total;
%% to_metric_name(interrupt) ->       bondy_wamp_interrupt_messages_total;
%% to_metric_name(invocation) ->      bondy_wamp_invocation_messages_total;
%% to_metric_name(publish) ->         bondy_wamp_publish_messages_total;
%% to_metric_name(published) ->       bondy_wamp_published_messages_total;
%% to_metric_name(register) ->        bondy_wamp_register_messages_total;
%% to_metric_name(registered) ->      bondy_wamp_registered_messages_total;
%% to_metric_name(result) ->          bondy_wamp_result_messages_total;
%% to_metric_name(subscribe) ->       bondy_wamp_subscribe_messages_total;
%% to_metric_name(subscribed) ->      bondy_wamp_subscribed_messages_total;
%% to_metric_name(unregister) ->      bondy_wamp_unregister_messages_total;
%% to_metric_name(unregistered) ->    bondy_wamp_unregistered_messages_total;
%% to_metric_name(unsubscribe) ->     bondy_wamp_unsubscribe_messages_total;
%% to_metric_name(unsubscribed) ->    bondy_wamp_unsubscribed_messages_total;
%% to_metric_name(welcome) ->         bondy_wamp_welcome_messages_total;
%% to_metric_name(yield) ->           bondy_wamp_yield_messages_total.


%% node_name() ->
%%     list_to_binary(node()).


bytes_bucket() ->
    [4, 16, 32, 64, 128, 256, 512, 1024].

%% seconds_duration_buckets() ->
%%     [0, 1, 30, 60, 600, 1800, 3600].

microseconds_duration_buckets() ->
    [10, 25, 50, 100, 250, 500,
      1000, 2500, 5000, 10000, 25000, 50000, 100000, 250000, 500000,
      1000000, 2500000, 5000000, 10000000].


