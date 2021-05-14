%% =============================================================================
%%  bondy_realm.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
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
-include("bondy_security.hrl").

%% We use persistent_term to cache the security status to avoid
%% accessing plum_db.
-define(GET_SECURITY_STATUS(Uri),
    try persistent_term:get({Uri, security_status}) of
        Status -> Status
    catch
        error:badarg ->
            Status = bondy_security:status(Uri),
            ok = persistent_term:put({Uri, security_status}, Status),
            Status
    end
).
-define(ENABLE_SECURITY(Uri),
    bondy_security:enable(Uri),
    persistent_term:put({Uri, security_status}, enabled)
).
-define(DISABLE_SECURITY(Uri),
    bondy_security:disable(Uri),
    persistent_term:put({Uri, security_status}, disabled)
).
-define(ERASE_SECURITY_STATUS(Uri),
    _ = persistent_term:erase({Uri, security_status}),
    ok
).


-define(DEFAULT_AUTH_METHOD, ?WAMP_TICKET_AUTH).
-define(PDB_PREFIX, {security, realms}).
-define(LOCAL_CIDRS, [
    %% single class A network 10.0.0.0 – 10.255.255.255
    {{10, 0, 0, 0}, 8},
    %% 16 contiguous class B networks 172.16.0.0 – 172.31.255.255
    {{172, 16, 0, 0}, 12},
    %% 256 contiguous class C networks 192.168.0.0 – 192.168.255.255
    {{192, 168, 0, 0}, 16}
]).


%% The maps_utils:validate/2 specification.
-define(REALM_SPEC, #{
    <<"uri">> => #{
        alias => uri,
        key => <<"uri">>,
        required => true,
        datatype => binary,
        validator => fun bondy_data_validators:realm_uri/1
    },
    <<"description">> => #{
        alias => description,
        key => <<"description">>,
        required => true,
        datatype => binary,
        default => <<>>
    },
    <<"authmethods">> => #{
        alias => authmethods,
        key => <<"authmethods">>,
        required => true,
        datatype => {list, {in, ?BONDY_AUTH_METHOD_NAMES}},
        default => ?BONDY_AUTH_METHOD_NAMES
    },
    <<"security_enabled">> => #{
        alias => security_enabled,
        key => <<"security_enabled">>,
        required => true,
        datatype => boolean,
        default => true
    },
    <<"users">> => #{
        alias => users,
        key => <<"users">>,
        required => true,
        default => [],
        datatype => {list, map}
    },
    <<"groups">> => #{
        alias => groups,
        key => <<"groups">>,
        required => true,
        default => [],
        datatype => {list, map}
    },
    <<"sources">> => #{
        alias => sources,
        key => <<"sources">>,
        required => true,
        default => [],
        datatype => {list, map}
    },
    <<"grants">> => #{
        alias => grants,
        key => <<"grants">>,
        required => true,
        default => [],
        datatype => {list, map}
    },
    <<"private_keys">> => #{
        alias => private_keys,
        key => <<"private_keys">>,
        required => true,
        allow_undefined => false,
        allow_null => false,
        default => fun gen_private_keys/0,
        validator => fun validate_private_keys/1
    }
}).


%% The overriden maps_utils:validate/2 specification
%% to make private_keys not required on update
-define(UPDATE_REALM_SPEC, ?REALM_SPEC#{
    <<"private_keys">> => #{
        alias => private_keys,
        key => <<"private_keys">>,
        required => false,
        allow_undefined => false,
        allow_null => false,
        validator => fun validate_private_keys/1
    }
}).


