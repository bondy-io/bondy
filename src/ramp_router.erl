-module(ramp_router).
-include ("ramp.hrl").

-type context()       ::  #{
    session_id => id(),
    realm_uri => uri(),
    subprotocol => subprotocol()
}.
-export_type([context/0]).

-export([init_context/0]).
-export([handle_message/2]).



%% =============================================================================
%% API
%% =============================================================================



-spec init_context() -> context().
init_context() ->
    #{}.


-spec handle_message(M :: message(), Ctxt :: map()) ->
    {ok, NewCtxt :: context()}
    | {stop, NewCtxt :: context()}
    | {reply, Reply :: message(), NewCtxt :: context()}
    | {stop, Reply :: message(), NewCtxt :: context()}.
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

handle_message(_M, #{session_id := _} = _Ctxt) ->
    %% TODO ALL
    error(not_yet_implemented).



%% =============================================================================
%% PRIVATE
%% =============================================================================



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
