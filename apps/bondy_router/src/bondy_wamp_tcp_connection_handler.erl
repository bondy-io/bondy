%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_tcp_connection_handler).
-moduledoc """
A ranch handler for the wamp protocol over either tcp or tls transports.
""".
-behaviour(gen_server).
-behaviour(ranch_protocol).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").

-define(TIMEOUT(S), S#state.idle_timeout).

-record(state, {
    listener :: atom(),
    socket :: gen_tcp:socket() | ssl:socket(),
    proxy_protocol :: bondy_tcp_proxy_protocol:t(),
    peername :: {inet:ip_address(), integer()},
    source_ip :: inet:ip_address(),
    transport :: module(),
    frame_type :: frame_type(),
    encoding :: atom(),
    max_len :: pos_integer(),
    %% The listener's resolved option block, handed over by
    %% `bondy_listener_ranch:stream_protocol_opts/2' at listener start. Held so
    %% the handshake can read `ping' out of it without a second lookup.
    opts = [] :: key_value:t(),
    idle_timeout :: timeout(),
    ping_idle_timeout :: non_neg_integer(),
    ping_tref :: optional(reference()),
    ping_payload :: binary(),
    %% Monotonic ms timestamp of the most recent router-initiated ping,
    %% used to observe the RTT when the matching pong arrives.
    ping_sent_at :: optional(integer()),
    ping_retry :: optional(bondy_retry:t()),
    hibernate = false :: boolean(),
    start_time :: integer(),
    active_n = once :: once | -32768..32767,
    buffer = <<>> :: binary(),
    shutdown_reason :: term() | undefined,
    protocol_state :: bondy_wamp_protocol:state() | undefined
}).

-type state() :: #state{}.

-export([start_link/3]).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).
-export([format_status/1]).

-ifdef(TEST).
%% Exposed so the "absent `enabled' means ping off" fall-through is pinned:
%% `bondy_listener_config:assert_ping_keys/4' stopped requiring `enabled'
%% BECAUSE of it, so the two have to be tested together.
-export([maybe_enable_ping/2]).
-endif.

%% =============================================================================
%% API
%% =============================================================================

-spec start_link(
    Ref :: ranch:ref(), Transport :: module(), ProtoOpts :: any()
) ->
    {ok, ConnPid :: pid()}
    | {ok, SupPid :: pid(), ConnPid :: pid()}.

start_link(Ref, Transport, Opts) ->
    {ok, proc_lib:spawn_link(?MODULE, init, [{Ref, Transport, Opts}])}.

%% =============================================================================
%% GEN SERVER CALLBACKS
%% =============================================================================

