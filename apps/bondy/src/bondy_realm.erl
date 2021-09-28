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
%% @doc Realms are routing and administrative domains and act as namespaces for
%% all resources in Bondy i.e. all users, groups, permissions, registrations
%% and subscriptions belong to a Realm. Messages and events are routed
%% separately for each individual realm so sessions attached to a realm won’t
%% see message and events occurring on another realm.
%%
%% The realm is a central and fundamental concept in Bondy. It does not only
%% serve as an authentication and authorization domain but also as a message
%% routing domain. Bondy ensures no messages routed in one realm will leak into
%% another realm.
%%
%% A realm's security may be checked, enabled, or disabled by an administrator
%% through the WAMP and HTTP APIs. This allows an administrator to change
%% security settings of a realm on the whole cluster quickly without needing to
%% change settings on a node-by-node basis.
%%
%% If you disable security, this means that you have disabled all of the
%% various authentication and authorization checks that take place when
%% establishing a session and executing operations against a Bondy Realm.
%% Users, groups, and other security resources remain available for
%% configuration while security is disabled, and will be applied if and when
%% security is re-enabled.
%%
%% A realm security is enabled by default.
%%
%% ## Storage
%%
%% Realms (and the associated users, credentials, groups, sources and
%% permissions) are persisted to disk and replicated across the cluster using
%% the `plum_db' subsystem.
%%
%% ## Bondy Master Realm
%% When you start Bondy for the first time it creates and stores the Bondy
%% Master realm a.k.a `com.leapsight.bondy'. This realm is the root realm which
%% allows an admin user to create, list, modify and delete other realms.
%%
%% ## Realm Characteristics
%%
%%
%% ## Same Sign-on (SSO)
%% Bondy SSO (Same Sign-on) is a feature that allows users to access multiple
%% realms using just one set of credentials.
%%
%% It is enabled by setting the realm's `sso_realm_uri' property during realm
%% creation or during an update operation.
%%
%% - It requires the user to authenticate when opening a session in a realm.
%% - Changing credentials e.g. updating password can be performed while
%% connected to any realm
%%
%% ## Realm Prototypes
%% A **Prototype Realm** is a realm that acts as a prototype for the
%% construction of other realms. A prototype realm is a normal realm whose
%% property `is_prototype' has been set to true.
%%
%% Prototypical inheritance allows us to reuse the properties
%% (including RBAC definitions) from one realm to another through a
%% reference URI configured on the `prototype_uri' property.
%%
%% Prototypical inheritance is a form of single inheritance as realms are only
%% related to a single prototype.
%%
%% The `prototype_uri' property is defined as an *irreflexive property*
%% i.e. a realm cannot have itself as prototype. In addition
%% *a prototype cannot inherit from another prototype*. This means the
%% inheritance chain is bounded to one level.
%%
%% ### Inherited properties
%% The following is the list of properties which a realm would inherit from
%%
%%
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_realm).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_security.hrl").

%% -define(PDB_PREFIX, {security, realms}).
%% TODO This is a breaking change, we need to migrate the realms in
%% {security, realms} into their new {security, RealmUri}
-define(PDB_PREFIX(Uri), {bondy_realm, Uri}).

%% The maps_utils:validate/2 specification used when creating realms.
-define(REALM_VALIDATOR, #{
    %% The Realm URI. It needs to be a valid WAMP Realm. Unmutable once created.
    <<"uri">> => #{
        alias => uri,
        key => uri,
        required => true,
        datatype => binary,
        validator => fun bondy_data_validators:realm_uri/1
    },
    %% A textual description of the realm.
    <<"description">> => #{
        alias => description,
        key => description,
        required => true,
        datatype => binary,
        default => <<>>,
        validator => fun
            (X) when byte_size(X) =< 512 ->
                true;
            (_) ->
                {error, <<"Value is too big (max. is 512 bytes).">>}
        end
    },
    %% Determines whether the realm is a prototype. Protoype realms cannot be
    %% used by themselves. Once a realm has been designated as a prototype it
    %% cannot be changed.
    <<"is_prototype">> => #{
        alias => is_prototype,
        key => is_prototype,
        required => true,
        datatype => boolean,
        default => false
    },
    %% The URI of the prototype this realm inherits from.
    <<"prototype_uri">> => #{
        alias => prototype_uri,
        key => prototype_uri,
        required => true,
        datatype => binary,
        allow_undefined => true,
        default => undefined,
        validator => fun bondy_data_validators:realm_uri/1
    },
    %% Determines whether the realm allows clients to establish sessions.
    %% Prototype realms never allow connections.
    <<"allow_connections">> => #{
        alias => allow_connections,
        key => allow_connections,
        required => true,
        datatype => boolean,
        default => true
    },
    %% Determines if this realm is an SSO Realm. Once a realm has been
    %% designated as an SSO realm it cannot be changed.
    <<"is_sso_realm">> => #{
        alias => is_sso_realm,
        key => is_sso_realm,
        required => true,
        datatype => boolean,
        default => false
    },
    %% Determines if this realm has an SSO realm associated with it.
    %% Once a realm has been associated with an SSO realm it cannot be changed.
    %% TODO change sso_realm_uri to allowed_sso_realms
    <<"sso_realm_uri">> => #{
        alias => sso_realm_uri,
        key => sso_realm_uri,
        required => true,
        datatype => binary,
        allow_undefined => true,
        default => undefined,
        validator => fun bondy_data_validators:realm_uri/1
    },
    %% Determines the authentication methods available for clients connecting
    %% to this realm.
    <<"authmethods">> => #{
        alias => authmethods,
        key => authmethods,
        required => true,
        datatype => {list, {in, ?BONDY_AUTH_METHOD_NAMES}},
        default => [
            ?WAMP_ANON_AUTH,
            ?PASSWORD_AUTH,
            ?OAUTH2_AUTH,
            ?WAMP_CRA_AUTH,
            % ?WAMP_SCRAM_AUTH,
            ?WAMP_TICKET_AUTH
        ]
    },
    <<"security_enabled">> => #{
        alias => security_enabled,
        key => security_enabled,
        required => true,
        datatype => boolean,
        default => true
    },
    %% This is a way to atomically create users together with the realm
    %% creation. User can be added at any time using the bondy_rbac_user module.
    %% This feature is used by the security config file see apply_config/1
    <<"users">> => #{
        alias => users,
        key => users,
        required => true,
        default => [],
        datatype => {list, map}
    },
    %% This is a way to atomically create gropus together with the realm
    %% creation. User can be added at any time using the bondy_rbac_group
    %% module.
    %% This feature is used by the security config file see apply_config/1
    <<"groups">> => #{
        alias => groups,
        key => groups,
        required => true,
        default => [],
        datatype => {list, map}
    },
    %% This is a way to atomically create sources together with the realm
    %% creation. User can be added at any time using the bondy_rbac_source
    %% module.
    %% This feature is used by the security config file see apply_config/1
    <<"sources">> => #{
        alias => sources,
        key => sources,
        required => true,
        default => [],
        datatype => {list, map}
    },
    %% This is a way to atomically create grants together with the realm
    %% creation. User can be added at any time using the bondy_rbac module.
    %% This feature is used by the security config file see apply_config/1
    <<"grants">> => #{
        alias => grants,
        key => grants,
        required => true,
        default => [],
        datatype => {list, map}
    },
    %% A set of keys used for signing
    <<"private_keys">> => #{
        alias => private_keys,
        key => private_keys,
        required => true,
        default => fun gen_keys/0,
        validator => fun validate_keys/1
    },
    %% A set of keys used for encryption
    <<"encryption_keys">> => #{
        alias => encryption_keys,
        key => encryption_keys,
        required => true,
        default => fun gen_encryption_keys/0,
        validator => fun validate_encryption_keys/1
    }
}).

-define(MASTER_REALM_VALIDATOR,
    maps:without(
        [
            <<"allow_connections">>,
            <<"is_prototype">>,
            <<"prototype_uri">>,
            <<"is_sso_realm">>,
            <<"sso_realm_uri">>
        ], ?REALM_VALIDATOR
    )
).

%% The overriden maps_utils:validate/2 specification
%% to make certain keys not required or not available during updates
-define(REALM_UPDATE_VALIDATOR, #{
    <<"description">> => #{
        alias => description,
        key => description,
        required => false,
        datatype => binary
    },
    <<"is_prototype">> => #{
        alias => is_prototype,
        key => is_prototype,
        required => false,
        datatype => boolean
    },
    <<"prototype_uri">> => #{
        alias => prototype_uri,
        key => prototype_uri,
        required => false,
        datatype => binary,
        allow_undefined => true,
        validator => fun bondy_data_validators:realm_uri/1
    },
    <<"allow_connections">> => #{
        alias => allow_connections,
        key => allow_connections,
        required => false,
        datatype => boolean
    },
    <<"is_sso_realm">> => #{
        alias => is_sso_realm,
        key => is_sso_realm,
        required => false,
        datatype => boolean
    },
    %% TODO change sso_realm_uri to allowed_sso_realms
    <<"sso_realm_uri">> => #{
        alias => sso_realm_uri,
        key => sso_realm_uri,
        required => false,
        datatype => binary,
        allow_undefined => true,
        validator => fun bondy_data_validators:realm_uri/1
    },
    <<"authmethods">> => #{
        alias => authmethods,
        key => authmethods,
        required => false,
        datatype => {list, {in, ?BONDY_AUTH_METHOD_NAMES}}
    },
    <<"security_enabled">> => #{
        alias => security_enabled,
        key => security_enabled,
        required => false,
        datatype => boolean
    },
    <<"users">> => #{
        alias => users,
        key => users,
        required => false,
        datatype => {list, map}
    },
    <<"groups">> => #{
        alias => groups,
        key => groups,
        required => false,
        datatype => {list, map}
    },
    <<"sources">> => #{
        alias => sources,
        key => sources,
        required => false,
        datatype => {list, map}
    },
    <<"grants">> => #{
        alias => grants,
        key => grants,
        required => true,
        default => [],
        datatype => {list, map}
    },
    <<"private_keys">> => #{
        alias => private_keys,
        key => private_keys,
        required => false,
        validator => fun validate_keys/1
    },
    <<"encryption_keys">> => #{
        alias => encryption_keys,
        key => encryption_keys,
        required => false,
        validator => fun validate_encryption_keys/1
    }
}).

-define(MASTER_REALM_UPDATE_VALIDATOR,
    maps:without(
        [
            <<"allow_connections">>,
            <<"is_prototype">>,
            <<"prototype_uri">>,
            <<"is_sso_realm">>,
            <<"sso_realm_uri">>
        ], ?REALM_UPDATE_VALIDATOR
    )
).

%% The default configuration for the master realm
-define(MASTER_REALM, #{
    uri => ?MASTER_REALM_URI,
    description => <<"The Bondy Master realm">>,
    authmethods => [
        ?TRUST_AUTH,
        ?WAMP_CRYPTOSIGN_AUTH,
        % ?WAMP_SCRAM_AUTH,
        ?WAMP_CRA_AUTH,
        ?PASSWORD_AUTH,
        ?WAMP_ANON_AUTH
    ],
    is_prototype => false,
    prototype_uri => undefined,
    is_sso_realm => false,
    sso_realm_uri => undefined,
    allow_connections => true,
    security_enabled => true,
    users => [
        #{
            username => <<"admin">>,
            password => <<"bondy-admin">>,
            groups => [<<"bondy.administrators">>],
            meta => #{
                <<"description">> => <<"The default Bondy administrator user.">>
            }
        }
    ],
    groups => [
        #{
            name => <<"bondy.administrators">>,
            groups => [
            ],
            meta => #{
                <<"description">> => <<"The Bondy administrators group">>
            }
        }
    ],
    grants => [
        #{
            permissions => [
                <<"wamp.call">>,
                <<"wamp.cancel">>,
                <<"wamp.subscribe">>,
                <<"wamp.unsubscribe">>
            ],
            uri => <<"">>,
            match => <<"prefix">>,
            roles => [<<"bondy.administrators">>],
            meta => #{
                <<"description">> => <<
                    "Allows the administrators users to make RPC Calls to "
                    "the Bondy Admin APIs and subscribe to all Bondy events. "
                    "This is too liberal and should be restricted."
                >>
            }
        },
        #{
            permissions => [
                <<"wamp.call">>,
                <<"wamp.cancel">>,
                <<"wamp.subscribe">>,
                <<"wamp.unsubscribe">>
            ],
            uri => <<"">>,
            match => <<"prefix">>,
            roles => [<<"anonymous">>],
            meta => #{
                <<"description">> => <<
                    "Allows anonymous users to make RPC Calls to the "
                    "Bondy Admin APIs and subscribe to all Bondy events. "
                    "This is too liberal and should be restricted."
                >>
            }
        }
    ],
    sources => [
        #{
            usernames => <<"all">>,
            authmethod => ?PASSWORD_AUTH,
            cidr => <<"0.0.0.0/0">>,
            meta => #{
                <<"description">> => <<
                    "Allows all users from any network authenticate using "
                    "password credentials. This should ideally be restricted "
                    "to your local administrative or DMZ network."
                >>
            }
        },
        #{
            usernames => <<"all">>,
            authmethod => ?WAMP_CRA_AUTH,
            cidr => <<"0.0.0.0/0">>,
            meta => #{
                <<"description">> => <<
                    "Allows all users from any network authenticate using "
                    "password credentials. This should ideally be restricted "
                    "to your local administrative or DMZ network."
                >>
            }
        },
        % #{
        %     usernames => <<"all">>,
        %     authmethod => ?WAMP_SCRAM_AUTH,
        %     cidr => <<"0.0.0.0/0">>,
        %     meta => #{
        %         <<"description">> => <<"
        %             Allows all users from any network authenticate using "
        %             "password credentials. This should ideally be restricted "
        %             "to your local administrative or DMZ network."
        %         >>
        %     }
        % },
        #{
            usernames => [<<"admin">>],
            authmethod => ?TRUST_AUTH,
            cidr => <<"127.0.0.0/8">>,
            meta => #{
                <<"description">> => <<
                    "Allows the admin user to connect over the loopback "
                    "interface (i.e. localhost) by presenting just its username."
                >>
            }
        },
        #{
            usernames => [<<"anonymous">>, <<"admin">>],
            authmethod => ?WAMP_ANON_AUTH,
            cidr => <<"127.0.0.0/8">>,
            meta => #{
                <<"description">> => <<
                    "Allows the anonymous user to connect over the loopback "
                    "interface (i.e. localhost) only."
                >>
            }
        }
    ]
}).

-define(BONDY_PRIV_REALM, #realm{
    uri = ?INTERNAL_REALM_URI,
    description = <<"The private realm used by bondy">>,
    authmethods = [],
    security_enabled = true,
    is_sso_realm = false,
    allow_connections = true
}).


-record(realm, {
    uri                             ::  uri(),
    description                     ::  binary(),
    is_prototype = false            ::  boolean(),
    prototype_uri                   ::  maybe(uri()),
    is_sso_realm = false            ::  boolean(),
    %% TODO change sso_realm_uri to allowed_sso_realms
    sso_realm_uri                   ::  maybe(uri()),
    allow_connections = true        ::  boolean(),
    authmethods                     ::  [binary()], % a wamp property
    security_enabled = true         ::  boolean(),
    password_opts                   ::  maybe(bondy_password:opts()),
    private_keys = #{}              ::  keyset(),
    public_keys = #{}               ::  keyset(),
    encryption_keys = #{}           ::  keyset(),
    info = #{}                      ::  map()
}).

-type t()                           ::  #realm{}.
-type kid()                         ::  binary().
-type keyset()                      ::  #{kid() => map()}.
-type external()                    ::  #{
    uri                     :=  uri(),
    is_prototype            :=  boolean(),
    prototype_uri           :=  maybe(uri()),
    description             :=  binary(),
    authmethods             :=  [binary()],
    is_sso_realm            :=  boolean(),
    allow_connections       :=  boolean(),
    public_keys             :=  [term()],
    security_status         :=  enabled | disabled
}.

-export_type([t/0]).
-export_type([uri/0]).
-export_type([external/0]).


-export([add/1]).
-export([allow_connections/1]).
-export([apply_config/0]).
-export([apply_config/1]).
-export([authmethods/1]).
-export([delete/1]).
-export([disable_security/1]).
-export([enable_security/1]).
-export([encryption_keys/1]).
-export([exists/1]).
-export([fetch/1]).
-export([get/1]).
-export([get/2]).
-export([get_encryption_key/2]).
-export([get_private_key/2]).
-export([get_public_key/2]).
-export([get_random_encryption_kid/1]).
-export([get_random_kid/1]).
-export([is_allowed_authmethod/2]).
-export([is_allowed_sso_realm/2]).
-export([is_prototype/1]).
-export([is_security_enabled/1]).
-export([is_sso_realm/1]).
-export([list/0]).
-export([lookup/1]).
-export([password_opts/1]).
-export([private_keys/1]).
-export([prototype_uri/1]).
-export([public_keys/1]).
-export([security_status/1]).
-export([sso_realm_uri/1]).
-export([to_external/1]).
-export([update/2]).
-export([uri/1]).
-export([is_property_value_inherited/2]).

-export([grants/1]).
-export([grants/2]).
-export([groups/1]).
-export([groups/2]).
-export([sources/1]).
-export([sources/2]).
-export([users/1]).
-export([users/2]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Loads a security config file from
%% `bondy_config:get([security, config_file])' if defined and applies its
%% definitions.
%% @end
%% -----------------------------------------------------------------------------
-spec apply_config() -> ok | no_return().

