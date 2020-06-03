%% =============================================================================
%%  bondy_wamp_protocol.erl -
%%
%%  Copyright (c) 2016-2019 Ngineo Limited t/a Leapsight. All rights reserved.
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
-include("bondy.hrl").
-include("bondy_security.hrl").
-include_lib("wamp/include/wamp.hrl").

-define(SHUTDOWN_TIMEOUT, 5000).
-define(IS_TRANSPORT(X), (T =:= ws orelse T =:= raw)).

-record(wamp_state, {
    subprotocol             ::  subprotocol() | undefined,
    authmethod              ::  any(),
    auth_token              ::  binary() | undefined,
    auth_signature          ::  binary() | undefined,
    auth_timestamp          ::  integer() | undefined,
    state_name = closed     ::  state_name(),
    context                 ::  bondy_context:t() | undefined
}).


-type state()               ::  #wamp_state{} | undefined.
-type state_name()          ::  closed
                                | establishing
                                | challenging
                                | failed
                                | established
                                | shutting_down.
-type raw_wamp_message()    ::  wamp_message:message()
                                | {raw, ping}
                                | {raw, pong}
                                | {raw, wamp_encoding:raw_error()}.


-export_type([frame_type/0]).
-export_type([encoding/0]).
-export_type([subprotocol/0]).
-export_type([state/0]).

-export([init/3]).
-export([peer/1]).
-export([agent/1]).
-export([session_id/1]).
-export([peer_id/1]).
-export([context/1]).
-export([handle_inbound/2]).
-export([handle_outbound/2]).
-export([terminate/1]).
-export([validate_subprotocol/1]).



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
-spec session_id(state()) -> id().

