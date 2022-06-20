%% =============================================================================
%%  bondy_bridge_relay_server.erl -
%%
%%  Copyright (c) 2016-2022 Leapsight. All rights reserved.
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
%% @doc EARLY DRAFT implementation of the server-side connection between and
%% edge node ({@link bondy_bridge_relay_client}) and a remote/core node
%% (this module).
%%
%% == Configuration Options ==
%% <ul>
%% <li>auth_timeout - once the connection is established how long to wait for
%% the client to send the HELLO message.</li>
%% </ul>
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_bridge_relay_server).
-behaviour(gen_statem).
-behaviour(ranch_protocol).

-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include_lib("bondy_plum_db.hrl").
-include("bondy.hrl").

-define(SOCKET_DATA(Tag), Tag == tcp orelse Tag == ssl).
-define(SOCKET_ERROR(Tag), Tag == tcp_error orelse Tag == ssl_error).
-define(CLOSED_TAG(Tag), Tag == tcp_closed orelse Tag == ssl_closed).
% -define(PASSIVE_TAG(Tag), Tag == tcp_passive orelse Tag == ssl_passive).


-record(state, {
    ranch_ref               ::  atom(),
    transport               ::  module(),
    opts                    ::  key_value:t(),
    socket                  ::  gen_tcp:socket() | ssl:sslsocket(),
    auth_timeout            ::  pos_integer(),
    idle_timeout            ::  pos_integer(),
    ping_retry              ::  optional(bondy_retry:t()),
    ping_retry_tref         ::  optional(timer:ref()),
    ping_sent               ::  optional({timer:ref(), binary()}),
    sessions = #{}          ::  #{id() => bondy_session:t()},
    sessions_by_realm = #{} ::  #{uri() => bondy_session_id:t()},
    %% The context for the session currently being established
    auth_context            ::  optional(bondy_auth:context()),
    registrations = #{}     ::  reg_indx(),
    start_ts                ::  pos_integer()
}).


% -type t()                   ::  #state{}.
-type reg_indx()            ::  #{
    SessionId :: bondy_session_id:t() => proxy_map()
}.
-type proxy_map()           ::  #{OrigEntryId :: id() => ProxyEntryId :: id()}.

%% API.
-export([start_link/3]).
-export([start_link/4]).

%% GEN_STATEM CALLBACKS
-export([callback_mode/0]).
-export([init/1]).
-export([terminate/3]).
-export([code_change/4]).

%% STATE FUNCTIONS
-export([connected/3]).

%% TODO pings should only be allowed if we have at least one session, otherwise
%% they do not count towards the idle_timeout.
%% At least one session has to be active for the connection to stay
%% online.



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start_link(RanchRef, Transport, Opts) ->
    gen_statem:start_link(?MODULE, {RanchRef, Transport, Opts}, []).


%% -----------------------------------------------------------------------------
%% @doc
%% This will be deprecated with Ranch 2.0
%% @end
%% -----------------------------------------------------------------------------
start_link(RanchRef, _, Transport, Opts) ->
    start_link(RanchRef, Transport, Opts).



%% =============================================================================
%% GEN_STATEM CALLBACKS
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
callback_mode() ->
    [state_functions, state_enter].


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
init({RanchRef, Transport, Opts}) ->
    AuthTimeout = key_value:get(auth_timeout, Opts, 5000),
    IdleTimeout = key_value:get(idle_timeout, Opts, infinity),

    State0 = #state{
        ranch_ref = RanchRef,
        transport = Transport,
        opts = Opts,
        auth_timeout = AuthTimeout,
        idle_timeout = IdleTimeout,
        start_ts = erlang:system_time(millisecond)
    },

    %% Setup ping
    PingOpts = key_value:get(ping, Opts, []),

    State = case key_value:get(enabled, PingOpts, false) of
        true ->
            State0#state{
                ping_retry = bondy_retry:init(ping, PingOpts)
            };
        false ->
            State0
    end,

    {ok, connected, State, AuthTimeout}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------

