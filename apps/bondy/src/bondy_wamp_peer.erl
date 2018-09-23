%% =============================================================================
%%  bondy_wamp_peer.erl -
%%
%%  Copyright (c) 2016-2018 Ngineo Limited t/a Leapsight. All rights reserved.
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
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_wamp_peer).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").

-define(SEND_TIMEOUT, 20000).

-define(LOCAL_TRANSPORT_SPEC, #{
    connection_process => #{
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => pid
    },
    encoding => #{
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => {in, ?WAMP_ENCODINGS}
    },
    peername => #{
        required => true,
        allow_null => false,
        allow_undefined => false,
        validator => fun
            ({IP, Port})
            when (tuple_size(IP) == 4 orelse tuple_size(IP) == 8)
            andalso Port >= 0, Port =< 65535 ->
                true;
            (_) ->
                false
        end
    },
    transport => #{
        required => false,
        allow_null => false,
        allow_undefined => true,
        datatype => {in, [ws, raw, http]}
    },
    transport_mod => #{
        required => false,
        allow_null => false,
        allow_undefined => true,
        datatype => atom
    },
    socket => #{
        required => false,
        allow_null => false,
        allow_undefined => true
    }
}).


-record(bondy_local_wamp_peer, {
    realm_uri               ::  binary(),
    node                    ::  atom(),
    session_id              ::  integer() | undefined,
    pid                     ::  pid(), % connection pid
    peername                ::  {inet:ip_address(), non_neg_integer()},
    encoding                ::  encoding(),
    transport               ::  transport() | http,
    transport_mod           ::  module() | undefined,
    socket                  ::  any() | undefined
}).

-record(bondy_remote_wamp_peer, {
    realm_uri       ::  binary(),
    node            ::  atom(),
    session_id      ::  integer() | undefined,
    pid             ::  list() | undefined
}).


-opaque t()                 ::  local() | remote().
-type local()               ::  #bondy_local_wamp_peer{}.
-type remote()              ::  #bondy_remote_wamp_peer{}.
-type transport_info()      ::  #{
    peername => {inet:ip_address(), non_neg_integer()},
    transport => transport(),
    transport_mod => module(),
    socket => any(),
    connection_process => pid(),
    peername => {inet:ip_address(), non_neg_integer()},
    encoding => encoding()
}.


-export_type([local/0]).
-export_type([remote/0]).
-export_type([transport_info/0]).
-export_type([t/0]).

-export([ack/2]).
-export([encoding/1]).
-export([is_local_connection_alive/1]).
-export([is_local/1]).
-export([is_peer/1]).
-export([is_remote/1]).
-export([new/2]).
-export([new/3]).
-export([new/4]).
-export([node/1]).
-export([pid/1]).
-export([realm_uri/1]).
-export([send/2]).
-export([send/3]).
-export([send/4]).
-export([session_id/1]).
-export([set_session_id/2]).
-export([socket/1]).
-export([peername/1]).
-export([to_remote/1]).
-export([transport/1]).
-export([transport_mod/1]).



%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc Creates a new remote wamp peer object.
%% @end
%% -----------------------------------------------------------------------------
new(Realm, Node) ->
    #bondy_remote_wamp_peer{realm_uri = Realm, node = Node}.

%% -----------------------------------------------------------------------------
%% @doc Creates a local wamp peer with no session, this is to support local
%% internal processes
%% @end
%% -----------------------------------------------------------------------------
new(Realm, Node, Pid) when is_pid(Pid) ->
    #bondy_local_wamp_peer{
        realm_uri = Realm,
        node = Node,
        pid = Pid
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(uri(), atom(), id(), transport_info() | pid()) -> t().
new(Realm, Node, SessionId, TransportInfo) when is_map(TransportInfo), is_integer(SessionId) ->
    Node =:= bondy_peer_service:mynode() orelse error(badarg),
    #{
        peername := Peername,
        encoding := Encoding,
        connection_process := Pid
    } = validate_transport(TransportInfo, ?LOCAL_TRANSPORT_SPEC),
    #bondy_local_wamp_peer{
        realm_uri = Realm,
        node = Node,
        session_id = SessionId,
        pid = Pid,
        peername = Peername,
        encoding = Encoding,
        transport_mod = maps:get(transport_mod, TransportInfo, undefined),
        transport = maps:get(transport, TransportInfo, undefined),
        socket = maps:get(socket, TransportInfo, undefined)
    };

