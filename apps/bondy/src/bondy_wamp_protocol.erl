%% =============================================================================
%%  bondy_wamp_protocol.erl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
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
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_wamp_protocol).
-behaviour(bondy_sensitive).
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").
-include("bondy_security.hrl").

-define(SHUTDOWN_TIMEOUT, 5000).
-define(IS_TRANSPORT(X), (T =:= ws orelse T =:= raw)).

-record(wamp_state, {
    subprotocol             ::  subprotocol() | undefined,
    authmethod              ::  any(),
    auth_context            ::  map() | undefined,
    auth_timestamp          ::  integer() | undefined,
    state_name              ::  state_name(),
    context                 ::  bondy_context:t() | undefined,
    goodbye_reason          ::  uri() | undefined
}).


-type state()               ::  #wamp_state{} | undefined.
-type state_name()          ::  closed
                                | establishing
                                | challenging
                                | failed
                                | established
                                | shutting_down.
-type raw_wamp_message()    ::  bondy_wamp_message:message()
                                | {raw, ping}
                                | {raw, pong}
                                | {raw, bondy_wamp_encoding:raw_error()}.


-export_type([frame_type/0]).
-export_type([encoding/0]).
-export_type([subprotocol/0]).
-export_type([state/0]).


%% BONDY_SENSITIVE CALLBACKS
-export([format_status/1]).

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



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec init(binary() | subprotocol(), bondy_session:peer(), map()) ->
    {ok, state()} | {error, any(), state()}.

init(Term, Peer, Opts) ->
    case validate_subprotocol(Term) of
        {ok, Sub} ->
            do_init(Sub, Peer, Opts);
        {error, Reason} ->
            {error, Reason, undefined}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec peer(state()) -> {inet:ip_address(), inet:port_number()}.

