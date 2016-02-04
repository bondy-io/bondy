-module(ramp_session).
-include ("ramp.hrl").

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



-spec open(uri(), session_opts()) -> session().
open(RealmUri, Details) when is_map(Details) ->
    _Realm = case ramp_config:automatically_create_realms() of
        true ->
            %% We force the creation of a new realm if it does not exist
            ramp_realm:get(RealmUri);
        false ->
            %% Will throw an exception if it does not exist
            ramp_realm:fetch(RealmUri)
    end,
    SessionId = ramp_id:new(global),
    Session0 = #session{
        id = SessionId,
        realm_uri = RealmUri
    },
    Session1 = parse_details(Details, Session0),
    case ets:insert_new(table(SessionId), Session1) of
        true ->
            Session1;
        false ->
            error({integrity_constraint_violation, SessionId})
    end.


-spec close(id() | session()) -> ok.
close(#session{id = Id}) ->
    close(Id);
close(Id) ->
    true = ets:delete(table(Id), Id),
    ok.


-spec id(session()) -> id().
id(#session{id = Id}) ->
    Id.


-spec realm_uri(id() | session()) -> uri().
realm_uri(#session{realm_uri = Uri}) ->
    Uri;
realm_uri(Id) ->
    #session{realm_uri = Uri} = fetch(Id),
    Uri.


-spec pid(id() | session()) -> pid().
pid(#session{pid = Pid}) ->
    Pid;
pid(Id) ->
    #session{pid = Pid} = fetch(Id),
    Pid.


-spec incr_seq(id() | session()) -> dict().
incr_seq(#session{id = Id}) ->
    incr_seq(Id);
incr_seq(SessionId) when is_integer(SessionId), SessionId >= 0 ->
    Tab = tuplespace:locate_table(?SESSION_TABLE_NAME, SessionId),
    ets:update_counter(Tab, SessionId, {?SESSION_SEQ_POS, 1, ?MAX_ID, 0}).


%% @doc Returns the number of realms in the tuplespace.
-spec size() -> non_neg_integer().
size() ->
    tuplespace:size(?SESSION_TABLE_NAME).


%% @doc Retrieves the session identified by Uri from the tuplespace or 'not_found'
%% if it doesn't exist.
-spec lookup(id()) -> session() | not_found.
lookup(Id) ->
    case do_lookup(Id)  of
        #session{} = Session ->
            Session;
        not_found ->
            not_found
    end.


%% @doc Retrieves the session identified by Id from the tuplespace. If the session
%% does not exist it fails with reason '{badarg, Id}'.
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
parse_details(Options, Session0)  when is_map(Options) ->

    case maps:fold(fun parse_details/3, Session0, Options) of
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
