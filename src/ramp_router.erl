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
-module(ramp_router).
-include("ramp.hrl").

-export([handle_message/2]).



%% =============================================================================
%% API
%% =============================================================================




-spec handle_message(M :: message(), Ctxt :: map()) ->
    {ok, NewCtxt :: ramp_context:context()}
    | {stop, NewCtxt :: ramp_context:context()}
    | {reply, Reply :: message(), NewCtxt :: ramp_context:context()}
    | {stop, Reply :: message(), NewCtxt :: ramp_context:context()}.
handle_message(#hello{}, #{session_id := _} = Ctxt) ->
    %% Client already has a session!
    %% It is a protocol error to receive a second "HELLO" message during the
    %% lifetime of the session and the _Peer_ must fail the session if that
    %% happens
    Abort = ramp_message:abort(
        #{message => <<"You've sent a HELLO message more than once.">>},
        <<"wamp.error.session_already_exists">>
    ),
    {stop, Abort, Ctxt};

handle_message(#hello{} = M, Ctxt0) ->
    %% Client does not have a session and wants to open one
    handle_open_session(M#hello.realm_uri, M#hello.details, Ctxt0);

handle_message(M, #{session_id := _} = Ctxt) ->
    %% Client already has a session!
    handle_session_message(M, Ctxt);

handle_message(_M, Ctxt) ->
    %% Client does not have a session and message is not HELLO
    Abort = ramp_message:abort(
        #{message => <<"You need to estalish a session first.">>},
        <<"wamp.error.not_in_session">>
    ),
    {stop, Abort, Ctxt}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
handle_session_message(#goodbye{}, #{goodbye_initiated := true} = Ctxt) ->
    %% The client is replying our goodbye.
    {stop, Ctxt};

handle_session_message(#goodbye{} = M, Ctxt) ->
    %% Goodbye initiated by client, we reply with goodbye.
    #{session_id := SessionId} = Ctxt,
    error_logger:info_report(
        "Session ~p closed as per client request. Reason: ~p~n",
        [SessionId, M#goodbye.reason_uri]
    ),
    Reply = ramp_message:goodbye(#{}, ?WAMP_ERROR_GOODBYE_AND_OUT),
    {stop, Reply, Ctxt};

handle_session_message(#subscribe{} = M, Ctxt) ->
    ReqId = M#subscribe.request_id,
    Opts = M#subscribe.options,
    Topic = M#subscribe.topic_uri,
    {ok, SubsId} = ramp_broker:subscribe(Topic, Opts, Ctxt),
    Reply = ramp_message:subscribed(ReqId, SubsId),
    {reply, Reply, Ctxt};

handle_session_message(#unsubscribe{} =M, Ctxt) ->
    ReqId = M#unsubscribe.request_id,
    SubsId = M#unsubscribe.subscription_id,
    Reply = case ramp_broker:unsubscribe(SubsId, Ctxt) of
        ok ->
            ramp_message:unsubscribed(ReqId);
        {error, no_such_subscription} ->
            ramp_error:error(
                ?UNSUBSCRIBE, ReqId, #{}, ramp:error_uri(no_such_subscription)
            )
    end,
    {reply, Reply, Ctxt};

handle_session_message(_M, _Ctxt) ->
    error(not_yet_implemented).


%% @private
handle_open_session(RealmUri, Details, Ctxt0) ->
    try
        Session = ramp_session:open(RealmUri, Details),
        SessionId = ramp_session:id(Session),
        Ctxt1 = Ctxt0#{
            session_id => SessionId,
            realm_uri => RealmUri
        },
        Welcome = ramp_message:welcome(
            SessionId,
            #{
                agent => ?RAMP_VERSION_STRING,
                roles => #{
                    dealer => #{},
                    broker => #{}
                }
            }
        ),
        {reply, Welcome, Ctxt1}
    catch
        error:{invalid_options, missing_client_role} ->
            Abort = ramp_message:abort(
                #{message => <<"Please provide at least one client role.">>},
                <<"wamp.error.missing_client_role">>
            ),
            {stop, Abort, Ctxt0}
    end.
