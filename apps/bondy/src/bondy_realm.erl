%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2017. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%% An implementation of a WAMP realm. 
%% A Realm is a routing and administrative domain, optionally
%% protected by authentication and authorization. Bondy messages are
%% only routed within a Realm. 
%%
%% Realms are persisted to disk and replicated across the cluster using the 
%% plumtree_metadata subsystem.
%% @end
%% =============================================================================
-module(bondy_realm).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").

-define(DEFAULT_AUTH_METHOD, ?TICKET_AUTH).
-define(PREFIX, {global, realms}).
-define(LOCAL_CIDRS, [
    {{10,0,0,0}, 8},
    {{172,16,0,0}, 12},
    {{192,168,0,0}, 16}
]).


-record(realm, {
    uri                         ::  uri(),
    description                 ::  binary(),
    authmethods                 ::  [binary()], % a wamp property
    private_keys                ::  map(),
    public_keys                 ::  map()
}).
-type realm()  ::  #realm{}.


-export_type([realm/0]).
-export_type([uri/0]).

-export([auth_methods/1]).
-export([delete/1]).
-export([disable_security/1]).
-export([enable_security/1]).
-export([fetch/1]).
-export([get/1]).
-export([get/2]).
-export([is_security_enabled/1]).
-export([public_keys/1]).
-export([get_random_kid/1]).
-export([get_private_key/2]).
-export([get_public_key/2]).
-export([list/0]).
-export([lookup/1]).
-export([put/1]).
-export([put/2]).
-export([security_status/1]).
-export([select_auth_method/2]).
-export([uri/1]).


-compile({no_auto_import, [put/2]}).



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
is_security_enabled(R) ->
    security_status(R) =:= enabled.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec security_status(realm()) -> enabled | disabled.
security_status(#realm{uri = Uri}) ->
    bondy_security:status(Uri).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec enable_security(realm()) -> ok.
enable_security(#realm{uri = Uri}) ->
    bondy_security:enable(Uri).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec disable_security(realm()) -> ok.
disable_security(#realm{uri = Uri}) ->
    bondy_security:disable(Uri).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec public_keys(realm()) -> [map()].
public_keys(#realm{public_keys = Keys}) ->
    [jose_jwk:to_map(K) || K <- Keys].


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get_private_key(realm(), Kid :: integer()) -> map() | undefined.
get_private_key(#realm{private_keys = Keys}, Kid) ->
    case maps:get(Kid, Keys, undefined) of
        undefined -> undefined;
        Map -> jose_jwk:to_map(Map)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get_public_key(realm(), Kid :: integer()) -> map() | undefined.
get_public_key(#realm{public_keys = Keys}, Kid) ->
    case maps:get(Kid, Keys, undefined) of
        undefined -> undefined;
        Map -> jose_jwk:to_map(Map)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
get_random_kid(#realm{private_keys = Map}) ->
    Kids = maps:keys(Map),
	lists:nth(rand:uniform(length(Kids)), Kids).


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
%% does not exist it will create a new one for Uri.
%% @end
%% -----------------------------------------------------------------------------
-spec get(uri(), map()) -> realm().
get(Uri, Opts) ->
    case lookup(Uri) of
        #realm{} = Realm ->
            Realm;
        not_found ->
            ok = put(Uri, Opts)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec put(uri()) -> realm().
put(Uri) ->
    bondy_realm:put(Uri, #{}).

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec put(uri(), map()) -> realm().
put(Uri, Opts) ->
    wamp_uri:is_valid(Uri) orelse error({?WAMP_ERROR_INVALID_URI, Uri}),
    #{
        description := Desc, 
        authmethods := Method
    } = maps_utils:validate(Opts, opts_spec()),

    Keys = maps:from_list([
        begin
            Priv = jose_jwk:generate_key({namedCurve, secp256r1}),
            Kid = list_to_binary(integer_to_list(erlang:phash2(Priv))),
            Fields = #{
                <<"kid">> => Kid
            },
            {Kid, jose_jwk:merge(Priv, Fields)}
        end || _ <- lists:seq(1, 3)
    ]),
    
    Realm = #realm{
        uri = Uri,
        description = Desc,
        private_keys = Keys,
        public_keys = maps:map(fun(_, V) -> jose_jwk:to_public(V) end, Keys),
        authmethods = Method
    },

    case lookup(Uri) of
        not_found ->
            ok = plumtree_metadata:put(?PREFIX, Uri, Realm),
            init(Realm);
        _ ->
            ok = plumtree_metadata:put(?PREFIX, Uri, Realm),
            Realm
    end.
    



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec delete(uri()) -> ok.
delete(?BONDY_REALM_URI) ->
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
        password => <<"bondy">>
    },
    ok = bondy_security_user:add(Uri, User),
    Opts = [],
    _ = [
        bondy_security_user:add_source(Uri, <<"admin">>, CIDR, password, Opts) 
        || CIDR <- ?LOCAL_CIDRS
    ],
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
%% Returns the maps_utils:spec() for validation the options
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