init({Ref, Transport, Opts}) ->
    ok = logger:update_process_metadata(#{
        listener => Ref,
        transport => Transport
    }),

    %% Connection processes are the highest fan-in mailboxes on a pub/sub
    %% workload (one EVENT per subscription per publication).
    _ = erlang:process_flag(
        message_queue_data,
        bondy_config:get([wamp_connection, message_queue_data], off_heap)
    ),

    %% Has to be called before the handshake.
    ProxyProtocol = bondy_tcp_proxy_protocol:init(Ref, 15_000),

    %% No per-connection TLS options: ranch already holds this listener's
    %% material, from the transport options the listen socket was bound with.
    {ok, Socket} = ranch:handshake(Ref),

    {PeerIP, _} = Peername = peername(Transport, Socket),

    SourceIP = source_ip(ProxyProtocol, PeerIP),

    %% throttle new connections per source IP (no-op unless enabled).
    %% Reject early by closing the just-accepted socket and terminating.
    %% `Ref` is the listener name — the listener-scope dimension.
    case bondy_rate_limit:throttle(connection, SourceIP, #{listener => Ref}) of
        throttled ->
            ?LOG_NOTICE(#{
                description => "TCP connection rejected (rate limit)",
                source_ip => inet:ntoa(SourceIP)
            }),
            try
                Transport:close(Socket)
            catch
                _:_ -> ok
            end,
            exit(normal);
        ok ->
            ok
    end,

    ok = logger:update_process_metadata(#{
        peername => inet_utils:peername_to_binary(Peername),
        source_ip => inet:ntoa(SourceIP)
    }),

    State = #state{
        listener = Ref,
        opts = Opts,
        %% From the listener's option block, resolved once at listener start.
        %% `bondy_listener_config:option_defaults/2` puts an `idle_timeout` in
        %% every raw-socket listener's spec, so the fallback here is for a
        %% listener started straight from `resolve/2` without option defaults —
        %% which is what several test cases do.
        idle_timeout = key_value:get(idle_timeout, Opts, infinity),
        start_time = erlang:monotonic_time(second),
        transport = Transport,
        socket = Socket,
        proxy_protocol = ProxyProtocol,
        peername = Peername,
        source_ip = SourceIP
    },

    %% Listener-level socket opts (nodelay, buffers, keepalive) are
    %% inherited from the listen socket, so only the per-connection
    %% receive settings are applied here.
    SocketOpts = [
        {active, active_n(State)},
        {packet, 0}
    ],

    %% If Transport == ssl, upgrades a gen_tcp, or equivalent, socket to an SSL
    %% socket by performing the TLS server-side handshake, returning a TLS
    %% socket.
    ok = maybe_exit(Transport:setopts(Socket, SocketOpts)),

    ok = socket_opened(State),

    ?LOG_INFO(#{
        description => "Established connection with client."
    }),

    gen_server:enter_loop(?MODULE, [], State, ?TIMEOUT(State)).

handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {noreply, State, ?TIMEOUT(State)}.

handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State, ?TIMEOUT(State)}.

%% Handle TCP & SSL handshake
handle_info(
    {Transport, Socket, <<?RAW_MAGIC:8, MaxLen:4, Encoding:4, _:16>>},
    #state{socket = Socket, protocol_state = undefined} = State0
) when
    Transport =:= tcp orelse Transport =:= ssl
->
    case handle_handshake(MaxLen, Encoding, State0) of
        {ok, State} ->
            case maybe_active_once(State) of
                ok ->
                    {noreply, reset_ping(State), ?TIMEOUT(State)};
                {error, Reason} ->
                    {stop, Reason, State}
            end;
        {stop, Reason, State} ->
            {stop, Reason, State}
    end;
%% Handle invalid TCP % SSL handshake
handle_info(
    {Transport, Socket, Data},
    #state{socket = Socket, protocol_state = undefined} = St
) when
    Transport =:= tcp orelse Transport =:= ssl
->
    %% RFC: After a _Client_ has connected to a _Router_, the _Router_ will
    %% first receive the 4 octets handshake request from the _Client_.
    %% If the _first octet_ differs from "0x7F", it is not a WAMP-over-
    %% RawSocket request. Unless the _Router_ also supports other
    %% transports on the connecting port (such as WebSocket), the
    %% _Router_ MUST *fail the connection*.
    ?LOG_WARNING(#{
        description => "Received data before WAMP protocol handshake",
        reason => invalid_handshake,
        data => Data
    }),
    {stop, invalid_handshake, St};