terminate(_Reason, _StateName, #state{socket = undefined} = State) ->
    ok = remove_all_registry_entries(State);

terminate(Reason, StateName, #state{} = State) ->
    ?LOG_INFO(#{
        description => "Closing connection",
        reason => Reason
    }),

    Transport = State#state.transport,
    Socket = State#state.socket,

    catch Transport:close(Socket),

    terminate(Reason, StateName, State#state{socket = undefined}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.



%% =============================================================================
%% STATE FUNCTIONS
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
connected(enter, connected, State) ->
    Ref = State#state.ranch_ref,
    Transport = State#state.transport,

    %% Setup and configure socket
    TLSOpts = bondy_config:get([Ref, tls_opts], []),
    {ok, Socket} = ranch:handshake(Ref, TLSOpts),

    SocketOpts = [
        binary,
        {packet, 4},
        {active, once}
        | bondy_config:get([Ref, socket_opts], [])
    ],
    %% If Transport == ssl, upgrades a gen_tcp, or equivalent, socket to an SSL
    %% socket by performing the TLS server-side handshake, returning a TLS
    %% socket.
    ok = Transport:setopts(Socket, SocketOpts),

    {ok, Peername} = bondy_utils:peername(Transport, Socket),
    PeernameBin = inet_utils:peername_to_binary(Peername),

    ok = logger:set_process_metadata(#{
        transport => Transport,
        peername => PeernameBin,
        socket => Socket
    }),

    ok = on_connect(State),

    {keep_state, State#state{socket = Socket}, [auth_timeout(State)]};


connected(info, {Tag, Socket, Data}, #state{socket = Socket} = State)
when ?SOCKET_DATA(Tag) ->
    ok = set_socket_active(State),

    case binary_to_term(Data) of
        {receive_message, SessionId, Msg} ->
            ?LOG_DEBUG(#{
                description => "Got session message from edge",
                reason => Msg,
                session_id => SessionId
            }),
            safe_receive_message(Msg, SessionId, State);
        Msg ->
            ?LOG_DEBUG(#{
                description => "Got message from edge",
                reason => Msg
            }),
            handle_message(Msg, State)
    end;

connected(info, {Tag, _Socket}, _) when ?CLOSED_TAG(Tag) ->
    ?LOG_INFO(#{
        description => "Bridge Relay connection closed by client"
    }),
    {stop, normal};

connected(info, {Tag, _, Reason}, _) when ?SOCKET_ERROR(Tag) ->
    ?LOG_INFO(#{
        description => "Bridge Relay connection closed due to error",
        reason => Reason
    }),
    {stop, Reason};

connected(info, {?BONDY_REQ, _Pid, RealmUri, M}, State) ->
    %% A local bondy:send(), we need to forward to edge client
    ?LOG_DEBUG(#{
        description => "Received WAMP request we need to FWD to edge",
        message => M
    }),

    SessionId = session_id(RealmUri, State),
    ok = send_message({receive_message, SessionId, M}, State),

    {keep_state_and_data, [idle_timeout(State)]};

connected(info, Msg, State) ->
    ?LOG_INFO(#{
        description => "Received unknown message",
        type => info,
        event => Msg
    }),

    {keep_state_and_data, [idle_timeout(State)]};

connected({call, From}, Request, State) ->
    ?LOG_INFO(#{
        description => "Received unknown request",
        type => call,
        event => Request
    }),

    gen_statem:reply(From, {error, badcall}),

    {keep_state_and_data, [idle_timeout(State)]};

%% TODO forward_message or forward?
connected(cast, {forward_message, Msg}, State) ->
    ok = send_message(Msg, State),
    {keep_state_and_data, [idle_timeout(State)]};

%% TODO forward_message or forward?
connected(cast, {forward, Msg}, State) ->
    ok = send_message(Msg, State),
    {keep_state_and_data, [idle_timeout(State)]};

connected(cast, Msg, State) ->
    ?LOG_INFO(#{
        description => "Received unknown message",
        type => cast,
        event => Msg
    }),
    {keep_state_and_data, [idle_timeout(State)]};

connected(timeout, _Msg, _) ->
    ?LOG_INFO(#{
        description => "Closing connection",
        reason => timeout
    }),
    {stop, normal};

connected(EventType, Msg, _) ->
    ?LOG_INFO(#{
        description => "Received unknown message",
        type => EventType,
        event => Msg
    }),
    {stop, normal}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
