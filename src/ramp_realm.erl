%% A Realm is a WAMP routing and administrative domain, optionally
%% protected by authentication and authorization.  WAMP messages are
%% only routed within a Realm.
-module(ramp_realm).
-include ("ramp.hrl").

-define(REALM_TABLE_NAME, realm).

-record(realm, {
    uri              ::  uri()
}).

-type realm()  ::  #realm{}.


-export([delete/1]).
-export([fetch/1]).
-export([get/1]).
-export([insert/1]).
-export([lookup/1]).
-export([size/0]).


%% @doc Returns the number of realms in the tuplespace.
-spec size() -> non_neg_integer().
size() ->
    tuplespace:size(?REALM_TABLE_NAME).


%% @doc Retrieves the realm identified by Uri from the tuplespace or 'not_found'
%% if it doesn't exist.
-spec lookup(uri()) -> realm() | not_found.
lookup(Uri) ->
    case do_lookup(Uri)  of
        #realm{} = Realm ->
            Realm;
        not_found ->
            not_found
    end.


%% @doc Retrieves the realm identified by Uri from the tuplespace. If the realm
%% does not exist it fails with reason '{badarg, Uri}'.
-spec fetch(uri()) -> realm().
fetch(Uri) ->
    case lookup(Uri) of
        not_found ->
            error({not_found, Uri});
        Realm ->
            Realm
    end.

%% @doc Retrieves the realm identified by Uri from the tuplespace. If the realm
%% does not exist it will insert a new one for Uri.
-spec get(uri()) -> realm().
get(Uri) ->
    case lookup(Uri) of
        #realm{} = Realm ->
            Realm;
        not_found ->
            insert(Uri)
    end.


-spec insert(uri()) -> realm().
insert(Uri) ->
    Tab = table(Uri),
    Realm = #realm{uri = Uri},
    case ets:insert_new(Tab, Realm) of
        true ->
            Realm;
        false ->
            error({realm_already_exists, Uri})
    end.


-spec delete(uri()) -> ok.
delete(Uri) ->
    true = ets:delete(table(Uri), Uri),
    ok.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
table(Uri) ->
    tuplespace:locate_table(?REALM_TABLE_NAME, Uri).


%% @private
-spec do_lookup(uri()) -> realm() | not_found.
do_lookup(Uri) ->
    Tab = table(Uri),
    case ets:lookup(Tab, Uri)  of
        [#realm{} = Realm] ->
            Realm;
        [] ->
            not_found
    end.