session_id(#wamp_state{context = Ctxt}) ->
    bondy_context:session_id(Ctxt).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec peer_id(state()) -> peer_id().

peer_id(#wamp_state{context = Ctxt}) ->
    bondy_context:peer_id(Ctxt).

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

terminate(St) ->
    bondy_context:close(St#wamp_state.context).


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
    {ok, state()}
    | {stop, state()}
    | {stop, [binary()], state()}
    | {reply, [binary()], state()}.

handle_inbound(Data, St) ->
    try wamp_encoding:decode(St#wamp_state.subprotocol, Data) of
        {Messages, <<>>} ->
            handle_inbound_messages(Messages, St)
    catch
        ?EXCEPTION(_, {unsupported_encoding, _} = Reason, _) ->
            abort(Reason, St);
        ?EXCEPTION(_, badarg, _) ->
            abort(decoding, St);
        ?EXCEPTION(_, function_clause, _) ->
            abort(incompatible_message, St)
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec handle_outbound(wamp_message:message(), state()) ->
    {ok, binary(), state()}
    | {stop, state()}
    | {stop, binary(), state()}
    | {stop, binary(), state(), After :: non_neg_integer()}.


handle_outbound(#result{} = M, St0) ->
    Ctxt0 = St0#wamp_state.context,
    ok = bondy_event_manager:notify({wamp, M, Ctxt0}),
    St1 = update_context(bondy_context:reset(Ctxt0), St0),
    Bin = wamp_encoding:encode(M, encoding(St1)),
    {ok, Bin, St1};

handle_outbound(#error{request_type = ?CALL} = M, St0) ->
    Ctxt0 = St0#wamp_state.context,
    ok = bondy_event_manager:notify({wamp, M, Ctxt0}),
    St1 = update_context(bondy_context:reset(Ctxt0), St0),
    Bin = wamp_encoding:encode(M, encoding(St1)),
    {ok, Bin, St1};

handle_outbound(#goodbye{} = M, St0) ->
    %% Bondy is shutting_down this session, we will stop when we
    %% get the client's goodbye response
    ok = bondy_event_manager:notify({wamp, M, St0#wamp_state.context}),
    Bin = wamp_encoding:encode(M, encoding(St0)),
    St1 = St0#wamp_state{state_name = shutting_down},
    {stop, Bin, St1, ?SHUTDOWN_TIMEOUT};

handle_outbound(M, St) ->
    case wamp_message:is_message(M) of
        true ->
            ok = bondy_event_manager:notify({wamp, M, St#wamp_state.context}),
            Bin = wamp_encoding:encode(M, encoding(St)),
            {ok, Bin, St};
        false ->
            %% RFC: WAMP implementations MUST close sessions (disposing all of their resources such as subscriptions and registrations) on protocol errors caused by offending peers.
            {stop, St}
    end.




%% =============================================================================
%% PRIVATE: HANDLING INBOUND MESSAGES
%% =============================================================================



-spec handle_inbound_messages([raw_wamp_message()], state()) ->
    {ok, state()}
    | {stop, state()}
    | {stop, [binary()], state()}
    | {reply, [binary()], state()}.

handle_inbound_messages(Messages, St) ->
    handle_inbound_messages(Messages, St, []).



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Handles one or more messages, routing them and returning a reply
%% when required.
%% @end
%% -----------------------------------------------------------------------------
-spec handle_inbound_messages(
    [raw_wamp_message()], state(), Acc :: [raw_wamp_message()]) ->
    {ok, state()}
    | {stop, state()}
    | {stop, [binary()], state()}
    | {reply, [binary()], state()}.

handle_inbound_messages([], St, []) ->
    %% We have no replies
    {ok, St};

handle_inbound_messages([], St, Acc) ->
    {reply, lists:reverse(Acc), St};

handle_inbound_messages(
    [#abort{} = M|_], #wamp_state{state_name = Name} = St0, [])
    when Name =/= established ->
    %% Client aborting, we ignore any subsequent messages
    Uri = M#abort.reason_uri,
    Details = M#abort.details,
    _ = lager:info(
        "Client aborted; reason=~s, state_name=~p, details=~p",
        [Uri, Name, Details]
    ),
    St1 = St0#wamp_state{state_name = closed},
    {stop, St1};

handle_inbound_messages(
    [#goodbye{}|_], #wamp_state{state_name = established} = St0, Acc) ->

    %% Client initiated a goodbye, we ignore any subsequent messages
    %% We reply with all previous messages plus a goodbye and stop
    Reply = wamp_message:goodbye(
        #{message => <<"Session closed by client.">>}, ?WAMP_GOODBYE_AND_OUT),
    Bin = wamp_encoding:encode(Reply, encoding(St0)),
    St1 = St0#wamp_state{state_name = closed},
    {stop, normal, lists:reverse([Bin|Acc]), St1};

handle_inbound_messages(
    [#goodbye{}|_], #wamp_state{state_name = shutting_down} = St0, Acc) ->
    %% Client is replying to our goodbye, we ignore any subsequent messages
    %% We reply all previous messages and close
    St1 = St0#wamp_state{state_name = closed},
    {stop, shutdown, lists:reverse(Acc), St1};

handle_inbound_messages(
    [#hello{} = M|_],
    #wamp_state{state_name = established, context = #{session := _}} = St0,
    Acc) ->
    Ctxt = St0#wamp_state.context,
    %% Client already has a session!
    %% RFC: It is a protocol error to receive a second "HELLO" message during
    %% the lifetime of the session and the _Peer_ must fail the session if that
    %% happens.
    ok = bondy_event_manager:notify({wamp, M, Ctxt}),
    %% We reply all previous messages plus an abort message and close
    Abort = abort_message(
        ?WAMP_PROTOCOL_VIOLATION,
        <<"You've sent a HELLO message more than once.">>,
        #{},
        St0
    ),
    ok = bondy_event_manager:notify({wamp, Abort, Ctxt}),
    Bin = wamp_encoding:encode(Abort, encoding(St0)),
    St1 = St0#wamp_state{state_name = closed},
    {stop, ?WAMP_PROTOCOL_VIOLATION, [Bin | Acc], St1};

handle_inbound_messages(
    [#hello{} = M|_], #wamp_state{state_name = challenging} = St, _) ->
    %% Client does not have a session but we already sent a challenge message
    %% in response to a HELLO message
    ok = bondy_event_manager:notify({wamp, M, St#wamp_state.context}),
    abort(
        ?WAMP_PROTOCOL_VIOLATION,
        <<"You've sent a HELLO message more than once.">>,
        #{},
        St
    );

handle_inbound_messages([#hello{realm_uri = Uri} = M|_], St0, _) ->
    %% Client is requesting a session
    %% This will return either reply with wamp_welcome() | wamp_challenge()
    %% or abort
    Ctxt0 = St0#wamp_state.context,
    ok = bondy_event_manager:notify({wamp, M, Ctxt0}),

    Ctxt1 = bondy_context:set_realm_uri(Ctxt0, Uri),
    St1 = update_context(Ctxt1, St0),

    maybe_open_session(
        maybe_auth_challenge(M#hello.details, get_realm(St1), St1));

handle_inbound_messages(
    [#authenticate{} = M|_],
    #wamp_state{state_name = established, context = #{session := _}} = St, _) ->
    ok = bondy_event_manager:notify({wamp, M, St#wamp_state.context}),
    %% Client already has a session so is already authenticated.
    abort(
        ?WAMP_PROTOCOL_VIOLATION,
        <<"You've sent an AUTHENTICATE message more than once.">>,
        #{},
        St
    );

handle_inbound_messages(
    [#authenticate{} = M|_], #wamp_state{state_name = challenging} = St, _) ->
    %% Client is responding to a challenge
    ok = bondy_event_manager:notify({wamp, M, St#wamp_state.context}),

    AuthMethod = St#wamp_state.authmethod,
    AuthId = bondy_context:authid(St#wamp_state.context),
    Signature = M#authenticate.signature,

    maybe_auth(AuthMethod, AuthId, Signature, St);

handle_inbound_messages(
    [#authenticate{} = M|_], #wamp_state{state_name = Name} = St, _)
    when Name =/= challenging ->
    %% Client has not been sent a challenge
    ok = bondy_event_manager:notify({wamp, M, St#wamp_state.context}),
    abort(
        ?WAMP_PROTOCOL_VIOLATION,
        <<"You need to request a session first by sending a HELLO message.">>,
        #{},
        St
    );

handle_inbound_messages(
    [H|T],
    #wamp_state{state_name = established, context = #{session := _}} = St,
    Acc) ->
    %% We have a session, so we forward messages via router
    case bondy_router:forward(H, St#wamp_state.context) of
        {ok, Ctxt} ->
            handle_inbound_messages(T, update_context(Ctxt, St), Acc);
        {reply, M, Ctxt} ->
            Bin = wamp_encoding:encode(M, encoding(St)),
            handle_inbound_messages(T, update_context(Ctxt, St), [Bin | Acc]);
        {stop, M, Ctxt} ->
            Bin = wamp_encoding:encode(M, encoding(St)),
            {stop, [Bin | Acc], update_context(Ctxt, St)}
    end;

handle_inbound_messages(_, St, _) ->
    %% Client does not have a session and message is not HELLO
    Reason = <<"You need to establish a session first.">>,
    abort(?WAMP_PROTOCOL_VIOLATION, Reason, #{}, St).



%% =============================================================================
%% PRIVATE: AUTH & SESSION
%% =============================================================================



maybe_auth(?WAMPCRA_AUTH, AuthId, Signature, St) ->
    ExpectedSignature = St#wamp_state.auth_signature,
    Ctxt0 = St#wamp_state.context,
    Realm = bondy_context:realm_uri(Ctxt0),
    Peer = bondy_context:peer(Ctxt0),
    AuthId = bondy_context:authid(Ctxt0),

    Result = bondy_security_utils:authenticate(
        hmac, {hmac, AuthId, Signature, ExpectedSignature}, Realm, Peer),

    case Result of
        {ok, _AuthCtxt} ->
            open_session(St);
        {error, Reason} ->
            abort({authentication_failed, Reason}, St)
    end;

maybe_auth(?TICKET_AUTH, AuthId, Password, St) ->
    Ctxt0 = St#wamp_state.context,
    Realm = bondy_context:realm_uri(Ctxt0),
    Peer = bondy_context:peer(Ctxt0),
    AuthId = bondy_context:authid(Ctxt0),

    Result = bondy_security_utils:authenticate(
        basic, {basic, AuthId, Password}, Realm, Peer),

    case Result of
        {ok, _AuthCtxt} ->
            open_session(St);
        {error, Reason} ->
            abort({authentication_failed, Reason}, St)
    end.


%% @private
maybe_open_session({challenge, AuthMethod, Challenge, St0}) ->
    M = wamp_message:challenge(AuthMethod, Challenge),
    ok = bondy_event_manager:notify({wamp, M, St0#wamp_state.context}),
    Bin = wamp_encoding:encode(M, encoding(St0)),
    St1 = St0#wamp_state{
        state_name = challenging,
        authmethod = AuthMethod
    },
    {reply, Bin, St1};

maybe_open_session({ok, St}) ->
    open_session(St);

maybe_open_session({error, Reason, St}) ->
    abort(Reason, St).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%% -----------------------------------------------------------------------------
-spec open_session(state()) ->
    {reply, binary(), state()}
    | {stop, binary(), state()}.

open_session(St0) ->
    try
        Ctxt0 = St0#wamp_state.context,
        Id = bondy_context:id(Ctxt0),
        AuthId = bondy_context:authid(Ctxt0),
        Realm = bondy_context:realm_uri(Ctxt0),
        Details = bondy_context:request_details(Ctxt0),

        %% We open a session
        Session = bondy_session:open(Id, maps:get(peer, Ctxt0), Realm, Details),

        %% We set the session in the context
        Ctxt1 = Ctxt0#{session => Session},
        St1 = update_context(Ctxt1, St0),

        %% We send the WELCOME message
        Welcome = wamp_message:welcome(
            Id,
            #{
                authid => AuthId,
                agent => bondy_router:agent(),
                roles => bondy_router:roles()
            }
        ),
        ok = bondy_event_manager:notify({wamp, Welcome, Ctxt1}),
        Bin = wamp_encoding:encode(Welcome, encoding(St1)),
        {reply, Bin, St1#wamp_state{state_name = established}}
    catch
        ?EXCEPTION(error, {invalid_options, missing_client_role} = Reason, _) ->
            abort(Reason, St0)
    end.


%% @private
abort({unsupported_encoding, Format}, St) ->
    Reason = <<"Unsupported message encoding">>,
    abort(?WAMP_PROTOCOL_VIOLATION, Reason, #{encoding => Format}, St);

abort(decoding, St) ->
    Reason = <<"Error during message decoding">>,
    abort(?WAMP_PROTOCOL_VIOLATION, Reason, #{}, St);

abort(incompatible_message, St) ->
    Reason = <<"Incompatible message">>,
    abort(?WAMP_PROTOCOL_VIOLATION, Reason, #{}, St);

abort({invalid_options, missing_client_role}, St) ->
    Reason = <<
        "No client roles provided. Please provide at least one client role."
    >>,
    abort(?WAMP_PROTOCOL_VIOLATION, Reason, #{}, St);

abort({authentication_failed, invalid_scheme}, St) ->
    Reason = <<"Unsupported authentication scheme.">>,
    abort(?WAMP_AUTHORIZATION_FAILED, Reason, #{}, St);

abort({authentication_failed, no_such_realm}, St) ->
    Reason = <<"The provided realm does not exist.">>,
    abort(?WAMP_AUTHORIZATION_FAILED, Reason, #{}, St);

abort({authentication_failed, bad_password}, St) ->
    Reason = <<"The password did not match.">>,
    abort(?WAMP_AUTHORIZATION_FAILED, Reason, #{}, St);

abort({authentication_failed, missing_password}, St) ->
    Reason = <<"The password was missing in the request.">>,
    abort(?WAMP_AUTHORIZATION_FAILED, Reason, #{}, St);

abort({authentication_failed, no_matching_sources}, St) ->
    Reason = <<
        "The authentication source does not match the sources allowed"
        " for this role."
    >>,
    abort(?WAMP_AUTHORIZATION_FAILED, Reason, #{}, St);

abort({no_such_realm, Realm}, St) ->
    Reason = <<"Realm '", Realm/binary, "' does not exist.">>,
    abort(?WAMP_NO_SUCH_REALM, Reason, #{}, St);

abort({missing_param, Param}, St) ->
    Reason = <<"Missing value for required parameter '", Param/binary, "'.">>,
    abort(?WAMP_PROTOCOL_VIOLATION, Reason, #{}, St);

abort({no_such_role, AuthId}, St) ->
    Reason = <<"User '", AuthId/binary, "' does not exist.">>,
    abort(?WAMP_NO_SUCH_ROLE, Reason, #{}, St);

abort({unsupported_authmethod, Param}, St) ->
    Reason = <<
        "Router could not use the '", Param/binary, "' authmethod requested."
        " Either the method is not supported by the Router or it is not"
        " allowed by the Realm."
    >>,
    abort(?WAMP_AUTHORIZATION_FAILED, Reason, #{}, St);

abort({invalid_authmethod, ?OAUTH2_AUTH = Method}, St) ->
    Reason = <<"Router could not use the '", Method/binary, "' authmethod requested.">>,
    abort(?WAMP_AUTHORIZATION_FAILED, Reason, #{}, St);

abort(no_authmethod, St) ->
    Reason = <<"Router could not use the authmethods requested.">>,
    abort(?WAMP_AUTHORIZATION_FAILED, Reason, #{}, St);

abort(oauth2_unused_token, St) ->
    Reason = <<
        "An access token was included in the HTTP request's authorization"
        " header but the 'oauth2' method was not found in the"
        " 'authmethods' parameter. Either remove the access token from the"
        " HTTP request or add the 'oauth2' method to the 'authmethods'"
        " parameter."
    >>,
    abort(?WAMP_AUTHORIZATION_FAILED, Reason, #{}, St);

abort(oauth2_missing_token, St) ->
    Reason = <<
        "The oauth2 authmethod was requested but an access token was not"
        " provided through the HTTP authorization header. Either provide"
        " an access token, remove 'oauth2' from the request's authmethods"
        " option or sort the elements of the authmethods parameter to " " prioritize other authmethod."
    >>,
    abort(?WAMP_AUTHORIZATION_FAILED, Reason, #{}, St);

abort(oauth2_invalid_grant, St) ->
    Reason = <<
        "The access token provided is expired, revoked, malformed,"
        " or invalid either because it does not match the Realm used in the"
        " request, or because it was issued to another peer."
    >>,
    abort(?WAMP_AUTHORIZATION_FAILED, Reason, #{}, St);

abort({Code, Term}, St) when is_atom(Term) ->
    abort({Code, ?CHARS2BIN(atom_to_list(Term))}, St).


%% @private
abort(Type, Reason, Details, St)
when is_binary(Type) andalso is_binary(Reason) ->
    M = abort_message(Type, Reason, Details, St),
    ok = bondy_event_manager:notify({wamp, M, St#wamp_state.context}),
    Reply = wamp_encoding:encode(M, encoding(St)),
    {stop, Reason, Reply, St}.


%% @private
abort_message(Type, Reason, Details0, _) ->
    Details = Details0#{
        message => Reason,
        timestamp => iso8601(erlang:system_time(microsecond))
    },
    wamp_message:abort(Details, Type).


%% @private
maybe_auth_challenge(_, {error, not_found}, St) ->
    #{realm_uri := Uri} = St#wamp_state.context,
    {error, {no_such_realm, Uri}, St};

maybe_auth_challenge(Details, Realm, St) ->
    Enabled = bondy_realm:is_security_enabled(Realm),
    maybe_auth_challenge(Enabled, Details, Realm, St).


%% @private
maybe_auth_challenge(
    true, Details, Realm, #wamp_state{auth_token = Token} = St0)
    when Token =/= undefined ->
    %% The client thas provided a JWT auth token in the HTTP headers.
    %% Providing an OAUTH2 token dissables the HELLO.Details authmethods
    %% requested.
    %% so we immediately authenticate it if the JWT is valid.
    %% Otherwise, we fail without checking the HELLO.details even if there
    %% was a valid method requested.


    _ = lager:debug(
        "Initiating WAMP/WS authentication using OAUTH2 access token", []
    ),

    AuthMethods = maps:get(authmethods, Details, []),

    case lists:member(?OAUTH2_AUTH, AuthMethods) of
        true ->
            case valid_authmethods([?OAUTH2_AUTH], Realm) of
                [?OAUTH2_AUTH] ->
                    Uri = bondy_realm:uri(Realm),
                    case bondy_oauth2:verify_jwt(Uri, Token) of
                        {ok, Claims} ->
                            AuthId = maps:get(<<"sub">>, Claims),
                            Ctxt0 = St0#wamp_state.context,
                            Ctxt1 = bondy_context:set_request_details(Ctxt0, Details),
                            Ctxt2 = bondy_context:set_authid(Ctxt1, AuthId),
                            St1 = update_context(Ctxt2, St0),
                            {ok, St1};
                        {error, Reason} when
                        Reason == oauth2_invalid_grant orelse
                        Reason == no_such_realm ->
                            {error, Reason, St0}
                    end;
                _ ->
                    %% oauth2 is not supported by the Realm
                    {error, {unsupported_authmethod, ?OAUTH2_AUTH}, St0}
            end;
        false ->
            %% It is an error to include a auth token and request other
            %% authmethod than OAUTH2.
            {error, oauth2_unused_token, St0}
    end;

maybe_auth_challenge(true, #{authid := UserId} = Details, Realm, St0) ->
    Ctxt0 = St0#wamp_state.context,
    Ctxt1 = bondy_context:set_request_details(Ctxt0, Details),
    Ctxt2 = bondy_context:set_authid(Ctxt1, UserId),
    St1 = update_context(Ctxt2, St0),

    case bondy_security_user:lookup(bondy_realm:uri(Realm), UserId) of
        {error, not_found} ->
            {error, {no_such_role, UserId}, St1};
        User ->
            do_auth_challenge(User, Realm, St1)
    end;

maybe_auth_challenge(true, Details, Realm, St0) ->
    %% There is no authid param, we check if anonymous is allowed
    case bondy_realm:is_auth_method(Realm, ?ANON_AUTH) of
        true ->
            Ctxt0 = St0#wamp_state.context,
            Uri = bondy_realm:uri(Realm),
            Peer = Peer = maps:get(peer, Ctxt0),
            Result = bondy_security_utils:authenticate_anonymous(Uri, Peer),

            case Result of
                {ok, _Ctxt} ->

                    TempId = bondy_utils:uuid(),
                    Ctxt1 = Ctxt0#{
                        request_details => Details,
                        is_anonymous => true
                    },
                    Ctxt2 = bondy_context:set_authid(Ctxt1, TempId),
                    St1 = update_context(Ctxt2, St0),
                    {ok, St1};

                {error, Reason} ->
                    {error, {authentication_failed, Reason}, St0}
            end;
        false ->
            {error, {missing_param, authid}, St0}
    end;

maybe_auth_challenge(false, #{authid := UserId} = Details, _, St0) ->
    Ctxt0 = St0#wamp_state.context,
    Ctxt1 = bondy_context:set_request_details(Ctxt0, Details),
    Ctxt2 = bondy_context:set_authid(Ctxt1, UserId),
    St1 = update_context(Ctxt2, St0),
    {ok, St1};

maybe_auth_challenge(false, Details, _, St0) ->
    TempId = bondy_utils:uuid(),
    Ctxt0 = St0#wamp_state.context,
    Ctxt1 = bondy_context:set_request_details(Ctxt0, Details),
    Ctxt2 = bondy_context:set_authid(Ctxt1, TempId),
    St1 = update_context(Ctxt2, St0),
    {ok, St1}.


%% @private
do_auth_challenge(User, Realm, St) ->
    Details = bondy_context:request_details(St#wamp_state.context),
    AuthMethods0 = maps:get(authmethods, Details, []),
    AuthMethods1 = valid_authmethods(AuthMethods0, Realm),
    do_auth_challenge(AuthMethods1, User, Realm, St).


%% @private
valid_authmethods(List, Realm) ->
    [
        X || X <- List, bondy_realm:is_auth_method(Realm, X)
    ].

%% @private
do_auth_challenge([?ANON_AUTH|T], User, Realm, St0) ->
    %% An authid was provided so we discard this method
    do_auth_challenge(T, User, Realm, St0);

do_auth_challenge([?COOKIE_AUTH|T], User, Realm, St) ->
    %% Unsupported
    do_auth_challenge(T, User, Realm, St);

do_auth_challenge([?WAMPCRA_AUTH = H|T], User, Realm, St0) ->
    case bondy_security_user:has_password(User) of
        true ->
            {ok, Extra, St1} = challenge_extra(H, User, St0),
            {challenge, H, Extra, St1};
        false ->
            do_auth_challenge(T, User, Realm, St0)
    end;

do_auth_challenge([?TICKET_AUTH = H|T], User, Realm, St0) ->
    case bondy_security_user:has_password(User) of
        true ->
            {ok, Extra, St1} = challenge_extra(H, User, St0),
            {challenge, H, Extra, St1};
        false ->
            do_auth_challenge(T, User, Realm, St0)
    end;

do_auth_challenge([?TLS_AUTH|T], User, Realm, St) ->
    %% Unsupported
    do_auth_challenge(T, User, Realm, St);

do_auth_challenge([?OAUTH2_AUTH|_], _, _, St) ->
    %% If we got here it is because we do not have a token.
    %% We fail as the request is invalid.
    {error, oauth2_missing_token, St};

do_auth_challenge([], _, _, St) ->
    {error, no_authmethod, St}.


%% @private
-spec challenge_extra(binary(), bondy_security_user:t(), state()) ->
    {ok, map(), state()}.

challenge_extra(?WAMPCRA_AUTH, User, St0) ->
    %% id is the future session_id
    #{id := Id} = Ctxt = St0#wamp_state.context,
    Details = bondy_context:request_details(Ctxt),
    RealmUri = bondy_context:realm_uri(Ctxt),
    #{<<"username">> := UserId} = User,

    %% The CHALLENGE.Details.challenge|string is a string the client needs to
    %% create a signature for.
    Microsecs = erlang:system_time(microsecond),
    Challenge = jsx:encode(#{
        authmethod => ?WAMPCRA_AUTH,
        authid => UserId,
        authprovider => <<"com.leapsight.bondy">>,
        authrole => maps:get(authrole, Details, <<"user">>), % @TODO
        nonce => bondy_utils:get_nonce(),
        session => Id,
        timestamp => iso8601(Microsecs)
    }),

    %% From the Spec:
    %% WAMP-CRA allows the use of salted passwords following the PBKDF2
    %% key derivation scheme. With salted passwords, the password
    %% itself is never stored, but only a key derived from the password
    %% and a password salt. This derived key is then practically
    %% working as the new shared secret.
    Pass = bondy_security_user:password(RealmUri, User),

    #{
        auth_name := pbkdf2,
        hash_pass := Hash,
        salt := Salt,
        iterations := Iterations
    } = Pass,

    KeyLen = bondy_security_pw:hash_len(Pass),

    Extra = #{
        challenge => Challenge,
        salt => Salt,
        keylen => KeyLen,
        iterations => Iterations
    },

    Millis = erlang:convert_time_unit(Microsecs, microsecond, millisecond),
    %% We compute the signature to compare it to what the client will send
    %% will send on the AUTHENTICATE.signature which is base64-encoded.
    Signature = base64:encode(crypto:hmac(sha256, Hash, Challenge)),
    St1 = St0#wamp_state{auth_timestamp = Millis, auth_signature = Signature},

    {ok, Extra, St1};

challenge_extra(?TICKET_AUTH, _UserId, St0) ->
    Extra = #{},
    Millis = erlang:system_time(millisecond),
    St1 = St0#wamp_state{auth_timestamp = Millis},
    {ok, Extra, St1}.


%% @private
get_realm(St) ->
    Uri = bondy_context:realm_uri(St#wamp_state.context),
    case bondy_config:get(automatically_create_realms) of
        true ->
            %% We force the creation of a new realm if it does not exist
            bondy_realm:get(Uri);
        false ->
            %% Will throw an exception if it does not exist
            bondy_realm:lookup(Uri)
    end.



%% =============================================================================
%% PRIVATE: UTILS
%% =============================================================================


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
encoding(#wamp_state{subprotocol = {_, _, E}}) -> E.


%% @private
do_init(Subprotocol, Peer, Opts) ->
    State = #wamp_state{
        subprotocol = Subprotocol,
        context = bondy_context:new(Peer, Subprotocol),
        auth_token = maps:get(auth_token, Opts, undefined)
    },
    {ok, State}.


%% @private
update_context(Ctxt, St) ->
    St#wamp_state{context = Ctxt}.


%% -----------------------------------------------------------------------------
%% @doc Convert a `util:timestamp()' or a calendar-style `{date(), time()}'
%% tuple to an ISO 8601 formatted string. Note that this function always
%% returns a string with no offset (i.e., ending in "Z").
%% Borrowed from
%% https://github.com/inaka/erlang_iso8601/blob/master/src/iso8601.erl
%% @end
%% -----------------------------------------------------------------------------
-spec iso8601(integer()) -> binary().

iso8601(SystemTime) when is_integer(SystemTime) ->
    %% SystemTime is in microsecs
    MegaSecs = SystemTime div 1000000000000,
    Secs = SystemTime div 1000000 - MegaSecs * 1000000,
    MicroSecs = SystemTime rem 1000000,
    Timestamp = {MegaSecs, Secs, MicroSecs},
    iso8601(calendar:now_to_datetime(Timestamp));

iso8601({{Y, Mo, D}, {H, Mn, S}}) when is_float(S) ->
    FmtStr = "~4.10.0B-~2.10.0B-~2.10.0BT~2.10.0B:~2.10.0B:~9.6.0fZ",
    IsoStr = io_lib:format(FmtStr, [Y, Mo, D, H, Mn, S]),
    list_to_binary(IsoStr);

iso8601({{Y, Mo, D}, {H, Mn, S}}) ->
    FmtStr = "~4.10.0B-~2.10.0B-~2.10.0BT~2.10.0B:~2.10.0B:~2.10.0BZ",
    IsoStr = io_lib:format(FmtStr, [Y, Mo, D, H, Mn, S]),
    list_to_binary(IsoStr).