challenge(Realm, Details, State0) ->
    {ok, Peer} = bondy_utils:peername(
        State0#state.transport, State0#state.socket
    ),

    SessionId = bondy_session_id:new(),
    Authid = maps:get(authid, Details),
    Authroles0 = maps:get(authroles, Details, []),

    case bondy_auth:init(SessionId, Realm, Authid, Authroles0, Peer) of
        {ok, AuthCtxt} ->
            %% TODO take it from conf
            ReqMethods = [<<"cryptosign">>],

            case bondy_auth:available_methods(ReqMethods, AuthCtxt) of
                [] ->
                    throw({no_authmethod, ReqMethods});

                [Method|_] ->
                    Uri = bondy_realm:uri(Realm),
                    FinalAuthid = bondy_auth:user_id(AuthCtxt),
                    Authrole = bondy_auth:role(AuthCtxt),
                    Authroles = bondy_auth:roles(AuthCtxt),
                    Authprovider = bondy_auth:provider(AuthCtxt),
                    SecEnabled = bondy_realm:is_security_enabled(Realm),

                    Properties = #{
                        type => bridge_relay,
                        peer => Peer,
                        security_enabled => SecEnabled,
                        is_anonymous => FinalAuthid == anonymous,
                        agent => bondy_router:agent(),
                        roles => maps:get(roles, Details, undefined),
                        authid => maybe_gen_authid(FinalAuthid),
                        authprovider => Authprovider,
                        authmethod => Method,
                        authrole => Authrole,
                        authroles => Authroles
                    },

                    %% We create a new session object but we do not open it
                    %% yet, as we need to send the callenge and verify the
                    %% response
                    Session = bondy_session:new(Uri, Properties),

                    Sessions0 = State0#state.sessions,
                    Sessions = maps:put(SessionId, Session, Sessions0),

                    SessionsByUri0 = State0#state.sessions_by_realm,
                    SessionsByUri = maps:put(Uri, SessionId, SessionsByUri0),

                    State = State0#state{
                        auth_context = AuthCtxt,
                        sessions = Sessions,
                        sessions_by_realm = SessionsByUri
                    },
                    do_challenge(Details, Method, State)
            end;

        {error, Reason0} ->
            throw({authentication_failed, Reason0})
    end.


