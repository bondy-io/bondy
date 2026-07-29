%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_realm).
-moduledoc """
Realms are routing and administrative domains and act as namespaces for
all resources in Bondy i.e. all users, groups, permissions, registrations
and subscriptions belong to a Realm. Messages and events are routed
separately for each individual realm so sessions attached to a realm won’t
see message and events occurring on another realm.

## Overview

The realm is a central and fundamental concept in Bondy. It does not only
serve as an authentication and authorization domain but also as a
**message routing domain**. Bondy ensures no messages routed in
one realm will leak into another realm.

## Security

A realm's security may be checked, enabled, or disabled by an administrator
through the WAMP and HTTP APIs. This allows an administrator to change
security settings of a realm on the whole cluster quickly without needing to
change settings on a node-by-node basis.

If you disable security, this means that you have disabled all of the
various authentication and authorization checks that take place when
establishing a session and executing operations against a Bondy Realm.
Users, groups, and other security resources remain available for
configuration while security is disabled, and will be applied if and when
security is re-enabled.

Realm security is enabled by default.

## Storage

Realms are persisted to disk and replicated across the cluster via the
bondy_db `bondy_realm` main table. Unlike the per-realm tables, the realm table
is a **global registry**:
all realms share a single bondy_db band (the empty binary, like the API Gateway
specs) and are keyed by their Uri, whose hash spreads them across
shards. `list/0` therefore scatter-scans the band across every shard. Realms'
associated RBAC objects (users, credentials, groups, sources, grants) live in
their own bondy_db tables.

## Bondy Master Realm
When you start Bondy for the first time it creates and stores the Bondy
Master realm a.k.a `com.leapsight.bondy`. This realm is the root realm which
allows an admin user to create, list, modify and delete other realms.

## Realm Properties

- **uri** `uri()` *[required, immutable]*
  The realm identifier.
- **description** `binary()`
  A textual description of the realm.
- **is_prototype** `boolean()` *[immutable]*
  If `true` this realm is a realm used as a prototype. *Default*: `false`.
- **prototype_uri** `uri()`
  If present, this it the URI of the the realm prototype this realm
  inherits some of its behaviour and features from.
- **sso_realm_uri** `uri()`
  If present, this it the URI of the SSO Realm this realm is connected to.
- **is_sso_realm** `boolean()` *[immutable]*
  If `true` this realm is an SSO Realm. *Default*: `false`.
- **allow_connections** `boolean()`
  If `true` this realm is allowing connections from clients. It is
  normally set to `false` when the realm is an SSO Realm.
  Default: `true`.
- **authmethods** `list(binary())`
  The list of the authentication methods allowed by this realm.
  Default: `[anonymous, password, ticket, oauth2, wampcra]`.
- **security_status** `binary()`
  The string `enabled` if security is enabled. Otherwise the string
  `disabled`.
- **public_keys** `list()`
  A list of JWK values.

## Realm Prototypes
A **Prototype Realm** is a realm that acts as a prototype for the
construction of other realms. A prototype realm is a normal realm whose
property `is_prototype` has been set to true.

Prototypical inheritance allows us to reuse the properties (including RBAC
definitions) from one realm to another through a reference URI configured on
the `prototype_uri` property.

Prototypical inheritance is a form of single inheritance as realms are can
only be related to a single prototype.

The `prototype_uri` property is defined as an *irreflexive property* i.e. a
realm cannot have itself as prototype. In addition *a prototype cannot
inherit from another prototype*. This means the inheritance chain is bounded
to one level.

### Inherited properties
The following is the list of properties which a realm inherits from a
prototype when those properties have not been assigned a value. Setting a
value to these properties is equivalente to overriding the prototype's.

- **security_enabled**
- **allow_connections**
- **sso_realm_uri**
- **authmethods**

In addition realms inherit Groups, Sources and Grants from their prototype.
The following are the inheritance rules:

1. Users cannot be defined at the prototype i.e. no user inheritance.
1. A realm has access to all groups defined in the prototype i.e. from a
realm perspective the prototype groups operate in the same way as if they
have been defined in the realm itself. This enables roles (users and groups)
in a realm to be members of groups defined in the prototype.
1. A group defined in a realm overrides any homonymous group in the
prototype. This works at all levels of the group membership chain.
1. The previous rule does not apply to the special group `all`. Permissions
granted to `all` are merged between a realm and its prototype.


## Same Sign-on (SSO)
Bondy SSO (Same Sign-on) is a feature that allows users to access multiple
realms using just one set of credentials.

It is enabled by setting the realm's `sso_realm_uri` property during realm
creation or during an update operation.

- It requires the user to authenticate when opening a session in a realm.
- Changing credentials e.g. updating password can be performed while
connected to any realm.
""".
-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include_lib("jose/include/jose_jwk.hrl").
-include("bondy.hrl").
-include("bondy_db_tables.hrl").
-include("bondy_security.hrl").

%% The realm table is a global registry: every realm shares this one bondy_db
%% band (the empty binary, mirroring the api_gateway specs) and is keyed by its
%% Uri, whose hash spreads realms across shards
%% while `bondy_db:list/2` over the band scatter-scans every realm.
-define(REALM_BAND, <<>>).

%% S-2: at-rest encryption marker for a `bondy_realm_keys` bundle field. A
%% sensitive field (`private`, `encryption`) is stored either as a plaintext JWK
%% (encryption off / legacy) or as `{?ENC_TAG, Envelope}` (a `bondy_keyring`
%% AES-256-GCM envelope over `term_to_binary(JWK)`). `public` is never encrypted.
-define(ENC_TAG, '$bondy_enc').
-define(SENSITIVE_KEY_FIELDS, [private, encryption]).

-define(DEFAULT_AUTHMETHODS, [
    ?WAMP_ANON_AUTH,
    ?PASSWORD_AUTH,
    ?OAUTH2_AUTH,
    ?WAMP_CRA_AUTH,
    % ?WAMP_SCRAM_AUTH,
    ?WAMP_TICKET_AUTH
]).

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
    %% Determines whether the realm is a prototype. Prototype realms cannot be
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
    %% TODO make it inheritable????
    <<"sso_realm_uri">> => #{
        alias => sso_realm_uri,
        key => sso_realm_uri,
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
        allow_undefined => true,
        default => undefined
    },
    %% Determines the authentication methods available for clients connecting
    %% to this realm.
    <<"authmethods">> => #{
        alias => authmethods,
        key => authmethods,
        required => true,
        datatype => {list, {in, ?BONDY_AUTH_METHOD_NAMES}},
        allow_undefined => true,
        default => undefined
    },
    <<"security_enabled">> => #{
        alias => security_enabled,
        key => security_enabled,
        required => false,
        datatype => boolean,
        allow_undefined => true,
        default => undefined
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
    %% This is a way to atomically create groups together with the realm
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
    %% A set of keys used for signing. The validator no longer generates keys;
    %% an absent/empty list yields an empty keyset and the create path
    %% (`maybe_gen_keys/2`) decides whether to mint them eagerly or defer to
    %% lazy generation on first use. See the REALM KEY MATERIAL section.
    <<"private_keys">> => #{
        alias => private_keys,
        key => private_keys,
        required => true,
        default => [],
        validator => fun validate_keys/1
    },
    %% A set of keys used for encryption. Generated like the signing keys above.
    <<"encryption_keys">> => #{
        alias => encryption_keys,
        key => encryption_keys,
        required => true,
        default => [],
        validator => fun validate_encryption_keys/1
    },
    <<"info">> => #{
        alias => info,
        key => info,
        required => false,
        default => #{},
        validator => ?INFO_VALIDATOR
    }
}).

-define(INFO_VALIDATOR, #{
    <<"oidc_providers">> => #{
        alias => oidc_providers,
        key => oidc_providers,
        required => false,
        validator => {map, {binary, ?OIDC_PROVIDER}}
    }
}).

-define(OIDC_PROVIDER, #{
    <<"authid_claim">> => #{
        alias => authid_claim,
        key => authid_claim,
        required => true,
        default => <<"preferred_username">>,
        datatype => binary
    },
    <<"auto_provision">> => #{
        alias => auto_provision,
        key => auto_provision,
        required => true,
        default => false,
        datatype => boolean
    },
    <<"client_id">> => #{
        alias => client_id,
        key => client_id,
        required => true,
        datatype => binary
    },
    <<"client_secret">> => #{
        alias => client_secret,
        key => client_secret,
        required => true,
        datatype => binary
    },
    <<"issuer">> => #{
        alias => issuer,
        key => issuer,
        required => true,
        datatype => binary
    },
    <<"redirect_uri">> => #{
        alias => redirect_uri,
        key => redirect_uri,
        required => true,
        datatype => binary
    },
    <<"scopes">> => #{
        alias => scopes,
        key => scopes,
        required => true,
        default => [<<"openid">>, <<"profile">>, <<"email">>],
        datatype => {list, binary}
    },
    <<"role_claim">> => #{
        alias => role_claim,
        key => role_claim,
        required => true,
        default => <<"roles">>,
        datatype => binary
    },
    <<"role_claim_fallback">> => #{
        alias => role_claim_fallback,
        key => role_claim_fallback,
        required => true,
        default => <<"role">>,
        datatype => binary
    },
    <<"role_mapping">> => #{
        alias => role_mapping,
        key => role_mapping,
        required => false,
        default => #{},
        datatype => map
    },
    <<"ticket_expiry_secs">> => #{
        alias => ticket_expiry_secs,
        key => ticket_expiry_secs,
        required => false,
        datatype => integer
    },
    <<"allow_unsafe_http">> => #{
        alias => allow_unsafe_http,
        key => allow_unsafe_http,
        required => true,
        default => false,
        datatype => boolean
    },
    <<"cookie_domain">> => #{
        alias => cookie_domain,
        key => cookie_domain,
        required => false,
        datatype => binary
    },
    <<"cookie_same_site">> => #{
        alias => cookie_same_site,
        key => cookie_same_site,
        required => true,
        default => <<"lax">>,
        datatype => {in, [<<"lax">>, <<"strict">>, <<"none">>]}
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
        ],
        ?REALM_VALIDATOR
    )
).

