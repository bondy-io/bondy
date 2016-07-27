%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%% A Realm is a routing and administrative domain, optionally
%% protected by authentication and authorization. Juno messages are
%% only routed within a Realm. This is equivalent to the WAMP Realm.
%% @end
%% =============================================================================
-module(juno_realm).
-include_lib("wamp/include/wamp.hrl").

-define(PREFIX, {global, realms}).

-record(realm, {
    uri                 ::  uri(),
    description         ::  binary()
    % account          ::  uri()
}).

-type realm()  ::  #realm{}.


-export([delete/1]).
-export([fetch/1]).
-export([get/1]).
-export([put/1]).
-export([put/2]).
-export([lookup/1]).



%% -----------------------------------------------------------------------------
%% @doc
%% Retrieves the realm identified by Uri from the tuplespace or 'not_found'
%% if it doesn't exist.
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(uri()) -> realm() | not_found.
lookup(Uri) ->
    case do_lookup(Uri)  of
        #realm{} = Realm ->
            Realm;
        not_found ->
            not_found
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Retrieves the realm identified by Uri from the tuplespace. If the realm
%% does not exist it fails with reason '{badarg, Uri}'.
%% @end
%% -----------------------------------------------------------------------------
-spec fetch(uri()) -> realm().
fetch(Uri) ->
    case lookup(Uri) of
        not_found ->
            error({not_found, Uri});
        Realm ->
            Realm
    end.

%% -----------------------------------------------------------------------------
%% @doc 
%% Retrieves the realm identified by Uri from the tuplespace. If the realm
%% does not exist it will put a new one for Uri.
%% @end
%% -----------------------------------------------------------------------------
-spec get(uri()) -> realm().
get(Uri) ->
    case lookup(Uri) of
        #realm{} = Realm ->
            Realm;
        not_found ->
            put(Uri)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec put(uri()) -> realm().
put(Uri) ->
    juno_realm:put(Uri, #{}).

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec put(uri(), map()) -> realm().
put(Uri, Opts) ->
    Realm = #realm{
        uri = Uri,
        description = maps:get(description, Opts, undefined)
    },
    ok = plumtree_metadata:put(?PREFIX, Uri, Realm),
    Realm.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec delete(uri()) -> ok.
delete(Uri) ->
    plumtree_metadata:delete(?PREFIX, Uri),
    ok.



%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
-spec do_lookup(uri()) -> realm() | not_found.
do_lookup(Uri) ->
    case plumtree_metadata:get(?PREFIX, Uri)  of
        #realm{} = Realm ->
            Realm;
        undefined ->
            not_found
    end.