%% @private
do_challenge(Details, Method, State0) ->
    AuthCtxt0 = State0#state.auth_context,
    SessionId = bondy_auth:session_id(AuthCtxt0),

    {Reply, State} =
        case bondy_auth:challenge(Method, Details, AuthCtxt0) of
            {false, _} ->
                M = {welcome, SessionId, #{}},
                {M, State0#state{auth_context = undefined}};

            {true, ChallengeExtra, AuthCtxt1} ->
                M = {challenge, Method, ChallengeExtra},
                {M, State0#state{auth_context = AuthCtxt1}};

            {error, Reason} ->
                %% At the moment we only support a single session/realm
                %% so we crash
                throw({authentication_failed, Reason})
        end,

    ok = send_message(Reply, State),

    State.


%% @private
authenticate(AuthMethod, Signature, Extra, State0) ->
    AuthCtxt0 = State0#state.auth_context,
    SessionId = bondy_auth:session_id(AuthCtxt0),

    case bondy_auth:authenticate(AuthMethod, Signature, Extra, AuthCtxt0) of
        {ok, AuthExtra0, _} ->
            State = State0#state{auth_context = undefined},

            AuthExtra = AuthExtra0#{node => bondy_config:nodestring()},
            M = {welcome, SessionId, #{authextra => AuthExtra}},

            ok = send_message(M, State),

            State;
        {error, Reason} ->
            %% At the moment we only support a single session/realm
            %% so we crash
            throw({authentication_failed, Reason})
    end.


%% @private
set_socket_active(State) ->
    (State#state.transport):setopts(State#state.socket, [{active, once}]).


%% @private
send_message(Message, State) ->
    Data = term_to_binary(Message),
    (State#state.transport):send(State#state.socket, Data).


%% @private
on_connect(_State) ->
    ?LOG_NOTICE(#{
        description => "Established connection with edge router"
    }),
    ok.


%% @private
auth_timeout(State) ->
    {timeout, State#state.auth_timeout, auth_timeout}.


%% @private
idle_timeout(State) ->
    {timeout, State#state.idle_timeout, idle_timeout}.


%% @private
handle_message({hello, _, _}, #state{auth_context = Ctxt} = State)
when Ctxt =/= undefined ->
    %% Session already being established, invalid message
    Abort = {abort, protocol_violation, #{
        message => <<"You've sent the HELLO message twice">>
    }},
    ok = send_message(Abort, State),
    {stop, normal, State};

handle_message({hello, Uri, Details}, State0) ->
    %% TODO validate Details
    ?LOG_DEBUG(#{
        description => "Got hello",
        details => Details
    }),

    try

        Realm = bondy_realm:fetch(Uri),

        bondy_realm:allow_connections(Realm)
            orelse throw(connections_not_allowed),

        %% We send the challenge
        State = challenge(Realm, Details, State0),

        %% We wait for response and timeout using auth_timeout again
        {keep_state, State, [auth_timeout(State)]}

    catch
        error:{not_found, Uri} ->
            Abort = {abort, no_such_realm, #{
                message => <<"Realm does not exist.">>,
                realm => Uri
            }},
            ok = send_message(Abort, State0),
            {stop, normal, State0};

        throw:connections_not_allowed = Reason ->
            Abort = {abort, Reason, #{
                message => <<"The Realm does not allow user connections ('allow_connections' setting is off). This might be a temporary measure taken by the administrator or the realm is meant to be used only as a Same Sign-on (SSO) realm.">>,
                realm => Uri
            }},
            ok = send_message(Abort, State0),
            {stop, normal, State0};

        throw:{no_authmethod, ReqMethods} ->
            Abort = {abort, no_authmethod, #{
                message => <<"The requested authentication methods are not available for this user on this realm.">>,
                realm => Uri,
                authmethods => ReqMethods
            }},
            ok = send_message(Abort, State0),
            {stop, normal, State0};

        throw:{authentication_failed, Reason} ->
            Abort = {abort, authentication_failed, #{
                message => <<"Authentication failed.">>,
                realm => Uri,
                reason => Reason
            }},
            ok = send_message(Abort, State0),
            {stop, normal, State0}

    end;

handle_message({authenticate, Signature, Extra}, State0) ->
    %% TODO validate Details
    ?LOG_DEBUG(#{
        description => "Got authenticate",
        signature => Signature,
        extra => Extra
    }),

    try

        State = authenticate(<<"cryptosign">>, Signature, Extra, State0),
        {keep_state, State, [idle_timeout(State)]}

    catch
        throw:{authentication_failed, Reason} ->
            RealmUri = bondy_auth:realm_uri(State0#state.auth_context),
            Abort = {abort, authentication_failed, #{
                message => <<"Authentication failed.">>,
                realm_uri => RealmUri,
                reason => Reason
            }},
            ok = send_message(Abort, State0),
            {stop, normal, State0}
    end;

handle_message({aae_sync, SessionId, Opts}, State) ->
    RealmUri = session_realm(SessionId, State),
    ok = full_sync(SessionId, RealmUri, Opts, State),
    Finish = {aae_sync, SessionId, finished},
    ok = gen_statem:cast(self(), {forward_message, Finish}),
    {keep_state_and_data, [idle_timeout(State)]}.


%% @private
safe_receive_message(Msg, SessionId, State) ->
    try
        receive_message(Msg, SessionId, State)
    catch
        throw:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Unhandled error",
                session => SessionId,
                message => Msg,
                class => throw,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {keep_state_and_data, [idle_timeout(State)]};

        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while handling session message",
                session => SessionId,
                message => Msg,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            Abort = {abort, server_error, #{
                reason => Reason
            }},
            ok = send_message(Abort, State),
            {stop, Reason, State}
    end.


%% @private
receive_message({registration_created, Entry}, SessionId, State0) ->
    State = add_registry_entry(SessionId, Entry, State0),

    {keep_state, State, [idle_timeout(State)]};

receive_message({registration_added, Entry}, SessionId, State0) ->
    State = add_registry_entry(SessionId, Entry, State0),

    {keep_state, State, [idle_timeout(State)]};

receive_message({registration_removed, Entry}, SessionId, State0) ->
    State = remove_registry_entry(SessionId, Entry, State0),

    {keep_state, State, [idle_timeout(State)]};

receive_message({registration_deleted, Entry}, SessionId, State0) ->
    State = remove_registry_entry(SessionId, Entry, State0),

    {keep_state, State, [idle_timeout(State)]};