%% The overridden maps_utils:validate/2 specification
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
    <<"allow_connections">> => #{
        alias => allow_connections,
        key => allow_connections,
        required => false,
        datatype => boolean,
        allow_undefined => true
    },
    <<"authmethods">> => #{
        alias => authmethods,
        key => authmethods,
        required => false,
        datatype => {list, {in, ?BONDY_AUTH_METHOD_NAMES}},
        allow_undefined => true
    },
    <<"security_enabled">> => #{
        alias => security_enabled,
        key => security_enabled,
        required => false,
        datatype => boolean,
        allow_undefined => true
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
        required => false,
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
    },
    <<"info">> => #{
        alias => info,
        key => info,
        required => false,
        default => #{},
        validator => ?INFO_VALIDATOR
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
        ],
        ?REALM_UPDATE_VALIDATOR
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
        ?PASSWORD_AUTH
        %% D-2: ?WAMP_ANON_AUTH removed — the master realm is the administrative
        %% control plane and must not accept anonymous connections.
    ],
    is_prototype => false,
    prototype_uri => undefined,
    is_sso_realm => false,
    sso_realm_uri => undefined,
    allow_connections => true,
    security_enabled => true,
    users => [
        #{
            %% D-1: no hardcoded password. The admin password is injected at
            %% first-boot creation (see add_master_realm/0 /
            %% resolve_master_admin_password/0) from
            %% `security.admin_user.password`, or a random one is generated and
            %% logged once.
            username => <<"admin">>,
            groups => [<<"bondy.administrators">>],
            meta => #{
                <<"description">> => <<"The default Bondy administrator user.">>
            }
        }
    ],
    groups => [
        #{
            name => <<"bondy.administrators">>,
            groups => [],
            meta => #{
                <<"description">> => <<"The Bondy administrators group">>
            }
        }
    ],
    grants => [
        %% D-2: the administrators group is granted wamp.* on the Bondy admin
        %% namespaces ONLY (`bondy.*` and `wamp.*`), not on all URIs (`<<"">>`).
        %% The anonymous grant that previously mirrored this has been REMOVED, so
        %% the anonymous role holds no capability on the master realm. The
        %% trailing-dot prefixes are component-safe under the current byte-prefix
        %% match and become component-correct once Z-1/WP-N lands.
        #{
            permissions => [
                <<"wamp.call">>,
                <<"wamp.cancel">>,
                <<"wamp.subscribe">>,
                <<"wamp.unsubscribe">>
            ],
            uri => <<"bondy.">>,
            match => <<"prefix">>,
            roles => [<<"bondy.administrators">>],
            meta => #{
                <<"description">> => <<
                    "Allows the administrators group to call the Bondy admin "
                    "APIs and subscribe to Bondy events under the 'bondy.' "
                    "namespace."
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
            uri => <<"wamp.">>,
            match => <<"prefix">>,
            roles => [<<"bondy.administrators">>],
            meta => #{
                <<"description">> => <<
                    "Allows the administrators group to use the WAMP meta API "
                    "and subscribe to WAMP events under the 'wamp.' namespace."
                >>
            }
        }
    ],
    sources => [
        %% D-1: master-realm credential auth defaults to LOOPBACK ONLY. The
        %% master realm is the administrative control plane; remote admin access
        %% is an explicit operator decision — add a source for your admin network
        %% (e.g. an RFC1918 CIDR) rather than exposing it to 0.0.0.0/0.
        #{
            usernames => <<"all">>,
            authmethod => ?PASSWORD_AUTH,
            cidr => <<"127.0.0.0/8">>,
            meta => #{
                <<"description">> => <<
                    "Allows users to authenticate using password credentials "
                    "from the loopback interface only. Add a source for your "
                    "admin network to allow remote administrative access."
                >>
            }
        },
        #{
            usernames => <<"all">>,
            authmethod => ?WAMP_CRYPTOSIGN_AUTH,
            cidr => <<"127.0.0.0/8">>,
            meta => #{
                <<"description">> => <<
                    "Allows users to authenticate using cryptosign from the "
                    "loopback interface only. Add a source for your admin "
                    "network to allow remote administrative access."
                >>
            }
        },
        #{
            usernames => <<"all">>,
            authmethod => ?WAMP_CRA_AUTH,
            cidr => <<"127.0.0.0/8">>,
            meta => #{
                <<"description">> => <<
                    "Allows users to authenticate using WAMP-CRA from the "
                    "loopback interface only. Add a source for your admin "
                    "network to allow remote administrative access."
                >>
            }
        },
        % #{
        %     usernames => <<"all">>,
        %     authmethod => ?WAMP_SCRAM_AUTH,
        %     cidr => <<"127.0.0.0/8">>,
        %     meta => #{
        %         <<"description">> => <<"loopback only">>
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
        }
        %% D-2: the anonymous loopback source has been REMOVED — the master realm
        %% no longer accepts anonymous connections.
    ]
}).

-define(CONTROL_REALM, #realm{
    uri = ?CONTROL_REALM_URI,
    description = <<
        "A private realm used by bondy internally for control plane purposes"
    >>,
    is_prototype = false,
    is_sso_realm = false,
    security_enabled = true,
    allow_connections = false,
    authmethods = []
}).

-define(DELETE_OPTS, #{
    force => #{
        alias => <<"force">>,
        key => force,
        required => true,
        default => false,
        datatype => boolean
    }
}).

-record(realm, {
    uri :: uri(),
    description :: binary(),
    is_prototype = false :: boolean(),
    prototype_uri :: optional(uri()),
    is_sso_realm = false :: boolean(),
    %% TODO change sso_realm_uri to allowed_sso_realms
    sso_realm_uri :: optional(uri()),
    allow_connections :: optional(boolean()),
    authmethods :: optional([binary()]),
    security_enabled :: optional(boolean()),
    password_opts :: optional(
        bondy_password:opts()
    ),
    %% it can be undefined when we strip the value only.
    %% See strip_private_keys
    private_keys = #{} :: optional(keymap()),
    public_keys = #{} :: keymap(),
    encryption_keys = #{} :: keymap(),
    info = #{} :: map()
}).

-opaque t() :: #realm{}.
-type kid() :: binary().
-type keymap() :: #{kid() => map()}.
-type keyset() :: [map()].
-type delete_opts() :: #{force => boolean()}.
-type external() :: #{
    uri := uri(),
    is_prototype := boolean(),
    prototype_uri := optional(uri()),
    description := binary(),
    authmethods := [binary()],
    is_sso_realm := boolean(),
    allow_connections := boolean(),
    public_keys := keyset(),
    security_status := enabled | disabled
}.

-export_type([t/0]).
-export_type([uri/0]).
-export_type([external/0]).

-export([allow_connections/1]).
-export([apply_config/0]).
-export([harden_master_realm/0]).
-export([authmethods/1]).
-export([create/1]).
-export([delete/1]).
-export([delete/2]).
-export([description/1]).
-export([disable_security/1]).
-export([enable_security/1]).
-export([encryption_keys/1]).
-export([exists/1]).
-export([fetch/1]).
-export([from_file/1]).
-export([get/1]).
-export([get/2]).
-export([get_encryption_key/2]).
-export([get_private_key/2]).
-export([get_public_key/2]).
-export([get_random_encryption_kid/1]).
-export([get_random_kid/1]).
-export([get_random_private_key/1]).
-export([get_oidc_provider/2]).
-export([info/1]).
-export([is_allowed_authmethod/2]).
-export([is_allowed_sso_realm/2]).
-export([is_prototype/1]).
-export([oidc_providers/1]).
-export([is_security_enabled/1]).
-export([is_sso_realm/1]).
-export([is_trusted_issuer/2]).
-export([is_type/1]).
-export([is_value_inherited/2]).
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
-export([strip_private_keys/1]).
-export([split_for_import/1]).
-export([keys_value_to_entries/1]).

-export([suspend/1]).
-export([close/2]).
-export([resume/1]).

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

-doc "Returns the URI that identifies the realm `Realm`.".
-spec uri(Realm :: t()) -> uri().