%% The default configuration for the admin realm
-define(BONDY_REALM, #{
    uri => ?BONDY_REALM_URI,
    description => <<"The Bondy administrative realm">>,
    authmethods => [
        ?WAMP_SCRAM_AUTH, ?WAMP_CRA_AUTH, ?PASSWORD_AUTH,
        ?WAMP_ANON_AUTH
    ],
    security_enabled => true, % but we allow anonymous access
    grants => [
        #{
            permissions => [
                <<"wamp.register">>,
                <<"wamp.unregister">>,
                <<"wamp.subscribe">>,
                <<"wamp.unsubscribe">>,
                <<"wamp.call">>,
                <<"wamp.cancel">>,
                <<"wamp.publish">>
            ],
            uri => <<"any">>,
            roles => <<"all">>
        },
        #{
            permissions => [
                <<"wamp.register">>,
                <<"wamp.unregister">>,
                <<"wamp.subscribe">>,
                <<"wamp.unsubscribe">>,
                <<"wamp.call">>,
                <<"wamp.cancel">>,
                <<"wamp.publish">>
            ],
            uri => <<"any">>,
            roles => [<<"anonymous">>],
            meta => #{
                description => <<"Allows anonymous users to do all WAMP operations. This is too liberal and should be restricted.">>
            }
        }
    ],
    sources => [
        #{
            usernames => <<"all">>,
            authmethod => ?PASSWORD_AUTH,
            cidr => <<"0.0.0.0/0">>,
            meta => #{
                description => <<"Allows all users from any network authenticate using password credentials. This should ideally be restricted to your local administrative or DMZ network.">>
            }
        },
        #{
            usernames => [<<"anonymous">>],
            authmethod => ?WAMP_ANON_AUTH,
            cidr => <<"0.0.0.0/0">>,
            meta => #{
                description => <<"Allows all users from any network authenticate as anonymous. This should ideally be restricted to your local administrative or DMZ network.">>
            }
        }
    ]
}).


-record(realm, {
    uri                             ::  uri(),
    description                     ::  binary(),
    authmethods                     ::  [binary()], % a wamp property
    private_keys = #{}              ::  map(),
    public_keys = #{}               ::  map(),
    password_opts                   ::  bondy_password:opts() | undefined
}).

-type t()                           ::  #realm{}.
-type external()                    ::  #{
                                            uri := uri(),
                                            description :=  binary(),
                                            authmethods :=  [binary()],
                                            public_keys :=  [term()],
                                            security_status :=  enabled
                                                                | disabled
                                        }.

-export_type([t/0]).
-export_type([uri/0]).
-export_type([external/0]).

