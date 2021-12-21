%% -----------------------------------------------------------------------------
%% @doc EARLY DRAFT implementation of the server-side connection between and
%% edge node (client) and a remote/core node (server).
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_edge_uplink_server).
-behaviour(gen_statem).
-behaviour(ranch_protocol).

-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include_lib("bondy_plum_db.hrl").


-define(SOCKET_DATA(Tag), Tag == tcp orelse Tag == ssl).
-define(SOCKET_ERROR(Tag), Tag == tcp_error orelse Tag == ssl_error).
-define(CLOSED_TAG(Tag), Tag == tcp_closed orelse Tag == ssl_closed).
% -define(PASSIVE_TAG(Tag), Tag == tcp_passive orelse Tag == ssl_passive).


-record(state, {
    ranch_ref               ::  atom(),
    transport               ::  module(),
    opts                    ::  key_value:t(),
    socket                  ::  gen_tcp:socket() | ssl:sslsocket(),
    idle_timeout            ::  pos_integer(),
    ping_retry              ::  maybe(bondy_retry:t()),
    ping_tref               ::  maybe(timer:ref()),
    ping_sent               ::  maybe({Ref :: timer:ref(), Data :: binary()}),
    sessions = #{}          ::  #{id() => bondy_edge_session:t()},
    sessions_by_uri = #{}   ::  #{uri() => id()},
    registrations = #{}     ::  reg_indx(),
    session                 ::  maybe(map()),
    auth_realm              ::  binary(),
    start_ts                ::  pos_integer()
}).

% -type t()                   ::  #state{}.
-type reg_indx()            ::  #{SessionId :: id() => proxy_map()}.
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
%% they do not count towads the idle_timeout.
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
    State0 = #state{
        ranch_ref = RanchRef,
        transport = Transport,
        opts = Opts,
        idle_timeout = key_value:get(idle_timeout, Opts, timer:minutes(10)),
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

    %% How much time till we get
    Timeout = key_value:get(auth_timeout, Opts, 5000),

    {ok, connected, State, Timeout}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
terminate(Reason, StateName, #state{transport = T, socket = S} = State)
when T =/= undefined andalso S =/= undefined ->
    ?LOG_DEBUG(#{
        description => "Closing connection",
        reason => Reason
    }),
    catch T:close(S),
    ok = on_close(Reason, State),
    NewState = State#state{transport = undefined, socket = undefined},
    terminate(Reason, StateName, NewState);

terminate(_Reason, _StateName, State) ->
    ok = remove_all_registry_entries(State).


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

    Opts = [
        binary,
        {packet, 4},
        {active, once}
        | bondy_config:get([Ref, socket_opts], [])
    ],

    %% Setup and configure socket
    {ok, Socket} = ranch:handshake(Ref),
    ok = Transport:setopts(Socket, Opts),

    {ok, Peername} = inet:peername(Socket),
    PeernameBin = inet_utils:peername_to_binary(Peername),

    ok = bondy_logger_utils:set_process_metadata(#{
        transport => Transport,
        peername => PeernameBin,
        socket => Socket
    }),

    ok = on_connect(State),

    {keep_state, State#state{socket = Socket}, [idle_timeout(State)]};


connected(info, {Tag, Socket, Data}, #state{socket = Socket} = State)
when ?SOCKET_DATA(Tag) ->
    ok = set_socket_active(State),
    case binary_to_term(Data) of
        {receive_message, SessionId, Msg} ->
            ?LOG_INFO(#{
                description => "Got session message from edge",
                reason => Msg,
                session_id => SessionId
            }),
            safe_handle_session_message(Msg, SessionId, State);
        Msg ->
            ?LOG_INFO(#{
                description => "Got message from edge",
                reason => Msg
            }),
            handle_message(Msg, State)
    end;

connected(info, {Tag, _Socket}, _) when ?CLOSED_TAG(Tag) ->
    {stop, normal};

connected(info, {Tag, _, Reason}, _) when ?SOCKET_ERROR(Tag) ->
    ?LOG_INFO(#{
        description => "Edge connection closed due to error",
        reason => Reason
    }),
    {stop, Reason};