apply_config() ->
    case bondy_config:get([security, config_file], undefined) of
        undefined ->
            ok;

        Filename ->
            apply_config(Filename)
    end.


%% -----------------------------------------------------------------------------
%% @doc Loads a security config file from `Filename'.
%% @end
%% -----------------------------------------------------------------------------
-spec apply_config(Filename :: file:filename_all()) -> ok | no_return().

apply_config(Filename) ->
    case bondy_utils:json_consult(Filename) of
        {ok, Realms} ->
            _ = lager:info(
                "Loading configuration file; path=~p",
                [Filename]
            ),

            %% Because realms can have the sso_realm_uri and prototype
            %% properties which point to other realms, we need to ensure all
            %% realms in the file are processed based on a precedence graph, so
            %% that SSO and prototype realms are created before the realms
            %% targeting them.
            SortedRealms = topsort(Realms),

            %% We add the realm and allow an update if it
            %% already exists by setting IsStrict argument
            %% to false
            _ = [add_or_update(Data) || Data <- SortedRealms],
            ok;

        {error, enoent} ->
            _ = lager:warning(
                "Error while parsing configuration file; path=~p, reason=~p",
                [Filename, file:format_error(enoent)]
            ),
            ok;

        {error, Reason} ->
            _ = lager:warning(
                "Error while parsing configuration file; path=~p, reason=~p",
                [Filename, Reason]
            ),
            error(invalid_config)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec uri(t()) -> uri().

uri(#realm{uri = Uri}) ->
    Uri.


%% -----------------------------------------------------------------------------
%% @doc Returns `true' if realm `Realm' is a prototype. Otherwise, returns
%% `false'.
%%
%% **Pre-conditions**
%% * The property `prototype_uri' MUST be `undefined'.
%% * This property cannot be set to `false' once it has been set to `true'.
%%
%% **Post-conditions**
%% * If this property is `true', the `prototype_uri' cannot be set.
%% @end
%% -----------------------------------------------------------------------------
-spec is_prototype(Realm :: t() | uri()) -> boolean().

