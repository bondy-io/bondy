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
-include("juno.hrl").
-include_lib("wamp/include/wamp.hrl").

-define(DEFAULT_AUTH_METHOD, ?WAMPCRA_AUTH).
-define(PREFIX, {global, realms}).
-define(LOCAL_CIDRS, [
    {{10,0,0,0}, 8},
    {{172,16,0,0}, 12},
    {{192,168,0,0}, 16}
]).


-record(realm, {
    uri                         ::  uri(),
    description                 ::  binary(),
    authmethods                 ::  [binary()] % a wamp property
    % account          ::  uri()
}).
-type realm()  ::  #realm{}.

-export_type([realm/0]).

-export([auth_methods/1]).
-export([delete/1]).
-export([disable_security/1]).
-export([enable_security/1]).
-export([fetch/1]).
-export([get/1]).
-export([get/2]).
-export([is_security_enabled/1]).
-export([list/0]).
-export([lookup/1]).
-export([put/1]).
-export([put/2]).
-export([security_status/1]).
-export([select_auth_method/2]).
-export([uri/1]).


-compile({no_auto_import,[put/2]}).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec auth_methods(realm()) -> [binary()].
auth_methods(#realm{authmethods = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_security_enabled(realm()) -> boolean().
is_security_enabled(#realm{authmethods = []}) ->
    false;
is_security_enabled(#realm{}) ->
    true.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec security_status(realm()) -> enabled | disabled.
security_status(#realm{uri = Uri}) ->
    juno_security:status(Uri).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec enable_security(realm()) -> ok.
enable_security(#realm{uri = Uri} = Realm) ->
    ok = juno_security:enable(Uri),
    Realm.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec disable_security(realm()) -> ok.
disable_security(#realm{uri = Uri} = Realm) ->
    ok = juno_security:disable(Uri),
    Realm.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec uri(realm()) -> uri().
uri(#realm{uri = Uri}) ->
    Uri.


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
    get(Uri, #{}).


%% -----------------------------------------------------------------------------
%% @doc 
%% Retrieves the realm identified by Uri from the tuplespace. If the realm
%% does not exist it will put a new one for Uri.
%% @end
%% -----------------------------------------------------------------------------
-spec get(uri(), map()) -> realm().
get(Uri, Opts) ->
    case lookup(Uri) of
        #realm{} = Realm ->
            Realm;
        not_found ->
            put(Uri, Opts)
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
    wamp_uri:is_valid(Uri) orelse error({invalid_uri, Uri}),
    #{
        description := Desc, 
        authmethods := Method
    } = ls_maps_utils:validate(Opts, opts_spec()),

    Realm = #realm{
        uri = Uri,
        description = Desc,
        authmethods = Method
    },

    case lookup(Uri) of
        not_found ->
            ok = plumtree_metadata:put(?PREFIX, Uri, Realm),
            init(Realm);
        _ ->
            ok = plumtree_metadata:put(?PREFIX, Uri, Realm)
    end.
    
    


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec delete(uri()) -> ok.
delete(?JUNO_REALM_URI) ->
    {error, not_permitted};
delete(Uri) ->
    plumtree_metadata:delete(?PREFIX, Uri),
    % TODO we need to close all sessions for this realm
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec list() -> [realm()].
list() ->
    [V || {_K, [V]} <- plumtree_metadata:to_list(?PREFIX), V =/= '$deleted'].


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec select_auth_method(realm(), [binary()]) -> any().
select_auth_method(Realm, []) ->
    select_auth_method(Realm, [?DEFAULT_AUTH_METHOD]);

select_auth_method(#realm{authmethods = Allowed}, Requested) ->
    A = sets:from_list(Allowed),
    R = sets:from_list(Requested),
    I = sets:intersection([A, R]),
    case sets:size(I) > 0 of
        true ->
            select_first_available(Requested, I);
        false ->
            case sets:is_element(?DEFAULT_AUTH_METHOD, A) of
                true ->
                    ?DEFAULT_AUTH_METHOD;
                false ->
                    %% We get the first from the list to respect client's
                    %% preference order
                    hd(Allowed)
            end
    end.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
init(#realm{uri = Uri} = Realm) ->
    User = #{
        username => <<"admin">>,
        password => <<"juno">>
    },
    ok = juno_user:add(Uri, User),
    Opts = [],
    _ = [juno_user:add_source(Uri, <<"admin">>, CIDR, password, Opts) || 
            CIDR <- ?LOCAL_CIDRS],
    enable_security(Realm).


%% @private
select_first_available([H|T], I) ->
    case sets:is_element(H, I) of
        true -> H;
        false -> select_first_available(T, I)
    end.


%% @private
-spec do_lookup(uri()) -> realm() | not_found.
do_lookup(Uri) ->
    case plumtree_metadata:get(?PREFIX, Uri)  of
        #realm{} = Realm ->
            Realm;
        undefined ->
            not_found
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Returns the ls_maps_utils:spec() for validation the options
%% @end
%% -----------------------------------------------------------------------------
opts_spec() ->
    #{
        description => #{
            required => true,
            datatype => binary, 
            default => <<>>
        },
        authmethods => #{
            required => true,
            datatype => {any, ?WAMP_AUTH_METHODS},
            default => ?WAMP_AUTH_METHODS
        }
    }.
