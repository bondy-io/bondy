%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_protocol).
-moduledoc """
Implements the WAMP protocol state machine shared by the WAMP transports
(WebSocket, raw socket, HTTP SSE and long-poll). It handles subprotocol
negotiation, the HELLO/CHALLENGE/AUTHENTICATE/WELCOME handshake and
authentication, and the encoding, decoding and routing of inbound and
outbound WAMP messages.
""".
-behaviour(bondy_sensitive).
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").
-include("bondy_security.hrl").

-define(SHUTDOWN_TIMEOUT, 5000).
-define(IS_TRANSPORT(X),
    (X =:= ws orelse X =:= raw orelse X =:= http_sse orelse X =:= http_longpoll)
).

-record(wamp_state, {
    subprotocol :: subprotocol() | undefined,
    authmethod :: any(),
    auth_claims :: map() | undefined,
    auth_context :: map() | undefined,
    auth_timestamp :: integer() | undefined,
    state_name :: state_name(),
    context :: bondy_context:t() | undefined,
    goodbye_reason :: uri() | undefined,
    %% AV-1: per-session message-throttle bucket, created at session open when
    %% message throttling is enabled (else `undefined`). Held here so the
    %% per-message path never reads config.
    msg_limiter :: bondy_rate_limit:session_limiter()
}).

-type state() :: #wamp_state{} | undefined.
-type state_name() ::
    closed
    | establishing
    | challenging
    | failed
    | established
    | shutting_down.
-type raw_wamp_message() ::
    bondy_wamp_message:message()
    | {raw, ping}
    | {raw, pong}
    | {raw, bondy_wamp_encoding:raw_error()}.

-export_type([frame_type/0]).
-export_type([encoding/0]).
-export_type([subprotocol/0]).
-export_type([state/0]).

%% BONDY_SENSITIVE CALLBACKS
-export([format_status/1]).

-ifdef(TEST).
%% Exported for regression testing of the generic pre-auth ABORT (A-2 / WP-D).
-export([abort_message/1]).
%% Exported for testing the AV-1 inbound throttle (WP-K).
-export([throttle/2]).
-endif.

%% API
-export([init/3]).
-export([peer/1]).
-export([agent/1]).
-export([session_id/1]).
-export([realm_uri/1]).
-export([ref/1]).
-export([context/1]).
-export([handle_inbound/2]).
-export([handle_outbound/2]).
-export([set_auth_claims/2]).
-export([terminate/1]).
-export([validate_subprotocol/1]).
-export([update_process_metadata/1]).

%% =============================================================================
%% BONDY_SENSITIVE CALLBACKS
%% =============================================================================

-spec format_status(State :: state()) -> state().

format_status(#wamp_state{} = State) ->
    NewAuthCtxt = bondy_sensitive:format_status(
        bondy_auth, State#wamp_state.auth_context
    ),
    NewCtxt = bondy_sensitive:format_status(
        bondy_context, State#wamp_state.context
    ),
    State#wamp_state{
        auth_context = NewAuthCtxt,
        context = NewCtxt
    }.

%% =============================================================================
%% API
%% =============================================================================

-spec init(binary() | subprotocol(), bondy_session:peer(), map()) ->
    {ok, state()} | {error, any(), state()}.

init(Term, Peer, Opts) ->
    case validate_subprotocol(Term) of
        {ok, Sub} ->
            do_init(Sub, Peer, Opts);
        {error, Reason} ->
            {error, Reason, undefined}
    end.

-spec peer(state()) -> {inet:ip_address(), inet:port_number()}.

