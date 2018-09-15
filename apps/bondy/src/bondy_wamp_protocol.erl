%% =============================================================================
%%  bondy_wamp_protocol.erl -
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
%% @doc Tnis module encapsulates the WAMP protocol in a pseudo FSM.
%% It is meant to be used by a transport process e.g. a gen_server owning a
%% gen_tcp through the handle_inbound/2 and handle_outbound/2 functions.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_wamp_protocol).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").

-define(SHUTDOWN_TIMEOUT, 5000).

-record(wamp_state, {
    subprotocol             ::  subprotocol() | undefined,
    transport_info          ::  bondy_wamp_peer:transport_info(),
    authmethod              ::  any(),
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
-type event_type()          ::  in | out.
-type raw_wamp_message()    ::  wamp_message:message()
                                | {raw, ping}
                                | {raw, pong}
                                | {raw, wamp_encoding:raw_error()}.

-export_type([frame_type/0]).
-export_type([encoding/0]).
-export_type([subprotocol/0]).
-export_type([state/0]).


-export([init/4]).
-export([init/5]).
-export([peer/1]).
-export([agent/1]).
-export([session_id/1]).
-export([handle_inbound/2]).
-export([handle_outbound/2]).
-export([terminate/1]).

%% PRIVATE
-export([closed/3]).
-export([establishing/3]).
-export([challenging/3]).
-export([failed/3]).
-export([established/3]).
-export([shutting_down/3]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec init(
    binary() | subprotocol(),
    pid(),
    {inet:ip_address(), non_neg_integer()},
    map()
    ) -> {ok, state()} | {error, any(), state()}.

init(Term, Pid, Peername, Opts) ->
    case wamp_subprotocol:validate(Term) of
        {ok, Subproto} ->
            do_init(Subproto, Pid, Peername, Opts);
        {error, Reason} ->
            {error, Reason, undefined}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec init(binary() | subprotocol(), pid(), module(), any(), map()) ->
    {ok, state()} | {error, any(), state()}.

init(Term, Pid, Transport, Socket, Opts) ->
    case wamp_subprotocol:validate(Term) of
        {ok, Subproto} ->
            do_init(Subproto, Pid, Transport, Socket, Opts);
        {error, Reason} ->
            {error, Reason, undefined}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec peer(state()) -> bondy_wamp_peer:t().

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
-spec terminate(state()) -> ok.

terminate(St) ->
    bondy_context:close(St#wamp_state.context).




%% -----------------------------------------------------------------------------
%% @doc
%% Handles wamp frames, decoding one or more messages, routing them and replying
%% when required.
%% @end
%% -----------------------------------------------------------------------------
-spec handle_inbound(binary(), state()) ->
    {ok, state()}
    | {stop, state()}
    | {stop, [binary()], state()}
    | {reply, [binary()], state()}.

handle_inbound(Data, St0) ->
    case ?MODULE:(St0#wamp_state.state_name)(in, Data, St0) of
        {ok, NextState, St1} ->
            {ok, St1#wamp_state{state_name = NextState}};
        {reply, NextState, Messages, St1} ->
            {reply, Messages, St1#wamp_state{state_name = NextState}};
        {stop, NextState, St1} ->
            {stop, St1#wamp_state{state_name = NextState}};
        {stop, NextState, Messages, St1} ->
            {stop, Messages, St1#wamp_state{state_name = NextState}}
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

handle_outbound(M, St0) ->
    case ?MODULE:(St0#wamp_state.state_name)(out, M, St0) of
        {ok, NextState, St1} ->
            {ok, St1#wamp_state{state_name = NextState}};
        {reply, NextState, Messages, St1} ->
            {reply, Messages, St1#wamp_state{state_name = NextState}};
        {stop, NextState, St1} ->
            {stop, St1#wamp_state{state_name = NextState}};
        {stop, NextState, Messages, St1} ->
            {stop, Messages, St1#wamp_state{state_name = NextState}};
        {stop, NextState, Messages, St1, Timeout} ->
            {stop, Messages, St1#wamp_state{state_name = NextState}, Timeout}
    end.



%% =============================================================================
%% PRIVATE: STATE FUNCTIONS
%% =============================================================================


%% @private
-spec closed(
    event_type(), Data :: binary() | wamp_message(), State :: state()) ->
    {ok, state_name(), state()}
    | {stop, state_name(),state()}
    | {stop, state_name(), [binary()], state()}
    | {reply, state_name(), [binary()], state()}.

closed(in, Data, St) ->
    %% Since we do not yet have a session, we carry on on the same process
    try wamp_encoding:decode(St#wamp_state.subprotocol, Data) of
        {Messages, <<>>} -> closed(in, Messages, St, [])
    catch
        _:Reason ->
            abort(Reason, St)
    end.


%% @private
-spec establishing(
    event_type(), Data :: binary() | wamp_message(), State :: state()) ->
    {ok, state_name(), state()}
    | {stop, state_name(),state()}
    | {stop, state_name(), [binary()], state()}
    | {reply, state_name(), [binary()], state()}.

establishing(in, Data, St) ->
    %% Since we do not yet have a session, we carry on on the same process
    try wamp_encoding:decode(St#wamp_state.subprotocol, Data) of
        {Messages, <<>>} -> establishing(in, Messages, St, [])
    catch
        _:Reason ->
            abort(Reason, St)
    end.


%% @private
-spec challenging(
    event_type(), Data :: binary() | wamp_message(), State :: state()) ->
    {ok, state_name(), state()}
    | {stop, state_name(),state()}
    | {stop, state_name(), [binary()], state()}
    | {reply, state_name(), [binary()], state()}.

challenging(in, Data, St) ->
    %% Since we do not yet have a session, we carry on on the same process
    try wamp_encoding:decode(St#wamp_state.subprotocol, Data) of
        {Messages, <<>>} -> challenging(in, Messages, St, [])
    catch
        _:Reason ->
            abort(Reason, St)
    end.


%% @private
-spec failed(
    event_type(), Data :: binary() | wamp_message(), State :: state()) ->
    {ok, state_name(), state()}
    | {stop, state_name(),state()}
    | {stop, state_name(), [binary()], state()}
    | {reply, state_name(), [binary()], state()}.

failed(in, Data, St) ->
    try wamp_encoding:decode(St#wamp_state.subprotocol, Data) of
        {Messages, <<>>} -> failed(in, Messages, St, [])
    catch
        _:Reason ->
            abort(Reason, St)
    end.


%% @private
-spec established(
    event_type(), Data :: binary() | wamp_message(), State :: state()) ->
    {ok, state_name(), state()}
    | {stop, state_name(),state()}
    | {stop, state_name(), [binary()], state()}
    | {reply, state_name(), [binary()], state()}.

%% INBOUND
established(in, Data, St) when is_binary(Data) ->
    %% DO this in the session process (for calls)
    %% and spawn a process from there for all other messages
    Subproto = St#wamp_state.subprotocol,

    try
        case wamp_encoding:decode_message_name(Subproto, Data) of
            Name when Name == call orelse
            Name == register orelse
            Name == goodbye ->
                %% Serialise it to keep WAMP invocation order guarantee
                {Messages, <<>>} = wamp_encoding:decode(Subproto, Data),
                established(in, Messages, St, []);
            _ ->
                %% Handle asynchronously
                case bondy_router:async_forward(Data, St#wamp_state.context) of
                    {ok, Ctxt} ->
                        {ok, established, update_context(Ctxt, St)};
                    {reply, M, Ctxt} ->
                        Bin = wamp_encoding:encode(M, encoding(St)),
                        {reply, established, [Bin], update_context(Ctxt, St)};
                    {stop, M, Ctxt} ->
                        Bin = wamp_encoding:encode(M, encoding(St)),
                        {stop, failed, [Bin], update_context(Ctxt, St)}
                end
        end
    catch
        _:Reason ->
            abort(Reason, St)
    end;


%% OUTBOUND
established(out, Bin, St) when is_binary(Bin) ->
    {reply, established, Bin, St};

established(out, #result{} = M, St0) ->
    Ctxt0 = St0#wamp_state.context,
    ok = bondy_event_manager:notify({wamp, M, Ctxt0}),
    St1 = update_context(bondy_context:reset(Ctxt0), St0),
    Bin = wamp_encoding:encode(M, encoding(St1)),
    {reply, established, Bin, St1};

established(out, #error{request_type = ?CALL} = M, St0) ->
    Ctxt0 = St0#wamp_state.context,
    ok = bondy_event_manager:notify({wamp, M, Ctxt0}),
    St1 = update_context(bondy_context:reset(Ctxt0), St0),
    Bin = wamp_encoding:encode(M, encoding(St1)),
    {reply, established, Bin, St1};

established(out, #goodbye{} = M, St0) ->
    %% Bondy is shutting_down this session, we will stop when we
    %% get the client's goodbye response
    ok = bondy_event_manager:notify({wamp, M, St0#wamp_state.context}),
    Bin = wamp_encoding:encode(M, encoding(St0)),
    %% This should be a
    %% {reply, shutting_down, Bin, St0, ?SHUTDOWN_TIMEOUT};
    %% and we should have a timer(Timeout) that triggers the stop action
    {stop, shutting_down, Bin, St0, ?SHUTDOWN_TIMEOUT};

established(out, M, St) when is_tuple(M) ->
    case wamp_message:is_message(M) of
        true ->
            ok = bondy_event_manager:notify({wamp, M, St#wamp_state.context}),
            Bin = wamp_encoding:encode(M, encoding(St)),
            {reply, established, Bin, St};
        false ->
            %% RFC: WAMP implementations MUST close sessions (disposing all of their resources such as subscriptions and registrations) on protocol errors caused by offending peers.
            _ = lager:error(
                "Invalid WAMP message; message=~p",
                [M]
            ),
            {stop, closed, St}
    end.


%% @private
-spec shutting_down(
    event_type(), Data :: binary() | wamp_message(), State :: state()) ->
    {ok, state_name(), state()}
    | {stop, state_name(),state()}
    | {stop, state_name(), [binary()], state()}
    | {reply, state_name(), [binary()], state()}.

shutting_down(in, Data, St) ->
    try wamp_encoding:decode(St#wamp_state.subprotocol, Data) of
        {Messages, <<>>} -> shutting_down(in, Messages, St, [])
    catch
        _:Reason ->
            abort(Reason, St)
    end.



%% =============================================================================
%% PRIVATE: AUX STATE FUNCTIONS
%% =============================================================================



%% @private
-spec closed(
    event_type(), [raw_wamp_message()], state(), Acc :: [raw_wamp_message()]) ->
    {ok, state_name(), state()}
    | {stop, state_name(),state()}
    | {stop, state_name(), [binary()], state()}
    | {reply, state_name(), [binary()], state()}.

closed(_, [], St, []) ->
    %% We have no replies
    {ok, closed, St};

closed(_, [], St, Acc) ->
    {reply, closed, lists:reverse(Acc), St};

closed(in, [#hello{realm_uri = Uri} = M|_], St0, _) ->
    %% Client is requesting a session
    %% This will return either reply with wamp_welcome() | wamp_challenge()
    %% or abort
    Ctxt0 = St0#wamp_state.context,
    ok = bondy_stats:update({wamp_message, M, Ctxt0}),

    Ctxt1 = Ctxt0#{realm_uri => Uri},
    St1 = update_context(Ctxt1, St0),
    maybe_open_session(
        maybe_auth_challenge(M#hello.details, get_realm(St1), St1)
    );

closed(in, [#abort{} = M|_], St0, []) ->
    %% Client aborting, we ignore any subsequent messages
    Uri = M#abort.reason_uri,
    Details = M#abort.details,
    _ = lager:info(
        "Client aborted; reason=~s, state_name=~p, details=~p",
        [Uri, closed, Details]
    ),
    {stop, closed, St0};

closed(_, _, St, _) ->
    %% Client does not have a session and message is not HELLO
    abort(
        closed,
        ?WAMP_PROTOCOL_VIOLATION,
        <<"You need to establish a session first.">>,
        #{},
        St
    ).


%% @private
-spec establishing(
    event_type(), [raw_wamp_message()], state(), Acc :: [raw_wamp_message()]) ->
    {ok, state_name(), state()}
    | {stop, state_name(),state()}
    | {stop, state_name(), [binary()], state()}
    | {reply, state_name(), [binary()], state()}.

establishing(_, [], St, []) ->
    %% We have no replies
    {ok, establishing, St};

establishing(_, [], St, Acc) ->
    {reply, establishing, lists:reverse(Acc), St};

establishing(in, [#abort{} = M|_], St0, _) ->
    %% Client aborting, we ignore any subsequent messages
    Uri = M#abort.reason_uri,
    Details = M#abort.details,
    _ = lager:info(
        "Client aborted; reason=~s, state_name=~p, details=~p",
        [Uri, establishing, Details]
    ),
    {stop, closed, St0};

establishing(in, [#hello{} = M|_], St, _) ->
    %% Client already sent a hello!
    %% RFC: It is a protocol error to receive a second "HELLO" message during
    %% the lifetime of the session and the _Peer_ must fail the session if that
    %% happens.
    ok = bondy_event_manager:notify({wamp, M, St#wamp_state.context}),
    %% We reply all previous messages plus an abort message and close
    abort(
        closed,
        ?WAMP_PROTOCOL_VIOLATION,
        <<"You've sent a HELLO message more than once.">>,
        #{},
        St
    );

establishing(_, _, State, _) ->
    {stop, failed, State}.


%% @private
-spec challenging(event_type(), [raw_wamp_message()], state(), Acc :: [raw_wamp_message()]) ->
    {ok, state_name(), state()}
    | {stop, state_name(),state()}
    | {stop, state_name(), [binary()], state()}
    | {reply, state_name(), [binary()], state()}.

challenging(_, [], St, []) ->
    %% We have no replies
    {ok, challenging, St};

challenging(_, [], St, Acc) ->
    {reply, challenging, lists:reverse(Acc), St};

challenging(in, [#authenticate{} = M|_], St, _) ->
    %% Client is responding to a challenge
    ok = bondy_stats:update({wamp_message, M, St#wamp_state.context}),

    ok = bondy_event_manager:notify({wamp, M, St#wamp_state.context}),

    Sign = M#authenticate.signature,
    Ctxt0 = St#wamp_state.context,
    AuthMethod = St#wamp_state.authmethod,
    Realm = bondy_context:realm_uri(Ctxt0),
    Peer = bondy_context:peername(Ctxt0),
    AuthId = bondy_context:authid(Ctxt0),

    case
        bondy_security_utils:authenticate(
            AuthMethod, {AuthMethod, AuthId, Sign}, Realm, Peer)
    of
        {ok, _AuthCtxt} ->
            %% We already stored the authid (username) in the ctxt
            open_session(St);
        {error, Reason} ->
            abort(closed, ?WAMP_AUTHORIZATION_FAILED, Reason, #{}, St)
    end;

challenging(in, [#abort{} = M|_], St0, []) ->
    %% Client aborting, we ignore any subsequent messages
    Uri = M#abort.reason_uri,
    Details = M#abort.details,
    _ = lager:info(
        "Client aborted; reason=~s, state_name=~p, details=~p",
        [Uri, challenging, Details]
    ),
    {stop, closed, St0};

challenging(_, _, State, _) ->
    {stop, failed, State}.


%% @private
-spec failed(event_type(), [raw_wamp_message()], state(), Acc :: [raw_wamp_message()]) ->
    {ok, state_name(), state()}
    | {stop, state_name(),state()}
    | {stop, state_name(), [binary()], state()}
    | {reply, state_name(), [binary()], state()}.

failed(_, _, State, _) ->
    {stop, failed, State}.


%% @private
-spec established(
    event_type(), [raw_wamp_message()], state(), Acc :: [raw_wamp_message()]) ->
    {ok, state_name(), state()}
    | {stop, state_name(),state()}
    | {stop, state_name(), [binary()], state()}
    | {reply, state_name(), [binary()], state()}.

established(_, [], St, []) ->
    %% We have no replies
    {ok, established, St};

established(_, [], St, Acc) ->
    {reply, established, lists:reverse(Acc), St};

established(
    in, [#hello{} = M|_], #wamp_state{context = #{session := _}} = St0, Acc) ->
    %% Client already has a session!
    %% RFC: It is a protocol error to receive a second "HELLO" message during
    %% the lifetime of the session and the _Peer_ must fail the session if that
    %% happens.
    ok = bondy_event_manager:notify({wamp, M, St0#wamp_state.context}),
    %% We reply all previous messages plus an abort message and close
    Bin = abort_error_bin(
        ?WAMP_PROTOCOL_VIOLATION,
        <<"You've sent a HELLO message more than once.">>,
        #{},
        St0
    ),
    {stop, failed, [Bin | Acc], St0};

established(
    in,
    [#authenticate{} = M|_],
    #wamp_state{context = #{session := _}} = St,
    Acc) ->
    ok = bondy_stats:update({wamp_message, M, St#wamp_state.context}),
    %% Client already has a session so is already authenticated.
    Bin = abort_error_bin(
        ?WAMP_PROTOCOL_VIOLATION,
        <<"You've sent an AUTHENTICATE message more than once.">>,
        #{},
        St
    ),
    {stop, failed, [Bin | Acc], St};

established(in, [#goodbye{}|_], St0, Acc) ->
    %% Client initiated a goodbye, we ignore any subsequent messages
    %% We reply with all previous messages plus a goodbye and stop
    Reply = wamp_message:goodbye(
        #{message => <<"Session closed by client.">>}, ?WAMP_GOODBYE_AND_OUT),
    Bin = wamp_encoding:encode(Reply, encoding(St0)),
    {stop, closed, lists:reverse([Bin|Acc]), St0};

established(in, [H|T], St, Acc) ->
    %% We have a session, so we route the messages
    case bondy_router:forward(H, St#wamp_state.context) of
        {ok, Ctxt} ->
            established(in, T, update_context(Ctxt, St), Acc);
        {reply, M, Ctxt} ->
            Bin = wamp_encoding:encode(M, encoding(St)),
            established(in, T, update_context(Ctxt, St), [Bin | Acc]);
        {stop, M, Ctxt} ->
            Bin = wamp_encoding:encode(M, encoding(St)),
            {stop, failed, [Bin | Acc], update_context(Ctxt, St)}
    end.


%% @private
-spec shutting_down(
    event_type(), [raw_wamp_message()], state(), Acc :: [raw_wamp_message()]) ->
    {ok, state_name(), state()}
    | {stop, state_name(),state()}
    | {stop, state_name(), [binary()], state()}
    | {reply, state_name(), [binary()], state()}.

shutting_down(in, [#goodbye{}|_], St, Acc) ->
    %% Client is replying to our goodbye, we ignore any subsequent messages
    %% We reply all previous messages and close
    {stop, closed, lists:reverse(Acc), St};

shutting_down(_, _, State, _) ->
    %% We ignore all other messages and wait for a goodbye reply from the client
    {ok, shutting_down, State}.



%% =============================================================================
%% PRIVATE: AUTH & SESSION
%% =============================================================================



%% @private
maybe_open_session({ok, St}) ->
    open_session(St);

maybe_open_session({error, {Code, Term}, St}) when is_atom(Term) ->
    maybe_open_session({error, {Code, ?CHARS2BIN(atom_to_list(Term))}, St});

maybe_open_session({error, {realm_not_found, Uri}, St}) ->
    abort(
        closed,
        ?WAMP_NO_SUCH_REALM,
        <<"Realm '", Uri/binary, "' does not exist.">>,
        #{},
        St
    );

maybe_open_session({error, {missing_param, Param}, St}) ->
    abort(
        closed,
        ?WAMP_PROTOCOL_VIOLATION,
        <<"Missing value for required parameter '", Param/binary, "'.">>,
        #{},
        St
    );

maybe_open_session({error, {user_not_found, AuthId}, St}) ->
    abort(
        closed,
        ?WAMP_NO_SUCH_ROLE,
        <<"User '", AuthId/binary, "' does not exist.">>,
        #{},
        St
    );

maybe_open_session({challenge, AuthMethod, Challenge, St0}) ->
    M = wamp_message:challenge(AuthMethod, Challenge),
    ok = bondy_event_manager:notify({wamp, M, St0#wamp_state.context}),
    Bin = wamp_encoding:encode(M, encoding(St0)),
    St1 = St0#wamp_state{authmethod = AuthMethod},
    {reply, challenging, Bin, St1}.




%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec open_session(state()) ->
    {reply, established, binary(), state()}
    | {stop, binary(), state()}.

open_session(St0) ->
    try
        #{
            realm_uri := Uri,
            authid := AuthId,
            id := Id,
            request_details := Details
        } = Ctxt0 = St0#wamp_state.context,

        %% We set the session in the context
        Ctxt1 = bondy_context:set_session_id(Ctxt0, Id),
        Peer = bondy_context:peer(Ctxt1),
        St1 = update_context(Ctxt1, St0),

        %% We open (store) a session
        _Session = bondy_session:open(Id, Peer, Uri, Details),
        {ok, _} = bondy_session_queue_server:start_link(Id, Peer),

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
        {reply, established, Bin, St1}
    catch
        ?EXCEPTION(error, {invalid_options, missing_client_role}, _) ->
            abort(
                closed,
                ?WAMP_PROTOCOL_VIOLATION,
                <<"No client roles provided. Please provide at least one client role.">>,
                #{},
                St0
            )
    end.



%% @private
abort({unsupported_encoding, Format}, St) ->
    Mssg = <<"Unsupported message encoding">>,
    abort(closed, ?WAMP_PROTOCOL_VIOLATION, Mssg, #{encoding => Format}, St);

abort(badarg, St) ->
    Mssg = <<"Error during message decoding">>,
    abort(closed, ?WAMP_PROTOCOL_VIOLATION, Mssg, #{}, St);

abort(function_clause, St) ->
    Mssg = <<"Incompatible message">>,
    abort(closed, ?WAMP_PROTOCOL_VIOLATION, Mssg, #{}, St).


%% @private
abort(NextState, Type, Reason, Details, St) ->
    {stop, NextState, abort_error_bin(Type, Reason, Details, St), St}.


%% @private
abort_error_bin(Type, Reason, Details0, St) ->
    Details = Details0#{
        message => Reason,
        timestamp => erlang:system_time(seconds)
    },
    M = wamp_message:abort(Details, Type),
    ok = bondy_event_manager:notify({wamp, M, St#wamp_state.context}),
    wamp_encoding:encode(M, encoding(St)).


%% @private
maybe_auth_challenge(_, {error, not_found}, St) ->
    #{realm_uri := Uri} = St#wamp_state.context,
    {error, {realm_not_found, Uri}, St};

maybe_auth_challenge(Details, Realm, St0) ->
    Ctxt0 = St0#wamp_state.context,
    case {bondy_realm:is_security_enabled(Realm), Details} of
        {true, #{authid := UserId}} ->
            Ctxt1 = Ctxt0#{authid => UserId, request_details => Details},
            St1 = update_context(Ctxt1, St0),
            AuthMethods = maps:get(authmethods, Details, []),
            AuthMethod = bondy_realm:select_auth_method(Realm, AuthMethods),
            % TODO Get User for Realm (change security module) and if not exist
            % return error else challenge
            case bondy_security_user:lookup(bondy_realm:uri(Realm), UserId) of
                {error, not_found} ->
                    {error, {user_not_found, UserId}, St1};
                User ->
                    Ch = challenge(AuthMethod, User, Details, St1),
                    {challenge, AuthMethod, Ch, St1}
            end;
        {true, _} ->
            {error, {missing_param, authid}, St0};
        {false, #{authid := UserId}} ->
            Ctxt1 = Ctxt0#{authid => UserId, request_details => Details},
            {ok, update_context(Ctxt1, St0)};
        {false, _} ->
            TempId = bondy_utils:uuid(),
            Ctxt1 = Ctxt0#{authid => TempId, request_details => Details},
            {ok, update_context(Ctxt1, St0)}
    end.


%% @private
challenge(?WAMPCRA_AUTH, User, Details, St) ->
    %% id is the future session_id
    #{id := Id} = Ctxt = St#wamp_state.context,
    #{username := UserId} = User,
    Ch0 = #{
        challenge => #{
            authmethod => ?WAMPCRA_AUTH,
            authid => UserId,
            authprovider => <<"com.leapsight.bondy">>,
            authrole => maps:get(authrole, Details, <<"user">>), % @TODO
            nonce => bondy_utils:get_nonce(),
            session => Id,
            timestamp => erlang:system_time(seconds)
        }
    },
    RealmUri = bondy_context:realm_uri(Ctxt),
    case bondy_security_user:password(RealmUri, User) of
        undefined ->
            Ch0;
        Pass ->
            #{
                auth_name := pbkdf2,
                hash_func := sha,
                iterations := Iter,
                salt := Salt
            } = Pass,
            Ch0#{
                salt => Salt,
                keylen => 16, % see bondy_security_pw.erl
                iterations => Iter
            }
    end;

challenge(?TICKET_AUTH, _UserId, _Details, _St) ->
    #{}.


%% @private
get_realm(St) ->
    Uri = bondy_context:realm_uri(St#wamp_state.context),
    case bondy_config:automatically_create_realms() of
        true ->
            %% We force the creation of a new realm if it does not exist
            bondy_realm:get(Uri);
        false ->
            %% Will throw an exception if it does not exist
            bondy_realm:lookup(Uri)
    end.


%% do_async(NextState, Data, St) ->
%%     Me = self(),
%%     Ctxt0 = St#wamp_state.context,
%%     Fun = fun() ->
%%         try wamp_encoding:decode(St#wamp_state.subprotocol, Data) of
%%             {Messages, <<>>} -> established(in, Messages, St, [])
%%         catch
%%             _:Reason ->
%%                 abort(Reason, St)
%%         end
%%     end,

%%     try bondy_router_worker:cast(Fun) of
%%         ok ->
%%             {ok, NextState, St};
%%         {error, overload} ->
%%             _ = lager:info(
%%                 "Router pool overloaded, will route message synchronously; "
%%                 "message=~p", [M]
%%             ),
%%             try wamp_encoding:decode(St#wamp_state.subprotocol, Data) of
%%                 {Messages, <<>>} -> established(in, Messages, St, [])
%%             catch
%%                 _:Reason ->
%%                     abort(Reason, St)
%%             end
%%     catch
%%         Class:Reason ->
%%             Uri = bondy_context:realm_uri(Ctxt0),
%%             SessionId = bondy_context:session_id(Ctxt0),
%%             _ = lager:error(
%%                 "Error while handling data; class=~p, reason=~p"
%%                 " realm_uri=~p, session_id=~p, stacktrace=~p",
%%                 [Class, Reason, Uri, SessionId, erlang:get_stacktrace()]
%%             ),
%%             {ok, NextState, St}
%%     end.


%% =============================================================================
%% PRIVATE: UTILS
%% =============================================================================


%% @private
encoding({_, _, E}) ->
    E;

encoding(#wamp_state{subprotocol = Subprotocol}) ->
    encoding(Subprotocol).


%% @private
transport({T, _, _}) ->
    T;
transport(#wamp_state{subprotocol = Subprotocol}) ->

    transport(Subprotocol).


%% @private
do_init(Subproto, Pid, Peername, _Opts) ->
    TransportInfo = #{
        peername => Peername,
        encoding => encoding(Subproto),
        connection_process => Pid
    },
    Ctxt = bondy_context:new(Subproto, TransportInfo),
    State = #wamp_state{
        subprotocol = Subproto,
        transport_info = TransportInfo,
        context = Ctxt
    },
    {ok, State}.


do_init(Subproto, Pid, TransportMod, Socket, _Opts) ->
    {ok, Peername} = inet:peername(Socket),
    TransportInfo = #{
        peername => Peername,
        encoding => encoding(Subproto),
        connection_process => Pid,
        transport => transport(Subproto),
        transport_mod => TransportMod,
        socket => Socket
    },
    Ctxt = bondy_context:new(Subproto, TransportInfo),
    State = #wamp_state{
        subprotocol = Subproto,
        transport_info = TransportInfo,
        context = Ctxt
    },
    {ok, State}.


%% @private
update_context(Ctxt, St) ->
    St#wamp_state{context = Ctxt}.