peer(#wamp_state{context = Ctxt}) ->
    bondy_context:peer(Ctxt).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec agent(state()) -> id().

agent(#wamp_state{context = Ctxt}) ->
    bondy_context:agent(Ctxt).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec realm_uri(state()) -> id().

realm_uri(#wamp_state{context = Ctxt}) ->
    bondy_context:realm_uri(Ctxt).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec session_id(state()) -> id().

session_id(#wamp_state{context = Ctxt}) ->
    bondy_context:session_id(Ctxt).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec ref(state()) -> bondy_ref:t().

ref(#wamp_state{context = Ctxt}) ->
    bondy_context:ref(Ctxt).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec context(state()) -> bondy_context:t().

context(#wamp_state{context = Ctxt}) ->
    Ctxt.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec terminate(state()) -> ok.


terminate(#wamp_state{context = undefined}) ->
    ok;

terminate(#wamp_state{} = State) ->
    Ctxt = State#wamp_state.context,

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



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec validate_subprotocol(binary() | subprotocol()) ->
    {ok, subprotocol()} | {error, invalid_subprotocol}.

validate_subprotocol(T) when is_binary(T) ->
    validate_subprotocol(subprotocol(T));

validate_subprotocol({ws, text, json} = S) ->
    {ok, S};
validate_subprotocol({ws, text, json_batched} = S) ->
    {ok, S};
validate_subprotocol({ws, binary, msgpack_batched} = S) ->
    {ok, S};
validate_subprotocol({ws, binary, bert_batched} = S) ->
    {ok, S};
validate_subprotocol({ws, binary, erl_batched} = S) ->
    {ok, S};
validate_subprotocol({raw, binary, json} = S) ->
    {ok, S};
validate_subprotocol({raw, binary, erl} = S) ->
    {ok, S};
validate_subprotocol({T, binary, msgpack} = S) when ?IS_TRANSPORT(T) ->
    {ok, S};
validate_subprotocol({T, binary, bert} = S) when ?IS_TRANSPORT(T) ->
    {ok, S};
validate_subprotocol({error, _} = Error) ->
    Error;
validate_subprotocol(_) ->
    {error, invalid_subprotocol}.



%% -----------------------------------------------------------------------------
%% @doc
%% Handles wamp frames, decoding 1 or more messages, routing them and replying
%% when required.
%% @end
%% -----------------------------------------------------------------------------
-spec handle_inbound(binary(), state()) ->
    {noreply, state()}
    | {reply, [binary()], state()}
    | {stop, state()}
    | {stop, [binary()], state()}
    | {stop, Reason :: any(), [binary()], state()}.

handle_inbound(Data, St) ->
    try bondy_wamp_encoding:decode(St#wamp_state.subprotocol, Data) of
        {Messages, <<>>} ->
            %% At the moment messages contain only one message as we do not yet
            %% support batched encoding
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



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec handle_outbound(bondy_wamp_message:message(), state()) ->
    {ok, binary(), state()}
    | {error, any(), state()}
    | {stop, state()}
    | {stop, binary(), state()}
    | {stop, binary(), state(), After :: non_neg_integer()}.


handle_outbound(#result{} = M, St0) ->
    Ctxt0 = St0#wamp_state.context,
    ok = notify(M, St0),
    St1 = update_context(bondy_context:reset(Ctxt0), St0),
    Bin = bondy_wamp_encoding:encode(M, encoding(St1)),
    {ok, Bin, St1};

handle_outbound(#error{request_type = ?CALL} = M, St0) ->
    Ctxt0 = St0#wamp_state.context,
    ok = notify(M, St0),
    St1 = update_context(bondy_context:reset(Ctxt0), St0),
    Bin = bondy_wamp_encoding:encode(M, encoding(St1)),
    {ok, Bin, St1};

handle_outbound(#goodbye{} = M, St0) ->
    %% Bondy is shutting_down this session, we will stop when we
    %% get the client's goodbye response
    ok = notify(M, St0),
    Bin = bondy_wamp_encoding:encode(M, encoding(St0)),
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
            ok = notify(M, St),
            Bin = bondy_wamp_encoding:encode(M, encoding(St)),
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
    | {reply, [binary()], state()}
    | {stop, state()}
    | {stop, [binary()], state()}
    | {stop, Reason :: any(), [binary()], state()}.

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
            error(Reason)
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Handles one or more messages, routing them and returning a reply
%% when required.
%% @end
%% -----------------------------------------------------------------------------
-spec handle_inbound_messages(
    [raw_wamp_message()], state(), Acc :: [raw_wamp_message()]) ->
    {noreply, state()}
    | {stop, state()}
    | {stop, [binary()], state()}
    | {stop, Reason :: any(), [binary()], state()}
    | {reply, [binary()], state()}.

handle_inbound_messages(
    [#abort{} = M|_], #wamp_state{state_name = established} = St0, []) ->
    ?LOG_INFO(#{
        description => "Client aborted",
        reason => M#abort.reason_uri,
        details => M#abort.details
    }),
    ok = notify(M, St0),
    St1 = St0#wamp_state{state_name = closed},

    {stop, St1};

handle_inbound_messages(
    [#goodbye{} = M|_], #wamp_state{state_name = established} = St0, Acc) ->
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

    ok = notify(Reply, St1),

    {stop, normal, lists:reverse([Bin|Acc]), St1};

handle_inbound_messages(
    [#goodbye{} = M|_], #wamp_state{state_name = shutting_down} = St0, Acc) ->
    %% Client is replying to our goodbye, we ignore any subsequent messages
    %% We reply all previous messages and close
    ok = notify(M, St0),
    St1 = St0#wamp_state{state_name = closed},

    {stop, shutdown, lists:reverse(Acc), St1};

handle_inbound_messages(
    [#hello{} = M|_], #wamp_state{context = #{session := _}} = St, Acc) ->
    %% Client already has a session!
    %% RFC:
    %% It is a protocol error to receive a second "HELLO" message during
    %% the lifetime of the session and the _Peer_ must fail the session if that
    %% happens.
    %% We reply all previous messages plus an abort message and close
    %% state_name might be 'close' already
    ok = notify(M, St),
    Reason = <<
        "Duplicate Session Initialization. "
        "You've attempted to send a HELLO message when you already "
        "have an active session established."
    >>,
    stop({protocol_violation, Reason}, Acc, St);

handle_inbound_messages(
    [#hello{realm_uri = Uri} = M|_],
    #wamp_state{state_name = closed} = St0, _) ->
    %% Client is requesting a session
    %% This will return either reply with
    %% wamp_welcome() | wamp_challenge() | wamp_abort()
    Ctxt0 = St0#wamp_state.context,
    ok = notify(M, St0),
    Ctxt1 = bondy_context:set_realm_uri(Ctxt0, Uri),
    St1 = update_context(Ctxt1, St0),
    St = set_next_state(establishing, St1),

    %% Lookup or create realm
    case bondy_realm:get(Uri) of
        {ok, Realm} ->
            ok = logger:update_process_metadata(#{realm => Uri}),
            maybe_open_session(
                maybe_auth_challenge(M#hello.details, Realm, St)
            );

        {error, not_found} ->
            stop({authentication_failed, {no_such_realm, Uri}}, St)
    end;

handle_inbound_messages([#hello{} = M|_], #wamp_state{} = St, _) ->
    %% Client does not have a session but we already received a HELLO message
    %% once, otherwise we would be in the 'close' state and match the previous
    %% clause
    ok = notify(M, St),
    Reason = <<"You've sent a HELLO message more than once.">>,
    stop({protocol_violation, Reason}, St);

handle_inbound_messages(
    [#authenticate{} = M|_],
    #wamp_state{state_name = established, context = #{session := _}} = St, _) ->
    ok = notify(M, St),
    %% Client already has a session so is already authenticated.
    Reason = <<"You've sent an AUTHENTICATE message more than once.">>,
    stop({protocol_violation, Reason}, St);

handle_inbound_messages(
    [#authenticate{} = M|_], #wamp_state{state_name = challenging} = St0, _) ->
    %% Client is responding to a challenge
    ok = notify(M, St0),

    AuthMethod = St0#wamp_state.authmethod,
    AuthCtxt0 = St0#wamp_state.auth_context,
    Signature = M#authenticate.signature,
    Extra = M#authenticate.extra,

    case bondy_auth:authenticate(AuthMethod, Signature, Extra, AuthCtxt0) of
        {ok, WelcomeAuthExtra, AuthCtxt1} ->
            St1 = St0#wamp_state{auth_context = AuthCtxt1},
            open_session(WelcomeAuthExtra, St1);
        {error, Reason} ->
            stop({authentication_failed, Reason}, St0)
    end;

handle_inbound_messages(
    [#authenticate{} = M|_], #wamp_state{state_name = Name} = St, _)
    when Name =/= challenging ->
    %% Client has not been sent a challenge
    ok = notify(M, St),
    Reason = <<"You need to establish a session first.">>,
    stop({protocol_violation, Reason}, St);

handle_inbound_messages(
    [H|T],
    #wamp_state{state_name = established, context = #{session := _}} = St,
    Acc) ->
    %% We have a session, so we forward messages via router
    case bondy_router:forward(H, St#wamp_state.context) of
        {ok, Ctxt} ->
            handle_inbound_messages(T, update_context(Ctxt, St), Acc);

        {reply, M, Ctxt} ->
            Bin = bondy_wamp_encoding:encode(M, encoding(St)),
            handle_inbound_messages(T, update_context(Ctxt, St), [Bin | Acc]);

        {stop, M, Ctxt} ->
            Bin = bondy_wamp_encoding:encode(M, encoding(St)),
            {stop, [Bin | Acc], update_context(Ctxt, St)}
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
    ok = notify(M, St0),
    Bin = bondy_wamp_encoding:encode(M, encoding(St0)),
    St1 = St0#wamp_state{
        state_name = challenging,
        authmethod = AuthMethod
    },
    {reply, Bin, St1};

maybe_open_session({ok, AuthExtra, St}) ->
    %% No need for a challenge, anonymous|trust or security disabled
    open_session(AuthExtra, St);

maybe_open_session({error, Reason, St}) ->
    stop(Reason, St).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%% -----------------------------------------------------------------------------
-spec open_session(map(), state()) ->
    {reply, binary(), state()}
    | {stop, binary(), state()}.

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
        Authmethod = bondy_auth:method(AuthCtxt),
        AuthmethodDetails = maps:get(authmethod_details, Extra, undefined),
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
            authroles => Authroles
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
        ok = notify(Welcome, St1),
        Bin = bondy_wamp_encoding:encode(Welcome, encoding(St1)),

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

        {reply, Bin, St1#wamp_state{state_name = established}}
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

maybe_auth_challenge(disabled, #{authid := _}, _
    , St) ->
    Reason = <<
        "You've provided and authid but the realm's security is disabled"
    >>,
    {error, {authentication_failed, Reason}, St};

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

                [Method|_] ->
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
            Reason = <<"The value for 'x_authroles' is invalid. It should be a list of groupnames.">>,
            throw({protocol_violation, Reason})
    end.


%% @private
-spec auth_challenge(Method :: binary(), State :: state()) ->
    {ok, AuthExtra :: map(), NewState :: state()}
    | {send_challenge, Method :: binary(), ChallengeExtra :: map(), NewState :: state()}
    | {error, {authentication_failed, Reason :: any()}, NewState :: state()}.

auth_challenge(Method, St0) ->
    Ctxt = St0#wamp_state.context,
    AuthCtxt0 = St0#wamp_state.auth_context,

    Details = bondy_context:request_details(Ctxt),

    case bondy_auth:challenge(Method, Details, AuthCtxt0) of
        {false, AuthCtxt1} ->
            Result = bondy_auth:authenticate(Method, undefined, #{}, AuthCtxt0),

            case Result of
                {ok, AuthExtra, AuthCtxt1} ->
                    St1 = St0#wamp_state{
                        auth_context = AuthCtxt1,
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
%% PRIVATE: UTILS
%% =============================================================================



%% @private

stop(#abort{} = M, St) ->
    stop(M, [], St);

stop(Reason, St) ->
    stop(abort_message(Reason), St).


%% @private
stop(#abort{reason_uri = Uri} = M, Acc, St0) ->
    ok = notify(M, St0),
    Bin = bondy_wamp_encoding:encode(M, encoding(St0)),

    %% We reply all previous messages plus an abort message and close
    St1 = St0#wamp_state{state_name = closed},
    {stop, Uri, [Bin|Acc], St1};

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
        message => <<"No authentication method requested. At least one authentication method is required.">>
    },
    bondy_wamp_message:abort(Details, ?WAMP_NOT_AUTH_METHOD);

abort_message({no_authmethod, _Opts}) ->
    Details = #{
        message => <<"The requested authentication methods are not available for this user on this realm.">>,
        description => <<"The requested methods are either not enabled for the authenticating user or realm or they are restricted to a specific network address range that doesn't match the client's. Check the realm configuration including the user (its roles) and the assigned sources.">>
    },
    bondy_wamp_message:abort(Details, ?WAMP_NOT_AUTH_METHOD);

abort_message(connections_not_allowed) ->
    Details = #{
        message => <<"The Realm does not allow user connections ('allow_connections' setting is off). This might be a temporary measure taken by the administrator or the realm is meant to be used only as a Same Sign-on (SSO) realm.">>
    },
    bondy_wamp_message:abort(Details, ?WAMP_AUTHENTICATION_FAILED);

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

abort_message(no_such_group) ->
    Details = #{
        message => <<"Group does not exist.">>
    },
    bondy_wamp_message:abort(Details, ?WAMP_NO_SUCH_ROLE);

abort_message({no_such_user, Username}) ->
    Details = #{
        message => <<"User '", Username/binary, "' does not exist.">>
    },
    bondy_wamp_message:abort(Details, ?WAMP_NO_SUCH_PRINCIPAL);

abort_message({protocol_violation, Reason}) when is_binary(Reason) ->
    bondy_wamp_message:abort(#{message => Reason}, ?WAMP_PROTOCOL_VIOLATION);

abort_message({authentication_failed, invalid_authmethod}) ->
    Details = #{
        message => <<"Unsupported authentication method.">>
    },
    bondy_wamp_message:abort(Details, ?WAMP_AUTHENTICATION_FAILED);

abort_message({authentication_failed, {no_such_realm, Realm}}) ->
    Details = #{
        message => <<"Realm '", Realm/binary, "' does not exist.">>
    },
    bondy_wamp_message:abort(Details, ?WAMP_NO_SUCH_REALM);

abort_message({authentication_failed, no_such_group}) ->
    Details = #{
        message => <<"A group does not exist for the the groupname or one of the groupnames requested ('authrole' or 'x_authroles').">>
    },
    bondy_wamp_message:abort(Details, ?WAMP_NO_SUCH_ROLE);

abort_message({authentication_failed, {no_such_user, Username}}) ->
    Details = #{
        message => <<"User '", Username/binary, "' does not exist.">>
    },
    bondy_wamp_message:abort(Details, ?WAMP_NO_SUCH_PRINCIPAL);

abort_message({authentication_failed, user_disabled}) ->
    Details = #{
        message => <<"The user requested (via 'authid') is disabled so we cannot establish a session. Contact your administrator to enable the user.">>
    },
    bondy_wamp_message:abort(Details, ?WAMP_NO_SUCH_PRINCIPAL);

abort_message({authentication_failed, invalid_scheme}) ->
    Details = #{
        message => <<"Unsupported authentication scheme.">>
    },
    bondy_wamp_message:abort(Details, ?WAMP_AUTHENTICATION_FAILED);

abort_message({authentication_failed, missing_signature}) ->
    Details = #{
        message => <<"The signature did not match.">>
    },
    bondy_wamp_message:abort(Details, ?WAMP_AUTHENTICATION_FAILED);

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
    %% bad_signature,
    Details = #{
        message => <<"The signature did not match.">>
    },
    bondy_wamp_message:abort(Details, ?WAMP_AUTHENTICATION_FAILED);

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
            "Router could not use the '", Method/binary, "' authmethod requested."
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
% abort_message(Details, Uri) when is_map(Details), is_binary(Uri) ->
%     bondy_wamp_message:abort(Details, Uri).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec subprotocol(binary()) ->
    bondy_wamp_protocol:subprotocol() | {error, invalid_subprotocol}.

subprotocol(?WAMP2_JSON) ->                 {ws, text, json};
subprotocol(?WAMP2_MSGPACK) ->              {ws, binary, msgpack};
subprotocol(?WAMP2_JSON_BATCHED) ->         {ws, text, json_batched};
subprotocol(?WAMP2_MSGPACK_BATCHED) ->      {ws, binary, msgpack_batched};
subprotocol(?WAMP2_BERT) ->                 {ws, binary, bert};
subprotocol(?WAMP2_ERL) ->                  {ws, binary, erl};
subprotocol(?WAMP2_BERT_BATCHED) ->         {ws, binary, bert_batched};
subprotocol(?WAMP2_ERL_BATCHED) ->          {ws, binary, erl_batched};
subprotocol(_) ->                           {error, invalid_subprotocol}.


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


notify(M, State) ->
    bondy_event_manager:notify(
        {[bondy, wamp, message], M, State#wamp_state.context}
    ).
