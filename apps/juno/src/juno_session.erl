%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%% A Session is a transient conversation between two Peers attached to a
%% Realm and running over a Transport.
%%
%% Juno implementation ties the lifetime of the underlying transport connection
%% for a WAMP connection to that of a WAMP Session
%% i.e. establish a new transport-layer connection as part of each new
%% session establishment.
%%
%% A Juno Session is a not an application Session and is not a store for
%% application specific content (an application session store should be
%% implemented as a service i.e. a Callee).
%%
%% @end
%% =============================================================================
-module(juno_session).
-include_lib("wamp/include/wamp.hrl").

-define(SESSION_TABLE_NAME, session).
-define(SESSION_SEQ_POS, 5).

-record(session, {
    id              ::  id(),
    realm_uri       ::  uri(),
    pid = self()    ::  pid(),
    seq = 0         ::  non_neg_integer(),
    caller          ::  map(),
    callee          ::  map(),
    subscriber      ::  map(),
    publisher       ::  map()
}).

-type session()  ::  #session{}.
-type session_opts() :: #{
    roles => map()
}.

-export([close/1]).
-export([fetch/1]).
-export([id/1]).
-export([incr_seq/1]).
-export([lookup/1]).
-export([open/2]).
-export([pid/1]).
-export([realm_uri/1]).
-export([size/0]).

%% -export([features/1]).
%% -export([subscriptions/1]).
%% -export([registrations/1]).



%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% If a realm exists for RealmUri or if
%% {@link juno_config:automatically_create_realms/0} returns true, this function
%% will return a new session with Opts as options.
%% Otherwise, it will fail with an exception.
%% @end
%% -----------------------------------------------------------------------------
-spec open(uri(), session_opts()) -> session().
open(RealmUri, Opts) when is_map(Opts) ->
    _Realm = case juno_config:automatically_create_realms() of
        true ->
            %% We force the creation of a new realm if it does not exist
            wamp_realm:get(RealmUri);
        false ->
            %% Will throw an exception if it does not exist
            wamp_realm:fetch(RealmUri)
    end,
    SessionId = wamp_id:new(global),
    Session0 = #session{
        id = SessionId,
        realm_uri = RealmUri
    },
    Session1 = parse_details(Opts, Session0),
    case ets:insert_new(table(SessionId), Session1) of
        true ->
            Session1;
        false ->
            error({integrity_constraint_violation, SessionId})
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec close(id() | session()) -> ok.
close(#session{id = Id}) ->
    close(Id);
close(Id) ->
    true = ets:delete(table(Id), Id),
    ok.

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec id(session()) -> id().
id(#session{id = Id}) ->
    Id.

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec realm_uri(id() | session()) -> uri().
realm_uri(#session{realm_uri = Uri}) ->
    Uri;
realm_uri(Id) ->
    #session{realm_uri = Uri} = fetch(Id),
    Uri.

%% -----------------------------------------------------------------------------
%% @doc
%% Returns the pid of the process managing the transport that the session
%% identified by Id runs on.
%% @end
%% -----------------------------------------------------------------------------
-spec pid(id() | session()) -> pid().
pid(#session{pid = Pid}) ->
    Pid;
pid(Id) ->
    pid(fetch(Id)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec incr_seq(id() | session()) -> dict().
incr_seq(#session{id = Id}) ->
    incr_seq(Id);
incr_seq(SessionId) when is_integer(SessionId), SessionId >= 0 ->
    Tab = tuplespace:locate_table(?SESSION_TABLE_NAME, SessionId),
    ets:update_counter(Tab, SessionId, {?SESSION_SEQ_POS, 1, ?MAX_ID, 0}).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the number of sessions in the tuplespace.
%% @end
%% -----------------------------------------------------------------------------
-spec size() -> non_neg_integer().
size() ->
    tuplespace:size(?SESSION_TABLE_NAME).


%% -----------------------------------------------------------------------------
%% @doc
%% Retrieves the session identified by Id from the tuplespace or 'not_found'
%% if it doesn't exist.
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(id()) -> session() | not_found.
lookup(Id) ->
    case do_lookup(Id)  of
        #session{} = Session ->
            Session;
        not_found ->
            not_found
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Retrieves the session identified by Id from the tuplespace. If the session
%% does not exist it fails with reason '{badarg, Id}'.
%% @end
%% -----------------------------------------------------------------------------
-spec fetch(id()) -> session().
fetch(Id) ->
    case lookup(Id) of
        not_found ->
            error({badarg, Id});
        Session ->
            Session
    end.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
parse_details(Opts, Session0)  when is_map(Opts) ->
    case maps:fold(fun parse_details/3, Session0, Opts) of
        #session{
            caller = undefined,
            callee = undefined,
            subscriber = undefined,
            publisher = undefined} ->
                error({invalid_options, missing_client_role});
        Session1 ->
            Session1
    end.


%% @private
parse_details(<<"roles">>, Roles, Session) when is_map(Roles) ->
    parse_details(Roles, Session);
parse_details(<<"caller">>, V, Session) when is_map(V) ->
    Session#session{caller = V};
parse_details(<<"calle">>, V, Session) when is_map(V) ->
    Session#session{callee = V};
parse_details(<<"subscriber">>, V, Session) when is_map(V) ->
    Session#session{subscriber = V};
parse_details(<<"publisher">>, V, Session) when is_map(V) ->
    Session#session{publisher = V};
parse_details(_, _, Session) ->
    Session.


%% @private
table(Id) ->
    tuplespace:locate_table(?SESSION_TABLE_NAME, Id).


%% @private
-spec do_lookup(id()) -> session() | not_found.
do_lookup(Id) ->
    Tab = table(Id),
    case ets:lookup(Tab, Id)  of
        [#session{} = Session] ->
            Session;
        [] ->
            not_found
    end.
