%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%% The Juno Router provides the routing logic for all interactions.
%% It delegates the actual handling of a WAMP message to either juno_dealer or juno_broker.
%%
%% The Juno Router is not a process i.e. all function calls are performed by the calling process.
%%
%% ,------.                                    ,------.
%% | Peer |                                    | Peer |
%% `--+---'                                    `--+---'
%%
%%                   TCP established
%%    |<----------------------------------------->|
%%    |                                           |
%%    |               TLS established             |
%%    |+<--------------------------------------->+|
%%    |+                                         +|
%%    |+           WebSocket established         +|
%%    |+|<------------------------------------->|+|
%%    |+|                                       |+|
%%    |+|            WAMP established           |+|
%%    |+|+<----------------------------------->+|+|
%%    |+|+                                     +|+|
%%    |+|+                                     +|+|
%%    |+|+            WAMP closed              +|+|
%%    |+|+<----------------------------------->+|+|
%%    |+|                                       |+|
%%    |+|                                       |+|
%%    |+|            WAMP established           |+|
%%    |+|+<----------------------------------->+|+|
%%    |+|+                                     +|+|
%%    |+|+                                     +|+|
%%    |+|+            WAMP closed              +|+|
%%    |+|+<----------------------------------->+|+|
%%    |+|                                       |+|
%%    |+|           WebSocket closed            |+|
%%    |+|<------------------------------------->|+|
%%    |+                                         +|
%%    |+              TLS closed                 +|
%%    |+<--------------------------------------->+|
%%    |                                           |
%%    |               TCP closed                  |
%%    |<----------------------------------------->|
%%
%% ,--+---.                                    ,--+---.
%% | Peer |                                    | Peer |
%% `------'                                    `------'
%%
%% @end
%% =============================================================================
-module(juno_router).
-include("juno.hrl").

-export([handle_message/2]).
%% -export([has_role/2]). ur, ctxt
%% -export([add_role/2]). uri, ctxt
%% -export([remove_role/2]). uri, ctxt
%% -export([authorise/4]). session, uri, action, ctxt
%% -export([start_realm/2]). uri, ctxt
%% -export([stop_realm/2]). uri, ctxt



%% =============================================================================
%% API
%% =============================================================================



-spec handle_message(M :: message(), Ctxt :: map()) ->
    {ok, NewCtxt :: juno_context:context()}
    | {stop, NewCtxt :: juno_context:context()}
    | {reply, Reply :: message(), NewCtxt :: juno_context:context()}
    | {stop, Reply :: message(), NewCtxt :: juno_context:context()}.
handle_message(#hello{}, #{session_id := _} = Ctxt) ->
    %% Client already has a session!
    %% RPC:
    %% It is a protocol error to receive a second "HELLO" message during the
    %% lifetime of the session and the _Peer_ must fail the session if that
    %% happens
    Abort = juno_message:abort(
        #{message => <<"You've sent a HELLO message more than once.">>},
        ?JUNO_SESSION_ALREADY_EXISTS
    ),
    {stop, Abort, Ctxt};

handle_message(#hello{} = M, Ctxt0) ->
    %% Client does not have a session and wants to open one
    open_session(M#hello.realm_uri, M#hello.details, Ctxt0);

handle_message(M, #{session_id := _} = Ctxt) ->
    %% Client already has a session!
    handle_session_message(M, Ctxt);

handle_message(_M, Ctxt) ->
    %% Client does not have a session and message is not HELLO
    Abort = juno_message:abort(
        #{message => <<"You need to estalish a session first.">>},
        ?JUNO_ERROR_NOT_IN_SESSION
    ),
    {stop, Abort, Ctxt}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
open_session(RealmUri, Details, Ctxt0) ->
    try
        Session = juno_session:open(RealmUri, Details),
        SessionId = juno_session:id(Session),
        Ctxt1 = Ctxt0#{
            session_id => SessionId,
            realm_uri => RealmUri
        },
        Welcome = juno_message:welcome(
            SessionId,
            #{
                agent => ?JUNO_VERSION_STRING,
                roles => #{
                    dealer => #{},
                    broker => #{}
                }
            }
        ),
        {reply, Welcome, Ctxt1}
    catch
        error:{not_found, RealmUri} ->
            Abort = juno_message:abort(
                #{message => <<"Real does not exist.">>},
                ?WAMP_ERROR_NO_SUCH_REALM
            ),
            {stop, Abort, Ctxt0};
        error:{invalid_options, missing_client_role} ->
            Abort = juno_message:abort(
                #{message => <<"Please provide at least one client role.">>},
                <<"wamp.error.missing_client_role">>
            ),
            {stop, Abort, Ctxt0}
    end.


%% @private
handle_session_message(#goodbye{}, #{goodbye_initiated := true} = Ctxt) ->
    %% The client is replying to our goodbye() message.
    {stop, Ctxt};

handle_session_message(#goodbye{} = M, Ctxt) ->
    %% Goodbye initiated by client, we reply with goodbye().
    #{session_id := SessionId} = Ctxt,
    error_logger:info_report(
        "Session ~p closed as per client request. Reason: ~p~n",
        [SessionId, M#goodbye.reason_uri]
    ),
    Reply = juno_message:goodbye(#{}, ?WAMP_ERROR_GOODBYE_AND_OUT),
    {stop, Reply, Ctxt};

handle_session_message(#subscribe{} = M, Ctxt) ->
    juno_broker:handle_message(M, Ctxt);

handle_session_message(#unsubscribe{} = M, Ctxt) ->
    juno_broker:handle_message(M, Ctxt);

handle_session_message(#publish{} = M, Ctxt) ->
    juno_broker:handle_message(M, Ctxt);

handle_session_message(#register{} = M, Ctxt) ->
    juno_dealer:handle_message(M, Ctxt);

handle_session_message(#unregister{} = M, Ctxt) ->
    juno_dealer:handle_message(M, Ctxt);

handle_session_message(#call{} = M, Ctxt) ->
    juno_dealer:handle_message(M, Ctxt);

handle_session_message(#cancel{} = M, Ctxt) ->
    juno_dealer:handle_message(M, Ctxt);

handle_session_message(#yield{} = M, Ctxt) ->
    juno_dealer:handle_message(M, Ctxt);

handle_session_message(#error{request_type = ?INVOCATION} = M, Ctxt) ->
    juno_dealer:handle_message(M, Ctxt);

handle_session_message(_M, _Ctxt) ->
    error(unexpected_message).
