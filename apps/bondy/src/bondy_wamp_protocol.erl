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
    auth_context    ::  map() | undefined,
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
    [#authenticate{} = M|_], #wamp_state{state_name = challenging} = St0, _) ->
    %% Client is responding to a challenge
    ok = bondy_event_manager:notify({wamp, M, St0#wamp_state.context}),

    AuthMethod = St0#wamp_state.authmethod,
    AuthCtxt0 = St0#wamp_state.auth_context,
    Signature = M#authenticate.signature,
    Extra = M#authenticate.extra,

    Result = bondy_auth:authenticate(AuthMethod, Signature, Extra, AuthCtxt0),

    case Result of
        {ok, Extra, AuthCtxt1} ->
            St1 = St0#wamp_state{auth_context = AuthCtxt1},
            open_session(Extra, St1);
        {error, Reason} ->
            abort({authentication_failed, Reason}, St0)
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
    %% No need for a challenge, security disabled or anonymous enabled
    open_session(undefined, St);

maybe_open_session({error, Reason, St}) ->
    abort(Reason, St).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%% -----------------------------------------------------------------------------
-spec open_session(map() | undefined, state()) ->
    {reply, binary(), state()}
    | {stop, binary(), state()}.

open_session(Extra, St0) ->
    try
        Ctxt0 = St0#wamp_state.context,
        AuthCtxt = St0#wamp_state.auth_context,
        Id = bondy_context:id(Ctxt0),
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
                agent => bondy_router:agent(),
                roles => bondy_router:roles(),
                authprovider => bondy_auth:provider(AuthCtxt),
                authmethod => bondy_auth:method(AuthCtxt),
                authrole => bondy_auth:role(AuthCtxt),
                'x_authroles' => bondy_auth:roles(AuthCtxt),
                authid => maybe_gen_authid(bondy_auth:user_id(AuthCtxt)),
                authextra => Extra
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
maybe_gen_authid(anonymous) ->
    bondy_utils:uuid();

maybe_gen_authid(UserId) ->
    UserId.


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
    Uri = bondy_context:realm_uri(St#wamp_state.context),
    Reason = <<"Realm '", Uri/binary, "' does not exist.">>,
    %% REVIEW shouldn't his be a ?WAMP_NO_SUCH_REALM error?
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

abort(no_such_realm, St) ->
    Uri = bondy_context:realm_uri(St#wamp_state.context),
    Reason = <<"Realm '", Uri/binary, "' does not exist.">>,
    abort(?WAMP_NO_SUCH_REALM, Reason, #{}, St);

abort({missing_param, Param}, St) ->
    Reason = <<"Missing value for required parameter '", Param/binary, "'.">>,
    abort(?WAMP_PROTOCOL_VIOLATION, Reason, #{}, St);

abort(no_such_role, St) ->
    Reason = <<"User does not exist.">>,
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
    {error, no_such_realm, St};

maybe_auth_challenge(Details, Realm, St) ->
    Status = bondy_realm:security_status(Realm),
    maybe_auth_challenge(Status, Details, Realm, St).


%% @private
maybe_auth_challenge(enabled, #{authid := UserId} = Details, Realm, St0)
when UserId =/= <<"anonymous">> ->
    Ctxt0 = St0#wamp_state.context,
    Ctxt1 = bondy_context:set_request_details(Ctxt0, Details),
    Ctxt = bondy_context:set_authid(Ctxt1, UserId),
    St1 = update_context(Ctxt, St0),

    SessionId = bondy_context:id(Ctxt),
    Roles = authroles(Details),
    Peer = bondy_context:peer(Ctxt),

    %% We initialise the auth context
    AuthCtxt = bondy_auth:init(SessionId, Realm, UserId, Roles, Peer),
    St2 = St1#wamp_state{auth_context = AuthCtxt},

    ReqMethods = maps:get(authmethods, Details, []),
    Methods = bondy_auth:available_methods(ReqMethods, AuthCtxt),
    auth_challenge(Methods, St2);


maybe_auth_challenge(enabled, Details, Realm, St0) ->
    %% authid is <<"anonymous">> or missing
    Ctxt0 = St0#wamp_state.context,
    Ctxt1 = bondy_context:set_request_details(Ctxt0, Details),
    Ctxt = bondy_context:set_authid(Ctxt1, anonymous),
    St1 = update_context(Ctxt, St0),

    SessionId = bondy_context:id(Ctxt),
    Roles = [<<"anonymous">>],
    Peer = bondy_context:peer(Ctxt),

    %% We initialise the auth context with anon id and role
    AuthCtxt = bondy_auth:init(SessionId, Realm, anonymous, Roles, Peer),
    St2 = St1#wamp_state{auth_context = AuthCtxt},

    auth_challenge([?WAMP_ANON_AUTH], St2);

maybe_auth_challenge(disabled, #{authid := UserId} = Details, _, St0) ->
    Ctxt0 = St0#wamp_state.context,
    Ctxt1 = bondy_context:set_request_details(Ctxt0, Details),
    Ctxt2 = bondy_context:set_authid(Ctxt1, UserId),
    St1 = update_context(Ctxt2, St0),
    {ok, St1};

maybe_auth_challenge(disabled, Details0, _, St) ->
    %% We set a temporary authid
    Details = Details0#{authid => bondy_utils:uuid()},
    maybe_auth_challenge(disabled, Details, St).


%% @private
authroles(Details) ->
    case maps:get('x_authroles', Details, undefined) of
        undefined ->
            case maps:get(authrole, Details, undefined) of
                undefined ->
                    undefined;
                Role ->
                    [Role]
            end;
        List when is_list(List) ->
            List;
        _ ->
            %% TODO Should we abort?
            []
    end.


%% @private
auth_challenge([?WAMP_ANON_AUTH|T], St0) ->
    %% An authid was provided so we discard this method
    auth_challenge(T,St0);

auth_challenge([H|T], St0) ->
    Ctxt = St0#wamp_state.context,
    AuthCtxt0 = St0#wamp_state.auth_context,

    Details = bondy_context:request_details(Ctxt),

    case bondy_auth:challenge(H, Details, AuthCtxt0) of
        {ok, ChallengeExtra, AuthCtxt1} ->
            St1 = St0#wamp_state{
                auth_context = AuthCtxt1,
                auth_timestamp = erlang:system_time(millisecond)
            },
            {challenge, H, ChallengeExtra, St1};
        {error, _Reason} ->
            %% TODO LOG
            auth_challenge(T, St0)
    end;

auth_challenge([], St) ->
    {error, no_authmethod, St}.


%% @private
-spec get_realm(state()) -> bondy_realm:t() | {error, not_found}.

get_realm(St) ->
    bondy_realm:get(bondy_context:realm_uri(St#wamp_state.context)).


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

