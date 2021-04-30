%% =============================================================================
%%  bondy_wamp_protocol.erl -
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
    challenge               ::  binary() | undefined,
    auth_challenge_state    ::  map() | undefined,
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
    Ctxt = St#wamp_state.context,
    ok = bondy_event_manager:notify({wamp, M, Ctxt}),

    AuthMethod = St#wamp_state.authmethod,
    Signature = M#authenticate.signature,
    Extra = M#authenticate.extra,
    ChallengeState = St#wamp_state.auth_challenge_state,

    Result = bondy_auth_method:authenticate(
        AuthMethod, Signature, Extra, ChallengeState, Ctxt
    ),

    case Result of
        {ok, _AuthCtxt} ->
            open_session(St);
        {error, Reason} ->
            abort({authentication_failed, Reason}, St)
    end;

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
        Session = bondy_session_manager:open(
            Id, maps:get(peer, Ctxt0), Realm, Details
        ),

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

abort({authentication_failed, oauth2_invalid_grant}, St) ->
    Reason = <<
        "The access token provided is expired, revoked, malformed,"
        " or invalid either because it does not match the Realm used in the"
        " request, or because it was issued to another peer."
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
        timestamp => bondy_utils:iso8601(erlang:system_time(microsecond))
    },
    wamp_message:abort(Details, Type).


%% @private
maybe_auth_challenge(_, {error, not_found}, St) ->
    RealmUri = bondy_context:realm_uri(St#wamp_state.context),
    {error, {no_such_realm, RealmUri}, St};

maybe_auth_challenge(Details, Realm, St) ->
    Status = bondy_realm:security_status(Realm),
    maybe_auth_challenge(Status, Details, Realm, St).


%% @private
maybe_auth_challenge(enabled, #{authid := UserId} = Details, Realm, St0) ->
    Ctxt0 = St0#wamp_state.context,
    Ctxt1 = bondy_context:set_request_details(Ctxt0, Details),
    Ctxt2 = bondy_context:set_authid(Ctxt1, UserId),
    St1 = update_context(Ctxt2, St0),

    case bondy_security_user:lookup(bondy_realm:uri(Realm), UserId) of
        {error, not_found} ->
            {error, {no_such_role, UserId}, St1};
        User ->
            auth_challenge(User, Realm, St1)
    end;

maybe_auth_challenge(enabled, Details, Realm, St0) ->
    %% Default to anonymous in case authmethods is empty
    AuthMethods = maps:get(authmethods, Details, [?ANON_AUTH]),

    case lists:member(?ANON_AUTH, AuthMethods) of
        true ->
            case bondy_realm:is_auth_method(Realm, ?ANON_AUTH) of
                true ->
                    Ctxt0 = St0#wamp_state.context,
                    Uri = bondy_realm:uri(Realm),
                    Peer = Peer = maps:get(peer, Ctxt0),
                    Result = bondy_security_utils:authenticate_anonymous(
                        Uri, Peer
                    ),
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
                    {error, {missing_param, <<"authid">>}, St0}
            end;
        false ->
            {error, {missing_param, <<"authid">>}, St0}
    end;


maybe_auth_challenge(disabled, #{authid := UserId} = Details, _, St0) ->
    Ctxt0 = St0#wamp_state.context,
    Ctxt1 = bondy_context:set_request_details(Ctxt0, Details),
    Ctxt2 = bondy_context:set_authid(Ctxt1, UserId),
    St1 = update_context(Ctxt2, St0),
    {ok, St1};

maybe_auth_challenge(disabled, Details0, _, St) ->
    %% We set a temporary authid
    Details = Details0#{authid =>  bondy_utils:uuid()},
    maybe_auth_challenge(disabled, Details, St).


%% @private
auth_challenge(User, Realm, St) ->
    Ctxt = St#wamp_state.context,
    Details = bondy_context:request_details(Ctxt),
    Requested = maps:get(authmethods, Details, []),
    case bondy_auth_method:valid_methods(Requested, User, Ctxt) of
        [] ->
            {error, no_authmethod, St};
        ValidMethods ->
            auth_challenge(ValidMethods, User, Realm, St)
    end.


%% @private
auth_challenge([?ANON_AUTH|T], User, Realm, St0) ->
    %% An authid was provided so we discard this method
    auth_challenge(T, User, Realm, St0);

auth_challenge([H|T], User, Realm, St0) ->
    case bondy_auth_method:challenge(H, User, St0#wamp_state.context) of
        {ok, ChallengeExtra, ChallengeState} ->
            St1 = St0#wamp_state{
                auth_challenge_state = ChallengeState,
                auth_timestamp = erlang:system_time(millisecond)
            },
            {challenge, H, ChallengeExtra, St1};
        {error, no_password} ->
            auth_challenge(T, User, Realm, St0);
        {error, unsupported_method} ->
            auth_challenge(T, User, Realm, St0);
        {error, invalid_authmethod} ->
            %% TODO LOG
            auth_challenge(T, User, Realm, St0)
    end;

auth_challenge([], _, _, St) ->
    %% TODO This is wrong because we are giving away information to a hacker
    %% We should pick the first
    %% We need to make the hacker work so pick wamp-scram with random data and
    %% do the challenge
    {error, no_authmethod, St}.


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
do_init(Subprotocol, Peer, _Opts) ->
    State = #wamp_state{
        subprotocol = Subprotocol,
        context = bondy_context:new(Peer, Subprotocol)
    },
    {ok, State}.


%% @private
update_context(Ctxt, St) ->
    St#wamp_state{context = Ctxt}.