connected(info, {?BONDY_PEER_REQUEST, _Pid, RealmUri, M}, State) ->
    ?LOG_WARNING(#{
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

connected(_EventType, _Msg, _) ->
    {stop, normal}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
challenge(Realm, Details, State0) ->
    {ok, Peer} = inet:peername(State0#state.socket),
    Sessions0 = State0#state.sessions,
    SessionsByUri0 = State0#state.sessions_by_uri,

    Uri = bondy_realm:uri(Realm),
    SessionId = bondy_utils:get_id(global),
    Authid = maps:get(authid, Details),
    Roles = maps:get(authroles, Details, []),

    case bondy_auth:init(SessionId, Realm, Authid, Roles, Peer) of
        {ok, AuthCtxt} ->
            %% TODO take it from conf
            ReqMethods = [<<"cryptosign">>],
            case bondy_auth:available_methods(ReqMethods, AuthCtxt) of
                [] ->
                    throw({no_authmethod, ReqMethods});

                [Method|_] ->
                    Session = #{
                        id => SessionId,
                        authid => Authid,
                        realm => bondy_realm:uri(Realm),
                        auth_context => AuthCtxt
                    },

                    Sessions = maps:put(SessionId, Session, Sessions0),
                    SessionsByUri = maps:put(Uri, SessionId, SessionsByUri0),

                    State = State0#state{
                        session = Session,
                        sessions = Sessions,
                        sessions_by_uri = SessionsByUri
                    },
                    do_challenge(SessionId, Details, Method, State)
            end;

        {error, Reason0} ->
            throw({authentication_failed, Reason0})
    end.


