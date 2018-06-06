%% =============================================================================
%%  bondy_realm.erl -
%%
%%  Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% An implementation of a WAMP realm.
%% A Realm is a routing and administrative domain, optionally
%% protected by authentication and authorization. Bondy messages are
%% only routed within a Realm.
%%
%% Realms are persisted to disk and replicated across the cluster using the
%% plum_db subsystem.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_realm).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").

-define(SPEC, #{
    description => #{
        alias => <<"description">>,
        key => description,
        required => true,
        datatype => binary,
        default => <<>>
    },
    authmethods => #{
        alias => <<"authmethods">>,
        key => authmethods,
        required => true,
        datatype => {list, {in, ?WAMP_AUTH_METHODS}},
        default => ?WAMP_AUTH_METHODS
    }
}).

-define(DEFAULT_AUTH_METHOD, ?TICKET_AUTH).
-define(PREFIX, {global, realms}).
-define(LOCAL_CIDRS, [
    {{10, 0, 0, 0}, 8},
    {{172, 16, 0, 0}, 12},
    {{192, 168, 0, 0}, 16}
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
-export([security_status/1]).
-export([public_keys/1]).
-export([get_random_kid/1]).
-export([get_private_key/2]).
-export([get_public_key/2]).
-export([list/0]).
-export([lookup/1]).
-export([add/1]).
-export([add/2]).
-export([select_auth_method/2]).
-export([uri/1]).
-export([to_map/1]).


%% -compile({no_auto_import, [put/2]}).



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
%% Retrieves the realm identified by Uri from the tuplespace or '{error, not_found}'
%% if it doesn't exist.
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(uri()) -> realm() | {error, not_found}.

lookup(Uri) ->
    case do_lookup(Uri)  of
        #realm{} = Realm ->
            Realm;
        Error ->
            Error
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
        #realm{} = Realm ->
            Realm;
        {error, not_found} ->
            error({not_found, Uri})
    end.

%% -----------------------------------------------------------------------------
%% @doc
%% Retrieves the realm identified by Uri from the tuplespace. If the realm
%% does not exist it will add a new one for Uri.
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
        {error, not_found} ->
            add(Uri, Opts)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add(uri()) -> realm().

add(Uri) when is_binary(Uri) ->
    add(Uri, #{});

add(#{uri := Uri} = Map) ->
    add(Uri, Map);

add(#{<<"uri">> := Uri} = Map) ->
    add(Uri, Map).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add(uri(), map()) -> realm() | no_return().

add(Uri, Opts) ->
    wamp_uri:is_valid(Uri) orelse error({?WAMP_INVALID_URI, Uri}),
    #{
        description := Desc,
        authmethods := Method
    } = maps_utils:validate(Opts, ?SPEC),

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
        {error, not_found} ->
            ok = plum_db:put(?PREFIX, Uri, Realm),
            init(Realm);
        _ ->
            error({already_exist, Uri})
    end.




%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec delete(uri()) -> ok | {error, not_permitted}.

delete(?BONDY_REALM_URI) ->
    {error, not_permitted};

delete(Uri) ->
    %% TODO if there are users in the realm, the caller will need to first explicitely delete hthe users so return {error, users_exist} or similar
    plum_db:delete(?PREFIX, Uri),
    % TODO we need to close all sessions for this realm
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec list() -> [realm()].
list() ->
    [V || {_K, [V]} <- plum_db:to_list(?PREFIX), V =/= '$deleted'].


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


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
to_map(#realm{} = R) ->
    #{
        <<"uri">> => R#realm.uri,
        %% public_keys => R#realm.public_keys.
        <<"description">> => R#realm.description,
        <<"authmethods">> => R#realm.authmethods
    }.





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
    % Opts = [],
    % _ = [
    %     bondy_security_user:add_source(Uri, <<"admin">>, CIDR, password, Opts)
    %     || CIDR <- ?LOCAL_CIDRS
    % ],
    %TODO remove this once we have the APIs to add sources
    _ = bondy_security:add_source(Uri, all, {{0, 0, 0, 0}, 0}, password, []),
    ok = enable_security(Realm),
    Realm.


%% @private
select_first_available([H|T], I) ->
    case sets:is_element(H, I) of
        true -> H;
        false -> select_first_available(T, I)
    end.


%% @private
-spec do_lookup(uri()) -> realm() | {error, not_found}.
do_lookup(Uri) ->
    case plum_db:get(?PREFIX, Uri)  of
        #realm{} = Realm ->
            Realm;
        undefined ->
            {error, not_found}
    end.

