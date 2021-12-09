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
-behaviour(bondy_sensitive).
-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
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


%% BONDY_SENSITIVE CALLBACKS
-export([format_status/2]).

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




%% =============================================================================
%% BONDY_SENSITIVE CALLBACKS
%% =============================================================================



-spec format_status(Opts :: normal | terminate, State :: state()) -> term().

format_status(Opt, #wamp_state{} = State) ->
    NewAuthCtxt = bondy_sensitive:format_status(
        Opt, bondy_auth, State#wamp_state.auth_context
    ),
    NewCtxt = bondy_sensitive:format_status(
        Opt, bondy_context, State#wamp_state.context
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

terminate(#wamp_state{context = Ctxt}) ->
    case bondy_context:has_session(Ctxt) of
        true ->
            Session = bondy_context:session(Ctxt),
            bondy_session_manager:close(Session);
        false ->
            ok
    end,
    bondy_context:close(Ctxt).



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
            Error = wamp_message:error(
                ReqType,
                ReqId,
                #{},
                ?WAMP_INVALID_URI,
                [<<"The URI '", Uri/binary, "' is not a valid WAMP URI.">>],
                #{}
            ),
            Bin = wamp_encoding:encode(Error, encoding(St)),
            %% At the moment messages contain only one message as we do not yet
            %% support batched encoding, when/if we enable support for batched
            %% we need to continue processing the additional messages
            {reply, [Bin], St};
        _:{validation_failed, _, _} = Reason ->
            %% Validation of the message option or details failed
            stop(Reason, St);
        _:{invalid_message, _} = Reason ->
            stop(Reason, St)
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
    {ok, state()}
    | {stop, state()}
    | {stop, [binary()], state()}
    | {reply, [binary()], state()}.

handle_inbound_messages(
    [#abort{} = M|_], #wamp_state{state_name = Name} = St0, [])
    when Name =/= established ->
    %% Client aborting, we ignore any subsequent messages
    Uri = M#abort.reason_uri,
    Details = M#abort.details,
    ?LOG_INFO(#{
        description => "Client aborted",
        reason => Uri,
        state_name => Name,
        details => Details
    }),
    ok = bondy_event_manager:notify({wamp, M, St0#wamp_state.context}),
    St1 = St0#wamp_state{state_name = closed},
    {stop, St1};

handle_inbound_messages(
    [#goodbye{}|_], #wamp_state{state_name = established} = St0, Acc) ->

    %% Client initiated a goodbye, we ignore any subsequent messages
    %% We reply with all previous messages plus a goodbye and stop
    Reply = wamp_message:goodbye(
        #{message => <<"Session closed by client.">>},
        ?WAMP_GOODBYE_AND_OUT
    ),
    Bin = wamp_encoding:encode(Reply, encoding(St0)),
    ok = bondy_event_manager:notify({wamp, Reply, St0#wamp_state.context}),
    St1 = St0#wamp_state{state_name = closed},
    {stop, normal, lists:reverse([Bin|Acc]), St1};

handle_inbound_messages(
    [#goodbye{} = M|_], #wamp_state{state_name = shutting_down} = St0, Acc) ->
    %% Client is replying to our goodbye, we ignore any subsequent messages
    %% We reply all previous messages and close
    ok = bondy_event_manager:notify({wamp, M, St0#wamp_state.context}),
    St1 = St0#wamp_state{state_name = closed},
    {stop, shutdown, lists:reverse(Acc), St1};

handle_inbound_messages(
    [#hello{} = M|_],
    #wamp_state{state_name = established, context = #{session := _}} = St,
    Acc) ->
    %% Client already has a session!
    %% RFC: It is a protocol error to receive a second "HELLO" message during
    %% the lifetime of the session and the _Peer_ must fail the session if that
    %% happens.
    %% We reply all previous messages plus an abort message and close
    ok = bondy_event_manager:notify({wamp, M, St#wamp_state.context}),
    Reason = <<"You've sent a HELLO message more than once.">>,
    stop({protocol_violation, Reason}, Acc, St);

handle_inbound_messages(
    [#hello{} = M|_], #wamp_state{state_name = challenging} = St, _) ->
    %% Client does not have a session but we already sent a challenge message
    %% in response to a HELLO message
    ok = bondy_event_manager:notify({wamp, M, St#wamp_state.context}),
    Reason = <<"You've sent a HELLO message more than once.">>,
    stop({protocol_violation, Reason}, St);

handle_inbound_messages([#hello{realm_uri = Uri} = M|_], St0, _) ->
    %% Client is requesting a session
    %% This will return either reply with wamp_welcome() | wamp_challenge()
    %% or abort
    Ctxt0 = St0#wamp_state.context,
    ok = bondy_event_manager:notify({wamp, M, Ctxt0}),

    Ctxt1 = bondy_context:set_realm_uri(Ctxt0, Uri),
    St1 = update_context(Ctxt1, St0),

    %% Lookup or create realm
    case bondy_realm:get(Uri) of
        {error, not_found} ->
            stop({authentication_failed, no_such_realm}, St1);
        Realm ->
            maybe_open_session(
                maybe_auth_challenge(M#hello.details, Realm, St1)
            )
    end;

handle_inbound_messages(
    [#authenticate{} = M|_],
    #wamp_state{state_name = established, context = #{session := _}} = St, _) ->
    ok = bondy_event_manager:notify({wamp, M, St#wamp_state.context}),
    %% Client already has a session so is already authenticated.
    Reason = <<"You've sent an AUTHENTICATE message more than once.">>,
    stop({protocol_violation, Reason}, St);

handle_inbound_messages(
    [#authenticate{} = M|_], #wamp_state{state_name = challenging} = St0, _) ->
    %% Client is responding to a challenge
    ok = bondy_event_manager:notify({wamp, M, St0#wamp_state.context}),

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
    ok = bondy_event_manager:notify({wamp, M, St#wamp_state.context}),
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
            Bin = wamp_encoding:encode(M, encoding(St)),
            handle_inbound_messages(T, update_context(Ctxt, St), [Bin | Acc]);
        {stop, M, Ctxt} ->
            Bin = wamp_encoding:encode(M, encoding(St)),
            {stop, [Bin | Acc], update_context(Ctxt, St)}
    end;

handle_inbound_messages(_, #wamp_state{state_name = shutting_down} = St, _) ->
    %% TODO should we reply with ERROR and keep on waiting for the client GOODBYE?
    Reason = <<"Router is shutting down. You should have replied with GOODBYE message.">>,
    stop({protocol_violation, Reason}, St);

handle_inbound_messages([], St, []) ->
    %% We have no replies
    {ok, St};

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
    M = wamp_message:challenge(AuthMethod, Challenge),
    ok = bondy_event_manager:notify({wamp, M, St0#wamp_state.context}),
    Bin = wamp_encoding:encode(M, encoding(St0)),
    St1 = St0#wamp_state{
        state_name = challenging,
        authmethod = AuthMethod
    },
    {reply, Bin, St1};

maybe_open_session({ok, St}) ->
    %% No need for a challenge, anonymous|trust or security disabled
    open_session(#{}, St);

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
        Id = bondy_context:id(Ctxt0),
        RealmUri = bondy_context:realm_uri(Ctxt0),
        ReqDetails = bondy_context:request_details(Ctxt0),
        Authid = bondy_auth:user_id(AuthCtxt),
        Authrole = bondy_auth:role(AuthCtxt),
        Authroles = bondy_auth:roles(AuthCtxt),
        Authprovider = bondy_auth:provider(AuthCtxt),
        Authmethod = bondy_auth:method(AuthCtxt),
        Agent = maps:get(agent, ReqDetails, undefined),
        UserMeta = bondy_rbac_user:meta(bondy_auth:user(AuthCtxt)),

        Properties = #{
            peer => maps:get(peer, Ctxt0),
            security_enabled => bondy_realm:is_security_enabled(RealmUri),
            is_anonymous => Authid == anonymous,
            agent => Agent,
            roles => maps:get(roles, ReqDetails, undefined),
            authid => maybe_gen_authid(Authid),
            authprovider => Authprovider,
            authmethod => Authmethod,
            authrole => Authrole,
            authroles => Authroles
        },

        %% We open a session
        Session = bondy_session_manager:open(Id, RealmUri, Properties),

        %% We set the session in the context
        Ctxt1 = bondy_context:set_session(Ctxt0, Session),
        St1 = update_context(Ctxt1, St0),

        %% We send the WELCOME message
        Welcome = wamp_message:welcome(
            Id,
            #{
                realm => RealmUri,
                agent => bondy_router:agent(),
                roles => bondy_router:roles(),
                authprovider => Authprovider,
                authmethod => Authmethod,
                authrole => to_bin(Authrole),
                authid => maybe_gen_authid(Authid),
                authextra => Extra#{
                    'x_authroles' => [to_bin(R) || R <- Authroles],
                    'x_meta' => UserMeta
                }
            }
        ),
        ok = bondy_event_manager:notify({wamp, Welcome, Ctxt1}),
        Bin = wamp_encoding:encode(Welcome, encoding(St1)),

        ok = bondy_logger_utils:update_process_metadata(#{
            agent => bondy_utils:maybe_slice(Agent, 0, 64),
            authmethod => Authmethod,
            realm_uri => RealmUri
        }),

        {reply, Bin, St1#wamp_state{state_name = established}}
    catch
        error:{invalid_options, missing_client_role} = Reason ->
            stop(Reason, St0)
    end.


%% @private
to_bin(Term) when is_atom(Term) ->
    atom_to_binary(Term, utf8);

to_bin(Term) when is_binary(Term) ->
    Term.


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
    case bondy_auth:init(SessionId, Realm, UserId, Roles, Peer) of
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
    case bondy_auth:init(SessionId, Realm, anonymous, Roles, Peer) of
        {ok, AuthCtxt} ->
            St2 = St1#wamp_state{auth_context = AuthCtxt},
            auth_challenge(?WAMP_ANON_AUTH, St2);
        {error, Reason} ->
            {error, {authentication_failed, Reason}, St1}
    end;

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
auth_challenge(Method, St0) ->
    Ctxt = St0#wamp_state.context,
    AuthCtxt0 = St0#wamp_state.auth_context,

    Details = bondy_context:request_details(Ctxt),

    case bondy_auth:challenge(Method, Details, AuthCtxt0) of
        {ok, AuthCtxt1} ->
            St1 = St0#wamp_state{
                auth_context = AuthCtxt1,
                auth_timestamp = erlang:system_time(millisecond)
            },
            {ok, St1};
        {ok, ChallengeExtra, AuthCtxt1} ->
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
    ok = bondy_event_manager:notify({wamp, M, St0#wamp_state.context}),
    Bin = wamp_encoding:encode(M, encoding(St0)),

    %% We reply all previous messages plus an abort message and close
    St1 = St0#wamp_state{state_name = closed},
    {stop, Uri, [Bin|Acc], St1}.


%% @private
abort_message(internal_error) ->
    Details = #{
        message => <<"Internal system error, contact your administrator.">>
    },
    wamp_message:abort(Details, ?BONDY_ERROR_INTERNAL);

abort_message(decoding_error) ->
    Details = #{
        message => <<"An error ocurred while deserealising a message.">>
    },
    wamp_message:abort(Details, ?WAMP_PROTOCOL_VIOLATION);

abort_message({invalid_message, _M}) ->
    Details = #{
        message => <<"An invalid message was received.">>
    },
    wamp_message:abort(Details, ?WAMP_PROTOCOL_VIOLATION);

abort_message({no_authmethod, []}) ->
    Details = #{
        message => <<"No authentication method requested. At least one authentication method is required.">>
    },
    wamp_message:abort(Details, ?WAMP_NOT_AUTH_METHOD);

abort_message({no_authmethod, _Opts}) ->
    Details = #{
        message => <<"The requested authentication methods are not available for this user on this realm.">>
    },
    wamp_message:abort(Details, ?WAMP_NOT_AUTH_METHOD);

abort_message(connections_not_allowed) ->
    Details = #{
        message => <<"The Realm does not allow user connections ('allow_connections' setting is off). This might be a temporary measure added by the administrator or the realm is meant to be used only as a Same Sign-on (SSO) realm.">>
    },
    wamp_message:abort(Details, ?WAMP_AUTHENTICATION_FAILED);

abort_message(no_such_realm) ->
    Details = #{
        message => <<"Realm does not exist.">>
    },
    wamp_message:abort(Details, ?WAMP_NO_SUCH_REALM);

abort_message(no_such_group) ->
    Details = #{
        message => <<"Group does not exist.">>
    },
    wamp_message:abort(Details, ?WAMP_NO_SUCH_ROLE);

abort_message({no_such_user, Username}) ->
    Details = #{
        message => <<"User '", Username/binary, "' does not exist.">>
    },
    wamp_message:abort(Details, ?WAMP_NO_SUCH_PRINCIPAL);

abort_message({protocol_violation, Reason}) when is_binary(Reason) ->
    wamp_message:abort(#{message => Reason}, ?WAMP_PROTOCOL_VIOLATION);

abort_message({authentication_failed, invalid_authmethod}) ->
    Details = #{
        message => <<"Unsupported authentication method.">>
    },
    wamp_message:abort(Details, ?WAMP_AUTHENTICATION_FAILED);

abort_message({authentication_failed, no_such_realm}) ->
    Details = #{
        message => <<"Realm does not exist.">>
    },
    wamp_message:abort(Details, ?WAMP_NO_SUCH_REALM);

abort_message({authentication_failed, no_such_group}) ->
    Details = #{
        message => <<"A group does not exist for the the groupname or one of the groupnames requested ('authrole' or 'x_authroles').">>
    },
    wamp_message:abort(Details, ?WAMP_NO_SUCH_ROLE);

abort_message({authentication_failed, {no_such_user, Username}}) ->
    Details = #{
        message => <<"User '", Username/binary, "' does not exist.">>
    },
    wamp_message:abort(Details, ?WAMP_NO_SUCH_PRINCIPAL);

abort_message({authentication_failed, user_disabled}) ->
    Details = #{
        message => <<"The user requested (via 'authid') is disabled so we cannot establish a session. Contact your administrator to enable the user.">>
    },
    wamp_message:abort(Details, ?WAMP_NO_SUCH_PRINCIPAL);

abort_message({authentication_failed, invalid_scheme}) ->
    Details = #{
        message => <<"Unsupported authentication scheme.">>
    },
    wamp_message:abort(Details, ?WAMP_AUTHENTICATION_FAILED);

abort_message({authentication_failed, missing_signature}) ->
    Details = #{
        message => <<"The signature did not match.">>
    },
    wamp_message:abort(Details, ?WAMP_AUTHENTICATION_FAILED);

abort_message({authentication_failed, oauth2_invalid_grant}) ->
    Details = #{
        message => <<
            "The access token provided is expired, revoked, malformed,"
            " or invalid either because it does not match the Realm used in the"
            " request, or because it was issued to another peer."
        >>
    },
    wamp_message:abort(Details, ?WAMP_AUTHENTICATION_FAILED);

abort_message({authentication_failed, _}) ->
    %% bad_signature,
    Details = #{
        message => <<"The signature did not match.">>
    },
    wamp_message:abort(Details, ?WAMP_AUTHENTICATION_FAILED);

abort_message({unsupported_encoding, Encoding}) ->
    Details = #{
        message => <<
            "Unsupported message encoding '",
            (atom_to_binary(Encoding))/binary,
            "'."
        >>
    },
    wamp_message:abort(Details, ?WAMP_PROTOCOL_VIOLATION);

abort_message({validation_failed, Details, _ReqInfo}) ->
    wamp_message:abort(Details, ?WAMP_PROTOCOL_VIOLATION);

abort_message({invalid_options, missing_client_role}) ->
    Details = #{
        message => <<
            "No client roles provided. Please provide at least one client role."
        >>
    },
    wamp_message:abort(Details, ?WAMP_PROTOCOL_VIOLATION);

abort_message({missing_param, Param}) ->
    Details = #{
        message => <<
            "Missing value for required parameter '", Param/binary, "'."
        >>
    },
    wamp_message:abort(Details, ?WAMP_PROTOCOL_VIOLATION);

abort_message({unsupported_authmethod, Method}) ->
    Details = #{
        message => <<
            "Router could not use the '", Method/binary, "' authmethod requested."
            " Either the method is not supported by the Router or it is not"
            " allowed by the Realm."
        >>
    },
    wamp_message:abort(Details, ?WAMP_NOT_AUTH_METHOD);

abort_message({invalid_authmethod, Method}) ->
    Details = #{
        message => <<
            "Router could not use the authmethod requested ('",
            Method/binary,
            "')."
        >>
    },
    wamp_message:abort(Details, ?WAMP_NOT_AUTH_METHOD);

abort_message({Code, Term}) when is_atom(Term) ->
    abort_message({Code, ?CHARS2BIN(atom_to_list(Term))}).


%% @private
% abort_message(Details, Uri) when is_map(Details), is_binary(Uri) ->
%     wamp_message:abort(Details, Uri).



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
do_init({_, _, Serializer} = Subprotocol, Peer, _Opts) ->
    State = #wamp_state{
        subprotocol = Subprotocol,
        context = bondy_context:new(Peer, Subprotocol)
    },
    ok = bondy_logger_utils:update_process_metadata(#{
        serializer => Serializer
    }),
    {ok, State}.


%% @private
update_context(Ctxt, St) ->
    St#wamp_state{context = Ctxt}.

