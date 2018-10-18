%% =============================================================================
%%  bondy_prometheus - this module is used to configure the prometheus metrics
%%  and export the prometheus report.
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
-include_lib("wamp/include/wamp.hrl").

-define(WAMP_MESSAGE_LABELS, [
    realm, node, protocol, transport, frame_type, encoding
]).

-export([init/0]).
-export([report/0]).
-export([wamp_message/2]).
-export([socket_open/3]).
-export([socket_closed/4]).
-export([socket_error/3]).
-export([days_duration_buckets/0]).
-export([hours_duration_buckets/0]).
-export([minutes_duration_buckets/0]).
-export([seconds_duration_buckets/0]).
-export([milliseconds_duration_buckets/0]).
-export([microseconds_duration_buckets/0]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
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
    [0, 1, 2, 5, 10, 15,
      25, 50, 75, 100, 150, 200, 250, 300, 400,
      500, 750, 1000, 1500, 2000, 2500, 3000, 4000, 5000].

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
microseconds_duration_buckets() ->
    [10, 25, 50, 100, 250, 500,
      1000, 2500, 5000, 10000, 25000, 50000, 100000, 250000, 500000,
      1000000, 2500000, 5000000, 10000000].



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec socket_open(
    Protocol :: atom(), Transport :: atom(), Peername :: binary()) -> ok.

socket_open(Procotol, Transport, Peername) ->
    Labels = get_socket_labels(Procotol, Transport, Peername),
    ok = prometheus_counter:inc(bondy_sockets_opened_total, Labels),
    prometheus_gauge:inc(bondy_sockets_total, Labels).

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec socket_closed(
    Protocol :: atom(), Transport:: atom(),
    Peername :: binary(), Seconds :: integer()) -> ok.

socket_closed(Procotol, Transport, Peername, Seconds) ->
    Labels = get_socket_labels(Procotol, Transport, Peername),
    ok = prometheus_counter:inc(bondy_sockets_closed_total, Labels),
    ok = prometheus_gauge:dec(bondy_sockets_total, Labels),
    prometheus_histogram:observe(
        bondy_socket_duration_seconds, Labels, Seconds).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec socket_error(
    Protocol :: atom(), Transport:: atom(), Peername :: binary()) -> ok.

socket_error(Procotol, Transport, Peername) ->
    Labels = get_socket_labels(Procotol, Transport, Peername),
    ok = prometheus_counter:inc(bondy_socket_errors_total, Labels),
    prometheus_gauge:dec(bondy_sockets_total, Labels).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec wamp_message(wamp_message:message(), bondy_context:t()) -> ok.

wamp_message(#abort{} = M, Ctxt) ->
    wamp_message(bondy_wamp_abort_messages_total, M, [], Ctxt);

wamp_message(#authenticate{} = M, Ctxt) ->
    wamp_message(bondy_wamp_authenticate_messages_total, M, [], Ctxt);

wamp_message(#call{procedure_uri = Val} = M, Ctxt) ->
    wamp_message(bondy_wamp_call_messages_total, M, [Val], Ctxt);

wamp_message(#cancel{} = M, Ctxt) ->
    wamp_message(bondy_wamp_cancel_messages_total, M, [], Ctxt);

wamp_message(#challenge{} = M, Ctxt) ->
    wamp_message(bondy_wamp_challenge_messages_total, M, [], Ctxt);

wamp_message(#error{error_uri = Val} = M, Ctxt) ->
    wamp_message(bondy_wamp_error_messages_total, M, [Val], Ctxt);

wamp_message(#event{} = M, Ctxt) ->
    wamp_message(bondy_wamp_event_messages_total, M, [], Ctxt);

wamp_message(#goodbye{} = M, Ctxt) ->
    wamp_message(bondy_wamp_goodbye_messages_total, M, [], Ctxt);

wamp_message(#hello{} = M, Ctxt) ->
    wamp_message(bondy_wamp_hello_messages_total, M, [], Ctxt);

wamp_message(#interrupt{} = M, Ctxt) ->
    wamp_message(bondy_wamp_interrupt_messages_total, M, [], Ctxt);

wamp_message(#invocation{} = M, Ctxt) ->
    wamp_message(bondy_wamp_invocation_messages_total, M, [], Ctxt);

wamp_message(#publish{topic_uri = Val} = M, Ctxt) ->
    wamp_message(bondy_wamp_publish_messages_total, M, [Val], Ctxt);

wamp_message(#published{} = M, Ctxt) ->
    wamp_message(bondy_wamp_published_messages_total, M, [], Ctxt);

wamp_message(#register{procedure_uri = Val} = M, Ctxt) ->
    wamp_message(bondy_wamp_register_messages_total, M, [Val], Ctxt);

wamp_message(#registered{} = M, Ctxt) ->
    wamp_message(bondy_wamp_registered_messages_total, M, [], Ctxt);

wamp_message(#result{} = M, Ctxt) ->
    wamp_message(bondy_wamp_result_messages_total, M, [], Ctxt);

wamp_message(#subscribe{topic_uri = Val} = M, Ctxt) ->
    wamp_message(bondy_wamp_subscribe_messages_total, M, [Val], Ctxt);

wamp_message(#subscribed{} = M, Ctxt) ->
    wamp_message(bondy_wamp_subscribed_messages_total, M, [], Ctxt);

wamp_message(#unregister{} = M, Ctxt) ->
    wamp_message(bondy_wamp_unregister_messages_total, M, [], Ctxt);

wamp_message(#unregistered{} = M, Ctxt) ->
    wamp_message(bondy_wamp_unregistered_messages_total, M, [], Ctxt);

wamp_message(#unsubscribe{} = M, Ctxt) ->
    wamp_message(bondy_wamp_unsubscribe_messages_total, M, [], Ctxt);

wamp_message(#unsubscribed{} = M, Ctxt) ->
    wamp_message(bondy_wamp_unsubscribed_messages_total, M, [], Ctxt);

wamp_message(#welcome{} = M, Ctxt) ->
    wamp_message(bondy_wamp_welcome_messages_total, M, [], Ctxt);

wamp_message(#yield{} = M, Ctxt) ->
    wamp_message(bondy_wamp_yield_messages_total, M, [], Ctxt).




%% =============================================================================
%% PRIVATE
%% =============================================================================




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


get_socket_labels(Protocol, Transport, Peername) ->
    [
        node_name(),
        Protocol,
        Transport,
        Peername
    ].


get_labels_values(Ctxt) ->
    {T, FT, E} = bondy_context:subprotocol(Ctxt),
    [
        get_realm(Ctxt),
        node_name(),
        wamp,
        T,
        FT,
        E
    ].

%% @private
get_realm(Ctxt) ->
    try
        bondy_context:realm_uri(Ctxt)
    catch
        _:_ ->
            undefined
    end.



wamp_message(Metric, M, LabelsValues, Ctxt) ->
    Size = erts_debug:flat_size(M) * 8,
    Labels = get_labels_values(Ctxt),
    AllLabels = lists:append(LabelsValues, Labels),
    ok = prometheus_counter:inc(bondy_wamp_messages_total, Labels),
    ok = prometheus_counter:inc(Metric, AllLabels),
    prometheus_histogram:observe(bondy_wamp_message_bytes, Labels, Size).


net_metrics() ->
    %% Sockets

    _ = prometheus_gauge:declare([
        {name, bondy_sockets_total},
        {help,
            <<"The number of active sockets on a bondy node.">>},
        {labels, [node, protocol, transport, peername]}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_sockets_opened_total},
        {help,
            <<"The number of sockets opened on a bondy node since reset.">>},
        {labels, [node, protocol, transport, peername]}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_sockets_closed_total},
        {help,
            <<"The number of sockets closed on a bondy node since reset.">>},
        {labels, [node, protocol, transport, peername]}
    ]),
    _ = prometheus_counter:declare([
        {name, bondy_socket_errors_total},
        {help,
            <<"The number of socket errors on a bondy node since reset.">>},
        {labels, [node, protocol, transport, peername]}
    ]),
    _ = prometheus_histogram:declare([
        {name, bondy_socket_duration_seconds},
        {help,
            <<"A histogram of the duration of a socket.">>},
        {labels, [node, protocol, transport, peername]}
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
    bondy_peer_service:mynode().


bytes_bucket() ->
    %% 0 to 8 Mbs
    [0, 1024, 1024*4, 1024*16, 1024*32, 1024*64, 1024*128, 1024*256, 1024*512, 1024*1024, 1024*1024*2, 1024*1024*4, 1024*1024*8].


