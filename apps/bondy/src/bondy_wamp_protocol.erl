%% 
%%  bondy_wamp_subprotocol -
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

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_wamp_protocol).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").

-define(IS_TRANSPORT(X), (T =:= ws orelse T =:= raw)).

-record(wamp_state, {
    transport               ::  transport(),
    frame_type              ::  frame_type(),
    encoding                ::  encoding(),
    buffer = <<>>           ::  binary(),
    challenge_sent          ::  {true, AuthMethod :: any()} | false,
    goodbye_initiated       ::  boolean(),
    context                 ::  bondy_context:context() | undefined
}).


-type subprotocol()         ::  {transport(), frame_type(), encoding()}.

-type state()               ::  #wamp_state{} | undefined.


-export_type([frame_type/0]).
-export_type([encoding/0]).
-export_type([subprotocol/0]).
-export_type([state/0]).

-export([init/3]).
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
-spec terminate(state()) -> ok.

terminate(St) ->
    bondy_context:close(St#wamp_state.context).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec validate_subprotocol(subprotocol()) -> ok | {error, invalid_subprotocol}.

validate_subprotocol(T) when is_binary(T) ->
    {ok, subprotocol(T)};

validate_subprotocol({ws, text, json_batched} = S) ->  
    {ok, S};
validate_subprotocol({ws, binary, msgpack_batched} = S) ->
    {ok, S};
validate_subprotocol({ws, binary, bert_batched} = S) ->
    {ok, S};
validate_subprotocol({ws, binary, erl_batched} = S) -> 
    {ok, S};
validate_subprotocol({T, text, json} = S) when ?IS_TRANSPORT(T) ->          
    {ok, S};
validate_subprotocol({T, binary, msgpack} = S) when ?IS_TRANSPORT(T) ->     
    {ok, S};
validate_subprotocol({T, binary, bert} = S) when ?IS_TRANSPORT(T) ->        
    {ok, S};
validate_subprotocol({T, binary, erl} = S) when ?IS_TRANSPORT(T) ->         
    {ok, S};
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

handle_inbound(Data0, #wamp_state{frame_type = T, encoding = E} = St) ->
    Data1 = <<(St#wamp_state.buffer)/binary, Data0/binary>>,
    {Messages, Buffer} = wamp_encoding:decode(Data1, T, E),
    handle_inbound_messages(Messages, St#wamp_state{buffer = Buffer}, []).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec handle_outbound(wamp_message:message(), state()) ->
    {ok, binary(), state()} 
    | {stop, state()}
    | {stop, binary(), state()}.

handle_outbound(#result{} = M, St0) ->
    ok = bondy_stats:update(M, St0#wamp_state.context),
    CallId = M#result.request_id,
    Ctxt0 = St0#wamp_state.context,
    Ctxt1 = bondy_context:remove_awaiting_call(Ctxt0, CallId),
    St1 = update_context(bondy_context:reset(Ctxt1), St0),
    Bin = wamp_encoding:encode(M, St1#wamp_state.encoding),
    {ok, Bin, St1};

handle_outbound(#error{request_type = ?CALL} = M, St0) ->
    ok = bondy_stats:update(M, St0#wamp_state.context),
    CallId = M#error.request_id,
    Ctxt0 = St0#wamp_state.context,
    Ctxt1 = bondy_context:remove_awaiting_call(Ctxt0, CallId),
    St1 = update_context(bondy_context:reset(Ctxt1), St0),
    Bin = wamp_encoding:encode(M, St1#wamp_state.encoding),
    {ok, Bin, St1};

handle_outbound(M, St) ->
    case wamp_message:is_message(M) of
        true ->
            ok = bondy_stats:update(M, St#wamp_state.context),
            Bin = wamp_encoding:encode(M, St#wamp_state.encoding),
            {ok, Bin, St};
        false ->
            {stop, St}
    end.




%% =============================================================================
%% PRIVATE: HANDLING INBOUND MESSAGES
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Handles one or more messages, routing them and returning a reply
%% when required.
%% @end
%% -----------------------------------------------------------------------------
-spec handle_inbound_messages(
    [wamp_message()], state(), Acc :: [wamp_message()]) ->
    {ok, state()} 
    | {stop, state()}
    | {stop, [binary()], state()}
    | {reply, [binary()], state()}.

handle_inbound_messages([], St, []) ->
    %% We have no replies
    {ok, St};

handle_inbound_messages([], St, Acc) ->
    {reply, lists:reverse(Acc), St};

handle_inbound_messages([#goodbye{} = M|_], St, Acc) ->
    %% The client initiated a goodbye, so we will not process
    %% any subsequent messages
   case bondy_router:forward(M, St#wamp_state.context) of
        {stop, Ctxt} ->
            {stop, lists:reverse(Acc), update_context(Ctxt, St)};
        {stop, Reply, Ctxt} ->
            Bin = wamp_encoding:encode(Reply, St#wamp_state.encoding),
            {stop, lists:reverse([Bin|Acc]), update_context(Ctxt, St)}
    end;

handle_inbound_messages(
    [#hello{} = M|_], 
    #wamp_state{context = #{session := _}} = St, _) ->
    ok = bondy_stats:update(M, St#wamp_state.context),
    %% Client already has a session!
    %% RFC:
    %% It is a protocol error to receive a second "HELLO" message during the
    %% lifetime of the session and the _Peer_ must fail the session if that
    %% happens
    abort(
        ?BONDY_SESSION_ALREADY_EXISTS, 
        <<"You've sent a HELLO message more than once.">>, 
        St);

handle_inbound_messages(
    [#hello{} = M|_], #wamp_state{challenge_sent = {true, _}} = St, _) ->
    ok = bondy_stats:update(M, St#wamp_state.context),
    %% Client does not have a session but we already sent a challenge message
    %% in response to a HELLO message
    abort(
        ?WAMP_ERROR_CANCELLED, 
        <<"You've sent a HELLO message more than once.">>, 
        St);

handle_inbound_messages([#hello{realm_uri = Uri} = M|_], St0, _) ->
    Ctxt0 = St0#wamp_state.context,
    ok = bondy_stats:update(M, Ctxt0),
    %% Client is requesting a session
    %% This will return either reply with wamp_welcome() | wamp_challenge()
    %% or abort 
    Ctxt1 = Ctxt0#{realm_uri => Uri},
    St1 = update_context(Ctxt1, St0),
    maybe_open_session(
        maybe_auth_challenge(M#hello.details, get_realm(St1), St1));

handle_inbound_messages(
    [#authenticate{} = M|_], #wamp_state{context = #{session := _}} = St, _) ->
    ok = bondy_stats:update(M, St#wamp_state.context),
    %% Client already has a session so is already authenticated.
    abort(
        ?BONDY_SESSION_ALREADY_EXISTS, 
        <<"You've sent an AUTHENTICATE message more than once.">>, 
        St);

handle_inbound_messages(
    [#authenticate{} = M|_], 
    #wamp_state{challenge_sent = {true, AuthMethod}} = St, 
    _) ->
    ok = bondy_stats:update(M, St#wamp_state.context),
    %% Client is responding to a challenge
    #authenticate{signature = Sign} = M,
    Ctxt0 = St#wamp_state.context,
    Realm = maps:get(realm_uri, Ctxt0),
    Peer = maps:get(peer, Ctxt0),
    AuthId = maps:get(authid, Ctxt0),
    case 
        bondy_security_utils:authenticate(
            AuthMethod, {AuthMethod, AuthId, Sign}, Realm, Peer) 
    of
        {ok, _AuthCtxt} ->
            %% We already stored the authid (username) in the ctxt
            open_session(St);
        {error, Reason} ->
            abort(?WAMP_ERROR_AUTHORIZATION_FAILED, Reason, St)
    end;

handle_inbound_messages([#authenticate{} = M|_], St, _) ->
    %% Client does not have a session and has not been sent a challenge
    ok = bondy_stats:update(M, St#wamp_state.context),
    abort(
        ?WAMP_ERROR_CANCELLED, 
        <<"You need to request a session first by sending a HELLO message.">>, 
        St);
    
handle_inbound_messages(
    [H|T], #wamp_state{context = #{session := _}} = St, Acc) ->
    %% We have a session, so we forward messages via router    
    case bondy_router:forward(H, St#wamp_state.context) of
        {ok, Ctxt} ->
            handle_inbound_messages(T, update_context(Ctxt, St), Acc);
        {reply, M, Ctxt} ->
            Bin = wamp_encoding:encode(M, St#wamp_state.encoding),
            handle_inbound_messages(T, update_context(Ctxt, St), [Bin | Acc]);
        {stop, M, Ctxt} ->
            Bin = wamp_encoding:encode(M, St#wamp_state.encoding),
            {stop, [Bin], update_context(Ctxt, St)}
    end;

handle_inbound_messages(_, St, _) ->
    %% Client does not have a session and message is not HELLO
    abort(
        ?BONDY_ERROR_NOT_IN_SESSION, 
        <<"You need to establish a session first.">>, 
        St).



%% =============================================================================
%% PRIVATE: AUTH & SESSION
%% =============================================================================





%% @private
maybe_open_session({ok, St}) ->
    open_session(St);

maybe_open_session({error, {realm_not_found, Uri}, St}) ->
    abort(
        ?WAMP_ERROR_NO_SUCH_REALM,
        <<"Realm '", Uri/binary, "' does not exist.">>,
        St
    );

maybe_open_session({error, {missing_param, Param}, St}) ->
    abort(
        ?WAMP_ERROR_CANCELLED,
        <<"Missing value for required parameter '", Param/binary, "'.">>,
        St
    );

maybe_open_session({error, {user_not_found, AuthId}, St}) ->
    abort(
        ?WAMP_ERROR_CANCELLED,
        <<"User '", AuthId/binary, "' does not exist.">>,
        St
    );

maybe_open_session({challenge, AuthMethod, Challenge, St0}) ->
    M = wamp_message:challenge(AuthMethod, Challenge),
    ok = bondy_stats:update(M, St0#wamp_state.context),
    St1 = St0#wamp_state{challenge_sent = {true, AuthMethod}},
    Bin = wamp_encoding:encode(M, St1#wamp_state.encoding),
    {reply, Bin, St1}.


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
        #{
            realm_uri := Uri, 
            id := Id, 
            request_details := Details
        } = Ctxt0 = St0#wamp_state.context,
        Session = bondy_session:open(Id, maps:get(peer, Ctxt0), Uri, Details),
        Ctxt1 = Ctxt0#{
            session => Session,
            roles => parse_roles(maps:get(<<"roles">>, Details))
        },
        St1 = update_context(Ctxt1, St0),

        Welcome = wamp_message:welcome(
            Id,
            #{
                <<"agent">> => ?BONDY_VERSION_STRING,
                <<"roles">> => bondy_router:roles()
            }
        ),
        ok = bondy_stats:update(Welcome, Ctxt1),
        Bin = wamp_encoding:encode(Welcome, St1#wamp_state.encoding),
        {reply, Bin, St1}
    catch
        error:{invalid_options, missing_client_role} ->
            abort(
                <<"wamp.error.missing_client_role">>, 
                <<"Please provide at least one client role.">>,
                St0)
    end.



%% ------------------------------------------------------------------------
%% private
%% @doc
%% Merges the client provided role features with the ones provided by
%% the router. This will become the feature set used by the router on
%% every session request.
%% @end
%% ------------------------------------------------------------------------
parse_roles(Roles) ->
    parse_roles(maps:keys(Roles), Roles).


%% @private
parse_roles([], Roles) ->
    Roles;

parse_roles([<<"caller">>|T], Roles) ->
    F = bondy_utils:merge_map_flags(
        maps:get(<<"caller">>, Roles), ?CALLER_FEATURES),
    parse_roles(T, Roles#{<<"caller">> => F});

parse_roles([<<"callee">>|T], Roles) ->
    F = bondy_utils:merge_map_flags(
        maps:get(<<"callee">>, Roles), ?CALLEE_FEATURES),
    parse_roles(T, Roles#{<<"callee">> => F});

parse_roles([<<"subscriber">>|T], Roles) ->
    F = bondy_utils:merge_map_flags(
        maps:get(<<"subscriber">>, Roles), ?SUBSCRIBER_FEATURES),
    parse_roles(T, Roles#{<<"subscriber">> => F});

parse_roles([<<"publisher">>|T], Roles) ->
    F = bondy_utils:merge_map_flags(
        maps:get(<<"publisher">>, Roles), ?PUBLISHER_FEATURES),
    parse_roles(T, Roles#{<<"publisher">> => F});

parse_roles([_|T], Roles) ->
    parse_roles(T, Roles).


%% @private
abort(Type, Reason, St) ->
    Details = #{
        <<"message">> => Reason,
        <<"timestamp">> => erlang:system_time(seconds)
    },
    M = wamp_message:abort(Details, Type),
    ok = bondy_stats:update(M, St#wamp_state.context),
    Bin = wamp_encoding:encode(M, St#wamp_state.encoding),
    {stop, Bin, St}.


%% @private
maybe_auth_challenge(_, not_found, St) ->
    #{realm_uri := Uri} = St#wamp_state.context,
    {error, {realm_not_found, Uri}, St};

maybe_auth_challenge(Details, Realm, St0) ->
    Ctxt0 = St0#wamp_state.context,
    case {bondy_realm:is_security_enabled(Realm), Details} of
        {true, #{<<"authid">> := UserId}} ->
            Ctxt1 = Ctxt0#{authid => UserId, request_details => Details},
            St1 = update_context(Ctxt1, St0),
            AuthMethods = maps:get(<<"authmethods">>, Details, []),
            AuthMethod = bondy_realm:select_auth_method(Realm, AuthMethods),
            % TODO Get User for Realm (change security module) and if not exist
            % return error else challenge
            case bondy_security_user:lookup(bondy_realm:uri(Realm), UserId) of
                not_found ->
                    {error, {user_not_found, UserId}, St1};
                User ->
                    Ch = challenge(AuthMethod, User, Details, St1),
                    {challenge, AuthMethod, Ch, St1}
            end;
        {true, _} ->
            {error, {missing_param, <<"authid">>}, St0};
        {false, _} ->
            Ctxt1 = Ctxt0#{authid => undefined, request_details => Details},
            St1 = update_context(Ctxt1, St0),
            {ok, St1}
    end.


%% @private
challenge(?WAMPCRA_AUTH, User, Details, St) ->
    %% id is the future session_id 
    #{id := Id} = Ctxt = St#wamp_state.context,
    #{username := UserId} = User,
    Ch0 = #{
        challenge => #{
            <<"authmethod">> => ?WAMPCRA_AUTH,
            <<"authid">> => UserId,
            <<"authprovider">> => <<"bondy">>, 
            <<"authrole">> => maps:get(authrole, Details, <<"user">>), % @TODO
            <<"nonce">> => bondy_utils:get_nonce(),
            <<"session">> => Id,
            <<"timestamp">> => calendar:universal_time()
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
                <<"salt">> => Salt,
                <<"keylen">> => 16, % see bondy_pw_auth.erl
                <<"iterations">> => Iter
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


%% =============================================================================
%% PRIVATE: UTILS
%% =============================================================================


%% @private
do_init({T, FrameType, Enc}, Peer, _Opts) ->
    State = #wamp_state{
        transport = T,
        frame_type = FrameType,
        encoding = Enc,
        context = bondy_context:new(Peer)
    },
    {ok, State}.


%% @private
update_context(Ctxt, St) ->
    St#wamp_state{context = Ctxt}.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec subprotocol(binary()) -> bondy_wamp_protocol:subprotocol().

subprotocol(?WAMP2_JSON) ->                 {ws, text, json};
subprotocol(?WAMP2_MSGPACK) ->              {ws, binary, msgpack};
subprotocol(?WAMP2_JSON_BATCHED) ->         {ws, text, json_batched};
subprotocol(?WAMP2_MSGPACK_BATCHED) ->      {ws, binary, msgpack_batched};
subprotocol(?WAMP2_BERT) ->                 {ws, binary, bert};
subprotocol(?WAMP2_ERL) ->                  {ws, binary, erl};
subprotocol(?WAMP2_BERT_BATCHED) ->         {ws, binary, bert_batched};
subprotocol(?WAMP2_ERL_BATCHED) ->          {ws, binary, erl_batched};
subprotocol(_) ->                           {error, invalid_subprotocol}. 


