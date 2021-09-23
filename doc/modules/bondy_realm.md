

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

The realm is a central and fundamental concept in Bondy. It does not only
serve as an authentication and authorization domain but also as a message
routing domain. Bondy ensures no messages routed in one realm will leak into
another realm.

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

A realm security is enabled by default.

## Storage

Realms (and the associated users, credentials, groups, sources and
permissions) are persisted to disk and replicated across the cluster using
the `plum_db` subsystem.

## Bondy Master Realm
When you start Bondy for the first time it creates and stores the Bondy
Master realm a.k.a `com.leapsight.bondy`. This realm is the root realm which
allows an admin user to create, list, modify and delete other realms.

## Realm Characteristics

## Same Sign-on (SSO)
Bondy SSO (Same Sign-on) is a feature that allows users to access multiple
realms using just one set of credentials.

It is enabled by setting the realm's `sso_realm_uri` property during realm
creation or during an update operation.

- It requires the user to authenticate when opening a session in a realm.
- Changing credentials e.g. updating password can be performed while
connected to any realm

## Realm Prototypes

<a name="types"></a>

## Data Types ##


<a name="external()"></a>


### external() ###


<pre><code>
external() = #{uri =&gt; <a href="#type-uri">uri()</a>, is_prototype =&gt; boolean(), prototype_uri =&gt; <a href="#type-maybe">maybe</a>(<a href="#type-uri">uri()</a>), description =&gt; binary(), authmethods =&gt; [binary()], is_sso_realm =&gt; boolean(), allow_connections =&gt; boolean(), public_keys =&gt; [term()], security_status =&gt; enabled | disabled}
</code></pre>


<a name="keyset()"></a>


### keyset() ###


<pre><code>
keyset() = #{<a href="#type-kid">kid()</a> =&gt; map()}
</code></pre>


<a name="kid()"></a>


### kid() ###


<pre><code>
kid() = binary()
</code></pre>


<a name="t()"></a>


### t() ###


<pre><code>
t() = #realm{uri = <a href="#type-uri">uri()</a>, description = binary(), prototype_uri = <a href="#type-maybe">maybe</a>(<a href="#type-uri">uri()</a>), is_prototype = boolean(), authmethods = [binary()], security_enabled = boolean(), is_sso_realm = boolean(), allow_connections = boolean(), sso_realm_uri = <a href="#type-maybe">maybe</a>(<a href="#type-uri">uri()</a>), private_keys = <a href="#type-keyset">keyset()</a>, public_keys = <a href="#type-keyset">keyset()</a>, password_opts = <a href="bondy_password.md#type-opts">bondy_password:opts()</a> | undefined, encryption_keys = <a href="#type-keyset">keyset()</a>, info = map()}
</code></pre>


<a name="functions"></a>

## Function Details ##

<a name="add-1"></a>

### add/1 ###

<pre><code>
add(Uri::<a href="#type-uri">uri()</a> | map()) -&gt; <a href="#type-t">t()</a> | no_return()
</code></pre>
<br />

<a name="allow_connections-1"></a>

### allow_connections/1 ###

<pre><code>
allow_connections(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; boolean()
</code></pre>
<br />

Returns `true` if the Realm is allowing connections. Otherwise returns
`false`.
This setting is used to either temporarilly restrict new connections to the
realm or to avoid connections when the realm is used as a Single Sign-on
Realm. When connections are not allowed the only way of managing the
resources in the realm is through ac connection to the Bondy admin realm.

<a name="apply_config-0"></a>

### apply_config/0 ###

<pre><code>
apply_config() -&gt; ok | no_return()
</code></pre>
<br />

Loads a security config file from
`bondy_config:get([security, config_file])` if defined and applies its
definitions.

<a name="apply_config-1"></a>

### apply_config/1 ###

<pre><code>
apply_config(Filename::<a href="file.md#type-filename_all">file:filename_all()</a>) -&gt; ok | no_return()
</code></pre>
<br />

Loads a security config file from `Filename`.

<a name="authmethods-1"></a>

### authmethods/1 ###

<pre><code>
authmethods(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; [binary()]
</code></pre>
<br />

Returns the list of supported authentication methods for Realm.
See [`is_allowed_authmethod`](is_allowed_authmethod.md) for more information about how this
affects the methods available for an authenticating user.

<a name="delete-1"></a>

### delete/1 ###

<pre><code>
delete(Uri::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; ok | {error, not_found | forbidden | active_users}
</code></pre>
<br />

<a name="disable_security-1"></a>

### disable_security/1 ###

<pre><code>
disable_security(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; ok | {error, forbidden}
</code></pre>
<br />

<a name="enable_security-1"></a>

### enable_security/1 ###

<pre><code>
enable_security(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; ok
</code></pre>
<br />

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

<a name="is_allowed_authmethod-2"></a>

### is_allowed_authmethod/2 ###

<pre><code>
is_allowed_authmethod(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>, Method::binary()) -&gt; boolean()
</code></pre>
<br />

Returs `true` if Method is an authentication method supported by realm
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

<a name="is_sso_realm-1"></a>

### is_sso_realm/1 ###

<pre><code>
is_sso_realm(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; boolean()
</code></pre>
<br />

Returns `true` if the Realm is a Same Sign-on (SSO) realm.
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

`password_opts(Realm) -> any()`

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

<a name="to_external-1"></a>

### to_external/1 ###

`to_external(Realm) -> any()`

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

