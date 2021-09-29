

# Module bondy_realm #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

Realms are routing and administrative domains and act as namespaces for
all resources in Bondy i.e.

<a name="description"></a>

## Description ##

all users, groups, permissions, registrations
and subscriptions belong to a Realm. Messages and events are routed
separately for each individual realm so sessions attached to a realm won’t
see message and events occurring on another realm.

## Overview

The realm is a central and fundamental concept in Bondy. It does not only
serve as an authentication and authorization domain but also as a message
routing domain. Bondy ensures no messages routed in one realm will leak into
another realm.

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

Realms (and the associated users, credentials, groups, sources and
permissions) are persisted to disk and replicated across the cluster using
the `plum_db` subsystem.

## Bondy Master Realm
When you start Bondy for the first time it creates and stores the Bondy
Master realm a.k.a `com.leapsight.bondy`. This realm is the root realm which
allows an admin user to create, list, modify and delete other realms.

## Realm Properties

* **uri** `uri()` *[required, immutable]* <br />The realm identifier.
* **description** `binary()` <br />A textual description of the realm.
* **is_prototype** `boolean()` *[immutable]*<br />If `true` this realm is a
realm used as a prototype.<br />*Default*: `false`
* **prototype_uri** `uri()` <br />If present, this it the URI of the the realm
prototype this realm inherits some of its behaviour and features from.
* **sso_realm_uri** `uri()` <br />If present, this it the URI of the SSO Realm
this realm is connected to.
* **is_sso_realm** `boolean()` *[immutable]*<br />If `true` this realm is an SSO
Realm.<br />*Default*: `false`.
* **allow_connections** `boolean()` <br />If `true` this realm is allowing
connections from clients. It is normally set to `false` when the realm is an
SSO Realm.<br />Default: `true`
* **authmethods** `list(binary()` <br />The list of the authentication methods
allowed by this realm.<br />*Default*:
`[anonymous, password, ticket, oauth2, wampcra]`
* **security_status** `binary()` <br />The string `enabled` if security is
enabled. Otherwise the string `disabled`.
* **public_keys** `list()` <br />A list of JWK values.

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
prototype when those properties have not been asigned a value. Setting a
value to these properties is equivalente to overriding the prototype's.

* **security_enabled**
* **allow_connections**

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

* It requires the user to authenticate when opening a session in a realm.
* Changing credentials e.g. updating password can be performed while
connected to any realm.
<a name="types"></a>

## Data Types ##


<a name="external()"></a>


### external() ###


<pre><code>
external() = #{uri =&gt; <a href="#type-uri">uri()</a>, is_prototype =&gt; boolean(), prototype_uri =&gt; <a href="#type-maybe">maybe</a>(<a href="#type-uri">uri()</a>), description =&gt; binary(), authmethods =&gt; [binary()], is_sso_realm =&gt; boolean(), allow_connections =&gt; boolean(), public_keys =&gt; [term()], security_status =&gt; enabled | disabled}
</code></pre>


<a name="t()"></a>


### t() ###


__abstract datatype__: `t()`


<a name="functions"></a>

## Function Details ##

<a name="allow_connections-1"></a>

### allow_connections/1 ###