uri(#realm{uri = Uri}) ->
    Uri.

-spec description(t() | uri()) -> map().

description(#realm{description = Value}) ->
    Value;
description(Uri) when is_binary(Uri) ->
    description(fetch(Uri)).

-spec is_type(Realm :: t() | uri()) -> boolean().

is_type(#realm{}) ->
    true;
is_type(_) ->
    false.

-doc """
Returns `true` if realm `Realm` is a prototype. Otherwise, returns
`false`.

**Pre-conditions**
- The property `prototype_uri` MUST be `undefined`.
- This property cannot be set to `false` once it has been set to `true`.

**Post-conditions**
- If this property is `true`, the `prototype_uri` cannot be set.
""".
-spec is_prototype(Realm :: t() | uri()) -> boolean().

is_prototype(#realm{is_prototype = Val}) ->
    Val;
is_prototype(Uri) when is_binary(Uri) ->
    is_prototype(fetch(Uri)).

-doc """
Returns the uri of realm `Realm` prototype if defined. Otherwise
returns `undefined`.
""".
-spec prototype_uri(Realm :: t() | uri()) -> optional(uri()).

prototype_uri(#realm{prototype_uri = Val}) ->
    Val;
prototype_uri(Uri) when is_binary(Uri) ->
    prototype_uri(fetch(Uri)).

-doc """
Returns `true` if the property value is inherited from a prototype.
Otherwise returns `false`.
""".
-spec is_value_inherited(Realm :: t() | uri(), Property :: atom()) ->
    boolean() | no_return().

is_value_inherited(#realm{prototype_uri = undefined}, Property) ->
    %% We have no prototype
    %% So we validate the property is valid and return false
    ok = check_is_property(Property),
    false;
is_value_inherited(
    #realm{allow_connections = Val}, allow_connections
) ->
    Val == undefined;
is_value_inherited(#realm{authmethods = Val}, authmethods) ->
    Val == undefined;
is_value_inherited(#realm{sso_realm_uri = Val}, sso_realm_uri) ->
    Val == undefined;
is_value_inherited(#realm{security_enabled = Val}, is_security_enabled) ->
    Val == undefined;
is_value_inherited(#realm{security_enabled = Val}, security_status) ->
    %% security_status is an util function that uses the value of the
    %% security_enabled property
    Val == undefined;
is_value_inherited(#realm{}, Property) ->
    %% The property is not inheritable.
    %% So we validate the property is valid and return false
    ok = check_is_property(Property),
    false;
is_value_inherited(Uri, Property) when is_binary(Uri) ->
    is_value_inherited(fetch(Uri), Property).

-doc """
Returns the same sign on (SSO) realm URI used by the realm.

If a value is set, then all authentication and user creation will be done on
the the SSO Realm.

Groups, permissions and sources are still managed by this realm
(or the prototype it inherits from).

If the value is `undefined` and the realm has a prototype the prototype's
value is returned. Otherwise if the realm doesn't have a prototype returns
`undefined`.
""".
-spec sso_realm_uri(Realm :: t() | uri()) -> optional(uri()).

sso_realm_uri(#realm{sso_realm_uri = undefined, prototype_uri = undefined}) ->
    undefined;
sso_realm_uri(#realm{sso_realm_uri = undefined, prototype_uri = Uri}) ->
    sso_realm_uri(Uri);
sso_realm_uri(#realm{sso_realm_uri = Val}) ->
    Val;
sso_realm_uri(Uri) when is_binary(Uri) ->
    sso_realm_uri(fetch(Uri)).

-doc """
Returns `true` if realm `Realm` is associated with the SSO Realm
identified by uri `SSORealmUri`. Otherwise returns `false`.
""".
-spec is_allowed_sso_realm(Realm :: t() | uri(), SSORealmUri :: uri()) ->
    boolean().

is_allowed_sso_realm(Realm, SSORealmUri) ->
    %% TODO change sso_realm_uri to allowed_sso_realms
    %% We call sso_realm_uri to resolve prototype inheritance
    SSORealmUri =:= sso_realm_uri(Realm).

-doc """
Returns `true` if the Realm is a Same Sign-on (SSO) realm.
Otherwise returns `false`.

If the value is `undefined` and the realm has a prototype the prototype's
value is returned. Otherwise if the realm doesn't have a prototype returns
`false`.
""".
-spec is_sso_realm(Realm :: t() | uri()) -> boolean().

is_sso_realm(#realm{is_sso_realm = Val}) ->
    Val;
is_sso_realm(Uri) when is_binary(Uri) ->
    is_sso_realm(fetch(Uri)).

-doc """
Returns `true` if a token or ticket whose issuer — the value of its `aud`
(JWT) / `authrealm` (ticket) claim, `AuthRealmUri` — may be accepted to
establish a session in realm `RealmUri`. Otherwise returns `false`.

An issuer is trusted iff it is the target realm itself, or the target realm's
configured SSO realm (resolving prototype inheritance via `sso_realm_uri/1`).

This is the cross-realm token-trust boundary: it prevents a token/ticket minted
under an unrelated — possibly attacker-controlled — realm or SSO family from
being replayed against `RealmUri` merely because that token verifies against its
own issuer's key. Every token/ticket verifier that binds a session to a target
realm MUST gate on this predicate.

The common same-realm case (`AuthRealmUri =:= RealmUri`) short-circuits before
any realm lookup, so only genuine SSO tokens incur a `fetch/1`.
""".
-spec is_trusted_issuer(RealmUri :: uri(), AuthRealmUri :: uri()) -> boolean().

is_trusted_issuer(RealmUri, AuthRealmUri) when
    is_binary(RealmUri) andalso is_binary(AuthRealmUri)
->
    AuthRealmUri =:= RealmUri orelse
        AuthRealmUri =:= sso_realm_uri(RealmUri).

-doc """
Returns `true` if the Realm is allowing connections. Otherwise returns
`false`.

If the value is `undefined` and the realm has a prototype the prototype's
value is returned. Otherwise if the realm doesn't have a prototype returns
`false`.

Note that a Prototype realm never allows connections irrespective of the
value set to this property. This this property is just used as a template
for realms to inherit from.

This setting is used to either temporarily restrict new connections to the
realm or to avoid connections when the realm is used as a Single Sign-on
Realm. When connections are not allowed the only way of managing the
resources in the realm is through a connection to the Bondy Master Realm.
""".
-spec allow_connections(Realm :: t() | uri()) -> boolean().

allow_connections(
    #realm{allow_connections = undefined, prototype_uri = undefined} = Realm
) ->
    %% By default allow connections unless this is a prototype realm
    not Realm#realm.is_prototype;
allow_connections(
    #realm{allow_connections = undefined, prototype_uri = Uri}
) ->
    allow_connections(Uri);
allow_connections(#realm{allow_connections = Val}) ->
    Val;
allow_connections(Uri) when is_binary(Uri) ->
    allow_connections(fetch(Uri)).

-doc "Sets allow_connections to false.".
-spec suspend(Realm :: t() | uri()) -> boolean().

suspend(#realm{} = Realm) ->
    case is_prototype(Realm) of
        true ->
            false;
        false ->
            _ = update(Realm, #{allow_connections => false}),
            true
    end;
suspend(Uri) when is_binary(Uri) ->
    suspend(fetch(Uri)).

-doc "Sets allow_connections to true.".
-spec resume(Realm :: t() | uri()) -> boolean() | no_return().

resume(#realm{} = Realm) ->
    case is_prototype(Realm) of
        true ->
            %% No need to update as prototype realms do not allow connections
            %% by design, but we return true to make this call idempotent.
            true;
        false ->
            _ = update(Realm, #{allow_connections => true}),
            true
    end;
resume(Uri) when is_binary(Uri) ->
    resume(fetch(Uri)).

-doc """
Calls the session manager to asynchronoulsy close all sessions for
realm `Realm`.
""".
-spec close(RealmUri :: uri(), Reason :: uri()) -> ok.

close(RealmUri, Reason) ->
    bondy_session_manager:close_all(RealmUri, Reason).

-doc """
Returns the list of supported authentication methods for Realm.

If the value is `undefined` and the realm has a prototype the prototype's
value is returned. Otherwise if the realm doesn't have a prototype returns
the default list of authentication methods.

See `is_allowed_authmethod/2` for more information about how this
affects the methods available for an authenticating user.
""".
-spec authmethods(Realm :: t() | uri()) -> [binary()].

authmethods(#realm{authmethods = undefined, prototype_uri = undefined}) ->
    ?DEFAULT_AUTHMETHODS;
authmethods(#realm{authmethods = undefined, prototype_uri = Uri}) ->
    authmethods(Uri);
authmethods(#realm{authmethods = Val}) ->
    Val;
authmethods(Uri) when is_binary(Uri) ->
    authmethods(fetch(Uri)).

-doc """
Returns `true` if Method is an authentication method supported by realm
`Realm`. Otherwise returns `false`.

The fact that method `Method` is included in the realm's `authmethods`
(See `authmethods/1`) is no guarantee that the method will be
available for a particular user.

The availability is also affected by the source rules defined for the realm
and the capabilities of each user e.g. if the user has no password then
the password-based authentication methods in this list will not be available.
""".
-spec is_allowed_authmethod(Realm :: t() | uri(), Method :: binary()) ->
    boolean().

is_allowed_authmethod(#realm{} = Realm, Method) ->
    lists:member(Method, authmethods(Realm));
is_allowed_authmethod(Uri, Method) when is_binary(Uri) ->
    is_allowed_authmethod(fetch(Uri), Method).

-doc """
Returns `true` if security is enabled. Otherwise returns `false`.

If the value is `undefined` and the realm has a prototype the prototype's
value is returned. Otherwise if the realm doesn't have a prototype returns
`true` (default).

Security for this realm can be enabled or disabled using the functions
`enable_security/1` and `disable_security/1` respectively.

See `security_status/1` if you want the security status representation
as an atom.
""".
-spec is_security_enabled(t() | uri()) -> boolean().

is_security_enabled(
    #realm{security_enabled = undefined, prototype_uri = undefined}
) ->
    true;
is_security_enabled(
    #realm{security_enabled = undefined, prototype_uri = Uri}
) ->
    is_security_enabled(Uri);
is_security_enabled(#realm{security_enabled = Val}) ->
    Val;
is_security_enabled(Uri) when is_binary(Uri) ->
    is_security_enabled(fetch(Uri)).

-doc """
A util function that returns the security status as an atom.
See `is_security_enabled/1`.
""".
-spec security_status(t() | uri()) -> enabled | disabled.

security_status(Term) ->
    case is_security_enabled(Term) of
        true -> enabled;
        false -> disabled
    end.

-doc "Enables security for realm `Realm`.".
-spec enable_security(t() | uri()) -> ok.

enable_security(#realm{} = Realm) ->
    _ = update(Realm, #{security_enabled => true}),
    ok;
enable_security(Uri) when is_binary(Uri) ->
    enable_security(fetch(Uri)).

-doc "Disables security for realm `Realm`.".
-spec disable_security(t() | uri()) -> ok | no_return().

disable_security(#realm{uri = ?MASTER_REALM_URI}) ->
    error(badarg);
disable_security(#realm{uri = ?CONTROL_REALM_URI}) ->
    error(badarg);
disable_security(#realm{} = Realm) ->
    _ = update(Realm, #{security_enabled => false}),
    ok;
disable_security(Uri) when is_binary(Uri) ->
    disable_security(fetch(Uri)).

-doc """
Returns the password options to be used as default when adding users
to this realm. If the options have not been defined returns atom `undefined`.
""".
-spec password_opts(t() | uri()) -> optional(bondy_password:opts()).

password_opts(#realm{password_opts = undefined, prototype_uri = undefined}) ->
    true;
password_opts(#realm{password_opts = undefined, prototype_uri = Uri}) ->
    password_opts(Uri);
password_opts(#realm{password_opts = Opts}) ->
    Opts;
password_opts(RealmUri) ->
    password_opts(fetch(RealmUri)).

-spec private_keys(t() | uri()) -> [map()].

private_keys(#realm{private_keys = undefined}) ->
    %% Special case when we strip the keys
    [];
private_keys(#realm{private_keys = Keys} = Realm0) when map_size(Keys) == 0 ->
    Realm = init_keys(Realm0),
    private_keys(Realm);
private_keys(#realm{private_keys = Keys}) ->
    [to_private_key(K) || {_, K} <- maps:to_list(Keys)];
private_keys(Uri) when is_binary(Uri) ->
    private_keys(fetch(Uri)).

-spec public_keys(t() | uri()) -> [map()].

public_keys(#realm{public_keys = Keys} = Realm0) when map_size(Keys) == 0 ->
    Realm = init_keys(Realm0),
    public_keys(Realm);
public_keys(#realm{public_keys = Keys}) ->
    [K || {_, K} <- maps:to_list(Keys)];
public_keys(Uri) when is_binary(Uri) ->
    public_keys(fetch(Uri)).

-spec get_private_key(t() | uri(), Kid :: binary()) -> map() | undefined.

get_private_key(#realm{private_keys = Keys}, Kid) ->
    case maps:get(Kid, Keys, undefined) of
        undefined -> undefined;
        Key -> to_private_key(Key)
    end;
get_private_key(Uri, Kid) when is_binary(Uri) ->
    get_private_key(fetch(Uri), Kid).

-spec get_public_key(t() | uri(), Kid :: binary()) -> map() | undefined.

get_public_key(#realm{public_keys = Keys}, Kid) ->
    case maps:get(Kid, Keys, undefined) of
        undefined -> undefined;
        Key -> Key
    end;
get_public_key(Uri, Kid) when is_binary(Uri) ->
    get_public_key(fetch(Uri), Kid).

-spec get_random_kid(t() | uri()) -> binary().

get_random_kid(#realm{private_keys = Keys} = Realm0) when map_size(Keys) == 0 ->
    %% Signing keys are generated lazily; mint (and persist) them on first use.
    Realm = init_keys(Realm0),
    get_random_kid(Realm);
get_random_kid(#realm{private_keys = Keys}) ->
    Kids = maps:keys(Keys),
    lists:nth(rand:uniform(length(Kids)), Kids);
get_random_kid(Uri) when is_binary(Uri) ->
    get_random_kid(fetch(Uri)).

-doc """
Returns a random signing key as `{Kid, PrivateKey}`, generating (and persisting)
the realm's signing keys on first use if it has none yet.

Use this in preference to the `get_random_kid/1` + `get_private_key/2` pair on
the same realm record: because keys are generated lazily, picking a kid may
generate keys that are NOT present in the in-hand `#realm{}` record, so a
follow-up `get_private_key/2` on that stale record would return `undefined`.
This function returns the matching key atomically.
""".
-spec get_random_private_key(t() | uri()) -> {binary(), map()}.

get_random_private_key(#realm{private_keys = Keys} = Realm0) when
    map_size(Keys) == 0
->
    Realm = init_keys(Realm0),
    get_random_private_key(Realm);
get_random_private_key(#realm{private_keys = Keys}) ->
    Kids = maps:keys(Keys),
    Kid = lists:nth(rand:uniform(length(Kids)), Kids),
    {Kid, to_private_key(maps:get(Kid, Keys))};
get_random_private_key(Uri) when is_binary(Uri) ->
    get_random_private_key(fetch(Uri)).

-spec encryption_keys(t() | uri()) -> [map()].

encryption_keys(#realm{encryption_keys = Keys} = Realm0) when
    map_size(Keys) == 0
->
    Data = #{encryption_keys => gen_encryption_keys()},
    Realm = merge_and_store(Realm0, Data, #{}),
    encryption_keys(Realm);
encryption_keys(#realm{encryption_keys = Keys}) ->
    [jose_jwk:to_map(K) || {_, K} <- maps:to_list(Keys)];
encryption_keys(Uri) when is_binary(Uri) ->
    encryption_keys(fetch(Uri)).

-spec get_encryption_key(t() | uri(), Kid :: binary()) -> map() | undefined.

get_encryption_key(#realm{encryption_keys = Keys}, Kid) ->
    case maps:get(Kid, Keys, undefined) of
        undefined -> undefined;
        Map -> jose_jwk:to_map(Map)
    end;
get_encryption_key(Uri, Kid) when is_binary(Uri) ->
    get_encryption_key(fetch(Uri), Kid).

-spec get_random_encryption_kid(t() | uri()) -> map().

get_random_encryption_kid(#realm{encryption_keys = Keys} = Realm0) when
    map_size(Keys) == 0
->
    %% Encryption keys are generated lazily; mint (and persist) them on first
    %% use.
    Data = #{encryption_keys => gen_encryption_keys()},
    Realm = merge_and_store(Realm0, Data, #{}),
    get_random_encryption_kid(Realm);
get_random_encryption_kid(#realm{encryption_keys = Keys}) ->
    Kids = maps:keys(Keys),
    lists:nth(rand:uniform(length(Kids)), Kids);
get_random_encryption_kid(Uri) when is_binary(Uri) ->
    get_random_encryption_kid(fetch(Uri)).

-spec info(t() | uri()) -> map() | no_return().

info(#realm{info = Info}) ->
    Info;
info(Uri) when is_binary(Uri) ->
    info(fetch(Uri)).

-doc """
Returns the OIDC providers configuration map for the given realm.
Returns an empty map if no providers are configured.
""".
-spec oidc_providers(Realm :: t() | uri()) -> [map()].

oidc_providers(#realm{info = Info}) ->
    maps:get(oidc_providers, Info, []);
oidc_providers(Uri) when is_binary(Uri) ->
    oidc_providers(fetch(Uri)).

-doc """
Looks up a specific OIDC provider configuration by name.
Returns `{ok, Config}` or `{error, not_found}`.
""".
-spec get_oidc_provider(Realm :: t() | uri(), ProviderName :: binary()) ->
    {ok, map()} | {error, not_found}.

get_oidc_provider(Realm, ProviderName) when is_binary(ProviderName) ->
    case maps:get(ProviderName, oidc_providers(Realm), not_found) of
        not_found ->
            {error, not_found};
        Value ->
            {ok, maybe_migrate_provider_config(Value)}
    end.

%% @private
%% Removes ticket_expiry_secs from provider configs where the value matches
%% the old hardcoded validator default (3600). This allows the handler to
%% fall through to the global bondy.conf setting. Explicitly set values
%% (different from the old default) are preserved.
maybe_migrate_provider_config(#{ticket_expiry_secs := 3600} = Config) ->
    maps:remove(ticket_expiry_secs, Config);
maybe_migrate_provider_config(Config) ->
    Config.

-spec exists(uri()) -> boolean().

exists(Uri) ->
    resulto:is_ok(lookup(Uri)).

-doc """
Retrieves the realm identified by Uri from the tuplespace or '{error, not_found}'
if it doesn't exist.
""".
-spec lookup(uri()) -> {ok, t()} | {error, not_found}.

lookup(Uri) ->
    do_lookup(string:casefold(Uri)).

-doc """
Retrieves the realm identified by Uri from the tuplespace. If the realm
does not exist it fails with reason '{badarg, Uri}'.
""".
-spec fetch(uri()) -> t() | no_return().

fetch(?CONTROL_REALM_URI) ->
    ?CONTROL_REALM;
fetch(Uri) ->
    case lookup(Uri) of
        {ok, #realm{} = Realm} ->
            Realm;
        {error, not_found} ->
            error({not_found, Uri})
    end.

-doc """
Retrieves the realm identified by Uri from the tuplespace. If the realm
does not exist and automatic creation of realms is enabled, it will add a
new one for Uri with the default configuration options.
""".
-spec get(uri()) -> {ok, t()} | {error, not_found}.

get(Uri) ->
    get(Uri, #{}).

-doc """
Retrieves the realm identified by Uri from the tuplespace. If the realm
does not exist and automatic creation of realms is enabled, it will create a
new one for Uri with configuration options `Opts`.
""".
-spec get(uri(), map()) -> {ok, t()} | {error, not_found | any()}.

get(Uri, Opts) ->
    Result = lookup(Uri),
    resulto:then_recover(
        Result,
        fun
            (not_found) when Uri == ?MASTER_REALM_URI ->
                resulto:result(add_master_realm());
            (not_found) ->
                resulto:result(maybe_create(Uri, Opts));
            (Reason) ->
                {error, Reason}
        end
    ).

-spec create(uri() | map()) -> t() | no_return().

create(Map0) when is_map(Map0) ->
    #{uri := Uri} = Map1 = validate(Map0, ?REALM_VALIDATOR),

    Prefix = binary:longest_common_prefix([?MASTER_REALM_URI, Uri]),
    Size = byte_size(?MASTER_REALM_URI),

    Prefix < Size andalso Uri =/= ?CONTROL_REALM_URI orelse
        error(badarg),

    case exists(Uri) of
        true ->
            error({already_exists, Uri});
        false ->
            do_create(Map1, #{})
    end;
create(Uri) when is_binary(Uri) ->
    create(#{uri => Uri}).

-spec update(Realm :: t() | uri(), Data :: map()) -> Realm :: t() | no_return().

update(#realm{uri = ?CONTROL_REALM_URI}, _) ->
    error(badarg);
update(#realm{uri = ?MASTER_REALM_URI} = Realm, Data0) ->
    Data = maps_utils:validate(Data0, ?MASTER_REALM_UPDATE_VALIDATOR),
    do_update(Realm, Data, #{});
update(#realm{} = Realm, Data0) ->
    Data = validate(Data0, ?REALM_UPDATE_VALIDATOR),
    do_update(Realm, Data, #{});
update(Uri, Data) when is_binary(Uri) ->
    update(fetch(Uri), Data).

-spec delete(t() | uri()) ->
    ok | {error, not_found | active_users} | no_return().

delete(Term) ->
    delete(Term, #{force => false}).

-doc """
Deletes the realm and all its associated resources in case the realm
has no users or the option `force` was passed with a value of `true`.
Calls close/2 which amongst other cleanup tasks should
kick out all opened sessions attached to the realm.
""".
-spec delete(t() | uri(), delete_opts()) ->
    ok | {error, not_found | active_users} | no_return().

delete(#realm{uri = Uri} = Realm, Opts0) ->
    %% TODO What is this is master realm? or prototype? or SSO?

    %% Cannot delete master and internal realms
    Uri =/= ?MASTER_REALM_URI andalso
        Uri =/= ?CONTROL_REALM_URI orelse
        error(badarg),

    Opts = maps_utils:validate(Opts0, ?DELETE_OPTS),
    Force = maps:get(force, Opts, false),

    case bondy_rbac_user:list(Uri, #{limit => 1}) of
        {L, _Cont} when length(L) > 0 andalso Force == false ->
            %% If there are users in the realm, the caller will need to first
            %% explicitly delete the users
            {error, active_users};
        _ ->
            %% Prevent new connections
            _ = suspend(Realm),

            %% We kick out all the local sessions
            %% Tell the local manager so that if can kick out the session and
            %% perform any other cleanup task. This is performed async.
            ok = close(Uri, ?WAMP_CLOSE_REALM),

            %% We synchronously delete the realm.
            %% This will be replicated and each node will handle the update
            %% (via an AAE exchange, once db.aae lands) and close the realm.
            ok = bondy_db:apply(table(), ?REALM_BAND, Uri, clear),

            %% We notify
            ok = on_delete(Uri),

            %% We order the removal of all associated data
            Work = fun() ->
                Opts1 = Opts0#{dirty => true},

                ok = bondy_rbac:remove_all(Uri, Opts1),

                %% Delete all tickets
                ok = bondy_ticket:revoke_all(Uri),

                %% TODO Delete all tokens

                %% Delete all sources
                bondy_rbac_source:remove_all(Uri),

                %% Delete all groups
                bondy_rbac_group:remove_all(Uri, Opts1),

                %% Delete all users
                bondy_rbac_user:remove_all(Uri, Opts1),

                ok
            end,

            case bondy_router_worker:cast(Work) of
                ok ->
                    ok;
                {error, Reason} = Error ->
                    ?LOG_ERROR(#{
                        description =>
                            "Realm data was not completed deleted. "
                            "Try deleting the realm again later",
                        reason => Reason
                    }),
                    Error
            end
    end;
delete(Uri, Opts) when is_binary(Uri) ->
    resulto:then(
        lookup(Uri),
        fun(#realm{} = Realm) -> delete(Realm, Opts) end
    ).

-doc """
Loads a security config file from
`bondy_config:get([security, config_file])` if defined and applies its
definitions.
""".
-spec apply_config() -> ok | no_return().

apply_config() ->
    case bondy_config:get([security, config_file], undefined) of
        undefined ->
            ok;
        Filename ->
            %% Apply the security config declaratively. Each object is written
            %% with `bondy_db:reconcile` (an idempotent set), so re-applying the
            %% unchanged file on every boot emits NO operations and never
            %% perturbs cross-node convergence — the op-based CRDT + anti-entropy
            %% reconcile multi-node writes, so plum_db's deterministic-version
            %% "rebase" hack is obsolete. The `declarative` flag carries that
            %% intent: overwrite-if-present and skip the runtime lifecycle
            %% side-effects. (Idempotency relies on each object being
            %% deterministic across nodes/boots; see `validate_rbac_config` for
            %% the deterministic password salt.)
            from_file(Filename, #{declarative => true})
    end.

-doc "Loads a security config file from `Filename`.".
-spec from_file(Filename :: file:filename_all()) -> ok | no_return().

from_file(Filename) ->
    from_file(Filename, #{}).

-doc "Loads a security config file from `Filename`.".
-spec from_file(Filename :: file:filename_all(), #{declarative => boolean()}) ->
    ok | no_return().

from_file(Filename, Opts) ->
    case bondy_utils:json_consult(Filename) of
        {ok, Realms} ->
            %% Because realms can have the sso_realm_uri and prototype
            %% properties which point to other realms, we need to ensure all
            %% realms in the file are processed based on a precedence graph, so
            %% that SSO and prototype realms are created before the realms
            %% targeting them.
            SortedRealms = topsort(Realms),

            Uris = [Uri || #{<<"uri">> := Uri} <- SortedRealms],
            Len = length(Uris),

            Details =
                case Len > 3 of
                    true ->
                        [A, B, C | _] = Uris,
                        Prefix = binary_utils:join([A, B, C], <<", ">>),
                        <<Prefix/binary, "...">>;
                    false ->
                        binary_utils:join([<<"a">>, <<"b">>], <<", ">>)
                end,

            ?LOG_INFO(#{
                description => "Loading configuration file",
                filename => Filename,
                summary => Details,
                realm_count => Len
            }),

            %% We add the realm and allow an update if it
            %% already exists by setting IsStrict argument
            %% to false
            _ = [add_or_update(Data, Opts) || Data <- SortedRealms],
            ok;
        {error, enoent} ->
            ?LOG_WARNING(#{
                description => "Error while parsing configuration file",
                filename => Filename,
                reason => file:format_error(enoent)
            }),
            ok;
        {error, Reason} ->
            ?LOG_WARNING(#{
                description => "Error while parsing configuration file",
                filename => Filename,
                reason => Reason
            }),
            error(invalid_config)
    end.

-spec list() -> [t()].

list() ->
    %% The realm table is a global registry under one band, so a single
    %% `list/2` scatter-scans every realm across all shards.
    {ok, Rows} = bondy_db:list(table(), ?REALM_BAND),
    [from_term(V) || {_K, V, _Hlc} <- Rows, is_tuple(V)].

-doc "Returns the external map representation of the realm.".
-spec to_external(t() | uri()) -> external().

to_external(#realm{} = R) ->
    Map = #{
        uri => R#realm.uri,
        description => R#realm.description,
        is_prototype => R#realm.is_prototype,
        prototype_uri => R#realm.prototype_uri,
        is_sso_realm => R#realm.is_sso_realm,
        sso_realm_uri => R#realm.sso_realm_uri,
        allow_connections => R#realm.allow_connections,
        authmethods => R#realm.authmethods,
        password_opts => R#realm.password_opts,
        security_status => security_status(R),
        public_keys => [
            begin
                {_, Map} = jose_jwk:to_map(K),
                Map
            end
         || {_, K} <- maps:to_list(R#realm.public_keys)
        ]
    },
    maps:filter(fun(_, V) -> V =/= undefined end, Map);
to_external(RealmUri) ->
    to_external(fetch(RealmUri)).

-doc """
A temporary hack to prevent keys being synced with an Edge router. We
will use this until be implement partial replication and decide on Key
management strategies.
""".
-spec strip_private_keys(t()) -> t().

strip_private_keys(#realm{} = R) ->
    R#realm{private_keys = undefined}.

%% =============================================================================
%% AUTHZ
%% =============================================================================

-doc """
Returns the list of users belonging to realm `Realm`.
Users are never inherited through prototypes.
""".
-spec users(Realm :: t() | uri()) -> list(bondy_rbac_user:t()).

users(Realm) ->
    users(Realm, #{}).

-doc """
Returns the list of users belonging to realm `Realm`.
Users are never inherited through prototypes.
""".
-spec users(Realm :: t() | uri(), Opts :: map()) -> list(bondy_rbac_user:t()).

users(#realm{uri = Uri}, Opts) ->
    %% TODO change this with continuation return
    bondy_rbac_user:list(Uri, Opts);
users(Uri, Opts) when is_binary(Uri) ->
    users(fetch(Uri), Opts).

-doc """
Returns the list of users belonging to realm `Realm`.
These includes the groups inherited from the prototype (if defined).
""".
-spec groups(Realm :: t() | uri()) -> list(bondy_rbac_user:t()).

groups(Realm) ->
    groups(Realm, #{}).

-doc """
Returns the list of groups belonging to realm `Realm`.
These includes the groups inherited from the prototype (if defined).
""".
-spec groups(Realm :: t() | uri(), Opts :: map()) -> list(bondy_rbac_user:t()).

groups(#realm{uri = Uri}, Opts) ->
    %% TODO change this with continuation return
    bondy_rbac_group:list(Uri, Opts);
groups(Uri, Opts) when is_binary(Uri) ->
    groups(fetch(Uri), Opts).

-doc """
Returns the list of sources belonging to realm `Realm`.
These includes the sources inherited from the prototype (if defined).
""".
-spec sources(Realm :: t() | uri()) -> list(bondy_rbac_user:t()).

sources(Realm) ->
    sources(Realm, #{}).

-doc """
Returns the list of sources belonging to realm `Realm`.
These includes the sources inherited from the prototype (if defined).
""".
-spec sources(Realm :: t() | uri(), Opts :: map()) -> list(bondy_rbac_user:t()).

sources(#realm{uri = Uri}, Opts) ->
    %% TODO change this with continuation return
    bondy_rbac_source:list(Uri, Opts);
sources(Uri, Opts) when is_binary(Uri) ->
    sources(fetch(Uri), Opts).

-doc """
Returns the list of grants belonging to realm `Realm`.
These includes the grants inherited from the prototype (if defined).
""".
-spec grants(Realm :: t() | uri()) -> list(bondy_rbac_user:t()).

grants(Realm) ->
    grants(Realm, #{}).

-doc """
Returns the list of grants belonging to realm `Realm`.
These includes the grants inherited from the prototype (if defined).
""".
-spec grants(Realm :: t() | uri(), Opts :: map()) ->
    [{{binary(), {binary(), binary()}}, [binary()]}].

grants(#realm{uri = Uri}, Opts) ->
    %% TODO change this with continuation return
    bondy_rbac:grants(Uri, Opts);
grants(Uri, Opts) when is_binary(Uri) ->
    grants(fetch(Uri), Opts).

%% =============================================================================
%% PRIVATE
%% =============================================================================
%%
%% The realm table has no prefix callbacks. The LOCAL lifecycle is the inline
%% `on_create/1`/`on_update/1`/`on_delete/1` notifications fired from the
%% create/update/delete paths. The REMOTE side-effect — close all sessions when
%% a peer deletes the realm via anti-entropy — is the `publish => true` /
%% `bondy_aae_reactor:react_realm/2` seam (see `bondy_namespace_catalog`),
%% exactly as the user on_merge works.

%% @private
add_master_realm() ->
    Data0 = inject_master_admin_password(?MASTER_REALM),
    Data = validate(Data0, ?MASTER_REALM_VALIDATOR),
    do_create(Data, #{declarative => true}).

%% @private
%% The master-realm 'admin' user ships WITHOUT a password (D-1: no hardcoded
%% default credential). Resolve it at first-boot creation: prefer the
%% operator-configured `security.admin_user.password`; otherwise generate a
%% random one and log it ONCE at notice level so the operator can capture it.
%% NOTE: a generated password is per-node — for a MULTI-NODE cluster operators
%% MUST set `security.admin_user.password` identically on every node so the
%% deterministically-salted admin user cell (see validate_rbac_config/2)
%% converges instead of diverging under anti-entropy.
inject_master_admin_password(#{users := Users} = Data) ->
    Password = resolve_master_admin_password(),
    NewUsers = [
        case User of
            #{username := <<"admin">>} -> User#{password => Password};
            _ -> User
        end
     || User <- Users
    ],
    Data#{users => NewUsers};
inject_master_admin_password(Data) ->
    Data.

%% @private
resolve_master_admin_password() ->
    case bondy_config:get([security, admin_user, password], undefined) of
        Configured when is_binary(Configured) andalso Configured =/= <<>> ->
            Configured;
        Configured when is_list(Configured) andalso Configured =/= [] ->
            list_to_binary(Configured);
        _ ->
            Password = base64:encode(crypto:strong_rand_bytes(18)),
            ?LOG_NOTICE(#{
                description =>
                    "No admin password configured for the master realm; a random "
                    "one was generated for the 'admin' user. Record it now (shown "
                    "only once) or set 'security.admin_user.password'. For a "
                    "multi-node cluster you MUST configure it identically on every "
                    "node.",
                realm => ?MASTER_REALM_URI,
                username => <<"admin">>,
                generated_password => Password
            }),
            Password
    end.

-doc """
Idempotent one-shot hardening of an ALREADY-STORED master realm (D-1/D-2), for
installations provisioned before the master-realm hardening. Fresh installs
create the master realm already hardened, so this is a no-op for them. Called at
boot (see `bondy_app`) after the master realm is guaranteed to exist. Guarded so
a failure can never crash boot.
""".
-spec harden_master_realm() -> ok.

harden_master_realm() ->
    try
        Realm = fetch(?MASTER_REALM_URI),
        %% Only remediate a LEGACY master realm — presence of the anonymous
        %% authmethod is the marker. This keeps the migration a true no-op (no
        %% writes, no log noise) on fresh / already-hardened installs.
        case lists:member(?WAMP_ANON_AUTH, authmethods(Realm)) of
            true ->
                ok = remediate_legacy_anon(Realm);
            false ->
                ok
        end,
        %% The password warning runs every boot (until rotated), independently of
        %% the anonymous remediation.
        ok = maybe_warn_legacy_admin_password(Realm)
    catch
        Class:Reason:Stacktrace ->
            ?LOG_WARNING(#{
                description =>
                    "Master realm hardening migration failed; continuing boot. "
                    "Review the master realm's security configuration manually.",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            })
    end,
    ok.

%% @private
%% Remediate a legacy (pre-hardening) master realm (D-2): remove the anonymous
%% authmethod and revoke the anonymous wamp.* grant. Removing the authmethod alone
%% already blocks anonymous sessions; the grant revoke is defence in depth and is
%% guarded so an RBAC quirk (e.g. anonymous role handling) cannot fail the whole
%% migration.
remediate_legacy_anon(#realm{uri = Uri} = Realm) ->
    NewMethods = authmethods(Realm) -- [?WAMP_ANON_AUTH],
    _ = update(Uri, #{<<"authmethods">> => NewMethods}),
    ?LOG_WARNING(#{
        description =>
            "Master realm hardening (D-2): removed anonymous authentication from "
            "the master realm. Anonymous clients can no longer connect to the "
            "administrative control plane.",
        realm => Uri
    }),
    Request = #{
        roles => [?WAMP_ANON_AUTH],
        permissions => [
            <<"wamp.call">>,
            <<"wamp.cancel">>,
            <<"wamp.subscribe">>,
            <<"wamp.unsubscribe">>
        ],
        uri => <<"">>,
        match => <<"prefix">>
    },
    try bondy_rbac:revoke(Uri, Request) of
        ok ->
            ?LOG_WARNING(#{
                description =>
                    "Master realm hardening (D-2): revoked the anonymous wamp.* "
                    "grant on the master realm.",
                realm => Uri
            });
        {error, Reason} ->
            ?LOG_WARNING(#{
                description =>
                    "Master realm hardening (D-2): could not auto-revoke the "
                    "anonymous master-realm grant; remove it manually.",
                realm => Uri,
                reason => Reason
            })
    catch
        _:CatchReason ->
            ?LOG_WARNING(#{
                description =>
                    "Master realm hardening (D-2): could not auto-revoke the "
                    "anonymous master-realm grant; remove it manually.",
                realm => Uri,
                reason => CatchReason
            })
    end,
    ok.

%% @private
maybe_warn_legacy_admin_password(#realm{uri = Uri}) ->
    case bondy_rbac_user:lookup(Uri, <<"admin">>) of
        {ok, User} ->
            case bondy_rbac_user:password(User) of
                undefined ->
                    ok;
                PW ->
                    case bondy_password:verify_string(<<"bondy-admin">>, PW) of
                        true ->
                            ?LOG_WARNING(#{
                                description =>
                                    "The master realm 'admin' user still uses the "
                                    "legacy default password 'bondy-admin' (D-1). "
                                    "Rotate it immediately via "
                                    "'security.admin_user.password' or the admin "
                                    "API.",
                                realm => Uri,
                                username => <<"admin">>
                            }),
                            ok;
                        false ->
                            ok
                    end
            end;
        _ ->
            ok
    end.

%% @private
validate(Map0, Spec) ->
    Map = maps_utils:validate(Map0, Spec),

    %% Preconditions

    IsProto = maps:get(is_prototype, Map, false),
    Proto = maps:get(prototype_uri, Map, undefined),

    ok =
        case {IsProto, Proto} of
            {true, undefined} ->
                ok;
            {true, _} ->
                error({inconsistency_error, [is_prototype, prototype_uri]});
            _ ->
                ok
        end,

    IsSSORealm = maps:get(is_sso_realm, Map, false),
    SSORealm = maps:get(sso_realm_uri, Map, undefined),

    ok =
        case {IsSSORealm, SSORealm} of
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

    PassOpts0 = password_opts(Realm),
    Len = 16,

    Users = [
        %% The following is not ideal but users shouldn't be providing
        %% passwords on the security configuration file anyway, instead they
        %% should be using Cryptosign for static users.
        %% TODO Review the idea of banning the creation of static users w/
        %% passwords altogether.

        %% A DETERMINISTIC salt (derived from the module hash, not a random
        %% one) so the salted password — and therefore the whole user object —
        %% is byte-identical on every node and every boot. That determinism is
        %% what lets the declarative config apply be idempotent: `store` uses
        %% `bondy_db:reconcile`, which re-writes the cell only when the value
        %% actually changes, so re-reading the same config file at boot emits no
        %% operations and never diverges cross-node convergence. (Assumes
        %% every node uses the same configuration file and build.)
        begin
            Secret = module_info(md5),
            Bin = term_to_binary(data, [deterministic]),
            Salt = crypto:macN(hmac, sha, Secret, Bin, Len),
            PassOpts = key_value:put([params, salt], Salt, PassOpts0),
            bondy_rbac_user:new(Data, #{password_opts => PassOpts})
        end
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
    %% We do this to override the config default protocol
    case lists:member(?WAMP_SCRAM_AUTH, Methods) of
        true -> bondy_password:default_opts(scram);
        false -> bondy_password:default_opts()
    end.

%% @private
apply_rbac_config(#realm{uri = Uri}, Map, Opts) ->
    #{
        groups := Groups,
        users := Users,
        sources := SourcesAssignments,
        grants := Grants
    } = Map,

    _ = [
        ok = maybe_error(
            bondy_rbac_group:add(Uri, Group, Opts), Uri
        )
     || Group <- Groups
    ],

    _ = [
        ok = maybe_error(
            bondy_rbac_user:add(
                Uri,
                User,
                Opts#{update_credentials => true, forward_credentials => true}
            ),
            Uri
        )
     || User <- Users
    ],

    _ = [
        ok = maybe_error(bondy_rbac_source:add(Uri, Assignment, Opts), Uri)
     || Assignment <- SourcesAssignments
    ],

    _ = [
        ok = maybe_error(bondy_rbac:grant(Uri, Grant, Opts), Uri)
     || Grant <- Grants
    ],

    ok.

%% @private
maybe_error({error, Reason}, Uri) ->
    error({Reason, Uri});
maybe_error({ok, _}, _) ->
    ok;
maybe_error(ok, _) ->
    ok.

%% @private
check_is_property(Property) when is_atom(Property) ->
    Props = [is_security_enabled | record_info(fields, realm)],
    lists:member(Property, Props) orelse error(badarg),
    ok;
check_is_property(_) ->
    error(badarg).

%% @private
maybe_create(Uri, Opts) ->
    case bondy_config:get([security, automatically_create_realms]) of
        true ->
            create(Opts#{<<"uri">> => Uri});
        false ->
            {error, not_found}
    end.

%% @private
add_or_update(#{<<"uri">> := Uri} = Data0, Opts) ->
    case lookup(Uri) of
        {ok, #realm{} = Realm} ->
            Data = validate(Data0, ?REALM_UPDATE_VALIDATOR),
            do_update(Realm, Data, Opts);
        {error, not_found} ->
            Data = validate(Data0, ?REALM_VALIDATOR),
            do_create(Data, Opts)
    end.

%% @private
do_create(#{uri := Uri} = Map0, Opts) ->
    Map = maybe_gen_keys(Map0, Opts),
    Realm0 = #realm{uri = Uri},
    Realm = merge_and_store(Realm0, Map, Opts),
    ok = on_create(Realm),
    Realm.

%% @private
%% Decide whether to mint key material eagerly at create time. See the REALM KEY
%% MATERIAL section for the rationale. Eager for an authoritative create (not
%% declarative) or a bootstrapping (solo) node; deferred to lazy generation for
%% a clustered node applying declarative config. A keyset explicitly supplied in
%% the create map is always kept verbatim.
maybe_gen_keys(Map, Opts) ->
    Declarative =
        is_map(Opts) andalso maps:get(declarative, Opts, false) =:= true,
    case (not Declarative) orelse is_solo() of
        true ->
            Map#{
                private_keys => ensure_keys(
                    maps:get(private_keys, Map, []), fun gen_keys/0
                ),
                encryption_keys => ensure_keys(
                    maps:get(encryption_keys, Map, []),
                    fun gen_encryption_keys/0
                )
            };
        false ->
            Map
    end.

%% @private
ensure_keys([], Gen) -> Gen();
ensure_keys(Keys, _) -> Keys.

%% @private
%% True only for a deployment that never had a peer (a bootstrapping single
%% node). `partisan_peer_service:members/0` lists the full known membership
%% (including currently-unreachable peers), so a clustered node — even when
%% partitioned — is not solo. On any error (e.g. queried before Partisan is
%% ready) we answer `false` and defer to lazy generation, which is always safe.
is_solo() ->
    case partisan_peer_service:members() of
        {ok, Members} when is_list(Members) -> length(Members) =< 1;
        _ -> false
    end.

%% @private
-spec do_lookup(uri()) -> {ok, t()} | {error, not_found}.

do_lookup(Uri) ->
    case do_get(Uri) of
        #realm{} = Realm ->
            {ok, Realm};
        undefined ->
            {error, not_found};
        Term ->
            try
                Realm = from_term(Term),
                ok = store(Uri, Realm),
                ok = store_keys(Uri, Realm),
                {ok, Realm}
            catch
                throw:badarg ->
                    ?LOG_WARNING(#{
                        description => "Invalid data retrieved from store",
                        data => Term
                    }),
                    {error, not_found}
            end
    end.

%% @private
%% The open bondy_db `bondy_realm` table handle. Raises if the catalogue has not
%% provisioned it yet.
table() ->
    case bondy_namespace_catalog:table(?BONDY_DB_REALM_TAB) of
        undefined ->
            error(bondy_realm_table_unavailable);
        Table ->
            Table
    end.

%% @private
%% Reads the realm record (or a legacy term, migrated by `do_lookup`), or
%% `undefined`. Key material lives in the separate `bondy_realm_keys` cell (it
%% is NOT part of the realm's bondy_db identity), so a `#realm{}` read merges it
%% back in from there; legacy terms are returned as-is for `do_lookup` to
%% migrate.
do_get(Uri) ->
    case bondy_db:read(table(), ?REALM_BAND, Uri) of
        {ok, {#realm{} = Realm, _Hlc}} ->
            merge_keys(Realm, read_keys(Uri));
        {ok, {Value, _Hlc}} ->
            Value;
        {error, not_found} ->
            undefined
    end.

%% @private
do_update(Realm0, Map, Opts) ->
    Realm = merge_and_store(Realm0, Map, Opts),
    ok = on_update(Realm),
    Realm.

%% @private
merge_and_store(Realm0, Map, Opts) ->
    Realm = maps:fold(fun fold_props/3, Realm0, Map),

    ok = check_integrity_constraints(Realm),

    %% We are going to call new on the respective modules so that we validate
    %% the data. This way we avoid adding anything to the database until all
    %% elements have been validated.
    RBACConfig = validate_rbac_config(Realm, Map),

    %% We then create the realm
    Uri = Realm#realm.uri,

    %% Identity/config cell (key material stripped) + the separate key cell.
    ok = store(Uri, Realm),
    ok = store_keys(Uri, Realm),

    %% We finally apply all the RBAC objects that have been validated
    %% but for them we do use the Opts as we received it (potentially the
    %% `declarative` config-apply flag).
    ok = apply_rbac_config(Realm, RBACConfig, Opts),

    Realm.

%% @private
%% Writes the realm IDENTITY record (key material stripped) to the global band
%% keyed by its Uri. The realm's bondy_db identity — and therefore its cross-node
%% convergence — is its Uri + config, NEVER the random signing/encryption keys,
%% which live in their own `bondy_realm_keys` cell (`store_keys/2`). Idempotent: a
%% write is emitted only when the stored record actually changes, so re-applying
%% the config file on every boot does not re-stamp the cell with a fresh HLC
%% (which would diverge convergence cross-node). Convergence is
%% handled by the op-based CRDT + anti-entropy; no deterministic-version rebase
%% is needed.
store(Uri, Realm) ->
    case bondy_db:reconcile(table(), ?REALM_BAND, Uri, strip_keys(Realm)) of
        ok ->
            ok;
        {error, Reason} ->
            throw(Reason)
    end.

%% =============================================================================
%% PRIVATE: REALM KEY MATERIAL (separate `bondy_realm_keys` cell)
%% =============================================================================
%% The realm's signing/encryption keys are random per generation, so they must
%% NOT be part of the realm's bondy_db identity (the identity cell + its cross-node
%% convergence must be Uri + config, deterministic across nodes). They live in their
%% own `bondy_realm_keys` cell, an add-wins map of `kid => key bundle` keyed by
%% the realm Uri. Add-wins means concurrent rotations — each minting a fresh
%% kid — merge to the UNION on every node, so the keys converge (and an imported
%% realm's keys are preserved) without a deterministic-version write.
%%
%% Key generation is gated so that the add-wins union does not accumulate a
%% redundant set per node (`maybe_gen_keys/2`):
%%
%%   * An AUTHORITATIVE create — a non-declarative `create/1` (API) — generates
%%     eagerly. It has a single creator node, so the keys are written once and
%%     propagate to peers via anti-entropy before any token is issued; this is
%%     what makes cross-node JWT verification of the first token reliable.
%%   * A BOOTSTRAPPING node (solo Partisan membership) also generates eagerly,
%%     even for declarative config-declared realms: it is the authoritative
%%     origin of those realms, so it mints their keys early for peers to inherit.
%%   * A node applying DECLARATIVE config while part of a cluster (a joiner, or a
%%     node re-reading the config file at boot) DEFERS: it creates the realm
%%     key-free and inherits the cluster's keys via anti-entropy, so joiners do
%%     not each mint a redundant set.
%%
%% Whatever is deferred is still covered by LAZY generation on first use (the
%% empty-keyset clauses in `private_keys/1`, `encryption_keys/1`,
%% `get_random_kid/1`, `get_random_private_key/1`, `get_random_encryption_kid/1`),
%% so a realm is never stuck without keys: a node that genuinely needs a key
%% before anti-entropy delivers one mints its own (union-merged). There is no
%% precise bootstrap-vs-join detection (boot-time membership is racy and Bondy
%% joins via dynamic peer discovery); the solo check plus the declarative flag
%% plus lazy fallback together keep the common case at exactly one keyset.

%% @private
%% The open `bondy_realm_keys` table handle. Raises if the catalogue has not
%% provisioned it yet.
keys_table() ->
    case bondy_namespace_catalog:table(?BONDY_DB_REALM_KEYS_TAB) of
        undefined ->
            error(bondy_realm_keys_table_unavailable);
        Table ->
            Table
    end.

%% @private
%% Empty ALL key material from the realm record — the value stored in the
%% identity cell. Keys are persisted separately by `store_keys/2`.
strip_keys(#realm{} = R) ->
    R#realm{private_keys = #{}, public_keys = #{}, encryption_keys = #{}}.

%% @private
%% Decompose a realm's key maps into `bondy_realm_keys` entries, one per `kid`:
%% a signing kid carries `{private, public}`, an encryption kid `{encryption}`.
%% The stored JWK values are carried verbatim (no re-encode) so a read merges
%% them back byte-identical.
keys_to_entries(#realm{
    private_keys = Priv0, public_keys = Pub, encryption_keys = Enc
}) ->
    Priv =
        case Priv0 of
            undefined -> #{};
            _ -> Priv0
        end,
    Signing = [
        {Kid, #{private => maps:get(Kid, Priv, undefined), public => P}}
     || {Kid, P} <- maps:to_list(Pub)
    ],
    Encryption = [
        {Kid, #{encryption => E}}
     || {Kid, E} <- maps:to_list(Enc)
    ],
    maps:from_list(Signing ++ Encryption).

%% @private
%% Rebuild a realm's key maps from the `bondy_realm_keys` aw-map value
%% (`#{kid => [Bundle]}`; distinct kids per rotation ⇒ each list is a singleton).
%% When the keys cell is EMPTY, the identity record's own keys are kept untouched
%% — this preserves a pre-split realm whose keys still live in the identity cell
%% (migrated to the keys cell on its next store), and a brand-new realm read
%% before its keys cell write lands. Only a populated keys cell is authoritative.
merge_keys(#realm{uri = Uri} = R, KeysMap) when map_size(KeysMap) > 0 ->
    {Priv, Pub, Enc} = maps:fold(
        fun(Kid, Bundles, Acc) -> fold_key_entry(Uri, Kid, Bundles, Acc) end,
        {#{}, #{}, #{}},
        KeysMap
    ),
    R#realm{private_keys = Priv, public_keys = Pub, encryption_keys = Enc};
merge_keys(#realm{} = R, _Empty) ->
    R.

%% @private
fold_key_entry(Uri, Kid, Bundles, {P, Pu, E}) ->
    %% Decrypt any at-rest-encrypted sensitive fields back to plaintext JWKs.
    case decrypt_bundle(Uri, Kid, bundle_of(Bundles)) of
        #{encryption := EncK} ->
            {P, Pu, E#{Kid => EncK}};
        #{public := PubK} = B ->
            P1 =
                case maps:get(private, B, undefined) of
                    undefined -> P;
                    PrivK -> P#{Kid => PrivK}
                end,
            {P1, Pu#{Kid => PubK}, E};
        _ ->
            {P, Pu, E}
    end.

%% =============================================================================
%% PRIVATE: REALM KEY AT-REST ENCRYPTION (S-2)
%% =============================================================================

%% @private
%% Encrypt the sensitive fields (`private`, `encryption`) of a bundle when the
%% keyring is enabled; otherwise return it unchanged (plaintext, legacy layout).
maybe_encrypt_bundle(_Uri, _Kid, Bundle, false) ->
    Bundle;
maybe_encrypt_bundle(Uri, Kid, Bundle, true) ->
    maps:map(
        fun(Field, V) ->
            case lists:member(Field, ?SENSITIVE_KEY_FIELDS) of
                true -> encrypt_field(Uri, Kid, Field, V);
                false -> V
            end
        end,
        Bundle
    ).

%% @private
encrypt_field(_Uri, _Kid, _Field, undefined) ->
    undefined;
encrypt_field(_Uri, _Kid, _Field, {?ENC_TAG, _} = Already) ->
    Already;
encrypt_field(Uri, Kid, Field, V) ->
    Envelope = bondy_keyring:seal(term_to_binary(V), key_aad(Uri, Kid, Field)),
    {?ENC_TAG, Envelope}.

%% @private
%% Decrypt any `{?ENC_TAG, Envelope}` sensitive fields back to plaintext JWKs;
%% plaintext fields pass through (encryption off / legacy / pre-migration).
decrypt_bundle(Uri, Kid, Bundle) ->
    maps:map(
        fun(Field, V) ->
            case lists:member(Field, ?SENSITIVE_KEY_FIELDS) of
                true -> decrypt_field(Uri, Kid, Field, V);
                false -> V
            end
        end,
        Bundle
    ).

%% @private
decrypt_field(Uri, Kid, Field, {?ENC_TAG, Envelope}) ->
    case bondy_keyring:open(Envelope, key_aad(Uri, Kid, Field)) of
        {ok, Bin} ->
            %% The plaintext is AES-256-GCM authenticated (we produced it), so
            %% `[safe]` is belt-and-suspenders over already-trusted bytes.
            binary_to_term(Bin, [safe]);
        {error, Reason} ->
            error({realm_key_decrypt_failed, Uri, Kid, Field, Reason})
    end;
decrypt_field(_Uri, _Kid, _Field, V) ->
    V.

%% @private
%% A bundle is plaintext iff none of its sensitive fields carries the encryption
%% marker. Drives the one-time plaintext → ciphertext migration in `store_keys`.
is_plaintext_bundle(Bundle) ->
    not lists:any(
        fun(Field) ->
            case maps:get(Field, Bundle, undefined) of
                {?ENC_TAG, _} -> true;
                _ -> false
            end
        end,
        ?SENSITIVE_KEY_FIELDS
    ).

%% @private
%% Additional Authenticated Data binds an envelope to its (realm, kid, field) so
%% it cannot be lifted into another slot.
key_aad(Uri, Kid, Field) ->
    <<Uri/binary, 0, Kid/binary, 0, (atom_to_binary(Field, utf8))/binary>>.

%% @private
%% An aw-map value is a sibling list; rotations use distinct kids so it is a
%% singleton. Tolerate a bare map for forward-compatibility.
bundle_of([B | _]) -> B;
bundle_of(B) when is_map(B) -> B.

%% @private
%% Read the realm's key material from its `bondy_realm_keys` cell, or `#{}` when
%% absent (keys arrive via creation, rotation, or anti-entropy).
read_keys(Uri) ->
    case bondy_db:read(keys_table(), ?REALM_BAND, Uri) of
        {ok, {KeysMap, _Hlc}} when is_map(KeysMap) ->
            KeysMap;
        {error, not_found} ->
            #{}
    end.

%% @private
%% Persist the realm's key material to its `bondy_realm_keys` cell, idempotently:
%% `put` only the kids whose bundle is new or changed, `rmv` kids that are gone
%% (revoked). Because it is called from `merge_and_store/3` (every create /
%% update / lazy key generation), the idempotent diff keeps re-applying config
%% from churning the keys cell — only a genuine key change emits an op.
store_keys(Uri, #realm{} = Realm) ->
    Desired = keys_to_entries(Realm),
    Current = read_keys(Uri),
    Table = keys_table(),
    Enabled = bondy_keyring:is_enabled(),
    %% Add / update changed or new kids. The idempotence check compares the
    %% LOGICAL (decrypted) bundle, not the stored bytes — at-rest encryption uses
    %% a fresh random IV per write, so ciphertext is never byte-stable and a
    %% byte comparison would re-stamp the cell on every boot (and diverge the
    %% aw-map cross-node). A stored *plaintext* bundle is additionally re-written
    %% once when encryption is enabled, to migrate it to ciphertext.
    ok = maps:foreach(
        fun(Kid, Desired0) ->
            Stored = current_bundle(Current, Kid),
            case key_needs_write(Uri, Kid, Desired0, Stored, Enabled) of
                true ->
                    Bundle = maybe_encrypt_bundle(Uri, Kid, Desired0, Enabled),
                    aw_apply(Table, Uri, {put, Kid, Bundle});
                false ->
                    ok
            end
        end,
        Desired
    ),
    %% Remove kids no longer present (revoked).
    _ = [
        aw_apply(Table, Uri, {rmv, Kid})
     || Kid <- maps:keys(Current),
        not maps:is_key(Kid, Desired)
    ],
    ok.

%% @private
%% Decide whether the stored bundle for `Kid` must be (re)written. `Stored` is
%% the raw (possibly encrypted) bundle, or `undefined` when absent.
key_needs_write(_Uri, _Kid, _Desired, undefined, _Enabled) ->
    true;
key_needs_write(Uri, Kid, Desired, Stored, Enabled) ->
    decrypt_bundle(Uri, Kid, Stored) =/= Desired orelse
        (Enabled andalso is_plaintext_bundle(Stored)).

%% @private
current_bundle(Current, Kid) ->
    case maps:get(Kid, Current, undefined) of
        undefined -> undefined;
        Bundles -> bundle_of(Bundles)
    end.

%% @private
aw_apply(Table, Uri, Op) ->
    case bondy_db:apply(Table, ?REALM_BAND, Uri, Op) of
        ok -> ok;
        {error, Reason} -> throw(Reason)
    end.

-doc """
Split a realm value for import. Returns `{Identity, KeyEntries}` where `Identity`
is the realm record with key material stripped (the value for the `bondy_realm`
identity cell) and `KeyEntries` is `[{Kid, Bundle}]` for the `bondy_realm_keys`
cell.

A post-split backup's realm record is already key-stripped, so `KeyEntries` is
empty and the keys arrive via their own `bondy_realm_keys` entries. A pre-split
(or legacy) backup carries the keys inside the realm record; they are extracted
here so the imported realm lands in the split layout (identity cell key-free,
keys in the aw-map cell) rather than re-introducing key bytes into the identity.
""".
-spec split_for_import(t() | term()) -> {term(), [{binary(), map()}]}.

split_for_import(#realm{} = R) ->
    {strip_keys(R), maps:to_list(keys_to_entries(R))};
split_for_import(Term) ->
    try from_term(Term) of
        #realm{} = R -> split_for_import(R);
        _ -> {Term, []}
    catch
        _:_ -> {Term, []}
    end.

-doc """
Translate a `bondy_realm_keys` cell's exported value (the materialized aw-map
`#{kid => [Bundle]}`) into `[{Kid, Bundle}]` for re-application as `{put, Kid,
Bundle}` ops on import — an aw-map cannot be restored with a `{set, _}`.
""".
-spec keys_value_to_entries(map() | term()) -> [{binary(), map()}].

keys_value_to_entries(Map) when is_map(Map) ->
    [{Kid, bundle_of(Bundles)} || {Kid, Bundles} <- maps:to_list(Map)];
keys_value_to_entries(_) ->
    [].

%% @private
fold_props(allow_connections, V, Realm) ->
    Realm#realm{allow_connections = V};
fold_props(authmethods, V, Realm0) ->
    Realm = Realm0#realm{authmethods = V},
    %% We get opts by calling the authmethods function which inherits the value
    %% from the prototype
    Opts = get_password_opts(authmethods(Realm)),
    Realm#realm{password_opts = Opts};
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
                "once it has been set to 'true'."
            >>
        }
    );
fold_props(prototype_uri, V, #realm{prototype_uri = undefined} = Realm) ->
    Realm#realm{prototype_uri = V};
fold_props(prototype_uri, V1, #realm{prototype_uri = V0}) when
    V0 =/= V1
->
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
                "once it has been set to 'true'."
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
fold_props(info, V, Realm) ->
    Realm#realm{info = V};
fold_props(_, _, Realm) ->
    %% We ignote the rest of the properties.
    %% They will be handled separately.
    Realm.

%% @private
%% The metric aggregate rides telemetry; the gen_event notification
%% remains for the WAMP meta-event publisher.
on_create(Realm) ->
    ok = bondy_telemetry:realm_event(created, Realm#realm.uri),
    bondy_event_manager:notify({[bondy, realm, created], Realm#realm.uri}).

%% @private
on_update(Realm) ->
    ok = bondy_telemetry:realm_event(updated, Realm#realm.uri),
    bondy_event_manager:notify({[bondy, realm, updated], Realm#realm.uri}).

%% @private
on_delete(Uri) ->
    ok = bondy_telemetry:realm_event(deleted, Uri),
    bondy_event_manager:notify({[bondy, realm, deleted], Uri}).

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
        end
     || Key <- New
    ]).

%% private
%% An empty key list is accepted as-is: signing keys are generated lazily on
%% first use, not eagerly at create time (see the REALM KEY MATERIAL section).
validate_keys([]) ->
    {ok, []};
validate_keys(L) when is_list(L) ->
    do_validate_keys(L);
validate_keys(_) ->
    false.

%% @private
-doc "This updates the realm and stores it.".
init_keys(Realm) ->
    Data = #{private_keys => gen_keys()},
    merge_and_store(Realm, Data, #{}).

%% @private
%% We generate the keys for signing
gen_keys() ->
    [
        jose_jwk:generate_key({namedCurve, secp256r1})
     || _ <- lists:seq(1, 3)
    ].

%% private
%% An empty key list is accepted as-is: encryption keys are generated lazily on
%% first use, not eagerly at create time (see the REALM KEY MATERIAL section).
validate_encryption_keys([]) ->
    {ok, []};
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
                        "Bondy could not compute a precedence graph for the "
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
                %% Bondy could not compute a precedence graph for the realms
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
                        "Bondy could not compute a precedence graph for the "
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
    %% We first add all the realms as vertices in the graph
    Vertices = [
        begin
            R = validate_uris(R0),
            Uri = maps:get(uri, R),
            digraph:add_vertex(Graph, Uri, R)
        end
     || R0 <- Realms
    ],
    precedence_graph_aux(Vertices, Graph).

%% @private
precedence_graph_aux([H | T], Graph) ->
    {H, Realm} = digraph:vertex(Graph, H),

    %% The following cases should be covered:
    %% 1. a prototype realm that has an sso_realm_uri
    %% 2. a realm that has a prototype_uri
    %% 3. a realm that has a sso_realm_uri
    %% 4. a realm that has a prototype_uri and sso_realm_uri
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

%% @private we validate just the URIs that are needed to build the precedence
%% graph
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
        <<"prototype_uri">> => #{
            key => prototype_uri,
            alias => prototype_uri,
            required => false,
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
    #realm{is_sso_realm = true, sso_realm_uri = undefined}, sso
) ->
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
    #realm{is_prototype = true, prototype_uri = undefined}, prototype
) ->
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
    #realm{uri = Uri, prototype_uri = Uri}, prototype
) ->
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
    _ =
        case lookup(Uri) of
            {ok, Realm} when Type == sso ->
                is_sso_realm(Realm) orelse error(badarg(Uri, Type, badtype));
            {ok, Realm} when Type == prototype ->
                is_prototype(Realm) orelse error(badarg(Uri, Type, badtype));
            {error, not_found = Reason} ->
                error(badarg(Uri, Type, Reason))
        end,
    ok.

%% @private
from_term(#realm{} = Realm) ->
    Realm;
from_term(Term) when
    is_tuple(Term), element(1, Term) == realm, tuple_size(Term) == 13
->
    %% 0.9.SNAPSHOT-SSO
    %% -record(realm, {
    %%     [2] uri                      ::  uri(),
    %%     [3] description              ::  binary(),
    %%     [4] authmethods              ::  [binary()],
    %%     [5] security_enabled = true  ::  boolean(),
    %%     [6] is_sso_realm = false     ::  boolean(),
    %%     [7] allow_connections = true ::  boolean(),
    %%     [8] sso_realm_uri            ::  optional(uri()),
    %%     [9] private_keys = #{}       ::  keyset(),
    %%     [10] public_keys = #{}        ::  keyset(),
    %%     [11] password_opts            ::  bondy_password:opts() | undefined,
    %%     [12] encryption_keys = #{}    ::  keyset(),
    %%     [13] info = #{}               ::  map()
    %% }).

    #realm{
        uri = element(2, Term),
        description = element(3, Term),
        is_prototype = false,
        prototype_uri = undefined,
        is_sso_realm = element(6, Term),
        sso_realm_uri = element(8, Term),
        allow_connections = element(7, Term),
        authmethods = element(4, Term),
        security_enabled = element(5, Term),
        password_opts = element(11, Term),
        private_keys = element(9, Term),
        public_keys = element(10, Term),
        encryption_keys = element(12, Term),
        info = element(13, Term)
    };
from_term({realm, Uri, Desc, Authmethods, PrivKeys, PubKeys, PassOpts}) ->
    %% Legacy 7-tuple realm format; effectively dead (current realms
    %% deserialise via the record clause above). Security status used to be
    %% read from the old plum_db `{security_status, Uri}` prefix, now retired —
    %% the live flag is the `security_enabled` record field, defaulting to
    %% `false` here.
    #realm{
        uri = Uri,
        description = Desc,
        is_prototype = false,
        prototype_uri = undefined,
        is_sso_realm = false,
        sso_realm_uri = undefined,
        allow_connections = true,
        authmethods = Authmethods,
        security_enabled = false,
        password_opts = PassOpts,
        private_keys = PrivKeys,
        public_keys = PubKeys,
        encryption_keys = #{},
        info = #{}
    };
from_term(_) ->
    throw(badarg).

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

%% In Erlang 24 Keys have an additional field, so until we have a migration
%% tool we do this lazily
to_private_key(#jose_jwk{kty = {Mod, PK0}} = JWK) when
    element(1, PK0) == 'ECPrivateKey', tuple_size(PK0) == 5
->
    JWK#jose_jwk{kty = {Mod, erlang:append_element(PK0, asn1_NOVALUE)}};
to_private_key(Term) ->
    Term.