receive_message({subscription_created, Entry}, SessionId, State0) ->
    State = add_registry_entry(SessionId, Entry, State0),

    {keep_state, State, [idle_timeout(State)]};

receive_message({subscription_added, Entry}, SessionId, State0) ->
    State = add_registry_entry(SessionId, Entry, State0),
    {keep_state, State, [idle_timeout(State)]};

receive_message({subscription_removed, Entry}, SessionId, State0) ->
    State = remove_registry_entry(SessionId, Entry, State0),

    {keep_state, State, [idle_timeout(State)]};

receive_message({subscription_deleted, Entry}, SessionId, State0) ->
    State = remove_registry_entry(SessionId, Entry, State0),

    {keep_state, State, [idle_timeout(State)]};

receive_message({forward, _, #publish{} = M, _Opts}, SessionId, State) ->
    RealmUri = session_realm(SessionId, State),
    ReqId = M#publish.request_id,
    TopicUri = M#publish.topic_uri,
    Args = M#publish.args,
    KWArg = M#publish.kwargs,
    Opts0 = M#publish.options,
    Opts = Opts0#{exclude_me => true},
    Ref = session_ref(SessionId, State),

    %% We do a re-publish so that bondy_broker disseminates the event using its
    %% normal optimizations
    Job = fun() ->
        Ctxt = bondy_context:local_context(RealmUri, Ref),
        bondy_broker:publish(ReqId, Opts, TopicUri, Args, KWArg, Ctxt)
    end,

    case bondy_router_worker:cast(Job) of
        ok ->
            ok;
        {error, overload} ->
            %% TODO return proper return ...but we should move this to router
            error(overload)
    end,

    {keep_state_and_data, [idle_timeout(State)]};

receive_message({forward, To, Msg, Opts}, SessionId, State) ->
    %% using cast here in theory breaks the CALL order guarantee!!!
    %% We either need to implement Partisan 4 plus:
    %% a) causality or
    %% b) a pool of relays (selecting one by hashing {CallerID, CalleeId}) and
    %% do it sync
    RealmUri = session_realm(SessionId, State),
    Job = fun() ->
        bondy_router:forward(Msg, To, Opts#{realm_uri => RealmUri})
    end,

    case bondy_router_worker:cast(Job) of
        ok ->
            ok;
        {error, overload} ->
            %% TODO return proper return ...but we should move this to router
            error(overload)
    end,

    {keep_state_and_data, [idle_timeout(State)]};

receive_message(Other, SessionId, State) ->
    ?LOG_INFO(#{
        description => "Unhandled message",
        session => SessionId,
        message => Other
    }),
    {keep_state_and_data, [idle_timeout(State)]}.


%% @private
add_registry_entry(SessionId, ExtEntry, State) ->
    Ref = session_ref(SessionId, State),

    ProxyEntry = bondy_registry_entry:proxy(Ref, ExtEntry),

    Id = bondy_registry_entry:id(ProxyEntry),
    OriginId = bondy_registry_entry:origin_id(ProxyEntry),

    case bondy_registry:add(ProxyEntry) of
        {ok, _} ->
            Index0 = State#state.registrations,
            Index = key_value:put([SessionId, OriginId], Id, Index0),
            State#state{registrations = Index};

        {error, already_exists} ->
            ok
    end.


%% @private
remove_registry_entry(SessionId, ExtEntry, State) ->
    Index0 = State#state.registrations,
    OriginId = maps:get(entry_id, ExtEntry),
    Type = maps:get(type, ExtEntry),

    try key_value:get([SessionId, OriginId], Index0) of
        ProxyId ->
            %% TODO get ctxt from session once we have real sessions
            RealmUri = session_realm(SessionId, State),
            Node = bondy_config:node(),
            Ctxt = #{
                realm_uri => RealmUri,
                node => Node,
                session_id => SessionId
            },

            ok = bondy_registry:remove(Type, ProxyId, Ctxt),

            Index = key_value:remove([SessionId, OriginId], Index0),
            State#state{registrations = Index}
    catch
        error:badkey ->
            State
    end.


remove_all_registry_entries(State) ->
    maps:foreach(
        fun(_, Session) ->
            RealmUri = bondy_session:realm_uri(Session),
            Ref = bondy_session:ref(Session),
            bondy_router:flush(RealmUri, Ref)
        end,
        State#state.sessions
    ).


