-module(ramp_router).
-include ("ramp.hrl").


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
    %% We already have a session!
    %% It is a protocol error to receive a second "HELLO" message during the
    %% lifetime of the session and the _Peer_ must fail the session if that
    %% happens
    Abort = ramp_message:abort(
        #{message => <<"You've sent a HELLO message more than once.">>},
        <<"wamp.error.session_already_exists">>
    ),
    {stop, Abort, Ctxt};

handle_message(#hello{} = M, Ctxt0) ->
    handle_open_session(M#hello.realm_uri, M#hello.details, Ctxt0);

handle_message(M, #{session_id := _} = Ctxt) ->
    handle_session_message(M, Ctxt);

handle_message(_M, Ctxt) ->
    Abort = ramp_message:abort(
        #{message => <<"You need to estalish a session first.">>},
        <<"wamp.error.not_in_session">>
    ),
    {stop, Abort, Ctxt}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
handle_session_message(#goodbye{} = M, Ctxt) ->
    SessionId = ramp_context:session_id(Ctxt),
    error_logger:info_report(
        "Session ~p closed as per client request. Reason: ~p~n",
        [SessionId, M#goodbye.reason_uri]
    ),
    Reply = ramp_message:goodbye(#{}, ?WAMP_ERROR_GOODBYE_AND_OUT),
    {stop, Reply, #{}};

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
            #{roles => #{
                dealer => #{},
                broker => #{}
            }}
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