new(Realm, Node, SessionId, Pid) when is_pid(Pid) orelse Pid =:= undefined ->
    Node =/= bondy_peer_service:mynode() orelse error(badarg),
    #bondy_remote_wamp_peer{
        realm_uri = Realm,
        node = Node,
        session_id = SessionId,
        pid = Pid
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
to_remote(#bondy_local_wamp_peer{} = Peer) ->
    #bondy_remote_wamp_peer{
        realm_uri = Peer#bondy_local_wamp_peer.realm_uri,
        node = Peer#bondy_local_wamp_peer.node,
        session_id = Peer#bondy_local_wamp_peer.session_id,
        pid = undefined
    };

to_remote(#bondy_remote_wamp_peer{} = Peer) ->
    Peer.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
is_peer(#bondy_local_wamp_peer{}) -> true;
is_peer(#bondy_remote_wamp_peer{}) -> true;
is_peer(_) -> false.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
is_local_connection_alive(#bondy_local_wamp_peer{pid = Pid}) ->
    erlang:is_process_alive(Pid).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
is_local(#bondy_local_wamp_peer{}) -> true;
is_local(#bondy_remote_wamp_peer{}) -> false.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
is_remote(#bondy_local_wamp_peer{}) -> false;
is_remote(#bondy_remote_wamp_peer{}) -> true.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
realm_uri(#bondy_local_wamp_peer{realm_uri = Val}) -> Val;
realm_uri(#bondy_remote_wamp_peer{realm_uri = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
node(#bondy_local_wamp_peer{node = Val}) -> Val;
node(#bondy_remote_wamp_peer{node = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
encoding(#bondy_local_wamp_peer{encoding = Val}) -> Val;
encoding(#bondy_remote_wamp_peer{}) -> undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
session_id(#bondy_local_wamp_peer{session_id = Val}) -> Val;
session_id(#bondy_remote_wamp_peer{session_id = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
set_session_id(#bondy_local_wamp_peer{} = P, Val) ->
    P#bondy_local_wamp_peer{session_id = Val};

set_session_id(#bondy_remote_wamp_peer{} = P, Val) ->
    P#bondy_remote_wamp_peer{session_id = Val}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
pid(#bondy_local_wamp_peer{pid = Val}) -> Val;
pid(#bondy_remote_wamp_peer{pid = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
transport(#bondy_local_wamp_peer{transport = Val}) -> Val;
transport(#bondy_remote_wamp_peer{}) -> undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
transport_mod(#bondy_local_wamp_peer{transport_mod = Val}) -> Val;
transport_mod(#bondy_remote_wamp_peer{}) -> undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
socket(#bondy_local_wamp_peer{socket = Val}) -> Val;
socket(#bondy_remote_wamp_peer{}) -> undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec peername(t()) -> {inet:ip_address(), non_neg_integer()} | undefined.

peername(#bondy_local_wamp_peer{peername = Val}) ->
    Val;

peername(#bondy_remote_wamp_peer{}) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% Acknowledges the reception of a WAMP message. This function should be used by
%% the peer transport module to acknowledge the reception of a message sent with
%% {@link send/3}.
%% @end
%% -----------------------------------------------------------------------------
-spec ack(pid(), reference()) -> ok.

ack(Pid, _) when Pid =:= self()  ->
    %% We do not need to send an ack (implicit ack send case)
    ok;

ack(Pid, Ref) when is_pid(Pid), is_reference(Ref) ->
    Pid ! {?BONDY_PEER_ACK, Ref},
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% Sends a message to a WAMP peer.
%% It calls `send/3' with a an empty map for Options.
%% @end
%% -----------------------------------------------------------------------------
-spec send(t(), wamp_message()) -> ok.

send(Peer, M) ->
    send(Peer, M, #{}).


%% -----------------------------------------------------------------------------
%% @doc
%% Sends a message to a local WAMP peer.
%% If the transport is not open it fails with an exception.
%% This function is used by the router (dealer | broker) to send WAMP messages
%% to local peers.
%% Opts is a map with the following keys:
%%
%% * timeout - timeout in milliseconds (defaults to 10000)
%% * enqueue (boolean) - if the peer is not reachable and this value is true,
%% bondy will enqueue the message so that the peer can resume the session and
%% consume all enqueued messages.
%%
%% @end
%% -----------------------------------------------------------------------------
-spec send(t(), wamp_message(), map()) -> ok | no_return().

send(#bondy_local_wamp_peer{} = Peer, M, Opts0) ->
    wamp_message:is_message(M) orelse error(invalid_wamp_message),
    do_send(Peer, M, validate_send_opts(Opts0));

send(#bondy_remote_wamp_peer{}, M, _) ->
    wamp_message:is_message(M) orelse error(invalid_wamp_message),
    error(not_my_node).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec send(t(), t(), wamp_message(), map()) -> ok | no_return().

send(
    #bondy_local_wamp_peer{realm_uri = R, node = N},
    #bondy_local_wamp_peer{realm_uri = R, node = N} = To,
    M,
    Opts0) ->
    %% We validate the message failing with exception
    wamp_message:is_message(M) orelse error(invalid_wamp_message),
    do_send(To, M, validate_send_opts(Opts0));

send(
    #bondy_local_wamp_peer{realm_uri = R} = From,
    #bondy_remote_wamp_peer{realm_uri = R} = To,
    M,
    Opts0) ->
    %% We validate the message failing with exception
    wamp_message:is_message(M) orelse error(invalid_wamp_message),
    bondy_peer_wamp_forwarder:forward(From, To, M, validate_send_opts(Opts0)).



%% =============================================================================
%% PRIVATE
%% =============================================================================



validate_send_opts(Opts) ->
    maps_utils:validate(Opts, #{
        timeout => #{
            required => true,
            datatype => timeout,
            default => ?SEND_TIMEOUT
        },
        enqueue => #{
            required => true,
            datatype => boolean,
            default => false
        }
    }).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
do_send(#bondy_local_wamp_peer{pid = Pid}, M, _Opts)
when Pid =:= self() ->
    Pid ! {?BONDY_PEER_REQUEST, Pid, make_ref(), M},
    %% This is a sync message so we resolve this sequentially
    %% so we will not get an ack, the ack is implicit
    ok;

do_send(
    #bondy_local_wamp_peer{
        transport = raw, transport_mod = Mod, socket = Socket
    } = Peer,
    M, Opts)
    when Mod /= undefined andalso
    Socket /= undefined andalso
    not is_record(M, goodbye) ->
    %% We encode and send the message directly to the raw socket
    %% unless it fails in which case we try to enqueue

    Enc = Peer#bondy_local_wamp_peer.encoding,
    SessionId =  Peer#bondy_local_wamp_peer.session_id,
    Data = wamp_encoding:encode(M, Enc),


    case bondy_session_worker:send(SessionId, Data) of
        ok ->
            ok;
        {error, Reason} ->
            Enqueue = maps:get(enqueue, Opts) andalso is_record(M, event),
            maybe_enqueue(Enqueue, SessionId, M, {socket_error, Reason})
    end;

    %% Alt 1
    %% case Mod:send(Socket, ?RAW_FRAME(Data)) of
    %%     ok ->
    %%         ok;
    %%     {error, Reason} ->
    %%         Enqueue = maps:get(enqueue, Opts) andalso is_record(M, event),
    %%         SessionId =  Peer#bondy_local_wamp_peer.session_id,
    %%         maybe_enqueue(Enqueue, SessionId, M, {socket_error, Reason})
    %% end;

    %% Alt 2
    %% try
    %%     case erlang:port_command(Socket, ?RAW_FRAME(Data), [nosuspend]) of
    %%         false ->
    %%             %% Port busy and nosuspend option passed
    %%             throw(busy);
    %%         true ->
    %%             receive
    %%                 {inet_reply, Socket, ok} ->
    %%                     ok;
    %%                 {inet_reply, Socket, Status} ->
    %%                     throw(Status)
    %%             end
    %%     end
    %% catch
    %%     throw:Reason ->
    %%         Enqueue = maps:get(enqueue, Opts) andalso is_record(M, event),
    %%         SessionId =  Peer#bondy_local_wamp_peer.session_id,
    %%         maybe_enqueue(Enqueue, SessionId, M, {socket_error, Reason});
    %%     error:_Error ->
    %%         Reason = einval,
    %%         Enqueue = maps:get(enqueue, Opts) andalso is_record(M, event),
    %%         SessionId =  Peer#bondy_local_wamp_peer.session_id,
    %%         maybe_enqueue(Enqueue, SessionId, M, {socket_error, Reason})
    %% end;


do_send(#bondy_local_wamp_peer{} = Peer, M, Opts) ->
    Pid = Peer#bondy_local_wamp_peer.pid,
    SessionId = Peer#bondy_local_wamp_peer.session_id,
    Timeout = maps:get(timeout, Opts),

    %% Should we enqueue the message in case the process representing
    %% the WAMP peer no longer exists?
    Enqueue = maps:get(enqueue, Opts),

    MonitorRef = erlang:monitor(process, Pid),

    %% The following no longer applies, as the process should be local
    %% However, we keep it as it is still the right thing to do
    %% ----------------------
    %% If the monitor/2 call failed to set up a connection to a
    %% remote node, we don't want the '!' operator to attempt
    %% to set up the connection again. (If the monitor/2 call
    %% failed due to an expired timeout, '!' too would probably
    %% have to wait for the timeout to expire.) Therefore,
    %% use erlang:send/3 with the 'noconnect' option so that it
    %% will fail immediately if there is no connection to the
    %% remote node.
    erlang:send(Pid, {?BONDY_PEER_REQUEST, self(), MonitorRef, M}, [noconnect]),

    receive
        {'DOWN', MonitorRef, process, Pid, Reason} ->
            %% The peer no longer exists
            maybe_enqueue(Enqueue, SessionId, M, Reason);
        {?BONDY_PEER_ACK, MonitorRef} ->
            %% The peer received the message and acked it using ack/2
            true = erlang:demonitor(MonitorRef, [flush]),
            ok
    after
        Timeout ->
            true = erlang:demonitor(MonitorRef, [flush]),
            maybe_enqueue(Enqueue, SessionId, M, timeout)
    end.


%% @private
maybe_enqueue(true, _SessionId, _M, _) ->
    %% TODO Enqueue for session resumption
    ok;

maybe_enqueue(false, SessionId, M, Reason) ->
    _ = lager:info(
        "Could not deliver message to WAMP peer; "
        "reason=~p, session_id=~p, message_type=~p",
        [Reason, SessionId, element(1, M)]
    ),
    ok.


%% @private
validate_transport(Map0, Spec) ->
    Map1 = maps_utils:validate(Map0, Spec),
    case maps:get(socket, Map1, undefined) of
        undefined ->
            Map1;
        Socket ->
            {ok, Peername} = inet:peername(Socket),
            maps:put(peername, Peername, Map1)
    end.