%% @private
full_sync(SessionId, RealmUri, Opts, State) ->
    Realm = bondy_realm:fetch(RealmUri),

    %% If the realm has a prototype we sync the prototype first
    case bondy_realm:prototype_uri(Realm) of
        undefined ->
            ok;
        ProtoUri ->
            full_sync(SessionId, ProtoUri, Opts, State)
    end,

    %% We do not automatically sync the SSO Realms, if the edge node wants it,
    %% that should be requested explicitely

    %% TODO However, we should sync a proyection of the SSO Realm, the realm
    %% definition itself but with users, groups, sources and grants that affect
    %% the Realm's users, and avoiding bringing the password
    %% SO WE NEED REPLICATION FILTERS AT PLUM_DB LEVEL
    %% This means that only non SSO Users can login.
    %% ALSO we are currently copying the CRA passwords which we shouldn't

    %% Finally we sync the realm
    ok = do_full_sync(SessionId, RealmUri, Opts, State).



%% -----------------------------------------------------------------------------
%% @private
%% @doc A temporary POC of full sync, not elegant at all.
%% This should be resolved at the plum_db layer and not here, but we are
%% interested in having a POC ASAP.
%% @end
%% -----------------------------------------------------------------------------
do_full_sync(SessionId, RealmUri, _Opts, _State0) ->
    %% TODO we should spawn an exchange statem for this
    Me = self(),

    Prefixes = [
        %% TODO We should NOT sync the priv keys!!
        %% We might need to split the realm from the priv keys to enable a
        %% AAE hash comparison.
        {?PLUM_DB_REALM_TAB, RealmUri},
        {?PLUM_DB_GROUP_TAB, RealmUri},
        %% TODO we should not sync passwords! We might need to split the
        %% password from the user object and allow admin to enable sync or not
        %% (e.g. WAMPSCRAM)
        {?PLUM_DB_USER_TAB, RealmUri},
        {?PLUM_DB_SOURCE_TAB, RealmUri},
        {?PLUM_DB_USER_GRANT_TAB, RealmUri},
        {?PLUM_DB_GROUP_GRANT_TAB, RealmUri}
        % ,
        % {?PLUM_DB_REGISTRATION_TAB, RealmUri},
        % {?PLUM_DB_SUBSCRIPTION_TAB, RealmUri},
        % {?PLUM_DB_TICKET_TAB, RealmUri}
    ],

    _ = lists:foreach(
        fun(Prefix) ->
            lists:foreach(
                fun(Obj0) ->
                    Obj = prepare_object(Obj0),
                    Msg = {aae_data, SessionId, Obj},
                    gen_statem:cast(Me, {forward_message, Msg})
                end,
                pdb_objects(Prefix)
            )
        end,
        Prefixes
    ),
    ok.


%% @private
prepare_object(Obj) ->
    case bondy_realm:is_type(Obj) of
        true ->
            %% A temporary hack to prevent keys being synced with an Edge
            %% router. We will use this until be implement partial replication
            %% and decide on Key management strategies.
            bondy_realm:strip_private_keys(Obj);
        false ->
            Obj
    end.


pdb_objects(FullPrefix) ->
    It = plum_db:iterator(FullPrefix, []),
    try
        pdb_objects(It, [])
    catch
        {break, Result} -> Result
    after
        ok = plum_db:iterator_close(It)
    end.


%% @private
pdb_objects(It, Acc0) ->
    case plum_db:iterator_done(It) of
        true ->
            Acc0;
        false ->
            Acc = [plum_db:iterator_element(It) | Acc0],
            pdb_objects(plum_db:iterate(It), Acc)
    end.


%% @private
session_realm(SessionId, #state{sessions = Map}) ->
    bondy_session:realm_uri(maps:get(SessionId, Map)).


%% @private
session_ref(SessionId, #state{sessions = Map}) ->
    bondy_session:ref(maps:get(SessionId, Map)).


%% @private
session_id(RealmUri, #state{sessions_by_realm = Map}) ->
    maps:get(RealmUri, Map).


%% @private
maybe_gen_authid(anonymous) ->
    bondy_utils:uuid();

maybe_gen_authid(UserId) ->
    UserId.