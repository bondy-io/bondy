

# Module bondy_realm #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

A Realm is a routing and administrative domain, optionally protected by
authentication and authorization.

<a name="description"></a>

## Description ##

It manages a set of users, credentials,
groups, sources and permissions.

A user belongs to and logs into a realm and Bondy messages are only routed
within a Realm.

Realms, users, credentials, groups, sources and permissions are persisted to
disk and replicated across the cluster using the `plum_db` subsystem.

## Bondy Admin Realm
When you start Bondy for the first time it creates the Bondy Admin realm
a.k.a `com.leapsight.bondy`. This realm is the root or master realm which
allows and administror user to create, list, modify and delete realms.

## Same Sign-on (SSO)
Bondy SSO (Same Sign-on) is a feature that allows users to access multiple
realms using just one set of credentials.

It is enabled by setting the realm's `sso_realm_uri` property during realm
creation or during an update operation.

- It requires the user to authenticate when opening a session in a realm.
- Changing credentials e.g. updating password can be performed while
connected to any realm
<a name="types"></a>

## Data Types ##




### <a name="type-external">external()</a> ###


<pre><code>
external() = #{uri =&gt; <a href="#type-uri">uri()</a>, description =&gt; binary(), authmethods =&gt; [binary()], is_sso_realm =&gt; boolean(), allow_connections =&gt; boolean(), public_keys =&gt; [term()], security_status =&gt; enabled | disabled}
</code></pre>




### <a name="type-t">t()</a> ###


<pre><code>
t() = #realm{uri = <a href="#type-uri">uri()</a>, description = binary(), authmethods = [binary()], security_enabled = boolean(), is_sso_realm = boolean(), allow_connections = boolean(), sso_realm_uri = <a href="#type-maybe">maybe</a>(<a href="#type-uri">uri()</a>), private_keys = map(), public_keys = map(), password_opts = <a href="bondy_password.md#type-opts">bondy_password:opts()</a> | undefined}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#add-1">add/1</a></td><td></td></tr><tr><td valign="top"><a href="#allow_connections-1">allow_connections/1</a></td><td>Returns <code>true</code> if the Realm is allowing connections.</td></tr><tr><td valign="top"><a href="#apply_config-0">apply_config/0</a></td><td>Loads a security config file from
<code>bondy_config:get([security, config_file])</code> if defined and applies its
definitions.</td></tr><tr><td valign="top"><a href="#apply_config-1">apply_config/1</a></td><td>Loads a security config file from <code>Filename</code>.</td></tr><tr><td valign="top"><a href="#authmethods-1">authmethods/1</a></td><td>Returns the list of supported authentication methods for Realm.</td></tr><tr><td valign="top"><a href="#delete-1">delete/1</a></td><td></td></tr><tr><td valign="top"><a href="#disable_security-1">disable_security/1</a></td><td></td></tr><tr><td valign="top"><a href="#enable_security-1">enable_security/1</a></td><td></td></tr><tr><td valign="top"><a href="#exists-1">exists/1</a></td><td></td></tr><tr><td valign="top"><a href="#fetch-1">fetch/1</a></td><td>
Retrieves the realm identified by Uri from the tuplespace.</td></tr><tr><td valign="top"><a href="#get-1">get/1</a></td><td>Retrieves the realm identified by Uri from the tuplespace.</td></tr><tr><td valign="top"><a href="#get-2">get/2</a></td><td>
Retrieves the realm identified by Uri from the tuplespace.</td></tr><tr><td valign="top"><a href="#get_private_key-2">get_private_key/2</a></td><td></td></tr><tr><td valign="top"><a href="#get_public_key-2">get_public_key/2</a></td><td></td></tr><tr><td valign="top"><a href="#get_random_kid-1">get_random_kid/1</a></td><td></td></tr><tr><td valign="top"><a href="#is_allowed_sso_realm-2">is_allowed_sso_realm/2</a></td><td>Returns the same sign on (SSO) realm URI used by the realm.</td></tr><tr><td valign="top"><a href="#is_authmethod-2">is_authmethod/2</a></td><td>Returs <code>true</code> if Method is an authentication method supported by realm
<code>Realm</code>.</td></tr><tr><td valign="top"><a href="#is_security_enabled-1">is_security_enabled/1</a></td><td></td></tr><tr><td valign="top"><a href="#is_sso_realm-1">is_sso_realm/1</a></td><td>Returns <code>true</code> if the Realm is enabled as a Same Sign-on (SSO) realm.</td></tr><tr><td valign="top"><a href="#list-0">list/0</a></td><td></td></tr><tr><td valign="top"><a href="#lookup-1">lookup/1</a></td><td>
Retrieves the realm identified by Uri from the tuplespace or '{error, not_found}'
if it doesn't exist.</td></tr><tr><td valign="top"><a href="#password_opts-1">password_opts/1</a></td><td></td></tr><tr><td valign="top"><a href="#public_keys-1">public_keys/1</a></td><td></td></tr><tr><td valign="top"><a href="#security_status-1">security_status/1</a></td><td></td></tr><tr><td valign="top"><a href="#sso_realm_uri-1">sso_realm_uri/1</a></td><td>Returns the same sign on (SSO) realm URI used by the realm.</td></tr><tr><td valign="top"><a href="#to_external-1">to_external/1</a></td><td></td></tr><tr><td valign="top"><a href="#update-2">update/2</a></td><td></td></tr><tr><td valign="top"><a href="#uri-1">uri/1</a></td><td></td></tr></table>


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
If the