is_prototype(#realm{is_prototype = Val}) ->
    Val;

is_prototype(Uri) when is_binary(Uri) ->
    is_prototype(fetch(Uri)).


%% -----------------------------------------------------------------------------
%% @doc Returns the uri of realm `Realm' prototype if defined. Otherwise
%% returns `undefined'.
%% @end
%% -----------------------------------------------------------------------------
-spec prototype_uri(Realm :: t() | uri()) -> maybe(uri()).

prototype_uri(#realm{prototype_uri = Val}) ->
    Val;

prototype_uri(Uri) when is_binary(Uri) ->
    prototype_uri(fetch(Uri)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_property_value_inherited(Realm :: t() | uri(), Property :: atom()) ->
    boolean() | no_return().

is_property_value_inherited(#realm{prototype_uri = undefined}, Property) ->
    lists:member(Property, record_info(fields, realm)) orelse error(badarg),
    false;

is_property_value_inherited(#realm{authmethods = Val}, authmethods) ->
    Val =/= [];

is_property_value_inherited(#realm{sso_realm_uri = Val}, sso_realm_uri) ->
    Val =/= undefined;

is_property_value_inherited(#realm{password_opts = Val}, password_opts) ->
    Val =/= undefined;

is_property_value_inherited(#realm{}, Property) ->
    lists:member(Property, record_info(fields, realm)) orelse error(badarg),
    false;

is_property_value_inherited(Uri, Property) when is_binary(Uri) ->
    is_property_value_inherited(fetch(Uri), Property).


%% -----------------------------------------------------------------------------
%% @doc Returns the same sign on (SSO) realm URI used by the realm.
%%
%% If a value is set, then all authentication and user creation will be done on
%% the the SSO Realm.
%%
%% Groups, permissions and sources are still managed by this realm
%% (or the prototype it inherits from).
%%
%% @end
%% -----------------------------------------------------------------------------
-spec sso_realm_uri(Realm :: t() | uri()) -> maybe(uri()).

sso_realm_uri(#realm{sso_realm_uri = Val}) ->
    Val;

sso_realm_uri(Uri) when is_binary(Uri) ->
    sso_realm_uri(fetch(Uri)).


%% -----------------------------------------------------------------------------
%% @doc Returns `true' if realm `Realm' is associated with the SSO Realm
%% identified by uri `SSORealmUri`. Otherwise returns `false'.
%% @end
%% -----------------------------------------------------------------------------
-spec is_allowed_sso_realm(Realm :: t() | uri(), SSORealmUri :: uri()) ->
    boolean().

is_allowed_sso_realm(#realm{sso_realm_uri = Val}, SSORealmUri) ->
    %% TODO change sso_realm_uri to allowed_sso_realms
    Val =:= SSORealmUri;

is_allowed_sso_realm(Uri, SSORealmUri) when is_binary(Uri) ->
    is_allowed_sso_realm(fetch(Uri), SSORealmUri).



%% -----------------------------------------------------------------------------
%% @doc Returns `true' if the Realm is a Same Sign-on (SSO) realm.
%% Otherwise returns `false'.
%% @end
%% -----------------------------------------------------------------------------
-spec is_sso_realm(Realm :: t() | uri()) -> boolean().

is_sso_realm(#realm{is_sso_realm = Val}) ->
    Val;

is_sso_realm(Uri) when is_binary(Uri) ->
    is_sso_realm(fetch(Uri)).


%% -----------------------------------------------------------------------------
%% @doc Returns `true' if the Realm is allowing connections. Otherwise returns
%% `false'.
%% This setting is used to either temporarilly restrict new connections to the
%% realm or to avoid connections when the realm is used as a Single Sign-on
%% Realm. When connections are not allowed the only way of managing the
%% resources in the realm is through ac connection to the Bondy admin realm.
%% @end
%% -----------------------------------------------------------------------------
-spec allow_connections(Realm :: t() | uri()) -> boolean().

allow_connections(#realm{is_prototype = true}) ->
    false;

allow_connections(#realm{allow_connections = Val}) ->
    Val;

allow_connections(Uri) when is_binary(Uri) ->
    allow_connections(fetch(Uri)).

%% -----------------------------------------------------------------------------
%% @doc Returns the list of supported authentication methods for Realm.
%% See {@link is_allowed_authmethod} for more information about how this
%% affects the methods available for an authenticating user.
%% @end
%% -----------------------------------------------------------------------------
-spec authmethods(Realm :: t() | uri()) -> [binary()].

authmethods(#realm{authmethods = Val}) ->
    Val;

authmethods(Uri) when is_binary(Uri) ->
    authmethods(fetch(Uri)).


%% -----------------------------------------------------------------------------
%% @doc Returs `true' if Method is an authentication method supported by realm
%% `Realm'. Otherwise returns `false'.
%%
%% The fact that method `Method' is included in the realm's `authmethods'
%% (See {3link authmethods/1}) is no guarantee that the method will be
%% available for a particular user.
%%
%% The availability is also affected by the source rules defined for the realm
%% and the capabilities of each user e.g. if the user has no password then
%% the password-based authentication methods in this list will not be available.
%% @end
%% -----------------------------------------------------------------------------
-spec is_allowed_authmethod(Realm :: t() | uri(), Method :: binary()) ->
    boolean().

is_allowed_authmethod(#realm{authmethods = L}, Method) ->
    lists:member(Method, L);

is_allowed_authmethod(Uri, Method) when is_binary(Uri) ->
    is_allowed_authmethod(fetch(Uri), Method).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_security_enabled(t() | uri()) -> boolean().

is_security_enabled(#realm{security_enabled = Val}) ->
    Val;

is_security_enabled(Uri) when is_binary(Uri) ->
    is_security_enabled(fetch(Uri)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec security_status(t() | uri()) -> enabled | disabled.

security_status(Term) ->
    case is_security_enabled(Term) of
        true -> enabled;
        false -> disabled
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec enable_security(t() | uri()) -> ok.

enable_security(#realm{} = Realm) ->
    _ = update(Realm, #{security_enabled => true}),
    ok;

enable_security(Uri) when is_binary(Uri) ->
    enable_security(fetch(Uri)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec disable_security(t() | uri()) -> ok | {error, badarg}.

disable_security(#realm{uri = ?MASTER_REALM_URI}) ->
    {error, badarg};

disable_security(#realm{uri = ?INTERNAL_REALM_URI}) ->
    {error, badarg};

disable_security(#realm{} = Realm) ->
    _ = update(Realm, #{security_enabled => false}),
    ok;

disable_security(Uri) when is_binary(Uri) ->
    disable_security(fetch(Uri)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec private_keys(t() | uri()) -> [map()].

private_keys(#realm{private_keys = Keys}) ->
    [jose_jwk:to_map(K) || {_, K} <- maps:to_list(Keys)];

private_keys(Uri) when is_binary(Uri) ->
    private_keys(fetch(Uri)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec public_keys(t() | uri()) -> [map()].

public_keys(#realm{public_keys = Keys}) ->
    [jose_jwk:to_map(K) || {_, K} <- maps:to_list(Keys)];

public_keys(Uri) when is_binary(Uri) ->
    public_keys(fetch(Uri)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get_private_key(t() | uri(), Kid :: binary()) -> map() | undefined.

get_private_key(#realm{private_keys = Keys}, Kid) ->
    case maps:get(Kid, Keys, undefined) of
        undefined -> undefined;
        Map -> jose_jwk:to_map(Map)
    end;

get_private_key(Uri, Kid) when is_binary(Uri) ->
    get_private_key(fetch(Uri), Kid).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get_public_key(t() | uri(), Kid :: binary()) -> map() | undefined.

get_public_key(#realm{public_keys = Keys}, Kid) ->
    case maps:get(Kid, Keys, undefined) of
        undefined -> undefined;
        Map -> jose_jwk:to_map(Map)
    end;

get_public_key(Uri, Kid) when is_binary(Uri) ->
    get_public_key(fetch(Uri), Kid).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get_random_kid(t() | uri()) -> binary().

get_random_kid(#realm{private_keys = Keys}) ->
    Kids = maps:keys(Keys),
    lists:nth(rand:uniform(length(Kids)), Kids);

get_random_kid(Uri) when is_binary(Uri) ->
    get_random_kid(fetch(Uri)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec encryption_keys(t() | uri()) -> [map()].

encryption_keys(#realm{encryption_keys = Keys} = Realm0)
when map_size(Keys) == 0 ->
    Data = #{encryption_keys => gen_encryption_keys()},
    Realm = merge_and_store(Realm0, Data),
    encryption_keys(Realm);

encryption_keys(#realm{encryption_keys = Keys}) ->
    [jose_jwk:to_map(K) || {_, K} <- maps:to_list(Keys)];

encryption_keys(Uri) when is_binary(Uri) ->
    encryption_keys(fetch(Uri)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get_encryption_key(t() | uri(), Kid :: binary()) -> map() | undefined.

get_encryption_key(#realm{encryption_keys = Keys}, Kid) ->
    case maps:get(Kid, Keys, undefined) of
        undefined -> undefined;
        Map -> jose_jwk:to_map(Map)
    end;

get_encryption_key(Uri, Kid) when is_binary(Uri) ->
    get_encryption_key(fetch(Uri), Kid).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get_random_encryption_kid(t() | uri()) ->  map().

get_random_encryption_kid(#realm{encryption_keys = Keys}) ->
    Kids = maps:keys(Keys),
    lists:nth(rand:uniform(length(Kids)), Kids);

get_random_encryption_kid(Uri) when is_binary(Uri) ->
    get_random_encryption_kid(fetch(Uri)).



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

fetch(?INTERNAL_REALM_URI) ->
    ?BONDY_PRIV_REALM;

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
        {error, not_found} when Uri == ?MASTER_REALM_URI ->
            add_master_realm();
        {error, not_found} ->
            maybe_add(Uri, Opts)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add(uri() | map()) -> t() | no_return().

add(?INTERNAL_REALM_URI) ->
    error(badarg);

add(?MASTER_REALM_URI) ->
    error(badarg);

add(Uri) when is_binary(Uri) ->
    add(#{uri => Uri});

add(Map0) ->
    #{uri := Uri} = Map1 = validate(Map0, ?REALM_VALIDATOR),

    case exists(Uri) of
        true ->
            error({already_exists, Uri});
        false ->
            do_add(Map1)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update(Realm :: t() | uri(), Data :: map()) -> Realm :: t() | no_return().

update(#realm{uri = ?INTERNAL_REALM_URI}, _) ->
    error(badarg);

update(#realm{uri = ?MASTER_REALM_URI} = Realm, Data0) ->
    Data = maps_utils:validate(Data0, ?MASTER_REALM_UPDATE_VALIDATOR),
    do_update(Realm, Data);

update(#realm{} = Realm, Data0) ->
    Data = validate(Data0, ?REALM_UPDATE_VALIDATOR),
    do_update(Realm, Data);

update(?INTERNAL_REALM_URI, _) ->
    error(badarg);

update(Uri, Data) when is_binary(Uri) ->
    do_update(fetch(Uri), Data).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec delete(t() | uri()) -> ok | {error, not_found | badarg | active_users}.

delete(?INTERNAL_REALM_URI) ->
    {error, badarg};

delete(?MASTER_REALM_URI) ->
    {error, badarg};

delete(Uri) when is_binary(Uri) ->
    case lookup(Uri) of
        #realm{} = Realm ->
            delete(Realm);
        {error, not_found} = Error ->
            Error
    end;

delete(#realm{uri = Uri})  ->
    %% TODO change this
    %% 1. disallow new connections to this realm
    %% ok = plum_db:put(?PDB_PREFIX(Uri), Uri, Realm#realm{allow_connections = false}),
    %% 2. Close all existing sessions (in all nodes)
    %% with wamp.close.close_realm URI reason
    %% 3. delete all grants
    %% 4. delete all sources
    %% 5. delete all groups
    %% 6. delete all users
    %% 7. delete realm

    %% If there are users in the realm, the caller will need to first
    %% explicitely delete the users
    case bondy_rbac_user:list(Uri, #{limit => 1}) of
        [] ->
            plum_db:delete(?PDB_PREFIX(Uri), Uri),
            ok = on_delete(Uri),
            %% TODO we need to close all sessions for this realm
            %% and send error wamp.close.close_realm
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
    Opts = [{remove_tombstones, true}, {resolver, lww}],
    [V || {_K, V} <- plum_db:match(?PDB_PREFIX('_'), '_', Opts)].


%% -----------------------------------------------------------------------------
%% @doc Returns theas password options to be used as default when adding users
%% to this realm. If the options have not been defined returns atom `undefined'.
%% @end
%% -----------------------------------------------------------------------------
-spec password_opts(t() | uri()) -> maybe(bondy_password:opts()).

password_opts(#realm{password_opts = Opts}) ->
    Opts;

password_opts(RealmUri) ->
    password_opts(fetch(RealmUri)).


%% -----------------------------------------------------------------------------
%% @doc Returns the external map representation of the realm.
%% @end
%% -----------------------------------------------------------------------------
-spec to_external(t() | uri()) -> external().

to_external(#realm{} = R) ->
    #{
        uri => R#realm.uri,
        description => R#realm.description,
        is_prototype => R#realm.is_prototype,
        prototype_uri => R#realm.prototype_uri,
        is_sso_realm => R#realm.is_sso_realm,
        sso_realm_uri => R#realm.sso_realm_uri,
        allow_connections => R#realm.allow_connections,
        authmethods => R#realm.authmethods,
        security_status => security_status(R),
        public_keys => [
            begin {_, Map} = jose_jwk:to_map(K), Map end
            || {_, K} <- maps:to_list(R#realm.public_keys)
        ]
    };

to_external(RealmUri) ->
    to_external(fetch(RealmUri)).


%% =============================================================================
%% AUTHZ
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Returns the list of users belonging to realm `Realm'.
%% Users are never inherited through prototypes.
%% @end
%% -----------------------------------------------------------------------------
-spec users(Realm :: t() | uri()) -> list(bondy_rbac_user:t()).

users(Realm) ->
    users(Realm, #{}).


%% -----------------------------------------------------------------------------
%% @doc Returns the list of users belonging to realm `Realm'.
%% Users are never inherited through prototypes.
%% @end
%% -----------------------------------------------------------------------------
-spec users(Realm :: t() | uri(), Opts :: map()) -> list(bondy_rbac_user:t()).

users(#realm{uri = Uri}, Opts) ->
    %% TODO change this with continuation return
    bondy_rbac_user:list(Uri, Opts);

users(Uri, Opts) when is_binary(Uri) ->
    users(fetch(Uri), Opts).


%% -----------------------------------------------------------------------------
%% @doc Returns the list of users belonging to realm `Realm'.
%% These includes the groups inherited from the prototype (if defined).
%% @end
%% -----------------------------------------------------------------------------
-spec groups(Realm :: t() | uri()) -> list(bondy_rbac_user:t()).

groups(Realm) ->
    groups(Realm, #{}).


%% -----------------------------------------------------------------------------
%% @doc Returns the list of groups belonging to realm `Realm'.
%% These includes the groups inherited from the prototype (if defined).
%% @end
%% -----------------------------------------------------------------------------
-spec groups(Realm :: t() | uri(), Opts :: map()) -> list(bondy_rbac_user:t()).

groups(#realm{uri = Uri}, Opts) ->
    %% TODO change this with continuation return
    bondy_rbac_group:list(Uri, Opts);

groups(Uri, Opts) when is_binary(Uri) ->
    groups(fetch(Uri), Opts).


%% -----------------------------------------------------------------------------
%% @doc Returns the list of sources belonging to realm `Realm'.
%% These includes the sources inherited from the prototype (if defined).
%% @end
%% -----------------------------------------------------------------------------
-spec sources(Realm :: t() | uri()) -> list(bondy_rbac_user:t()).

sources(Realm) ->
    sources(Realm, #{}).


%% -----------------------------------------------------------------------------
%% @doc Returns the list of sources belonging to realm `Realm'.
%% These includes the sources inherited from the prototype (if defined).
%% @end
%% -----------------------------------------------------------------------------
-spec sources(Realm :: t() | uri(), Opts :: map()) -> list(bondy_rbac_user:t()).

sources(#realm{uri = Uri}, Opts) ->
    %% TODO change this with continuation return
    bondy_rbac_source:list(Uri, Opts);

sources(Uri, Opts) when is_binary(Uri) ->
    sources(fetch(Uri), Opts).


%% -----------------------------------------------------------------------------
%% @doc Returns the list of grants belonging to realm `Realm'.
%% These includes the grants inherited from the prototype (if defined).
%% @end
%% -----------------------------------------------------------------------------
-spec grants(Realm :: t() | uri()) -> list(bondy_rbac_user:t()).

grants(Realm) ->
    grants(Realm, #{}).


%% -----------------------------------------------------------------------------
%% @doc Returns the list of grants belonging to realm `Realm'.
%% These includes the grants inherited from the prototype (if defined).
%% @end
%% -----------------------------------------------------------------------------
-spec grants(Realm :: t() | uri(), Opts :: map()) -> list(bondy_rbac_user:t()).

grants(#realm{uri = Uri}, Opts) ->
    %% TODO change this with continuation return
    bondy_rbac:grants(Uri, Opts);

grants(Uri, Opts) when is_binary(Uri) ->
    grants(fetch(Uri), Opts).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
add_master_realm() ->
    Data = validate(?MASTER_REALM, ?MASTER_REALM_VALIDATOR),
    do_add(Data).


%% @private
validate(Map0, Spec) ->
    Map = maps_utils:validate(Map0, Spec),

    %% Preconditions

    IsProto = maps:get(is_prototype, Map, false),
    Proto = maps:get(prototype_uri, Map, undefined),

    ok = case {IsProto, Proto} of
        {true, undefined} ->
            ok;
        {true, _} ->
            error({inconsistency_error, [is_prototype, prototype_uri]});
        _ ->
            ok
    end,

    IsSSORealm = maps:get(is_sso_realm, Map, false),
    SSORealm = maps:get(sso_realm_uri, Map, undefined),

    ok = case {IsSSORealm, SSORealm} of
        {true, undefined} ->
            ok;
        {true, _} ->
            error({inconsistency_error, [is_sso_realm, sso_realm_uri]});
        _ ->
            ok
    end,

    Map.


%% @private
validate_rbac_config(#realm{uri = Uri} = Realm, Map) ->
    Groups0 = [
        bondy_rbac_group:new(Data)
        || Data <- maps:get(groups, Map, [])
    ],

    Groups = group_topsort(Uri, Groups0),

    Users = [
        bondy_rbac_user:new(Data, #{password_opts => password_opts(Realm)})
        || Data <- maps:get(users, Map, [])
    ],
    SourceAssignments = [
        bondy_rbac_source:new_assignment(Data)
        || Data <- maps:get(sources, Map, [])
    ],
    Grants = [
        bondy_rbac:request(Data)
        || Data <- maps:get(grants, Map, [])
    ],
    #{
        groups => Groups,
        users => Users,
        sources => SourceAssignments,
        grants => Grants
    }.


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
apply_rbac_config(#realm{uri = Uri}, Map) ->
    #{
        groups := Groups,
        users := Users,
        sources := SourcesAssignments,
        grants := Grants
    } = Map,

    _ = [
        ok = maybe_error(
            bondy_rbac_group:add_or_update(Uri, Group)
        )
        || Group <- Groups
    ],

    _ = [
        ok = maybe_error(
            bondy_rbac_user:add_or_update(
                Uri,
                User,
                #{update_credentials => true, forward_credentials => true}
            )
        )
        || User <- Users
    ],

    _ = [
        ok = maybe_error(bondy_rbac_source:add(Uri, Assignment))
        || Assignment <- SourcesAssignments
    ],

    _ = [
        ok = maybe_error(bondy_rbac:grant(Uri, Grant))
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
maybe_add(Uri, Opts) ->
    case bondy_config:get([security, automatically_create_realms]) of
        true ->
            add(Opts#{<<"uri">> => Uri});
        false ->
            {error, not_found}
    end.


%% @private
add_or_update(#{<<"uri">> := Uri} = Data0) ->
    case lookup(Uri) of
        #realm{} = Realm ->
            Data = validate(Data0, ?REALM_UPDATE_VALIDATOR),
            do_update(Realm, Data);
        {error, not_found} ->
            Data = validate(Data0, ?REALM_VALIDATOR),
            do_add(Data)
    end.


%% @private
do_add(#{uri := Uri} = Map) ->
    Realm0 = #realm{uri = Uri},
    Realm = merge_and_store(Realm0, Map),
    ok = on_add(Realm),
    Realm.


%% @private
do_update(Realm0, Map) ->
    Realm = merge_and_store(Realm0, Map),
    ok = on_update(Realm),
    Realm.


%% @private
merge_and_store(Realm0, Map) ->
    Realm = maps:fold(fun fold_props/3, Realm0, Map),

    ok = check_integrity_constraints(Realm),

    %% We are going to call new on the respective modules so that we validate
    %% the data. This way we avoid adding anything to the database until all
    %% elements have been validated.
    RBACConfig = validate_rbac_config(Realm, Map),

    %% We then create the realm
    Uri = Realm#realm.uri,
    ok = plum_db:put(?PDB_PREFIX(Uri), Uri, Realm),

    %% We finally apply all the RBAC objects that have been validated
    ok = apply_rbac_config(Realm, RBACConfig),

    Realm.


%% @private
fold_props(allow_connections, V, Realm) ->
    Realm#realm{allow_connections = V};

fold_props(authmethods, V, Realm) ->
    Realm#realm{
        authmethods = V,
        %% TODO derive password options based on authmethods
        password_opts = get_password_opts(V)
    };

fold_props(description, V, Realm) ->
    Realm#realm{description = V};

fold_props(is_prototype, true, #realm{is_prototype = false} = Realm) ->
    Realm#realm{is_prototype = true};

fold_props(is_prototype, false, #realm{is_prototype = true}) ->
    error(
        {
            badarg,
            <<
                "Cannot set property 'is_prototype' to 'false' "
                "once it has been to 'true'."
            >>
        }
    );

fold_props(prototype_uri, V, #realm{prototype_uri = undefined} = Realm) ->
    Realm#realm{prototype_uri = V};

fold_props(prototype_uri, V1, #realm{prototype_uri = V0})
when V0 =/= V1 ->
    error(
        {
            badarg,
            <<"Cannot set update 'prototype_uri' once it has been set.">>
        }
    );

fold_props(is_sso_realm, true, #realm{is_sso_realm = false} = Realm) ->
    Realm#realm{is_sso_realm = true};

fold_props(is_sso_realm, false, #realm{is_sso_realm = true}) ->
    error(
        {
            badarg,
            <<
                "Cannot set property 'is_sso_realm' to 'false' "
                "once it has been to 'true'."
            >>
        }
    );

fold_props(sso_realm_uri, V, Realm) ->
    Realm#realm{sso_realm_uri = V};

fold_props(security_enabled, V, Realm) ->
    Realm#realm{security_enabled = V};
fold_props(private_keys, V, Realm) ->
    set_keys(Realm, V);

fold_props(encryption_keys, V, Realm) ->
    set_encryption_keys(Realm, V);

fold_props(_, _, Realm) ->
    %% We ignote the rest of the properties.
    %% They will be handled separately.
    Realm.


%% @private
on_add(Realm) ->
    ok = bondy_event_manager:notify({realm_added, Realm#realm.uri}),
    ok.


%% @private
on_update(Realm) ->
    ok = bondy_event_manager:notify({realm_updated, Realm#realm.uri}),
    ok.


%% @private
on_delete(Uri) ->
    ok = bondy_event_manager:notify({realm_deleted, Uri}),
    ok.


%% @private
set_keys(Realm, undefined) ->
    Realm;

set_keys(#realm{private_keys = Old} = Realm, New) ->
    PrivateKeys = keys_to_jwts(Old, New),
    PublicKeys = maps:map(fun(_, V) -> jose_jwk:to_public(V) end, PrivateKeys),
    Realm#realm{
        private_keys = PrivateKeys,
        public_keys = PublicKeys
    }.


%% @private
set_encryption_keys(Realm, undefined) ->
    Realm;

set_encryption_keys(#realm{encryption_keys = Old} = Realm, New) ->
    Realm#realm{
        encryption_keys = keys_to_jwts(Old, New)
    }.


%% @private
keys_to_jwts(Old, New) ->
    maps:from_list([
        begin
            Kid = list_to_binary(integer_to_list(erlang:phash2(Key))),
            case maps:get(Kid, Old, undefined) of
                undefined ->
                    Fields = #{<<"kid">> => Kid},
                    {Kid, jose_jwk:merge(Key, Fields)};
                Existing ->
                    {Kid, Existing}
            end
        end || Key <- New
    ]).


%% @private
-spec do_lookup(uri()) -> t() | {error, not_found}.

do_lookup(Uri) ->
    case plum_db:get(?PDB_PREFIX(Uri), Uri) of
        #realm{} = Realm ->
            Realm;
        undefined ->
            {error, not_found};
        Data ->
            _ = lager:warning(
                "Invalid realm data retrieved from store; data=~p", [Data]
            ),
            {error, not_found}
    end.


%% private
validate_keys([]) ->
    {ok, gen_keys()};

validate_keys(L) when is_list(L) ->
    do_validate_keys(L);

validate_keys(_) ->
    false.


%% @private
%% We generate the keys for signing
gen_keys() ->
    [
        jose_jwk:generate_key({namedCurve, secp256r1})
        || _ <- lists:seq(1, 3)
    ].


%% private
validate_encryption_keys([]) ->
    {ok, gen_encryption_keys()};

validate_encryption_keys(L) when is_list(L) ->
    do_validate_keys(L);

validate_encryption_keys(_) ->
    false.


%% @private
gen_encryption_keys() ->
    [
        jose_jwk:generate_key({rsa, 2048, 65537})
        || _ <- lists:seq(1, 3)
    ].


%% @private
do_validate_keys(L) when is_list(L) ->
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
            L
        ),
        {ok, Keys}
    catch
        _:_ ->
            false
    end.


group_topsort(Uri, Groups) ->
    try
        bondy_rbac_group:topsort(Groups)
    catch
        error:{cycle, Path} ->
            EReason = list_to_binary(
                io_lib:format(
                    <<
                        "Bondy could not compute a precendece graph for the "
                        "groups defined on the configuration provided for "
                        "realm '~s' as they form a cycle with path ~p"
                    >>,
                    [Uri, Path]
                )
            ),
            error({invalid_config, EReason})
    end.


%% @private
topsort(Realms) ->
    Graph = digraph:new([acyclic]),

    try
        _ = precedence_graph(Realms, Graph),

        case digraph_utils:topsort(Graph) of
            false ->
                %% Bondy could not compute a precendence graph for the realms
                %% defined on the configuration file.
                Realms;
            Vertices ->
                [element(2, digraph:vertex(Graph, V)) || V <- Vertices]
        end

    catch
        throw:{cycle, Path} ->
            EReason = list_to_binary(
                io_lib:format(
                    <<
                        "Bondy could not compute a precendece graph for the "
                        "realms defined on the configuration provided as they "
                        "form a cycle with path ~p"
                    >>,
                    [Path]
                )
            ),
            error({invalid_config, EReason})

    after
        digraph:delete(Graph)
    end.


%% @private
precedence_graph(Realms, Graph) ->
    Vertices = [
        begin
            R = validate_uris(R0),
            Uri = maps:get(uri, R),
            digraph:add_vertex(Graph, Uri, R)
        end || R0 <- Realms
    ],
    precedence_graph_aux(Vertices, Graph).


%% @private
precedence_graph_aux([H|T], Graph) ->
    {H, Realm} = digraph:vertex(Graph, H),
    Uris = maps:values(
        maps:with([prototype_uri, sso_realm_uri], Realm)
    ),
    _ = [
        precedence_graph_add_edge(Graph, Uri, H)
        || Uri <- Uris, Uri =/= undefined
    ],
    precedence_graph_aux(T, Graph);

precedence_graph_aux([], Graph) ->
    Graph.


%% @private
precedence_graph_add_edge(Graph, A, B) ->
    case digraph:vertex(Graph, A) of
        {A, _} ->
            case digraph:add_edge(Graph, A, B) of
                {error, {bad_edge, Path}} ->
                    throw({cycle, Path});
                {error, Reason} ->
                    error(Reason);
                _Edge ->
                    ok
            end;
        false ->
            %% The SSO or Prototype URI is not in the config file
            %% so it must exist already in the store. If it doesn't exist
            %% we will get an integrity constratint error
            %% during merge_and_store, so we do nothing here
            ok
    end.


%% @private
validate_uris(Data) ->
    %% We prevalidate the data
    Opts = #{keep_unknown => true},
    Validator = #{
        <<"uri">> => #{
            key => uri,
            alias => uri,
            required => true,
            datatype => binary,
            validator => fun bondy_data_validators:realm_uri/1
        },
        <<"sso_realm_uri">> => #{
            key => sso_realm_uri,
            alias => sso_realm_uri,
            required => false,
            datatype => binary,
            validator => fun bondy_data_validators:realm_uri/1
        }
    },
    maps_utils:validate(Data, Validator, Opts).



%% @private
check_integrity_constraints(Realm) ->
    ok = check_integrity_constraints(Realm, prototype),
    ok = check_integrity_constraints(Realm, sso),
    ok.


%% @private

check_integrity_constraints(
    #realm{is_sso_realm = true, sso_realm_uri = undefined}, sso) ->
    ok;

check_integrity_constraints(#realm{is_sso_realm = true}, sso) ->
    error(
        {
            inconsistency_error,
            [is_sso_realm, sso_realm_uri],
            <<
                "The realm is defined as a Same Sign-on (SSO) realm "
                "(the property 'is_sso_realm' is set to 'true') but "
                "property 'sso_realm_uri' has been defined). "
                "An SSO realm cannot itself use SSO."
            >>
        }
    );

check_integrity_constraints(#realm{uri = Uri, sso_realm_uri = Uri}, sso) ->
    %% sso relationship is irreflexive
    error(
        {
            inconsistency_error,
            [uri, sso_realm_uri],
            <<
                "The value for property 'sso_realm_uri' in invalid. "
                "It is equal to the realm's URI. "
                "A realm cannot have itself as SSO realm."
            >>
        }
    );

check_integrity_constraints(
    #realm{is_sso_realm = false, sso_realm_uri = Uri}, sso
) when Uri =/= undefined ->
    check_realm_type(Uri, sso);

check_integrity_constraints(_, sso) ->
    ok;

check_integrity_constraints(
    #realm{is_prototype = true, prototype_uri = undefined}, prototype) ->
    ok;

check_integrity_constraints(#realm{is_prototype = true}, prototype) ->
    error(
        {
            badarg,
            [is_prototype, prototype_uri],
            <<
                "The realm is defined as a prototype "
                "(the property 'is_prototype' is set to 'true') but "
                "property 'prototype_uri' has been defined). "
                "An prototype realm cannot inherit from another prototype."
            >>
        }
    );

check_integrity_constraints(
    #realm{uri = Uri, prototype_uri = Uri}, prototype) ->
    %% prototype relationship is irreflexive
    error(
        {
            badarg,
            [uri, prototype_uri],
            <<
                "The value for property 'prototype_uri' in invalid. "
                "It is equal to the realm's URI. "
                "A realm cannot have itself as a prototype."
            >>
        }
    );

check_integrity_constraints(
    #realm{is_prototype = false, prototype_uri = Uri}, prototype
) when Uri =/= undefined ->
    check_realm_type(Uri, prototype);

check_integrity_constraints(_, prototype) ->
    ok.


%% @private
check_realm_type(undefined, _) ->
    ok;

check_realm_type(Uri, Type) ->
    _ = case lookup(Uri) of
        {error, not_found = Reason} ->
            error(badarg(Uri, Type, Reason));
        Realm when Type == sso ->
            is_sso_realm(Realm) orelse error(badarg(Uri, Type, badtype));
        Realm when Type == prototype ->
            is_prototype(Realm) orelse error(badarg(Uri, Type, badtype))
    end,
    ok.


%% @private
badarg(Uri, prototype, not_found) ->
    {
        badarg,
        <<
            "Property 'prototype_uri' refers to a realm ('",
            Uri/binary,
            "') that doesn't exist."
        >>
    };

badarg(Uri, sso, not_found) ->
    {
        badarg,
        <<
            "Property 'sso_realm_uri' refers to a realm ('",
            Uri/binary,
            "') that doesn't exist."
        >>
    };

badarg(Uri, prototype, badtype) ->
    {
        badarg,
        <<
            "Property 'prototype_uri' refers to a realm ('",
            Uri/binary,
            "') that isn't a Prototype Realm."
        >>
    };

badarg(Uri, sso, badtype) ->
    {
        badarg,
        <<
            "Property 'sso_realm_uri' refers to a realm ('",
            Uri/binary,
            "') that isn't a Same Sign-on Realm."
        >>
    }.