%% Handle TCP & SSL data
handle_info({Transport, Socket, Data}, #state{socket = Socket} = State0) when
    Transport =:= tcp orelse Transport =:= ssl
->
    %% We append the newly received data to the existing buffer
    Buffer = State0#state.buffer,
    State1 = State0#state{buffer = <<>>},

    case handle_inbound(<<Buffer/binary, Data/binary>>, State1) of
        {ok, State} ->
            case maybe_active_once(State1) of
                ok ->
                    {noreply, reset_ping(State), ?TIMEOUT(State)};
                {error, Reason} ->
                    {stop, Reason, State}
            end;
        {stop, Reason, State} ->
            {stop, Reason, disable_ping(State)}
    end;
handle_info({tcp_passive, Socket}, #state{socket = Socket} = State) ->
    %% We are using {active, N} and we consumed N messages from the socket
    ok = reset_inet_opts(State),
    {noreply, State, ?TIMEOUT(State)};
handle_info({tcp_closed, _Socket}, State) ->
    {stop, normal, State};
handle_info({tcp_error, _, _} = Reason, State) ->
    {stop, Reason, State};
%% SSL control message handlers
handle_info({ssl_passive, Socket}, #state{socket = Socket} = State) ->
    %% We are using {active, N} and we consumed N messages from the socket
    ok = reset_inet_opts(State),
    {noreply, State, ?TIMEOUT(State)};
handle_info({ssl_closed, _Socket}, State) ->
    {stop, normal, State};
handle_info({ssl_error, _, _} = Reason, State) ->
    {stop, Reason, State};
handle_info({?BONDY_REQ, Pid, _RealmUri, M}, St) when Pid =:= self() ->
    %% Here we receive a message from the bondy_router in those cases
    %% in which the router is embodied by our process i.e. the sync part
    %% of a routing process e.g. wamp calls
    handle_outbound(M, St);
handle_info({?BONDY_REQ, _Pid, _RealmUri, M}, St) ->
    %% Here we receive the messages that either the router or another peer
    %% have sent to us using bondy:send/2,3
    %% ok = bondy:ack(Pid, Ref),
    %% We send the message to the peer
    handle_outbound(M, St);
handle_info(
    {timeout, Ref, ping_idle_timeout}, #state{ping_tref = Ref} = State
) ->
    ?LOG_DEBUG(#{
        description => "Connection timeout, sending first ping",
        attempts => bondy_retry:count(State#state.ping_retry)
    }),

    %% ping_idle_timeout (not to be confused with idle_timeout)
    %% We avoid using the gen_server timeout as the ping has already a timer
    maybe_send_ping(State);
handle_info({timeout, Ref, ping_timeout}, #state{ping_tref = Ref} = State) ->
    ?LOG_DEBUG(#{
        description => "Ping timeout, retrying ping",
        attempts => bondy_retry:count(State#state.ping_retry)
    }),
    %% We will retry or fail depending on retry configuration and state
    maybe_send_ping(State);
handle_info({timeout, Ref, Msg}, State) ->
    ?LOG_DEBUG(#{
        description => "Received unknown timeout",
        message => Msg,
        ref => Ref
    }),
    {noreply, State};
handle_info({stop, Reason}, State) ->
    {stop, Reason, State};
handle_info({'DOWN', Ref, process, Pid, Reason}, State) ->
    ?LOG_DEBUG(#{
        description => "Failed to send message to destination, process is gone",
        reason => noproc,
        destination => Pid,
        destination_ref => Ref,
        destination_termination_reason => Reason
    }),
    {noreply, State};
handle_info(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.

terminate(Reason, #state{transport = T, socket = S} = State0) when
    T =/= undefined andalso S =/= undefined
->
    ok = close_socket(Reason, State0),
    State = State0#state{transport = undefined, socket = undefined},
    terminate(Reason, State);
terminate(normal, State) ->
    ?LOG_INFO(#{
        description => "Connection closed by client",
        reason => normal
    }),
    do_terminate(State);
terminate(closed, State) ->
    ?LOG_INFO(#{
        description => "Connection closed by client",
        reason => closed
    }),
    do_terminate(State);
terminate(timeout, State) ->
    ?LOG_INFO(#{
        description => "Connection closed by router",
        reason => idle_timeout
    }),
    do_terminate(State);
terminate(shutdown, State) ->
    ?LOG_INFO(#{
        description => "Connection closed by router",
        reason => shutdown
    }),
    do_terminate(State);
terminate({shutdown, Reason}, State) ->
    ?LOG_INFO(#{
        description => "Connection closed by router",
        reason => Reason
    }),
    do_terminate(State);
terminate({tcp_error, _, Reason}, State) ->
    ?LOG_ERROR(#{
        description => "Connection closing due to TCP error",
        reason => Reason
    }),
    do_terminate(State);