<a name="delete-1"></a>

### delete/1 ###

<pre><code>
delete(Uri::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>) -&gt; ok | {error, forbidden | active_users}
</code></pre>
<br />

<a name="disable_security-1"></a>

### disable_security/1 ###

<pre><code>
disable_security(Realm::<a href="#type-t">t()</a>) -&gt; ok | {error, forbidden}
</code></pre>
<br />

<a name="enable_security-1"></a>

### enable_security/1 ###

<pre><code>
enable_security(Realm::<a href="#type-t">t()</a>) -&gt; ok
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

throws `no_such_realm`

Retrieves the realm identified by Uri from the tuplespace. If the realm
does not exist and automatic creation of realms is enabled, it will create a
new one for Uri with configuration options `Opts`.

<a name="get_private_key-2"></a>

### get_private_key/2 ###

<pre><code>
get_private_key(Realm::<a href="#type-t">t()</a>, Kid::integer()) -&gt; map() | undefined
</code></pre>
<br />

<a name="get_public_key-2"></a>

### get_public_key/2 ###

<pre><code>
get_public_key(Realm::<a href="#type-t">t()</a>, Kid::integer()) -&gt; map() | undefined
</code></pre>
<br />

<a name="get_random_kid-1"></a>

### get_random_kid/1 ###

`get_random_kid(Realm) -> any()`

<a name="is_allowed_sso_realm-2"></a>

### is_allowed_sso_realm/2 ###

<pre><code>
is_allowed_sso_realm(Realm::<a href="#type-t">t()</a> | <a href="#type-uri">uri()</a>, SSORealmUri::<a href="#type-uri">uri()</a>) -&gt; boolean()
</code></pre>
<br />

Returns the same sign on (SSO) realm URI used by the realm.
If a value is set, then all authentication and user creation will be done on
the Realm represented by the SSO Realm.
Groups, Permissions and Sources are still managed by this realm.

<a name="is_authmethod-2"></a>

### is_authmethod/2 ###

<pre><code>
is_authmethod(Realm::<a href="#type-t">t()</a>, Method::binary()) -&gt; boolean()
</code></pre>
<br />

Returs `true` if Method is an authentication method supported by realm
`Realm`. Otherwise returns `false`.

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

Returns `true` if the Realm is enabled as a Same Sign-on (SSO) realm.
Otherwise returns `false`.
If this property is `true`, the `sso_realm_uri` cannot be set.
This property cannot be set to `false` once it has been set to `true`.

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

<a name="public_keys-1"></a>

### public_keys/1 ###

<pre><code>
public_keys(Realm::<a href="#type-t">t()</a>) -&gt; [map()]
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
the Realm represented by the SSO Realm.
Groups, Permissions and Sources are still managed by this realm.

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