peer(#wamp_state{context = Ctxt}) ->
    bondy_context:peer(Ctxt).

-spec agent(state()) -> id().

agent(#wamp_state{context = Ctxt}) ->
    bondy_context:agent(Ctxt).

-spec realm_uri(state()) -> id().

realm_uri(#wamp_state{context = Ctxt}) ->
    bondy_context:realm_uri(Ctxt).

-spec session_id(state()) -> id().

session_id(#wamp_state{context = Ctxt}) ->
    bondy_context:session_id(Ctxt).

-spec ref(state()) -> bondy_ref:t().

ref(#wamp_state{context = Ctxt}) ->
    bondy_context:ref(Ctxt).

-spec context(state()) -> bondy_context:t().

context(#wamp_state{context = Ctxt}) ->
    Ctxt.

-doc """
Sets the auth ticket (e.g. from a `bondy_ticket` cookie) in the protocol
state. Used by HTTP transport sessions to inject the ticket before WAMP
HELLO processing.
""".
-spec set_auth_claims(map() | undefined, state()) -> state().

set_auth_claims(Claims, #wamp_state{} = St) ->
    St#wamp_state{auth_claims = Claims}.

-spec terminate(state()) -> ok.

terminate(#wamp_state{context = undefined}) ->
    ok;
terminate(#wamp_state{} = State) ->
    Ctxt = State#wamp_state.context,

    %% AV-1: free the per-session message-throttle bucket (no-op if none).
    _ = bondy_rate_limit:delete_session_limiter(State#wamp_state.msg_limiter),

    case bondy_context:has_session(Ctxt) of
        true ->
            Session = bondy_context:session(Ctxt),
            %% We just cleanup without specifying reason to avoid sending a
            %% GOODBYE message as it should have already been sent.
            bondy_session_manager:close(Session);
        false ->
            ok
    end,

    bondy_context:close(Ctxt);
terminate(_) ->
    ok.

-spec validate_subprotocol(binary() | subprotocol()) ->
    {ok, subprotocol()} | {error, invalid_subprotocol}.

validate_subprotocol(T) when is_binary(T) ->
    validate_subprotocol(subprotocol(T));
validate_subprotocol({ws, text, json} = S) ->
    {ok, S};
validate_subprotocol({ws, text, json_batched} = S) ->
    {ok, S};
validate_subprotocol({ws, binary, cbor_batched} = S) ->
    {ok, S};
validate_subprotocol({ws, binary, msgpack_batched} = S) ->
    {ok, S};
validate_subprotocol({ws, binary, erl_batched} = S) ->
    {ok, S};
validate_subprotocol({raw, binary, json} = S) ->
    {ok, S};
validate_subprotocol({raw, binary, erl} = S) ->
    {ok, S};
validate_subprotocol({http_sse, text, json} = S) ->
    {ok, S};
validate_subprotocol({http_longpoll, text, json} = S) ->
    {ok, S};
validate_subprotocol({T, binary, cbor} = S) when ?IS_TRANSPORT(T) ->
    {ok, S};
validate_subprotocol({T, binary, msgpack} = S) when ?IS_TRANSPORT(T) ->
    {ok, S};
%% NOTE: bert / bert_batched are intentionally NOT accepted — bert:decode/1 uses
%% binary_to_term/1 without [safe] (pre-auth atom-table exhaustion DoS). See
%% bondy_wamp_subprotocol:from_binary/1.
validate_subprotocol({error, _} = Error) ->
    Error;
validate_subprotocol(_) ->
    {error, invalid_subprotocol}.

-doc """
Handles wamp frames, decoding 1 or more messages, routing them and replying
when required.
""".
-spec handle_inbound(binary(), state()) ->
    {noreply, state()}
    | {reply, [iodata()], state()}
    | {stop, state()}
    | {stop, [iodata()], state()}
    | {stop, Reason :: any(), [iodata()], state()}.

handle_inbound(Data, St) ->
    try bondy_wamp_encoding:decode(St#wamp_state.subprotocol, Data) of
        {[], <<>>} ->
            {noreply, St};
        {[M | _] = Messages, <<>>} ->
            %% At the moment messages contain only one message as we do not yet
            %% support batched encoding. Notifying here (single site, with the
            %% frame's wire size) covers every inbound message uniformly.
            ok = notify(M, byte_size(Data), St),
            handle_inbound_messages(Messages, St)
    catch
        _:{unsupported_encoding, _} = Reason ->
            stop(Reason, St);
        _:badarg ->
            stop(decoding_error, St);
        _:{invalid_uri, Uri, ReqInfo} ->
            #{request_type := ReqType, request_id := ReqId} = ReqInfo,
            Error = bondy_wamp_message:error(
                ReqType,
                ReqId,
                #{},
                ?WAMP_INVALID_URI,
                [<<"The URI '", Uri/binary, "' is not a valid WAMP URI.">>],
                #{}
            ),
            Bin = bondy_wamp_encoding:encode(Error, encoding(St)),
            %% TODO Shouldn't we stop here?
            %% At the moment messages contain only one message as we do not yet
            %% support batched encoding, when/if we enable support for batched
            %% we need to continue processing the additional messages
            {reply, [Bin], St};
        _:{validation_failed, _, _} = Reason ->
            %% Validation of the message option or details failed
            stop(Reason, St);
        _:{invalid_message, _} = Reason ->
            stop(Reason, St);
        Class:Reason:Stacktrace ->
            %% WE SHOULD NEVER REACH THIS POINT AS THIS WILL STOP THE
            %% CONNECTION.
            ?LOG_ERROR(#{
                description => <<"Error while evaluating inbound data">>,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace,
                data => Data
            }),
            stop(internal_error, St)
    end.

-spec handle_outbound(bondy_wamp_message:message(), state()) ->
    {ok, iodata(), state()}
    | {error, any(), state()}
    | {stop, state()}
    | {stop, iodata(), state()}
    | {stop, iodata(), state(), After :: non_neg_integer()}.

handle_outbound(#result{} = M, St0) ->
    Ctxt0 = St0#wamp_state.context,
    St1 = update_context(bondy_context:reset(Ctxt0), St0),
    Bin = bondy_wamp_encoding:encode(M, encoding(St1)),
    ok = notify(M, erlang:iolist_size(Bin), St1),
    {ok, Bin, St1};
handle_outbound(#error{request_type = ?CALL} = M, St0) ->
    Ctxt0 = St0#wamp_state.context,
    St1 = update_context(bondy_context:reset(Ctxt0), St0),
    Bin = bondy_wamp_encoding:encode(M, encoding(St1)),
    ok = notify(M, erlang:iolist_size(Bin), St1),
    {ok, Bin, St1};
handle_outbound(#goodbye{} = M, St0) ->
    %% Bondy is shutting_down this session, we will stop when we
    %% get the client's goodbye response
    Bin = bondy_wamp_encoding:encode(M, encoding(St0)),
    ok = notify(M, erlang:iolist_size(Bin), St0),
    St1 = St0#wamp_state{
        state_name = shutting_down,
        goodbye_reason = M#goodbye.reason_uri
    },
    %% We stop the connection after the timeout.
    %% This is to guarantee the client the chance to reply the
    %% goodbye message.
    {stop, Bin, St1, ?SHUTDOWN_TIMEOUT};
handle_outbound(M, St) ->
    case bondy_wamp_message:is_message(M) of
        true ->
            Bin = bondy_wamp_encoding:encode(M, encoding(St)),
            ok = notify(M, erlang:iolist_size(Bin), St),
            {ok, Bin, St};
        false ->
            %% This SHOULD not happen, we drop the message
            ?LOG_ERROR(#{
                description =>
                    "Invalid WAMP message dropped by protocol handler",
                data => M
            }),
            {ok, St}
    end.

%% =============================================================================
%% PRIVATE: HANDLING INBOUND MESSAGES
%% =============================================================================

-spec handle_inbound_messages([raw_wamp_message()], state()) ->
    {noreply, state()}
    | {reply, [iodata()], state()}
    | {stop, state()}
    | {stop, [iodata()], state()}
    | {stop, Reason :: any(), [iodata()], state()}.

handle_inbound_messages(Messages, St) ->
    try
        handle_inbound_messages(Messages, St, [])
    catch
        throw:Reason ->
            stop(Reason, St);
        Class:Reason:Stacktrace when Class /= throw ->
            ?LOG_ERROR(#{
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace,
                state_name => St#wamp_state.state_name
            }),
            %% REVIEW shouldn't we call stop({system_failure, Reason}) to abort?
            error({system_failure, Reason})
    end.

%% @private
-doc """
Handles one or more messages, routing them and returning a reply
when required.
""".
-spec handle_inbound_messages(
    [raw_wamp_message()], state(), Acc :: [raw_wamp_message()]
) ->
    {noreply, state()}
    | {stop, state()}
    | {stop, [iodata()], state()}
    | {stop, Reason :: any(), [iodata()], state()}
    | {reply, [iodata()], state()}.

handle_inbound_messages(
    [#abort{} = M | _], #wamp_state{state_name = established} = St0, []
) ->
    ?LOG_INFO(#{
        description => "Client aborted",
        reason => M#abort.reason_uri,
        details => M#abort.details
    }),
    St1 = St0#wamp_state{state_name = closed},

    {stop, St1};
handle_inbound_messages(
    [#goodbye{} = M | _], #wamp_state{state_name = established} = St0, Acc
) ->
    %% Client initiated goodbye, we ignore any subsequent messages
    %% We reply with all previous messages plus a goodbye and stop
    Reply = bondy_wamp_message:goodbye(
        #{message => <<"Session closed by client.">>},
        ?WAMP_GOODBYE_AND_OUT
    ),
    Bin = bondy_wamp_encoding:encode(Reply, encoding(St0)),
    St1 = St0#wamp_state{
        state_name = closed,
        goodbye_reason = M#goodbye.reason_uri
    },

    ok = notify(Reply, erlang:iolist_size(Bin), St1),

    {stop, normal, lists:reverse([Bin | Acc]), St1};
handle_inbound_messages(
    [#goodbye{} | _], #wamp_state{state_name = shutting_down} = St0, Acc
) ->
    %% Client is replying to our goodbye, we ignore any subsequent messages
    %% We reply all previous messages and close
    St1 = St0#wamp_state{state_name = closed},

    {stop, shutdown, lists:reverse(Acc), St1};
handle_inbound_messages(
    [#hello{} | _], #wamp_state{context = #{session := _}} = St, Acc
) ->
    %% Client already has a session!
    %% RFC:
    %% It is a protocol error to receive a second "HELLO" message during
    %% the lifetime of the session and the _Peer_ must fail the session if that
    %% happens.
    %% We reply all previous messages plus an abort message and close
    %% state_name might be 'close' already
    Reason = <<
        "Duplicate Session Initialization. "
        "You've attempted to send a HELLO message when you already "
        "have an active session established."
    >>,
    stop({protocol_violation, Reason}, Acc, St);
handle_inbound_messages(
    [#hello{} = M | _],
    #wamp_state{state_name = closed} = St0,
    _
) ->
    %% Client is requesting a session
    %% This will return either reply with
    %% wamp_welcome() | wamp_challenge() | wamp_abort()
    %% Load admission gate first (one atomics read): when the node's run
    %% queues are deep, a session open the node accepts will spend
    %% seconds of wall clock in scheduling delay and likely time out on
    %% the client after holding a socket, session state and auth work
    %% the whole while. Refusing HERE costs a parse and an encoded
    %% ABORT, and the reason URI is retryable (wamp.error.unavailable)
    %% so well-behaved clients back off and try again — admitted
    %% sessions keep their establishment latency instead of sharing the
    %% overload with everyone.
    case admit_hello() of
        false ->
            ok = bondy_prometheus:report_dropped(admission, hello),
            stop(overload, St0);
        true ->
            handle_hello(M, St0)
    end;
handle_inbound_messages([#hello{} | _], #wamp_state{} = St, _) ->
    %% Client does not have a session but we already received a HELLO message
    %% once, otherwise we would be in the 'close' state and match the previous
    %% clause
    Reason = <<"You've sent a HELLO message more than once.">>,
    stop({protocol_violation, Reason}, St);
handle_inbound_messages(
    [#authenticate{} | _],
    #wamp_state{state_name = established, context = #{session := _}} = St,
    _
) ->
    %% Client already has a session so is already authenticated.
    Reason = <<"You've sent an AUTHENTICATE message more than once.">>,
    stop({protocol_violation, Reason}, St);
handle_inbound_messages(
    [#authenticate{} = M | _], #wamp_state{state_name = challenging} = St0, _
) ->
    %% Client is responding to a challenge
    %% AV-1: throttle credential-verification attempts per source IP so a
    %% credential-stuffing / brute-force flood is rate-limited (no-op unless
    %% enabled). Applied before the (expensive) verification.
    case throttle(auth, St0) of
        throttled ->
            stop({rate_limited, auth}, St0);
        ok ->
            AuthMethod = St0#wamp_state.authmethod,
            AuthCtxt0 = St0#wamp_state.auth_context,
            Signature = M#authenticate.signature,
            Extra = M#authenticate.extra,

            case
                bondy_auth:authenticate(AuthMethod, Signature, Extra, AuthCtxt0)
            of
                {ok, WelcomeAuthExtra, AuthCtxt1} ->
                    St1 = St0#wamp_state{auth_context = AuthCtxt1},
                    open_session(WelcomeAuthExtra, St1);
                {error, Reason} ->
                    stop({authentication_failed, Reason}, St0)
            end
    end;
handle_inbound_messages(
    [#authenticate{} | _], #wamp_state{state_name = Name} = St, _
) when
    Name =/= challenging
->
    %% Client has not been sent a challenge
    Reason = <<"You need to establish a session first.">>,
    stop({protocol_violation, Reason}, St);
handle_inbound_messages(
    [H | T],
    #wamp_state{state_name = established, context = #{session := _}} = St,
    Acc
) ->
    %% AV-1 (opt-in): per-session throttle for flood-prone verbs before routing.
    case msg_throttle(H, St) of
        allow ->
            %% We have a session, so we forward messages via router
            case bondy_router:forward(H, St#wamp_state.context) of
                {ok, Ctxt} ->
                    handle_inbound_messages(T, update_context(Ctxt, St), Acc);
                {reply, M, Ctxt} ->
                    Bin = bondy_wamp_encoding:encode(M, encoding(St)),
                    handle_inbound_messages(
                        T, update_context(Ctxt, St), [Bin | Acc]
                    );
                {stop, M, Ctxt} ->
                    Bin = bondy_wamp_encoding:encode(M, encoding(St)),
                    {stop, [Bin | Acc], update_context(Ctxt, St)}
            end;
        {throttled, ErrorMsg} ->
            Bin = bondy_wamp_encoding:encode(ErrorMsg, encoding(St)),
            handle_inbound_messages(T, St, [Bin | Acc]);
        drop ->
            handle_inbound_messages(T, St, Acc)
    end;
handle_inbound_messages(_, #wamp_state{state_name = shutting_down} = St, _) ->
    %% TODO should we reply with ERROR and keep on waiting for the client
    %% GOODBYE?
    Reason = <<
        "Router is shutting down. "
        "You should have replied with GOODBYE message."
    >>,
    stop({protocol_violation, Reason}, St);
handle_inbound_messages([], St, []) ->
    %% We have no replies
    {noreply, St};
handle_inbound_messages([], St, Acc) ->
    {reply, lists:reverse(Acc), St};
handle_inbound_messages(_, St, _) ->
    %% Client does not have a session and message is not HELLO
    Reason = <<"You need to establish a session first.">>,
    stop({protocol_violation, Reason}, St).

%% =============================================================================
%% PRIVATE: AUTH & SESSION
%% =============================================================================

%% @private
maybe_open_session({send_challenge, AuthMethod, Challenge, St0}) ->
    M = bondy_wamp_message:challenge(AuthMethod, Challenge),
    Bin = bondy_wamp_encoding:encode(M, encoding(St0)),
    ok = notify(M, erlang:iolist_size(Bin), St0),
    St1 = St0#wamp_state{
        state_name = challenging,
        authmethod = AuthMethod
    },
    {reply, [Bin], St1};
maybe_open_session({ok, AuthExtra, St}) ->
    %% No need for a challenge, anonymous|trust or security disabled
    open_session(AuthExtra, St);
maybe_open_session({error, Reason, St}) ->
    stop(Reason, St).

%% @private
%% Replies are ALWAYS proper lists of encoded messages: a bare iodata
%% message would be indistinguishable from a message list downstream.
-spec open_session(map(), state()) ->
    {reply, [iodata()], state()}
    | {stop, iodata(), state()}.

open_session(Extra, St0) when is_map(Extra) ->
    try
        Ctxt0 = St0#wamp_state.context,
        AuthCtxt = St0#wamp_state.auth_context,
        RealmUri = bondy_context:realm_uri(Ctxt0),
        SessionId0 = bondy_context:session_id(Ctxt0),

        ReqDetails = bondy_context:request_details(Ctxt0),
        ReqRoles = maps:get(roles, ReqDetails, undefined),

        Authrealm = bondy_auth:authrealm(AuthCtxt),
        Authid = bondy_auth:user_id(AuthCtxt),
        %% Authrole might be undefined here. This happens when the user sends
        %% 'default' or NULL (althrough WAMP clients should not send NULL).
        Authrole = bondy_auth:role(AuthCtxt),
        Authroles = bondy_auth:roles(AuthCtxt),
        Authprovider = bondy_auth:provider(AuthCtxt),
        AuthmethodDetails = maps:get(authmethod_details, Extra, undefined),
        Authmethod =
            case bondy_auth:method(AuthCtxt) of
                ?WAMP_COOKIE_AUTH = M ->
                    %% Exchange with authmethod from ticket (cookie)
                    maps:get(authmethod, AuthmethodDetails, M);
                M ->
                    %% WAMP-level authmethod
                    M
            end,
        Agent = maps:get(agent, ReqDetails, undefined),
        Peer = bondy_context:peer(Ctxt0),

        Properties = #{
            peer => Peer,
            security_enabled => bondy_realm:is_security_enabled(RealmUri),
            is_anonymous => Authid == anonymous,
            agent => Agent,
            roles => ReqRoles,
            authrealm => Authrealm,
            authid => maybe_gen_authid(Authid),
            authprovider => Authprovider,
            authmethod => Authmethod,
            authmethod_details => AuthmethodDetails,
            authrole => Authrole,
            authroles => Authroles,
            transport_type => maps:get(transport_type, Ctxt0, undefined),
            transport_id => maps:get(transport_id, Ctxt0, undefined)
        },

        %% We open a session
        Result = bondy_session_manager:open(SessionId0, RealmUri, Properties),
        %% throw if we got an error
        Session = resulto:throw_or_unwrap(Result),

        %% This might be different than the SessionId0 in case we found a
        %% collision while storing (almost impossible).
        SessionId = bondy_session:external_id(Session),

        %% We set the session in the context
        Ctxt1 = bondy_context:set_session(Ctxt0, Session),
        St1 = update_context(Ctxt1, St0),

        SessionInfo = bondy_session:to_external(Session),

        %% We send the WELCOME message
        Welcome = bondy_wamp_message:welcome(
            SessionId,
            SessionInfo#{
                realm => RealmUri,
                agent => bondy_router:agent(),
                roles => bondy_router:roles()
            }
        ),
        Bin = bondy_wamp_encoding:encode(Welcome, encoding(St1)),
        ok = notify(Welcome, erlang:iolist_size(Bin), St1),

        %% We define the process metadata and which keys are exposed as logger
        %% metadata.
        Meta = #{
            agent => bondy_utils:maybe_slice(Agent, 0, 64),
            authid => Authid,
            authmethod => Authmethod,
            authrealm => Authrealm,
            protocol_session_id => SessionId,
            realm => RealmUri,
            session_id => SessionId0
        },
        %% Do not expose authid as it might be private info
        LogKeys = [agent, authmethod, protocol_session_id, realm, session_id],

        ok = bondy:set_process_metadata(Meta, LogKeys),

        %% AV-1: resolve the per-session message-throttle bucket ONCE, now that
        %% the session is open (or `undefined` if message throttling is off).
        {reply, [Bin], St1#wamp_state{
            state_name = established,
            msg_limiter = bondy_rate_limit:new_session_limiter()
        }}
    catch
        throw:Reason ->
            stop(Reason, St0);
        error:pool_busy = Reason ->
            stop(Reason, St0);
        error:{invalid_options, missing_client_role} = Reason ->
            stop(Reason, St0)
    end.

%% @private
maybe_gen_authid(anonymous) ->
    bondy_utils:uuid();
maybe_gen_authid(UserId) ->
    UserId.

maybe_auth_challenge(Details, Realm, St) ->
    case bondy_realm:allow_connections(Realm) of
        true ->
            Status = bondy_realm:security_status(Realm),
            maybe_auth_challenge(Status, Details, Realm, St);
        false ->
            {error, connections_not_allowed, St}
    end.

%% @private
maybe_auth_challenge(Flag, #{authid := <<"anonymous">>} = Details, Realm, St) ->
    maybe_auth_challenge(Flag, maps:without([authid], Details), Realm, St);
maybe_auth_challenge(
    disabled,
    #{authid := _},
    _,
    St
) ->
    Reason = <<
        "You've provided and authid but the realm's security is disabled"
    >>,
    {error, {authentication_failed, Reason}, St};
maybe_auth_challenge(
    enabled,
    Details,
    Realm,
    #wamp_state{auth_claims = Claims} = St0
) when is_map(Claims) ->
    %% Cookie-based authentication — identity comes from ticket claims
    Ctxt0 = St0#wamp_state.context,
    Ctxt1 = bondy_context:set_request_details(Ctxt0, Details),

    SessionId = bondy_context:session_id(Ctxt1),
    SourceIP = bondy_context:source_ip(Ctxt1),

    %% Extract identity from ticket claims
    Authid = maps:get(authid, Claims),
    Authroles = maps:get(authroles, Claims, []),

    Ctxt = bondy_context:set_authid(Ctxt1, Authid),
    St1 = update_context(Ctxt, St0),

    Opts = #{claims => Claims},

    case
        bondy_auth:init(
            SessionId, Realm, Authid, Authroles, SourceIP, Opts
        )
    of
        {ok, AuthCtxt} ->
            St2 = St1#wamp_state{auth_context = AuthCtxt},
            ReqMethods = [?WAMP_COOKIE_AUTH],

            case bondy_auth:available_methods(ReqMethods, AuthCtxt) of
                [] ->
                    {error, {no_authmethod, ReqMethods}, St2};
                [Method | _] ->
                    auth_challenge(Method, St2)
            end;
        {error, Reason} ->
            {error, {authentication_failed, Reason}, St1}
    end;
maybe_auth_challenge(enabled, #{authid := UserId} = Details, Realm, St0) ->
    Ctxt0 = St0#wamp_state.context,
    Ctxt1 = bondy_context:set_request_details(Ctxt0, Details),
    Ctxt = bondy_context:set_authid(Ctxt1, UserId),
    St1 = update_context(Ctxt, St0),

    SessionId = bondy_context:session_id(Ctxt),
    Roles = authroles(Details),
    SourceIP = bondy_context:source_ip(Ctxt),

    %% We initialise the auth context
    case bondy_auth:init(SessionId, Realm, UserId, Roles, SourceIP) of
        {ok, AuthCtxt} ->
            St2 = St1#wamp_state{auth_context = AuthCtxt},
            ReqMethods = maps:get(authmethods, Details, []),

            case bondy_auth:available_methods(ReqMethods, AuthCtxt) of
                [] ->
                    {error, {no_authmethod, ReqMethods}, St2};
                [Method | _] ->
                    auth_challenge(Method, St2)
            end;
        {error, Reason} ->
            {error, {authentication_failed, Reason}, St1}
    end;
maybe_auth_challenge(_, Details, Realm, St0) ->
    %% Anonymous: authid missing or matched prev clause with <<"anonymous">>
    Ctxt0 = St0#wamp_state.context,
    Ctxt1 = bondy_context:set_request_details(Ctxt0, Details),
    Ctxt = bondy_context:set_authid(Ctxt1, anonymous),
    St1 = update_context(Ctxt, St0),

    SessionId = bondy_context:session_id(Ctxt),
    Roles = [<<"anonymous">>],
    SourceIP = bondy_context:source_ip(Ctxt),

    %% We initialise the auth context with anon id and role
    case bondy_auth:init(SessionId, Realm, anonymous, Roles, SourceIP) of
        {ok, AuthCtxt} ->
            St = St1#wamp_state{auth_context = AuthCtxt},
            auth_challenge(?WAMP_ANON_AUTH, St);
        {error, Reason} ->
            {error, {authentication_failed, Reason}, St1}
    end.

%% @private
authroles(Details) ->
    case maps:get('x_authroles', Details, undefined) of
        undefined ->
            case maps:get(authrole, Details, undefined) of
                undefined ->
                    %% null
                    undefined;
                <<>> ->
                    %% empty string
                    undefined;
                Role ->
                    Role
            end;
        List when is_list(List) ->
            List;
        _ ->
            Reason =
                <<"The value for 'x_authroles' is invalid. It should be a list of groupnames.">>,
            throw({protocol_violation, Reason})
    end.

%% @private
-spec auth_challenge(Method :: binary(), State :: state()) ->
    {ok, AuthExtra :: map(), NewState :: state()}
    | {send_challenge, Method :: binary(), ChallengeExtra :: map(),
        NewState :: state()}
    | {error, {authentication_failed, Reason :: any()}, NewState :: state()}.

auth_challenge(Method, St0) ->
    Ctxt = St0#wamp_state.context,
    AuthCtxt0 = St0#wamp_state.auth_context,

    Details = bondy_context:request_details(Ctxt),

    case bondy_auth:challenge(Method, Details, AuthCtxt0) of
        {false, AuthCtxt1} ->
            Ticket = St0#wamp_state.auth_claims,
            Result = bondy_auth:authenticate(
                Method, Ticket, #{}, AuthCtxt1
            ),

            case Result of
                {ok, AuthExtra, AuthCtxt2} ->
                    St1 = St0#wamp_state{
                        auth_context = AuthCtxt2,
                        auth_timestamp = erlang:system_time(millisecond)
                    },
                    {ok, AuthExtra, St1};
                {error, Reason} ->
                    {error, {authentication_failed, Reason}, St0}
            end;
        {true, ChallengeExtra, AuthCtxt1} ->
            St1 = St0#wamp_state{
                auth_context = AuthCtxt1,
                auth_timestamp = erlang:system_time(millisecond)
            },
            {send_challenge, Method, ChallengeExtra, St1};
        {error, Reason} ->
            {error, {authentication_failed, Reason}, St0}
    end.

%% =============================================================================
%% PRIVATE: ADMISSION & RATE LIMITING (AV-1)
%% =============================================================================

%% @private
%% The load admission gate for new sessions: refuses when the node is in
%% the busy state (deep run queues — see `bondy_regulator_load`) and the
%% gate is enabled (`load_regulation.hello.enabled`, default on). Both
%% reads are lock-free; fails open.
admit_hello() ->
    case bondy_config:get([load_regulation, hello, enabled], true) of
        true ->
            not bondy_regulator_load:busy();
        false ->
            true
    end.

%% @private
%% The admitted-HELLO path: per-source-IP handshake throttle, then realm
%% lookup and the auth challenge / session open.
handle_hello(#hello{realm_uri = Uri} = M, St0) ->
    %% AV-1: throttle the pre-auth handshake per source IP (no-op unless
    %% enabled).
    case throttle(handshake, St0) of
        throttled ->
            stop({rate_limited, handshake}, St0);
        ok ->
            T0 = erlang:monotonic_time(microsecond),
            Ctxt0 = St0#wamp_state.context,
            Ctxt1 = bondy_context:set_realm_uri(Ctxt0, Uri),
            St1 = update_context(Ctxt1, St0),
            St = set_next_state(establishing, St1),

            %% Lookup or create realm
            Result =
                case bondy_realm:get(Uri) of
                    {ok, Realm} ->
                        ok = logger:update_process_metadata(#{realm => Uri}),
                        maybe_open_session(
                            maybe_auth_challenge(M#hello.details, Realm, St)
                        );
                    {error, not_found} ->
                        stop({authentication_failed, {no_such_realm, Uri}}, St)
                end,
            DurationUs = erlang:monotonic_time(microsecond) - T0,
            ok = bondy_telemetry:wamp_hello(DurationUs),
            Result
    end.

%% @private
%% Per-source-IP inbound throttle for the handshake / auth classes. Delegates to
%% the shared `bondy_rate_limit` policy (off by default; never raises).
throttle(Class, #wamp_state{} = St) ->
    {IP, _Port} = peer(St),
    bondy_rate_limit:throttle(Class, IP).

%% @private
%% AV-1 Stage 4: opt-in per-session throttle for the flood-prone verbs
%% (CALL/PUBLISH/SUBSCRIBE/REGISTER), keyed by session id. Returns `allow`,
%% `{throttled, ErrorMsg}` (a WAMP ERROR to return), or `drop` (throttled but the
%% verb expects no reply — an unacknowledged PUBLISH). Non-throttled verbs (and
%% the whole feature when disabled) short-circuit to `allow` with a single map
%% read. Message throttling has its own opt-in flag on top of the master switch.
msg_throttle(#call{} = M, St) ->
    do_msg_throttle(M, St, reply);
msg_throttle(#subscribe{} = M, St) ->
    do_msg_throttle(M, St, reply);
msg_throttle(#register{} = M, St) ->
    do_msg_throttle(M, St, reply);
msg_throttle(#publish{options = Opts} = M, St) ->
    Reply =
        case maps:get(acknowledge, Opts, false) of
            true -> reply;
            _ -> noreply
        end,
    do_msg_throttle(M, St, Reply);
msg_throttle(_M, _St) ->
    allow.

%% @private
do_msg_throttle(M, #wamp_state{msg_limiter = Limiter}, Reply) ->
    %% Hot path: a field read + (only when enabled) an atomics consume. No
    %% config read per message — the bucket was resolved once at session open.
    case bondy_rate_limit:allow_session(Limiter) of
        ok ->
            allow;
        throttled when Reply == reply ->
            Details = #{
                message => <<"Rate limited. Please slow down and retry.">>
            },
            {throttled,
                bondy_wamp_message:error_from(M, Details, ?WAMP_UNAVAILABLE)};
        throttled ->
            drop
    end.

%% =============================================================================
%% PRIVATE: UTILS
%% =============================================================================

%% @private

stop(#abort{} = M, St) ->
    stop(M, [], St);
stop(Reason, St) ->
    stop(abort_message(Reason), St).

%% @private
stop(#abort{reason_uri = Uri} = M, Acc, St0) ->
    Bin = bondy_wamp_encoding:encode(M, encoding(St0)),
    ok = notify(M, erlang:iolist_size(Bin), St0),

    %% We reply all previous messages plus an abort message and close
    St1 = St0#wamp_state{state_name = closed},
    {stop, Uri, [Bin | Acc], St1};
stop(Reason, Acc, St) ->
    stop(abort_message(Reason), Acc, St).

%% @private
abort_message(internal_error) ->
    Details = #{
        message => <<"Internal system error, contact your administrator.">>
    },
    bondy_wamp_message:abort(Details, ?BONDY_ERROR_INTERNAL);
abort_message(decoding_error) ->
    Details = #{
        message => <<"An error occurred while deserealising a message.">>
    },
    bondy_wamp_message:abort(Details, ?WAMP_PROTOCOL_VIOLATION);
abort_message({invalid_message, _M}) ->
    Details = #{
        message => <<"An invalid message was received.">>
    },
    bondy_wamp_message:abort(Details, ?WAMP_PROTOCOL_VIOLATION);
abort_message({no_authmethod, []}) ->
    Details = #{
        message =>
            <<"No authentication method requested. At least one authentication method is required.">>
    },
    bondy_wamp_message:abort(Details, ?WAMP_NOT_AUTH_METHOD);
abort_message({no_authmethod, ReqMethods}) ->
    Details = #{
        message =>
            <<"The requested authentication methods are not available for this user on this realm.">>,
        description =>
            <<"The requested methods are either not enabled for the authenticating user or realm or they are restricted to a specific network address range that doesn't match the client's. Check the realm configuration including the user (its roles) and the assigned sources.">>,
        requested_methods => ReqMethods
    },
    bondy_wamp_message:abort(Details, ?WAMP_NOT_AUTH_METHOD);
abort_message(connections_not_allowed) ->
    Details = #{
        message =>
            <<"The Realm does not allow user connections ('allow_connections' setting is off). This might be a temporary measure taken by the administrator or the realm is meant to be used only as a Same Sign-on (SSO) realm.">>
    },
    bondy_wamp_message:abort(Details, ?WAMP_AUTHENTICATION_FAILED);
abort_message(overload) ->
    %% The load admission gate refused this session: the node's run
    %% queues are too deep to establish a session within a useful time.
    %% An availability condition, not a client error — the retryable URI
    %% tells clients to back off and try again (possibly reaching
    %% another node through their load balancer).
    Details = #{
        message => <<
            "The router is overloaded and cannot accept new sessions "
            "at the moment. Please retry."
        >>
    },
    bondy_wamp_message:abort(Details, ?WAMP_UNAVAILABLE);
abort_message({rate_limited, _Class}) ->
    %% AV-1: inbound throttle tripped. A pre-auth signal, so the reason is not a
    %% user-enumeration oracle; keep it generic and non-specific about the limit.
    Details = #{
        message =>
            <<"Too many requests. Please slow down and retry later.">>
    },
    bondy_wamp_message:abort(Details, ?WAMP_UNAVAILABLE);
abort_message(no_such_realm) ->
    Details = #{
        message => <<"Realm does not exist.">>
    },
    bondy_wamp_message:abort(Details, ?WAMP_NO_SUCH_REALM);
abort_message({no_such_realm, Realm}) ->
    Details = #{
        message => <<"Realm '", Realm/binary, "' does not exist.">>
    },
    bondy_wamp_message:abort(Details, ?WAMP_NO_SUCH_REALM);
abort_message({no_such_groups, Groups}) when is_list(Groups) ->
    Joined = lists:join(<<", ">>, Groups),
    Msg = iolist_to_binary(
        [<<"The following groups do not exist: ">>, Joined]
    ),
    Details = #{message => Msg},
    bondy_wamp_message:abort(Details, ?WAMP_NO_SUCH_ROLE);
abort_message({no_such_user, Username}) ->
    ?LOG_INFO(#{
        description =>
            "Authentication failed; returning a generic reason to the client "
            "to avoid user enumeration.",
        reason => no_such_user,
        authid => Username
    }),
    generic_authentication_failed();
abort_message({protocol_violation, Reason}) when is_binary(Reason) ->
    bondy_wamp_message:abort(#{message => Reason}, ?WAMP_PROTOCOL_VIOLATION);
abort_message({authentication_failed, invalid_authmethod}) ->
    Details = #{
        message => <<"Unsupported authentication method.">>
    },
    bondy_wamp_message:abort(Details, ?WAMP_AUTHENTICATION_FAILED);
abort_message({authentication_failed, temporarily_unavailable}) ->
    %% The AE auth fence refused because this node cannot currently confirm
    %% its security view is fresh. This is an availability condition, not a
    %% credential failure — a retryable URI stops clients (and their humans)
    %% from treating it as a bad password.
    Details = #{
        message => <<
            "Authentication is temporarily unavailable on this node. "
            "Please retry."
        >>
    },
    bondy_wamp_message:abort(Details, ?WAMP_UNAVAILABLE);
abort_message({authentication_failed, {no_such_realm, Realm}}) ->
    Details = #{
        message => <<"Realm '", Realm/binary, "' does not exist.">>
    },
    bondy_wamp_message:abort(Details, ?WAMP_NO_SUCH_REALM);
abort_message({authentication_failed, {no_such_groups, Groups}}) when
    is_list(Groups)
->
    Joined = lists:join(<<", ">>, Groups),
    Msg = iolist_to_binary([
        <<"The following groups requested via 'authrole' or 'x_authroles' ">>,
        <<"do not exist: ">>,
        Joined
    ]),
    Details = #{message => Msg},
    bondy_wamp_message:abort(Details, ?WAMP_NO_SUCH_ROLE);
abort_message({authentication_failed, {no_such_user, Username}}) ->
    ?LOG_INFO(#{
        description =>
            "Authentication failed; returning a generic reason to the client "
            "to avoid user enumeration.",
        reason => no_such_user,
        authid => Username
    }),
    generic_authentication_failed();
abort_message({authentication_failed, user_disabled}) ->
    ?LOG_INFO(#{
        description =>
            "Authentication failed; returning a generic reason to the client "
            "to avoid user enumeration.",
        reason => user_disabled
    }),
    generic_authentication_failed();
abort_message({authentication_failed, invalid_scheme}) ->
    Details = #{
        message => <<"Unsupported authentication scheme.">>
    },
    bondy_wamp_message:abort(Details, ?WAMP_AUTHENTICATION_FAILED);
abort_message({authentication_failed, missing_signature}) ->
    generic_authentication_failed();
abort_message({authentication_failed, oauth2_invalid_grant}) ->
    Details = #{
        message => <<
            "The access token provided is expired, revoked, malformed,"
            " or invalid either because it does not match the Realm used in the"
            " request, or because it was issued to another peer."
        >>
    },
    bondy_wamp_message:abort(Details, ?WAMP_AUTHENTICATION_FAILED);
abort_message({authentication_failed, _}) ->
    %% Wrong password, bad signature, or any other unspecified auth failure.
    %% Kept byte-identical to the unknown/disabled-user responses above so the
    %% client cannot distinguish them (no user-enumeration oracle).
    generic_authentication_failed();
abort_message({unsupported_encoding, Encoding}) ->
    Details = #{
        message => <<
            "Unsupported message encoding '",
            (atom_to_binary(Encoding))/binary,
            "'."
        >>
    },
    bondy_wamp_message:abort(Details, ?WAMP_PROTOCOL_VIOLATION);
abort_message({validation_failed, Details, _ReqInfo}) ->
    bondy_wamp_message:abort(Details, ?WAMP_PROTOCOL_VIOLATION);
abort_message({invalid_options, missing_client_role}) ->
    Details = #{
        message => <<
            "No client roles provided. Please provide at least one client role."
        >>
    },
    bondy_wamp_message:abort(Details, ?WAMP_PROTOCOL_VIOLATION);
abort_message({missing_param, Param}) ->
    Details = #{
        message => <<
            "Missing value for required parameter '", Param/binary, "'."
        >>
    },
    bondy_wamp_message:abort(Details, ?WAMP_PROTOCOL_VIOLATION);
abort_message({unsupported_authmethod, Method}) ->
    Details = #{
        message => <<
            "Router could not use the '",
            Method/binary,
            "' authmethod requested."
            " Either the method is not supported by the Router or it is not"
            " allowed by the Realm."
        >>
    },
    bondy_wamp_message:abort(Details, ?WAMP_NOT_AUTH_METHOD);
abort_message({invalid_authmethod, Method}) ->
    Details = #{
        message => <<
            "Router could not use the authmethod requested ('",
            Method/binary,
            "')."
        >>
    },
    bondy_wamp_message:abort(Details, ?WAMP_NOT_AUTH_METHOD);
abort_message({Code, Term}) when is_atom(Term) ->
    abort_message({Code, ?CHARS2BIN(atom_to_list(Term))}).

%% @private
%% A single, client-indistinguishable ABORT for every pre-authentication
%% credential/identity failure — unknown user, disabled user, bad or missing
%% signature, wrong password. Distinct reason URIs or messages here would be a
%% user-enumeration oracle (CWE-204); the specific reason is logged server-side
%% by the callers.
generic_authentication_failed() ->
    bondy_wamp_message:abort(
        #{message => <<"Authentication failed.">>},
        ?WAMP_AUTHENTICATION_FAILED
    ).

%% @private
% abort_message(Details, Uri) when is_map(Details), is_binary(Uri) ->
%     bondy_wamp_message:abort(Details, Uri).

-spec subprotocol(binary()) ->
    bondy_wamp_protocol:subprotocol() | {error, invalid_subprotocol}.

subprotocol(?WAMP2_JSON) -> {ws, text, json};
subprotocol(?WAMP2_CBOR) -> {ws, binary, cbor};
subprotocol(?WAMP2_MSGPACK) -> {ws, binary, msgpack};
subprotocol(?WAMP2_JSON_BATCHED) -> {ws, text, json_batched};
subprotocol(?WAMP2_CBOR_BATCHED) -> {ws, binary, cbor_batched};
subprotocol(?WAMP2_MSGPACK_BATCHED) -> {ws, binary, msgpack_batched};
subprotocol(?WAMP2_BERT) -> {ws, binary, bert};
subprotocol(?WAMP2_ERL) -> {ws, binary, erl};
subprotocol(?WAMP2_BERT_BATCHED) -> {ws, binary, bert_batched};
subprotocol(?WAMP2_ERL_BATCHED) -> {ws, binary, erl_batched};
subprotocol(?WAMP2_JSON_SSE) -> {http_sse, text, json};
subprotocol(_) -> {error, invalid_subprotocol}.

%% @private
encoding(#wamp_state{subprotocol = {_, _, Serializer}}) ->
    Serializer.

%% @private
do_init({_, _, _} = Subprotocol, Peer, Opts) ->
    Ctxt = bondy_context:new(Peer, Subprotocol, Opts),
    State = #wamp_state{
        state_name = closed,
        subprotocol = Subprotocol,
        context = Ctxt
    },

    ok = update_process_metadata(State),

    {ok, State}.

%% @private
update_context(Ctxt, St) ->
    St#wamp_state{context = Ctxt}.

%% @private
set_next_state(Name, St) ->
    St#wamp_state{state_name = Name}.

update_process_metadata(#wamp_state{} = State) ->
    #wamp_state{
        subprotocol = {_, _, Serializer},
        context = Ctxt
    } = State,

    ok = logger:update_process_metadata(#{
        protocol => wamp,
        serializer => Serializer,
        peername => bondy_context:peername(Ctxt)
    }).

notify(M, WireSize, State) ->
    bondy_telemetry:wamp_message(M, WireSize, State#wamp_state.context).