terminate(Reason, State) ->
    ?LOG_ERROR(#{
        description => "Connection closing",
        reason => Reason
    }),
    do_terminate(State).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

format_status(#{state := State} = Status) ->
    PState0 = State#state.protocol_state,
    PState = bondy_sensitive:format_status(bondy_wamp_protocol, PState0),
    maps:put(Status, state, State#state{protocol_state = PState});
format_status(Status) ->
    Status.

%% =============================================================================
%% PRIVATE
%% =============================================================================

source_ip(ProxyProtocol, PeerIP) ->
    case bondy_tcp_proxy_protocol:source_ip(ProxyProtocol, PeerIP) of
        {ok, SourceIP} ->
            SourceIP;
        {error, {socket_error, Message}} ->
            ?LOG_INFO(#{
                description =>
                    "Connection rejected. "
                    "The source IP Address couldn't be obtained "
                    "due to a socket error.",
                reason => Message,
                proxy_protocol => maps:without([error], ProxyProtocol)
            }),
            exit(normal);
        {error, {protocol_error, Message}} ->
            ?LOG_INFO(#{
                description =>
                    "Connection rejected. "
                    "The source IP Address couldn't be obtained "
                    "due to a proxy protocol error.",
                reason => Message,
                proxy_protocol => maps:without([error], ProxyProtocol)
            }),
            exit(normal)
    end.

peername(Transport, Socket) ->
    case bondy_utils:peername(Transport, Socket) of
        {ok, {local, _}} ->
            %% A Unix domain socket has no network peer; it is local by
            %% construction. Represent it as the loopback address so the
            %% IP-based pipeline (logging, events, source-based authz) works
            %% unchanged.
            {{127, 0, 0, 1}, 0};
        {ok, {_, _} = Peername} ->
            Peername;
        {ok, NonIPAddr} ->
            ?LOG_ERROR(#{
                description =>
                    "Unexpected peername when establishing connection",
                reason => invalid_socket,
                peername => NonIPAddr
            }),
            error(invalid_socket);
        {error, Reason} ->
            ?LOG_ERROR(#{
                description =>
                    "Unexpected peername when establishing connection",
                reason => inet:format_error(Reason)
            }),
            error(invalid_socket)
    end.

%% @private
-spec handle_inbound(Data :: binary(), State :: state()) ->
    {ok, state()} | {stop, raw_error(), state()}.

handle_inbound(
    <<0:5, _:3, Len:24, _Data/binary>>, #state{max_len = MaxLen} = St
) when Len > MaxLen ->
    %% RFC: During the connection, Router MUST NOT send messages to the Client
    %% longer than the LENGTH requested by the Client, and the Client MUST NOT
    %% send messages larger than the maximum requested by the Router in it's
    %% handshake reply.
    %% If a message received during a connection exceeds the limit requested,
    %% a Peer MUST fail the connection.
    ?LOG_ERROR(#{
        description => "Client committed a WAMP protocol violation",
        reason => maximum_message_length_exceeded,
        maximum_length => MaxLen,
        message_length => Len
    }),
    {stop, maximum_message_length_exceeded, St};