<pre><code>
allow_connections(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; boolean()
</code></pre>
<br />

Returns `true` if the Realm is allowing connections. Otherwise returns
`false`.

If the value is `undefined` and the realm has a prototype the prototype's
value is returned. Otherwise if the realm doesn't have a prototype returns
`false`.

Note that a Prototype realm never allows connections irrespective of the
value set to this property. This this property is just used as a template
for realms to inherit from.

This setting is used to either temporarilly restrict new connections to the
realm or to avoid connections when the realm is used as a Single Sign-on
Realm. When connections are not allowed the only way of managing the
resources in the realm is through a connection to the Bondy Master Realm.

<a name="apply_config-0"></a>

### apply_config/0 ###

<pre><code>
apply_config() -&gt; ok | no_return()
</code></pre>
<br />

Loads a security config file from
`bondy_config:get([security, config_file])` if defined and applies its
definitions.

<a name="authmethods-1"></a>

### authmethods/1 ###

<pre><code>
authmethods(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; [binary()]
</code></pre>
<br />

Returns the list of supported authentication methods for Realm.

If the value is `undefined` and the realm has a prototype the prototype's
value is returned. Otherwise if the realm doesn't have a prototype returns
the default list of authentication methods.

See [`is_allowed_authmethod`](is_allowed_authmethod.md) for more information about how this
affects the methods available for an authenticating user.

<a name="create-1"></a>

### create/1 ###

<pre><code>
create(Map0::<a href="#type-uri">uri()</a> | map()) -&gt; <a href="#type-t">t()</a> | no_return()
</code></pre>
<br />

<a name="delete-1"></a>

### delete/1 ###

<pre><code>
delete(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; ok | {error, not_found | active_users} | no_return()
</code></pre>
<br />

<a name="disable_security-1"></a>

### disable_security/1 ###

<pre><code>
disable_security(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; ok | no_return()
</code></pre>
<br />

Disables security for realm `Realm`.

<a name="enable_security-1"></a>

### enable_security/1 ###

<pre><code>
enable_security(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; ok
</code></pre>
<br />

Enables security for realm `Realm`.

<a name="encryption_keys-1"></a>

### encryption_keys/1 ###

<pre><code>
encryption_keys(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; [map()]
</code></pre>
<br />

<a name="exists-1"></a>

### exists/1 ###

<pre><code>
exists(Uri::<a href="#type-uri">uri()</a>) -&gt; boolean()
</code></pre>
<br />

<a name="fetch-1"></a>

### fetch/1 ###

<pre><code>
fetch(Uri::<a href="#type-uri">uri()</a>) -&gt; <a href="#type-t">t()</a>
</code></pre>
<br />

Retrieves the realm identified by Uri from the tuplespace. If the realm
does not exist it fails with reason '{badarg, Uri}'.

<a name="from_file-1"></a>

### from_file/1 ###

<pre><code>
from_file(Filename::<a href="file.md#type-filename_all">file:filename_all()</a>) -&gt; ok | no_return()
</code></pre>
<br />

Loads a security config file from `Filename`.

<a name="get-1"></a>

### get/1 ###

<pre><code>
get(Uri::<a href="#type-uri">uri()</a>) -&gt; <a href="#type-t">t()</a> | {error, not_found}
</code></pre>
<br />

Retrieves the realm identified by Uri from the tuplespace. If the realm
does not exist and automatic creation of realms is enabled, it will add a
new one for Uri with the default configuration options.

<a name="get-2"></a>

### get/2 ###

<pre><code>
get(Uri::<a href="#type-uri">uri()</a>, Opts::map()) -&gt; <a href="#type-t">t()</a> | {error, not_found}
</code></pre>
<br />

Retrieves the realm identified by Uri from the tuplespace. If the realm
does not exist and automatic creation of realms is enabled, it will create a
new one for Uri with configuration options `Opts`.

<a name="get_encryption_key-2"></a>

### get_encryption_key/2 ###

<pre><code>
get_encryption_key(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>, Kid::binary()) -&gt; map() | undefined
</code></pre>
<br />

<a name="get_private_key-2"></a>

### get_private_key/2 ###

<pre><code>
get_private_key(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>, Kid::binary()) -&gt; map() | undefined
</code></pre>
<br />

<a name="get_public_key-2"></a>

### get_public_key/2 ###

<pre><code>
get_public_key(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>, Kid::binary()) -&gt; map() | undefined
</code></pre>
<br />

<a name="get_random_encryption_kid-1"></a>

### get_random_encryption_kid/1 ###

<pre><code>
get_random_encryption_kid(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; map()
</code></pre>
<br />

<a name="get_random_kid-1"></a>

### get_random_kid/1 ###

<pre><code>
get_random_kid(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; binary()
</code></pre>
<br />

<a name="grants-1"></a>

### grants/1 ###

<pre><code>
grants(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; [<a href="bondy_rbac_user.md#type-t">bondy_rbac_user:t()</a>]
</code></pre>
<br />

Returns the list of grants belonging to realm `Realm`.
These includes the grants inherited from the prototype (if defined).

<a name="grants-2"></a>

### grants/2 ###

<pre><code>
grants(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>, Opts::map()) -&gt; [<a href="bondy_rbac_user.md#type-t">bondy_rbac_user:t()</a>]
</code></pre>
<br />

Returns the list of grants belonging to realm `Realm`.
These includes the grants inherited from the prototype (if defined).

<a name="groups-1"></a>

### groups/1 ###

<pre><code>
groups(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; [<a href="bondy_rbac_user.md#type-t">bondy_rbac_user:t()</a>]
</code></pre>
<br />

Returns the list of users belonging to realm `Realm`.
These includes the groups inherited from the prototype (if defined).

<a name="groups-2"></a>

### groups/2 ###

<pre><code>
groups(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>, Opts::map()) -&gt; [<a href="bondy_rbac_user.md#type-t">bondy_rbac_user:t()</a>]
</code></pre>
<br />

Returns the list of groups belonging to realm `Realm`.
These includes the groups inherited from the prototype (if defined).

<a name="is_allowed_authmethod-2"></a>

### is_allowed_authmethod/2 ###

<pre><code>
is_allowed_authmethod(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>, Method::binary()) -&gt; boolean()
</code></pre>
<br />

Returns `true` if Method is an authentication method supported by realm
`Realm`. Otherwise returns `false`.

The fact that method `Method` is included in the realm's `authmethods`
(See {3link authmethods/1}) is no guarantee that the method will be
available for a particular user.

The availability is also affected by the source rules defined for the realm
and the capabilities of each user e.g. if the user has no password then
the password-based authentication methods in this list will not be available.

<a name="is_allowed_sso_realm-2"></a>

### is_allowed_sso_realm/2 ###

<pre><code>
is_allowed_sso_realm(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>, SSORealmUri::<a href="#type-uri">uri()</a>) -&gt; boolean()
</code></pre>
<br />

Returns `true` if realm `Realm` is associated with the SSO Realm
identified by uri `SSORealmUri`. Otherwise returns `false`.

<a name="is_prototype-1"></a>

### is_prototype/1 ###

<pre><code>
is_prototype(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; boolean()
</code></pre>
<br />

Returns `true` if realm `Realm` is a prototype. Otherwise, returns
`false`.

**Pre-conditions**
* The property `prototype_uri` MUST be `undefined`.
* This property cannot be set to `false` once it has been set to `true`.

**Post-conditions**
* If this property is `true`, the `prototype_uri` cannot be set.

<a name="is_security_enabled-1"></a>

### is_security_enabled/1 ###

<pre><code>
is_security_enabled(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; boolean()
</code></pre>
<br />

Returns `true` if security is enabled. Otherwise returns `false`.

If the value is `undefined` and the realm has a prototype the prototype's
value is returned. Otherwise if the realm doesn't have a prototype returns
`true` (default).

Security for this realm can be enabled or disabled using the functions
[`enable_security/1`](#enable_security-1) and [`disable_security/1`](#disable_security-1) respectively.

See [`security_status/1`](#security_status-1) if you want the security status representation
as an atom.

<a name="is_sso_realm-1"></a>

### is_sso_realm/1 ###

<pre><code>
is_sso_realm(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; boolean()
</code></pre>
<br />

Returns `true` if the Realm is a Same Sign-on (SSO) realm.
Otherwise returns `false`.

If the value is `undefined` and the realm has a prototype the prototype's
value is returned. Otherwise if the realm doesn't have a prototype returns
`false`.

<a name="is_value_inherited-2"></a>

### is_value_inherited/2 ###

<pre><code>
is_value_inherited(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>, Property::atom()) -&gt; boolean() | no_return()
</code></pre>
<br />

Returns `true` if the property value is inherited from a prototype.
Otherwise returns `false`.

<a name="list-0"></a>

### list/0 ###

<pre><code>
list() -&gt; [<a href="#type-t">t()</a>]
</code></pre>
<br />

<a name="lookup-1"></a>

### lookup/1 ###

<pre><code>
lookup(Uri::<a href="#type-uri">uri()</a>) -&gt; <a href="#type-t">t()</a> | {error, not_found}
</code></pre>
<br />

Retrieves the realm identified by Uri from the tuplespace or '{error, not_found}'
if it doesn't exist.

<a name="password_opts-1"></a>

### password_opts/1 ###

<pre><code>
password_opts(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; <a href="#type-maybe">maybe</a>(<a href="bondy_password.md#type-opts">bondy_password:opts()</a>)
</code></pre>
<br />

Returns the password options to be used as default when adding users
to this realm. If the options have not been defined returns atom `undefined`.

<a name="private_keys-1"></a>

### private_keys/1 ###

<pre><code>
private_keys(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; [map()]
</code></pre>
<br />

<a name="prototype_uri-1"></a>

### prototype_uri/1 ###

<pre><code>
prototype_uri(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; <a href="#type-maybe">maybe</a>(<a href="#type-uri">uri()</a>)
</code></pre>
<br />

Returns the uri of realm `Realm` prototype if defined. Otherwise
returns `undefined`.

<a name="public_keys-1"></a>

### public_keys/1 ###

<pre><code>
public_keys(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; [map()]
</code></pre>
<br />

<a name="security_status-1"></a>

### security_status/1 ###

<pre><code>
security_status(Term::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; enabled | disabled
</code></pre>
<br />

A util function that returns the security status as an atom.
See [`is_security_enabled/1`](#is_security_enabled-1).

<a name="sources-1"></a>

### sources/1 ###

<pre><code>
sources(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; [<a href="bondy_rbac_user.md#type-t">bondy_rbac_user:t()</a>]
</code></pre>
<br />

Returns the list of sources belonging to realm `Realm`.
These includes the sources inherited from the prototype (if defined).

<a name="sources-2"></a>

### sources/2 ###

<pre><code>
sources(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>, Opts::map()) -&gt; [<a href="bondy_rbac_user.md#type-t">bondy_rbac_user:t()</a>]
</code></pre>
<br />

Returns the list of sources belonging to realm `Realm`.
These includes the sources inherited from the prototype (if defined).

<a name="sso_realm_uri-1"></a>

### sso_realm_uri/1 ###

<pre><code>
sso_realm_uri(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; <a href="#type-maybe">maybe</a>(<a href="#type-uri">uri()</a>)
</code></pre>
<br />

Returns the same sign on (SSO) realm URI used by the realm.

If a value is set, then all authentication and user creation will be done on
the the SSO Realm.

Groups, permissions and sources are still managed by this realm
(or the prototype it inherits from).

If the value is `undefined` and the realm has a prototype the prototype's
value is returned. Otherwise if the realm doesn't have a prototype returns
`undefined`.

<a name="to_external-1"></a>

### to_external/1 ###

<pre><code>
to_external(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; <a href="#type-external">external()</a>
</code></pre>
<br />

Returns the external map representation of the realm.

<a name="update-2"></a>

### update/2 ###

<pre><code>
update(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>, Data::map()) -&gt; Realm::<a href="#type-t">t()</a> | no_return()
</code></pre>
<br />

<a name="uri-1"></a>

### uri/1 ###

<pre><code>
uri(Realm::<a href="#type-t">t()</a>) -&gt; <a href="#type-uri">uri()</a>
</code></pre>
<br />

Returns the URI that identifies the realm `Realm`.

<a name="users-1"></a>

### users/1 ###

<pre><code>
users(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; [<a href="bondy_rbac_user.md#type-t">bondy_rbac_user:t()</a>]
</code></pre>
<br />

Returns the list of users belonging to realm `Realm`.
Users are never inherited through prototypes.

<a name="users-2"></a>

### users/2 ###

<pre><code>
users(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>, Opts::map()) -&gt; [<a href="bondy_rbac_user.md#type-t">bondy_rbac_user:t()</a>]
</code></pre>
<br />

Returns the list of users belonging to realm `Realm`.
Users are never inherited through prototypes.

