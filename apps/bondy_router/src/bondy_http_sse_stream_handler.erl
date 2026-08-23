%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_sse_stream_handler).
-moduledoc """
A `cowboy_loop` handler for SSE (Server-Sent Events) streams.

Handles GET /wamp/sse/:transport_id/receive. Opens a long-lived SSE connection
that delivers WAMP messages to the client as SSE events.

Messages arrive via two paths:
1. Sync replies (WELCOME, CHALLENGE, ABORT) from `handle_inbound` — delivered
   as `{sync_reply, Bin}` messages directly from the transport session
2. Async messages (EVENT, INVOCATION, etc.) — drained from the transport queue
   on `drain_queue` notifications

Keepalive SSE comments are sent periodically to prevent intermediaries from
closing the connection, unless the listener's resolved `sse.ping.enabled` is
`false`. The interval is the listener's resolved `sse.ping.interval`.
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("http_api.hrl").

-record(state, {
    transport_id :: binary(),
    session_pid :: pid(),
    session_mon :: reference(),
    encoding :: encoding(),
    %% `undefined' when the listener's resolved `ping.enabled' is `false':
    %% no keepalive timer is ever scheduled for this connection.
    keepalive_interval :: optional(pos_integer()),
    keepalive_ref :: optional(reference())
}).

-define(DRAIN_BATCH_SIZE, 50).

-export([init/2]).
-export([info/3]).
-export([terminate/3]).

%% =============================================================================
%% COWBOY LOOP CALLBACKS
%% =============================================================================

init(Req0, Opts) ->
    %% The route state is built once per listener by
    %% `bondy_http_services:carrier_state/2', which always sets `config', so
    %% this performs no configuration lookup per connection.
    Config = maps:get(config, Opts),
    CorsConfig = bondy_http_cors:config_from_req(Req0),
    Req0a = bondy_http_cors:set_headers(Req0, CorsConfig),
    Req1 = bondy_http_utils:set_all_headers(Req0a),
    TransportId = cowboy_req:binding(transport_id, Req1),

    case bondy_http_transport_session:whereis(TransportId) of
        undefined ->
            ReplyBody = json:encode(#{
                <<"error">> => <<"transport_not_found">>
            }),
            Req = cowboy_req:reply(
                ?HTTP_NOT_FOUND,
                #{<<"content-type">> => <<"application/json">>},
                ReplyBody,
                Req1
            ),
            {ok, Req, Opts};
        SessionPid ->
            case validate_sse_auth(SessionPid, Req1) of
                {error, unauthorized} ->
                    ReplyBody = json:encode(#{
                        <<"error">> => <<"unauthorized">>
                    }),
                    Req = cowboy_req:reply(
                        ?HTTP_UNAUTHORIZED,
                        #{<<"content-type">> => <<"application/json">>},
                        ReplyBody,
                        Req1
                    ),
                    {ok, Req, Opts};
                ok ->
                    %% Register as SSE stream with the transport session
                    ok = bondy_http_transport_session:register_sse_stream(
                        SessionPid, self()
                    ),

                    %% Monitor the session process
                    MonRef = erlang:monitor(process, SessionPid),

                    %% Get encoding for this transport
                    Encoding = bondy_http_transport_session:encoding(
                        SessionPid
                    ),

                    %% Start SSE stream response
                    Headers = #{
                        <<"content-type">> =>
                            <<"text/event-stream; charset=utf-8">>,
                        <<"cache-control">> => <<"no-cache">>,
                        <<"x-accel-buffering">> => <<"no">>
                    },
                    Req = cowboy_req:stream_reply(200, Headers, Req1),

                    %% No defaults: a resolved `sse' carrier config carries
                    %% every key of `bondy_listener_config:?CARRIER_DEFAULTS'.
                    IdleTimeout = maps:get(idle_timeout, Config),
                    ResetOnSend = maps:get(reset_idle_timeout_on_send, Config),
                    ok = cowboy_req:cast(
                        {set_options, #{
                            idle_timeout => IdleTimeout,
                            reset_idle_timeout_on_send => ResetOnSend
                        }},
                        Req
                    ),

                    %% Schedule initial drain and keepalive
                    self() ! drain_queue,

                    State0 = #state{
                        transport_id = TransportId,
                        session_pid = SessionPid,
                        session_mon = MonRef,
                        encoding = Encoding,
                        keepalive_interval = keepalive_interval(Config)
                    },
                    State = schedule_keepalive(State0),

                    {cowboy_loop, Req, State}
            end
    end.

info({sync_reply, Bin}, Req, State) ->
    %% Bin may be iodata; cow_sse scans `data` for newlines, so flatten.
    ok = cowboy_req:stream_events(
        #{event => <<"wamp">>, data => iolist_to_binary(Bin)},
        nofin,
        Req
    ),
    {ok, Req, State};
info(drain_queue, Req, #state{transport_id = TransportId} = State) ->
    Messages = bondy_http_transport_queue:dequeue_batch(
        TransportId, ?DRAIN_BATCH_SIZE
    ),
    ok = send_wamp_events(Messages, Req, State),
    %% If we got a full batch, there might be more
    case length(Messages) >= ?DRAIN_BATCH_SIZE of
        true ->
            self() ! drain_queue;
        false ->
            ok
    end,
    {ok, Req, State};
info(keepalive, Req, State) ->
    ok = cowboy_req:stream_events(
        #{comment => <<"keepalive">>},
        nofin,
        Req
    ),
    {ok, Req, schedule_keepalive(State)};
info(
    {'DOWN', Ref, process, Pid, _Reason},
    Req,
    #state{session_pid = Pid, session_mon = Ref} = State
) ->
    ok = cowboy_req:stream_events(
        #{event => <<"transport_error">>, data => <<"session_terminated">>},
        nofin,
        Req
    ),
    {stop, Req, State};
info({stop_stream, FinalBins}, Req, State) ->
    lists:foreach(
        fun(Bin) ->
            ok = cowboy_req:stream_events(
                #{event => <<"wamp">>, data => iolist_to_binary(Bin)},
                nofin,
                Req
            )
        end,
        FinalBins
    ),
    {stop, Req, State};
info(_Msg, Req, State) ->
    {ok, Req, State}.

terminate(_Reason, _Req, #state{keepalive_ref = Ref}) when is_reference(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok;
terminate(_Reason, _Req, _State) ->
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
validate_sse_auth(SessionPid, Req) ->
    case bondy_http_transport_session:auth_claims(SessionPid) of
        undefined ->
            ok;
        #{authrealm := Authrealm} = StoredClaims ->
            Cookies = bondy_http_utils:parse_cookies(Req),
            CookieName = bondy_http_utils:ticket_cookie_name(Authrealm),
            case lists:keyfind(CookieName, 1, Cookies) of
                false ->
                    {error, unauthorized};
                {_, Ticket} ->
                    case bondy_ticket:verify(Ticket) of
                        {ok, #{
                            authid := Authid, authrealm := Authrealm2
                        }} ->
                            #{
                                authid := ExpAuthid,
                                authrealm := ExpAuthrealm
                            } = StoredClaims,
                            case
                                Authid =:= ExpAuthid andalso
                                    Authrealm2 =:= ExpAuthrealm
                            of
                                true -> ok;
                                false -> {error, unauthorized}
                            end;
                        {error, _} ->
                            {error, unauthorized}
                    end
            end
    end.

%% @private
%% `ping.enabled' and `ping.interval' both come from
%% `bondy_listener_config:?CARRIER_DEFAULTS' when the operator states neither,
%% and the merge is at the leaf, so a listener stating one still gets the other.
%% The two shapes below are therefore the only two, and there is no third for a
%% `ping' key that is absent altogether.
keepalive_interval(Config) ->
    case maps:get(ping, Config) of
        #{enabled := true, interval := Interval} -> Interval;
        #{enabled := false} -> undefined
    end.

%% @private
schedule_keepalive(#state{keepalive_interval = undefined} = State) ->
    State;
schedule_keepalive(#state{keepalive_interval = Interval} = State) ->
    Ref = erlang:send_after(Interval, self(), keepalive),
    State#state{keepalive_ref = Ref}.

%% @private
send_wamp_events([], _Req, _State) ->
    ok;
send_wamp_events(Messages, Req, #state{encoding = Encoding}) ->
    Events = lists:map(
        fun(Msg) ->
            %% cow_sse scans `data` for newlines, so flatten here (SSE is
            %% not a hot path).
            Bin = iolist_to_binary(bondy_wamp_encoding:encode(Msg, Encoding)),
            #{event => <<"wamp">>, data => Bin}
        end,
        Messages
    ),
    cowboy_req:stream_events(Events, nofin, Req).