handle_inbound(<<0:5, 0:3, Len:24, Msg:Len/binary, Rest/binary>>, State0) ->
    %% We received a WAMP message
    %% Len is the number of octets after serialization
    case bondy_wamp_protocol:handle_inbound(Msg, State0#state.protocol_state) of
        {noreply, PSt} ->
            handle_inbound(Rest, State0#state{protocol_state = PSt});
        {reply, L, PSt} ->
            State = State0#state{protocol_state = PSt},
            ok = send_messages(L, State),
            handle_inbound(Rest, State);
        {stop, PSt} ->
            State = State0#state{protocol_state = PSt},
            {stop, normal, State};
        {stop, L, PSt} ->
            State = State0#state{protocol_state = PSt},
            ok = send_messages(L, State),
            {stop, normal, State};
        {stop, normal, L, PSt} ->
            State = State0#state{protocol_state = PSt},
            ok = send_messages(L, State),
            {stop, normal, State};
        {stop, Reason, L, PSt} ->
            State = State0#state{
                protocol_state = PSt,
                shutdown_reason = Reason
            },
            ok = send_messages(L, State),
            {stop, shutdown, State}
    end;
handle_inbound(<<0:5, 1:3, Len:24, Payload:Len/binary, Rest/binary>>, State) ->
    %% We received a PING, send a PONG
    ok = send_frame(<<0:5, 2:3, Len:24, Payload/binary>>, State),
    handle_inbound(Rest, State);
handle_inbound(<<0:5, 2:3, Len:24, Payload:Len/binary, Rest/binary>>, State) ->
    %% We received a PONG
    ?LOG_DEBUG(#{
        description => "Received pong",
        payload => Payload
    }),

    case Payload == State#state.ping_payload of
        true ->
            handle_inbound(Rest, observe_ping_rtt(State));
        false ->
            ?LOG_ERROR(#{
                description => "Invalid pong message from peer",
                reason => invalid_ping_response,
                received => Payload,
                expected => State#state.ping_payload
            }),
            {stop, invalid_ping_response, State}
    end;
handle_inbound(<<0:5, R:3, Len:24, Msg:Len/binary, Rest/binary>>, State) when
    R > 2
->
    %% The three bits (R) encode the type of the transport message,
    %% values 3 to 7 are reserved
    ok = send_frame(error_number(use_of_reserved_bits), State),
    ?LOG_ERROR(#{
        description =>
            "Client committed a WAMP protocol violation, message dropped",
        reason => use_of_reserved_bits,
        value => R,
        message => Msg
    }),
    %% Should we stop instead?
    handle_inbound(Rest, State);
handle_inbound(<<>>, State) ->
    %% We finished consuming data
    {ok, State};
handle_inbound(Data, State0) ->
    %% We have a partial message i.e. byte_size(Data) < Len
    %% we store is as buffer
    State = State0#state{buffer = Data},
    {ok, State}.

-spec handle_outbound(any(), state()) ->
    {noreply, state(), timeout()}
    | {stop, normal, state()}.

handle_outbound(M, State0) ->
    case bondy_wamp_protocol:handle_outbound(M, State0#state.protocol_state) of
        {ok, ProtoState} ->
            State = State0#state{protocol_state = ProtoState},
            {noreply, State, ?TIMEOUT(State)};
        {ok, Bin, ProtoState} ->
            State = State0#state{protocol_state = ProtoState},
            case send_message(Bin, State) of
                ok ->
                    {noreply, State, ?TIMEOUT(State)};
                {error, Reason} ->
                    {stop, Reason, State}
            end;
        {stop, ProtoState} ->
            State = State0#state{protocol_state = ProtoState},
            {stop, normal, disable_ping(State)};
        {stop, Bin, ProtoState} ->
            State = State0#state{protocol_state = ProtoState},
            case send_message(Bin, State) of
                ok ->
                    {stop, normal, disable_ping(State)};
                {error, Reason} ->
                    {stop, Reason, disable_ping(State)}
            end;
        {stop, Bin, ProtoState, Time} when is_integer(Time), Time > 0 ->
            %% We send ourselves a message to stop after Time
            State = State0#state{protocol_state = ProtoState},
            erlang:send_after(Time, self(), {stop, normal}),

            case send_message(Bin, State) of
                ok ->
                    {noreply, disable_ping(State)};
                {error, Reason} ->
                    {stop, Reason, disable_ping(State)}
            end
    end.

%% @private
handle_handshake(Len, Enc, State) ->
    try
        init_wamp(Len, Enc, State)
    catch
        throw:Reason:Stacktrace ->
            ok = send_frame(error_number(Reason), State),
            ?LOG_INFO(#{
                description => "WAMP protocol error, closing connection.",
                class => throw,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {stop, Reason, State}
    end.

%% @private
init_wamp(Len, Enc, State0) ->
    MaxLen = validate_max_len(Len),
    {FrameType, EncName} = validate_encoding(Enc),
    Proto = {raw, FrameType, EncName},
    Peer = State0#state.peername,
    Opts = #{
        source_ip => State0#state.source_ip,
        listener => State0#state.listener
    },

    case bondy_wamp_protocol:init(Proto, Peer, Opts) of
        {ok, ProtoState} ->
            State1 = State0#state{
                frame_type = FrameType,
                encoding = EncName,
                max_len = MaxLen,
                protocol_state = ProtoState
            },

            %% From the listener's option block in state, not a fresh
            %% application-environment read: this runs on every accepted
            %% connection, and the block was already resolved once at listener
            %% start.
            %%
            %% An absent `ping` block is a legitimate listener, not a
            %% misconfiguration: every `listeners.$name.ping.*` mapping is
            %% default-free, so a listener that configured no ping has no key
            %% at this path at all, and a read with no default raises `badarg`
            %% here — after the socket is accepted, so the listener binds and
            %% then dies on the first client's handshake.
            %%
            %% The default is `enabled => false` rather than the empty list:
            %% `maybe_enable_ping/2` has a clause for `enabled` true and one
            %% for false and NONE for its absence, so `#{}` would move the
            %% same crash one line down.
            PingOpts = maps_utils:from_property_list(
                key_value:get(
                    ping, State0#state.opts, [{enabled, false}]
                )
            ),

            State = maybe_enable_ping(PingOpts, State1),

            ok = send_frame(
                <<?RAW_MAGIC, Len:4, Enc:4, 0:8, 0:8>>, State
            ),

            ok = logger:update_process_metadata(#{
                protocol => wamp,
                serializer => State#state.encoding
            }),

            ?LOG_INFO(#{
                description => "Established WAMP Session with client."
            }),

            {ok, State};
        {error, Reason} ->
            {stop, Reason, State0}
    end.