-export([add/1]).
-export([add/2]).
-export([apply_config/0]).
-export([authmethods/1]).
-export([delete/1]).
-export([disable_security/1]).
-export([enable_security/1]).
-export([fetch/1]).
-export([get/1]).
-export([get/2]).
-export([get_private_key/2]).
-export([get_public_key/2]).
-export([get_random_kid/1]).
-export([is_authmethod/2]).
-export([is_security_enabled/1]).
-export([list/0]).
-export([lookup/1]).
-export([public_keys/1]).
-export([security_status/1]).
-export([to_external/1]).
-export([update/2]).
-export([uri/1]).
-export([exists/1]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Loads a security config file from
%% `bondy_config:get([security, config_file])` if defined and applies its
%% definitions.
%% @end
%% -----------------------------------------------------------------------------
-spec apply_config() -> ok | no_return().

apply_config() ->
    case bondy_config:get([security, config_file], undefined) of
        undefined ->
            ok;
        FName ->
            case bondy_utils:json_consult(FName) of
                {ok, Realms} ->
                    _ = lager:info(
                        "Loading configuration file; path=~p",
                        [FName]
                    ),
                    _ = [
                        begin
                            Valid = maps_utils:validate(
                                Data, ?UPDATE_REALM_SPEC
                            ),
                            %% We add the realm and allow an update if it
                            %% already exists by setting IsStrict argument
                            %% to false
                            maybe_add(Valid, false)
                        end || Data <- Realms
                    ],
                    ok;
                {error, enoent} ->
                    _ = lager:warning(
                        "No configuration file found; path=~p",
                        [FName]
                    ),
                    ok;
                {error, {badarg, Reason}} ->
                    error({invalid_config, Reason});
                {error, Reason} ->
                    error(Reason)
            end
    end.



%% -----------------------------------------------------------------------------
%% @doc Returns the list of supported authentication methods for Realm.
%% @end
%% -----------------------------------------------------------------------------
-spec authmethods(Realm :: t() | uri()) -> [binary()].

authmethods(Uri) when is_binary(Uri) ->
    authmethods(fetch(Uri));

authmethods(#realm{authmethods = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc Returs `true' if Method is an authentication method supported by realm
%% `Realm'. Otherwise returns `false'.
%% @end
%% -----------------------------------------------------------------------------
-spec is_authmethod(Realm :: t(), Method :: binary()) -> boolean().

is_authmethod(#realm{authmethods = L}, Method) ->
    lists:member(Method, L).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_security_enabled(t() | uri()) -> boolean().

is_security_enabled(R) ->
    security_status(R) =:= enabled.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec security_status(t() | uri()) -> enabled | disabled.

security_status(#realm{uri = Uri}) ->
    security_status(Uri);

security_status(Uri) when is_binary(Uri) ->
    ?GET_SECURITY_STATUS(Uri).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec enable_security(t()) -> ok.

enable_security(#realm{uri = Uri}) ->
    ?ENABLE_SECURITY(Uri).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec disable_security(t()) -> ok | {error, forbidden}.

disable_security(#realm{uri = ?BONDY_REALM_URI}) ->
    {error, forbidden};

disable_security(#realm{uri = Uri}) ->
    ?DISABLE_SECURITY(Uri).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec public_keys(t()) -> [map()].

public_keys(#realm{public_keys = Keys}) ->
    [jose_jwk:to_map(K) || {_, K} <- maps:to_list(Keys)].


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get_private_key(t(), Kid :: integer()) -> map() | undefined.

get_private_key(#realm{private_keys = Keys}, Kid) ->
    case maps:get(Kid, Keys, undefined) of
        undefined -> undefined;
        Map -> jose_jwk:to_map(Map)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get_public_key(t(), Kid :: integer()) -> map() | undefined.

get_public_key(#realm{public_keys = Keys}, Kid) ->
    case maps:get(Kid, Keys, undefined) of
        undefined -> undefined;
        Map -> jose_jwk:to_map(Map)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
get_random_kid(#realm{private_keys = Keys}) ->
    Kids = maps:keys(Keys),
    lists:nth(rand:uniform(length(Kids)), Kids).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec uri(t()) -> uri().

uri(#realm{uri = Uri}) ->
    Uri.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec exists(uri()) -> boolean().

exists(Uri) ->
    do_lookup(Uri) =/= {error, not_found}.


%% -----------------------------------------------------------------------------
%% @doc
%% Retrieves the realm identified by Uri from the tuplespace or '{error, not_found}'
%% if it doesn't exist.
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(uri()) -> t() | {error, not_found}.

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
-spec fetch(uri()) -> t().

fetch(Uri) ->
    case lookup(Uri) of
        #realm{} = Realm ->
            Realm;
        {error, not_found} ->
            error({not_found, Uri})
    end.


%% -----------------------------------------------------------------------------
%% @doc Retrieves the realm identified by Uri from the tuplespace. If the realm
%% does not exist and automatic creation of realms is enabled, it will add a
%% new one for Uri with the default configuration options.
%% @end
%% -----------------------------------------------------------------------------
-spec get(uri()) ->  t() | {error, not_found}.

get(Uri) ->
    get(Uri, #{}).


%% -----------------------------------------------------------------------------
%% @doc
%% Retrieves the realm identified by Uri from the tuplespace. If the realm
%% does not exist and automatic creation of realms is enabled, it will create a
%% new one for Uri with configuration options `Opts'.
%% @end
%% -----------------------------------------------------------------------------
-spec get(uri(), map()) ->  t() | {error, not_found}.

get(Uri, Opts) ->
    case lookup(Uri) of
        #realm{} = Realm ->
            Realm;
        {error, not_found} when Uri == ?BONDY_REALM_URI ->
            %% We always create the Bondy admin realm if not found
            add(?BONDY_REALM, false);
        {error, not_found} ->
            case bondy_config:get([security, automatically_create_realms]) of
                true ->
                    add(Opts#{<<"uri">> => Uri}, false);
                false ->
                    error(auto_create_realms_disabled)
            end
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add(uri() | map()) -> t() | no_return().

add(Uri) when is_binary(Uri) ->
    add(#{<<"uri">> => Uri});

add(Map) ->
    add(Map, true, ?REALM_SPEC).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add(map(), boolean()) -> t() | no_return().

add(Map, IsStrict) ->
    add(Map, IsStrict, ?REALM_SPEC).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update(uri(), map()) -> t() | no_return().

update(_Uri, Map) ->
    add(Map, false, ?UPDATE_REALM_SPEC).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec delete(uri()) -> ok | {error, forbidden | active_users}.

delete(?BONDY_REALM_URI) ->
    {error, forbidden};

delete(?BONDY_PRIV_REALM_URI) ->
    {error, forbidden};

delete(Uri) ->
    %% If there are users in the realm, the caller will need to first
    %% explicitely delete the users first
    case bondy_rbac_user:list(Uri, #{limit => 1}) of
        [] ->
            ok = ?ERASE_SECURITY_STATUS(Uri),
            plum_db:delete(?PDB_PREFIX, Uri),
            ok = bondy_event_manager:notify({realm_deleted, Uri}),
            %% TODO we need to close all sessions for this realm
            ok;
        L when length(L) > 0 ->
            {error, active_users}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec list() -> [t()].

list() ->
    [V || {_K, [V]} <- plum_db:to_list(?PDB_PREFIX), V =/= '$deleted'].




%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
to_external(#realm{} = R) ->
    #{
        uri => R#realm.uri,
        description => R#realm.description,
        authmethods => R#realm.authmethods,
        security_enabled => security_status(R),
        public_keys => [
            begin {_, Map} = jose_jwk:to_map(K), Map end
            || {_, K} <- maps:to_list(R#realm.public_keys)
        ]
    }.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
maybe_enable_security(_, #realm{uri = ?BONDY_REALM_URI} = Realm) ->
    enable_security(Realm);

maybe_enable_security(undefined, Realm) ->
    enable_security(Realm);

maybe_enable_security(true, Realm) ->
    enable_security(Realm);

maybe_enable_security(false, Realm) ->
    disable_security(Realm).


%% @private
validate_rbac_config(Realm, Map) ->
    Groups = [
        bondy_rbac_group:new(Data)
        || Data <- maps:get(<<"groups">>, Map)
    ],
    Users = [
        bondy_rbac_user:new(Data, #{password_opts => password_opts(Realm)})
        || Data <- maps:get(<<"users">>, Map)
    ],
    SourceAssignments = [
        bondy_rbac_source:new_assignment(Data)
        || Data <- maps:get(<<"sources">>, Map)
    ],
    Grants = [
        bondy_rbac_policy:new(Data)
        || Data <- maps:get(<<"grants">>, Map)
    ],
    #{
        groups => Groups,
        users => Users,
        sources => SourceAssignments,
        grants => Grants
    }.


%% @private
password_opts(#realm{password_opts = undefined}) ->
    #{};

password_opts(#realm{password_opts = Opts}) ->
    Opts.


%% @private
get_password_opts([]) ->
    undefined;

get_password_opts(Methods) when is_list(Methods) ->
    %% We do this to overide the config default protocol
    case lists:member(?WAMP_SCRAM_AUTH, Methods) of
        true -> bondy_password:default_opts(scram);
        false -> bondy_password:default_opts()
    end.





%% @private
apply_rbac_config(Uri, Map) ->
    #{
        groups := Groups,
        users := Users,
        sources := SourcesAssignments,
        grants := Grants
    } = Map,

    _ = [
            ok = maybe_error(bondy_rbac_group:add_or_update(Uri, Group))
        || Group <- Groups
    ],

    _ = [
        ok = maybe_error(bondy_rbac_user:add_or_update(Uri, User))
        || User <- Users
    ],

    _ = [
        ok = maybe_error(bondy_rbac_source:add(Uri, Assignment))
        || Assignment <- SourcesAssignments
    ],

    _ = [
        ok = maybe_error(bondy_rbac_policy:grant(Uri, Grant))
        || Grant <- Grants
    ],

    ok.


%% @private
maybe_error({error, Reason}) ->
    error(Reason);

maybe_error({ok, _}) ->
    ok;

maybe_error(ok) ->
    ok.


%% @private
add(Map0, IsStrict, Spec) ->
    #{<<"uri">> := Uri} = Map1 = maps_utils:validate(Map0, Spec),
    wamp_uri:is_valid(Uri) orelse error({?WAMP_INVALID_URI, Uri}),
    maybe_add(Map1, IsStrict).


%% @private
maybe_add(#{<<"uri">> := Uri} = Map, IsStrict) ->
    case lookup(Uri) of
        #realm{} when IsStrict ->
            error({already_exists, Uri});
        #realm{} = Realm ->
            do_update(Realm, Map);
        {error, not_found} ->
            do_add(Map)
    end.


%% @private
do_add(#{<<"uri">> := Uri} = Map) ->
    Realm0 = #realm{uri = Uri},
    Realm1 = add_or_update(Realm0, Map),

    ok = bondy_event_manager:notify({realm_added, Realm1#realm.uri}),

    Data = #{
        <<"username">> => <<"admin">>,
        <<"password">> => <<"bondy-admin">>
    },
    User = bondy_rbac_user:new(Data),
    {ok, _} = bondy_rbac_user:add(Uri, User),

    % Opts = [],
    % _ = [
    %     bondy_rbac_user:add_source(Uri, <<"admin">>, CIDR, password, Opts)
    %     || CIDR <- ?LOCAL_CIDRS
    % ],
    %TODO remove this once we have the APIs to add sources
    Source = bondy_rbac_source:new(#{
        cidr => {{0, 0, 0, 0}, 0},
        authmethod => ?PASSWORD_AUTH
    }),
    _ = bondy_rbac_source:add(Uri, all, Source),

    Realm1.



%% @private
do_update(Realm, Map) ->
    NewRealm = add_or_update(Realm, Map),
    ok = bondy_event_manager:notify({realm_updated, NewRealm#realm.uri}),
    NewRealm.


%% @private
add_or_update(Realm0, Map) ->
    #{
        <<"description">> := Desc,
        <<"authmethods">> := Methods,
        <<"security_enabled">> := SecurityEnabled
    } = Map,

    KeyList = maps:get(<<"private_keys">>, Map, undefined),

    Realm1 = Realm0#realm{
        description = Desc,
        authmethods = Methods,
        %% TODO derive password options based on authmethods
        password_opts = get_password_opts(Methods)
    },

    %% We are going to call new on the respective modules so that we validate
    %% the data. This way we avoid adding anything to the database until all
    %% elements have been validated.
    RBACData = validate_rbac_config(Realm1, Map),

    NewRealm = set_keys(Realm1, KeyList),

    Uri = NewRealm#realm.uri,
    ok = plum_db:put(?PDB_PREFIX, Uri, NewRealm),
    ok = maybe_enable_security(SecurityEnabled, NewRealm),
    ok = apply_rbac_config(Uri, RBACData),

    NewRealm.


%% @private
set_keys(Realm, undefined) ->
    Realm;

set_keys(#realm{private_keys = Keys} = Realm, KeyList) ->
    PrivateKeys = maps:from_list([
        begin
            Kid = list_to_binary(integer_to_list(erlang:phash2(Priv))),
            case maps:get(Kid, Keys, undefined) of
                undefined ->
                    Fields = #{<<"kid">> => Kid},
                    {Kid, jose_jwk:merge(Priv, Fields)};
                Existing ->
                    {Kid, Existing}
            end
        end || Priv <- KeyList
    ]),
    PublicKeys = maps:map(fun(_, V) -> jose_jwk:to_public(V) end, PrivateKeys),
    Realm#realm{
        private_keys = PrivateKeys,
        public_keys = PublicKeys
    }.


%% @private
-spec do_lookup(uri()) -> t() | {error, not_found}.

do_lookup(Uri) ->
    case plum_db:get(?PDB_PREFIX, Uri) of
        #realm{} = Realm ->
            Realm;
        undefined ->
            {error, not_found}
    end.


%% private
validate_private_keys([]) ->
    {ok, gen_private_keys()};

validate_private_keys(Pems) when length(Pems) < 3 ->
    false;

validate_private_keys(Pems) ->
    try
        Keys = lists:map(
            fun
                ({jose_jwk, _, _, _} = Key) ->
                    Key;
                (Pem) ->
                    case jose_jwk:from_pem(Pem) of
                        {jose_jwk, _, _, _} = Key -> Key;
                        _ -> false
                    end
            end,
            Pems
        ),
        {ok, Keys}
    catch
        ?EXCEPTION(_, _, _) ->
            false
    end.


%% @private
gen_private_keys() ->
    [
        jose_jwk:generate_key({namedCurve, secp256r1})
        || _ <- lists:seq(1, 3)
    ].