%% @private
do_challenge(SessionId, Details, Method, State0) ->
    Session0 = maps:get(SessionId, State0#state.sessions),
    AuthCtxt0 = maps:get(auth_context, Session0),

    {AuthCtxt, Reply} =
        case bondy_auth:challenge(Method, Details, AuthCtxt0) of
            {ok, AuthCtxt1} ->
                M = {welcome, SessionId, #{}},
                {AuthCtxt1, M};

            {ok, ChallengeExtra, AuthCtxt1} ->
                M = {challenge, Method, ChallengeExtra},
                {AuthCtxt1, M};

            {error, Reason} ->
                throw({authentication_failed, Reason})
        end,

    Session = Session0#{
        auth_context => AuthCtxt,
        start_ts => erlang:system_time(millisecond)
    },

    State = State0#state{
        sessions = maps:put(SessionId, Session, State0#state.sessions)
    },

    ok = send_message(Reply, State),

    State.


%% @private
authenticate(AuthMethod, Signature, Extra, State0) ->
    SessionId = maps:get(id, State0#state.session),

    Session0 = maps:get(SessionId, State0#state.sessions),
    AuthCtxt0 = maps:get(auth_context, Session0),

    {AuthCtxt, Reply} =
        case bondy_auth:authenticate(AuthMethod, Signature, Extra, AuthCtxt0) of
            {ok, WelcomeAuthExtra, AuthCtxt1} ->
                M = {welcome, SessionId, #{authextra => WelcomeAuthExtra}},
                {AuthCtxt1, M};
            {error, Reason} ->
                throw({authentication_failed, Reason})
        end,

    Session = Session0#{
        auth_context => AuthCtxt,
        start_ts => erlang:system_time(millisecond)
    },

    State = State0#state{
        sessions = maps:put(SessionId, Session, State0#state.sessions),
        session = undefined
    },

    ok = send_message(Reply, State),

    State.


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
on_close(_Reason, _State) ->
    ok.


%% @private
idle_timeout(State) ->
    {timeout, State#state.idle_timeout, idle_timeout}.


%% @private
handle_message({hello, _, _}, #state{session = Session} = State)
when Session =/= undefined ->
    %% Session already being established, wrong message
    ok = send_message({abort, #{}, protocol_violation}, State),
    {stop, State};

handle_message({hello, Uri, Details}, State0) ->
    %% TODO validate Details
    ?LOG_DEBUG(#{
        description => "Got hello",
        details => Details
    }),
    try

        Realm = bondy_realm:get(Uri),

        bondy_realm:allow_connections(Realm)
            orelse throw(connections_not_allowed),

        State = challenge(Realm, Details, State0),
        {keep_state, State, [idle_timeout(State)]}

    catch
        error:{not_found, Uri} ->
            Reason = {no_such_realm, Uri},
            ok = send_message({abort, #{}, Reason}, State0),
            {stop, State0};

        throw:Reason ->
            ok = send_message({abort, #{}, Reason}, State0),
            {stop, State0}

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
        throw:Reason ->
            ok = send_message({abort, #{}, Reason}, State0),
            {stop, State0}
    end;

handle_message({aae_sync, SessionId, Opts}, State) ->
    RealmUri = session_realm(SessionId, State),
    ok = full_sync(SessionId, RealmUri, Opts, State),
    {keep_state_and_data, [idle_timeout(State)]}.


%% @private
safe_handle_session_message(Msg, SessionId, State) ->
    try
        handle_session_message(Msg, SessionId, State)
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
            ok = send_message({abort, #{}, server_error}, State),
            {stop, State}
    end.


%% @private
handle_session_message({registration_created, Entry}, SessionId, State0) ->
    State = add_registry_entry(SessionId, Entry, State0),

    {keep_state, State, [idle_timeout(State)]};

handle_session_message({registration_added, Entry}, SessionId, State0) ->
    State = add_registry_entry(SessionId, Entry, State0),

    {keep_state, State, [idle_timeout(State)]};

handle_session_message({registration_removed, Entry}, SessionId, State0) ->
    State = remove_registry_entry(SessionId, Entry, State0),

    {keep_state, State, [idle_timeout(State)]};

handle_session_message({registration_deleted, Entry}, SessionId, State0) ->
    State = remove_registry_entry(SessionId, Entry, State0),

    {keep_state, State, [idle_timeout(State)]};

handle_session_message({subscription_created, Entry}, SessionId, State0) ->
    State = add_registry_entry(SessionId, Entry, State0),

    {keep_state, State, [idle_timeout(State)]};

handle_session_message({subscription_added, Entry}, SessionId, State0) ->
    State = add_registry_entry(SessionId, Entry, State0),
    {keep_state, State, [idle_timeout(State)]};

handle_session_message({subscription_removed, Entry}, SessionId, State0) ->
    State = remove_registry_entry(SessionId, Entry, State0),

    {keep_state, State, [idle_timeout(State)]};

handle_session_message({subscription_deleted, Entry}, SessionId, State0) ->
    State = remove_registry_entry(SessionId, Entry, State0),

    {keep_state, State, [idle_timeout(State)]};

handle_session_message({forward, To, Msg, Opts}, _SessionId, State) ->
    %% using cast here in theory breaks the CALL order guarantee!!!
    %% We either need to implement Partisan 4 plus:
    %% a) causality or
    %% b) a pool of relays (selecting one by hashing {CallerID, CalleeId}) and
    %% do it sync
    Job = fun() ->
        bondy_router:forward(Msg, To, Opts)
    end,

    case bondy_router_worker:cast(Job) of
        ok ->
            ok;
        {error, overload} ->
            %% TODO return proper return ...but we should move this to router
            error(overload)
    end,

    {keep_state_and_data, [idle_timeout(State)]}.


%% @private
add_registry_entry(SessionId, ExtEntry, State) ->
    RealmUri = bondy_ref:realm_uri(maps:get(ref, ExtEntry)),
    Nodestring = bondy_config:nodestring(),

    Ref = bondy_ref:new(bridge_relay, RealmUri, self(), SessionId, Nodestring),
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

            ok = bondy_registry:remove(registration, ProxyId, Ctxt),

            Index = key_value:remove([SessionId, OriginId], Index0),
            State#state{registrations = Index}
    catch
        error:badkey ->
            State
    end.


remove_all_registry_entries(State) ->
    Node = bondy_config:node(),

    maps:foreach(
        fun(RealmUri, SessionId) ->
            Ref = bondy_ref:new(bridge_relay, RealmUri, self(), SessionId),
            Ctxt = #{
                realm_uri => RealmUri,
                session_id => SessionId,
                node => Node,
                ref => Ref
            },
            bondy_router:close_context(Ctxt)
        end,
        State#state.sessions_by_uri
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
    %% SO WE NEED REPLICATION FILTERS AT PLUM_DB LEVEL b
    %%

    %% Finally we sync the realm
    ok = do_full_sync(SessionId, RealmUri, Opts, State),

    Finish = {aae_sync, SessionId, finished},
    gen_statem:cast(self(), {forward, Finish}).



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
        %% We might need to split the realm from the priv keys to simplify AAE
        %% compare operation. But we should be doing some form of Key exchange
        %% anyways
        {?PLUM_DB_REALM_TAB, RealmUri},
        {?PLUM_DB_GROUP_TAB, RealmUri},
        %% TODO we should not sync passwords!
        %% We might need to split the password from the user object to simplify
        %% AAE compare operation
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
                fun(O) ->
                    Msg = {aae_data, SessionId, O},
                    gen_statem:cast(Me, {forward, Msg})
                end,
                pdb_objects(Prefix)
            )
        end,
        Prefixes
    ),
    ok.


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
    maps:get(realm, maps:get(SessionId, Map)).


session_id(RealmUri, #state{sessions_by_uri = Map}) ->
    maps:get(RealmUri, Map).