%% @private
do_terminate(undefined) ->
    ok;
do_terminate(State) ->
    ok = cancel_timer(State#state.ping_tref),
    bondy_wamp_protocol:terminate(State#state.protocol_state).

%% @private
%% All messages travel in a single Transport:send call (one writev)
%% instead of one syscall per message.
-spec send_messages([iodata()], state()) -> ok | {error, any()}.

send_messages([Msg], St) ->
    send_message(Msg, St);
send_messages(L, St) when is_list(L) ->
    send_frame([frame(Msg) || Msg <- L], St).

%% @private
-spec send_message(iodata(), state()) -> ok | {error, any()}.

send_message(Msg, St) ->
    send_frame(frame(Msg), St).

%% @private
%% iodata-preserving equivalent of ?RAW_FRAME (which requires a flat
%% binary): the encoded message is never copied, only length-prefixed.
frame(Msg) ->
    [?RAW_MSG_PREFIX, <<(erlang:iolist_size(Msg)):24>>, Msg].

%% @private
-spec send_frame(iodata(), state()) -> ok | {error, any()}.

send_frame(Frame, St) ->
    (St#state.transport):send(St#state.socket, Frame).

%% @private
-doc """
The possible values for "LENGTH" are:

- `0`: 2**9 octets
- `1`: 2**10 octets ...
- `15`: 2**24 octets

This means a *Client* can choose the maximum message length between **512**
and **16M** octets.
""".
validate_max_len(N) when N >= 0, N =< 15 ->
    trunc(math:pow(2, 9 + N));
validate_max_len(_) ->
    %% TODO define correct error return
    throw(maximum_message_length_unacceptable).

%% @private
-doc """
- `0`: illegal
- `1`: JSON
- `2`: MessagePack
- `3`: CBOR
- `4 - 15`: reserved for future serializers
""".
validate_encoding(1) ->
    {binary, json};
validate_encoding(2) ->
    {binary, msgpack};
validate_encoding(3) ->
    {binary, cbor};
validate_encoding(N) ->
    case lists:keyfind(N, 2, bondy_config:get(wamp_serializers, [])) of
        {erl, N} ->
            {binary, erl};
        %% SECURITY: bert is intentionally NOT resolved, even if present in the
        %% wamp_serializers config — bert:decode/1 => binary_to_term/1 without
        %% [safe] is a pre-auth atom-table exhaustion DoS. See
        %% bondy_wamp_subprotocol:from_binary/1. (This clause also handles the
        %% `false` returned by lists:keyfind/3 for an unknown slot.)
        _ ->
            %% TODO define correct error return
            throw(serializer_unsupported)
    end.

%% @private
-doc """
- `0`: illegal (must not be used)
- `1`: serializer unsupported
- `2`: maximum message length unacceptable
- `3`: use of reserved bits (unsupported feature)
- `4`: maximum connection count reached
- `5 - 15`: reserved for future errors
""".
error_number(serializer_unsupported) -> ?RAW_ERROR(1);
error_number(maximum_message_length_unacceptable) -> ?RAW_ERROR(2);
error_number(use_of_reserved_bits) -> ?RAW_ERROR(3);
error_number(maximum_connection_count_reached) -> ?RAW_ERROR(4).

%% error_reason(1) -> serializer_unsupported;
%% error_reason(2) -> maximum_message_length_unacceptable;
%% error_reason(3) -> use_of_reserved_bits;
%% error_reason(4) -> maximum_connection_count_reached.

%% @private
socket_opened(_St) ->
    bondy_telemetry:socket_open(wamp, raw).

%% @private
close_socket(Reason, St) ->
    Socket = St#state.socket,
    try
        (St#state.transport):close(Socket)
    catch
        _:_ -> ok
    end,

    Seconds = erlang:monotonic_time(second) - St#state.start_time,

    %% We report socket stats
    ok = bondy_telemetry:socket_closed(wamp, raw, Seconds),

    case Reason of
        {tcp_error, _, _} ->
            %% We increase the socker error counter
            ok = bondy_telemetry:socket_error(wamp, raw);
        _ ->
            ok
    end.

%% @private
active_n(#state{active_n = N}) ->
    %% TODO make this dynamic based on adaptive algorithm that takes into
    %% account:
    %% - overall node load
    %% - this socket traffic i.e. slow traffic => once, high traffic => N
    N.

%% @private
maybe_active_once(#state{active_n = once} = State) ->
    Transport = State#state.transport,
    Socket = State#state.socket,
    Transport:setopts(Socket, [{active, once}]);
maybe_active_once(#state{active_n = N} = State) ->
    Transport = State#state.transport,
    Socket = State#state.socket,
    Transport:setopts(Socket, [{active, N}]).

%% @private
reset_inet_opts(#state{} = State) ->
    Transport = State#state.transport,
    Socket = State#state.socket,
    N = active_n(State),
    Transport:setopts(Socket, [{active, N}]).

%% @private
maybe_exit({error, Reason}) ->
    exit(Reason);
maybe_exit(Term) ->
    Term.

%% =============================================================================
%% PRIVATE: PING TIMEOUT
%% =============================================================================

%% @private
maybe_enable_ping(#{enabled := true} = PingOpts, State) ->
    %% The ping block's OWN interval, not the listener's `idle_timeout`. Taken
    %% from `idle_timeout`, the probe timer and the reap timer came due at the
    %% same moment, so the connection was closed rather than probed: the
    %% keepalive could neither hold a NAT binding open nor notice a dead peer any
    %% sooner than the reap already did. At `idle_timeout = infinity` — the
    %% handler's own fallback, in force since the `wamp.{tcp,tls}.idle_timeout`
    %% mapping was removed — `erlang:start_timer/3` in `reset_ping/1` raises
    %% `badarg` instead, killing every connection on a listener whose ping is
    %% enabled.
    IdleTimeout = maps:get(idle_timeout, PingOpts),
    Timeout = maps:get(timeout, PingOpts),
    Attempts = maps:get(max_attempts, PingOpts),

    Retry = bondy_retry:init(
        ping_timeout,
        #{
            % disable, use max_retries only
            deadline => 0,
            interval => Timeout,
            max_retries => Attempts,
            backoff_enabled => false
        }
    ),

    State#state{
        ping_idle_timeout = IdleTimeout,
        ping_payload = bondy_utils:generate_fragment(16),
        ping_retry = Retry
    };
maybe_enable_ping(#{enabled := false}, State) ->
    State;
%% A value that is neither boolean is a configuration ERROR, and stays loud: it
%% is the one case where silently running without a keepalive would hide the
%% mistake, on the very mechanism whose job is to notice a dead peer. Unreachable
%% from `bondy.conf' — the schema datatype is `{flag, on, off}', so cuttlefish
%% renders a boolean — and rejected at boot by
%% `bondy_listener_config:assert_ping_keys/4' for anything that resolves through
%% an inventory, so this is the backstop for a direct or `sys.config' caller.
maybe_enable_ping(#{enabled := Invalid}, _State) ->
    error({invalid_ping_enabled, Invalid});
%% Ping off is the fall-through: `enabled' ABSENT is a legitimate listener, not a
%% mistake — every `listeners.$name.ping.*' mapping is default-free, so one that
%% set some other `ping' key and not this one arrives here with no `enabled' at
%% all. Matching only `false' made that a `function_clause' on the first
%% connection, after the socket was accepted.
maybe_enable_ping(_PingOpts, State) ->
    State.

%% @private
reset_ping(#state{ping_retry = undefined} = State) ->
    %% ping disabled
    State;
reset_ping(#state{ping_tref = undefined} = State) ->
    Time = State#state.ping_idle_timeout,
    Ref = erlang:start_timer(Time, self(), ping_idle_timeout),

    State#state{ping_tref = Ref};
reset_ping(#state{} = State) ->
    ok = cancel_timer(State#state.ping_tref),

    %% Reset retry state
    {_, Retry} = bondy_retry:succeed(State#state.ping_retry),

    Time = State#state.ping_idle_timeout,
    Ref = erlang:start_timer(Time, self(), ping_idle_timeout),

    State#state{
        ping_retry = Retry,
        ping_tref = Ref
    }.

%% @private
disable_ping(#state{ping_retry = undefined} = State) ->
    State;
disable_ping(#state{} = State) ->
    ok = cancel_timer(State#state.ping_tref),
    State#state{ping_retry = undefined}.

%% @private
cancel_timer(Ref) when is_reference(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok;
cancel_timer(_) ->
    ok.

%% @private
maybe_send_ping(#state{ping_idle_timeout = undefined} = State) ->
    %% ping disabled
    {noreply, State};
maybe_send_ping(#state{} = State) ->
    {Result, Retry} = bondy_retry:fail(State#state.ping_retry),
    maybe_send_ping(Result, State#state{ping_retry = Retry}).

%% @private
maybe_send_ping(Limit, State) when
    Limit == deadline orelse Limit == max_retries
->
    % ?LOG_INFO(#{
    %     description => "Connection closing.",
    %     reason => ping_timeout
    % }),
    {stop, {shutdown, ping_timeout}, State};
maybe_send_ping(_Time, #state{} = State0) ->
    %% We send a ping
    Bin = State0#state.ping_payload,
    Frame = <<0:5, 1:3, (byte_size(Bin)):24, Bin/binary>>,
    ok = send_frame(Frame, State0),

    %% We schedule the next retry
    Ref = bondy_retry:fire(State0#state.ping_retry),
    State = State0#state{
        ping_tref = Ref,
        ping_sent_at = erlang:monotonic_time(millisecond)
    },

    {noreply, State}.

%% @private
%% Observes the ping round-trip time when a pong answers a
%% router-initiated ping. Retries resend the same payload, so the RTT is
%% measured from the most recent send.
observe_ping_rtt(#state{ping_sent_at = SentAt} = State) when
    is_integer(SentAt)
->
    Rtt = erlang:monotonic_time(millisecond) - SentAt,
    ok = bondy_telemetry:ping_rtt(wamp, raw, Rtt),
    State#state{ping_sent_at = undefined};
observe_ping_rtt(State) ->
    State.
