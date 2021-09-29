

# Module bondy_rbac_user #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

A user is a role that is able to log into a Bondy Realm.

<a name="description"></a>

## Description ##

They  have attributes associated with themelves like username, credentials
(password or authorized keys) and metadata determined by the client
applications. Users can be assigned group memberships.

**Note:**
Usernames and group names are stored in lower case. All functions in this
module are case sensitice so when using the functions in this module make
sure the inputs you provide are in lowercase to. If you need to convert your
input to lowercase use [`string:casefold/1`](string.md#casefold-1).

<a name="types"></a>

## Data Types ##


<a name="add_error()"></a>


### add_error() ###


<pre><code>
add_error() = no_such_realm | reserved_name | already_exists
</code></pre>


<a name="add_opts()"></a>


### add_opts() ###


<pre><code>
add_opts() = #{password_opts =&gt; <a href="bondy_password.md#type-opts">bondy_password:opts()</a>}
</code></pre>


<a name="external()"></a>


### external() ###


<pre><code>
external() = #{type =&gt; ?TYPE, version =&gt; binary(), username =&gt; <a href="#type-username">username()</a>, groups =&gt; [binary()], has_password =&gt; boolean(), has_authorized_keys =&gt; boolean(), sso_realm_uri =&gt; <a href="#type-maybe">maybe</a>(<a href="#type-uri">uri()</a>), meta =&gt; #{binary() =&gt; any()}}
</code></pre>


<a name="list_opts()"></a>


### list_opts() ###


<pre><code>
list_opts() = #{limit =&gt; pos_integer()}
</code></pre>


<a name="new_opts()"></a>


### new_opts() ###


<pre><code>
new_opts() = #{password_opts =&gt; <a href="bondy_password.md#type-opts">bondy_password:opts()</a>}
</code></pre>


<a name="t()"></a>


### t() ###


<pre><code>
t() = #{type =&gt; ?TYPE, version =&gt; binary(), username =&gt; <a href="#type-username">username()</a>, groups =&gt; [binary()], password =&gt; <a href="bondy_password.md#type-future">bondy_password:future()</a> | <a href="bondy_password.md#type-t">bondy_password:t()</a>, authorized_keys =&gt; [binary()], sso_realm_uri =&gt; <a href="#type-maybe">maybe</a>(<a href="#type-uri">uri()</a>), meta =&gt; #{binary() =&gt; any()}, password_opts =&gt; <a href="bondy_password.md#type-opts">bondy_password:opts()</a>}
</code></pre>


<a name="update_error()"></a>


### update_error() ###


<pre><code>
update_error() = no_such_realm | reserved_name | {no_such_user, <a href="#type-username">username()</a>} | {no_such_groups, [<a href="bondy_rbac_group.md#type-name">bondy_rbac_group:name()</a>]}
</code></pre>


<a name="update_opts()"></a>


### update_opts() ###


<pre><code>
update_opts() = #{update_credentials =&gt; boolean(), password_opts =&gt; <a href="bondy_password.md#type-opts">bondy_password:opts()</a>}
</code></pre>


<a name="username()"></a>


### username() ###


<pre><code>
username() = binary() | anonymous
</code></pre>


<a name="functions"></a>

## Function Details ##

<a name="add-2"></a>

### add/2 ###

<pre><code>
add(RealmUri::<a href="#type-uri">uri()</a>, User::<a href="#type-t">t()</a>) -&gt; {ok, <a href="#type-t">t()</a>} | {error, <a href="#type-add_error">add_error()</a>}
</code></pre>
<br />

Adds a new user to the RBAC store. `User` MUST have been
created using [`new/1`](#new-1) or [`new/2`](#new-2).
This record is globally replicated.

<a name="add_group-3"></a>

### add_group/3 ###

<pre><code>
add_group(RealmUri::<a href="#type-uri">uri()</a>, Users::all | <a href="#type-t">t()</a> | [<a href="#type-t">t()</a>] | <a href="#type-username">username()</a> | [<a href="#type-username">username()</a>], Groupname::<a href="bondy_rbac_group.md#type-name">bondy_rbac_group:name()</a>) -&gt; ok | {error, Reason::any()}
</code></pre>
<br />

Adds group named `Groupname` to users `Users` in realm with uri
`RealmUri`.

<a name="add_groups-3"></a>

### add_groups/3 ###

<pre><code>
add_groups(RealmUri::<a href="#type-uri">uri()</a>, Users::all | <a href="#type-t">t()</a> | [<a href="#type-t">t()</a>] | <a href="#type-username">username()</a> | [<a href="#type-username">username()</a>], Groupnames::[<a href="bondy_rbac_group.md#type-name">bondy_rbac_group:name()</a>]) -&gt; ok | {error, Reason::any()}
</code></pre>
<br />

Adds groups `Groupnames` to users `Users` in realm with uri
`RealmUri`.

<a name="add_or_update-2"></a>

### add_or_update/2 ###

<pre><code>
add_or_update(RealmUri::<a href="#type-uri">uri()</a>, User::<a href="#type-t">t()</a>) -&gt; {ok, <a href="#type-t">t()</a>} | {error, <a href="#type-add_error">add_error()</a>}
</code></pre>
<br />

Adds a new user or updates an existing one.
This change is globally replicated.

<a name="add_or_update-3"></a>

### add_or_update/3 ###

<pre><code>
add_or_update(RealmUri::<a href="#type-uri">uri()</a>, User::<a href="#type-t">t()</a>, Opts::<a href="#type-update_opts">update_opts()</a>) -&gt; {ok, <a href="#type-t">t()</a>} | {error, <a href="#type-add_error">add_error()</a>}
</code></pre>
<br />

Adds a new user or updates an existing one.
This change is globally replicated.

<a name="authorized_keys-1"></a>

### authorized_keys/1 ###

`authorized_keys(X1) -> any()`

Returns the list of authorized keys for this user. These keys are used
with the WAMP Cryptosign authentication method or equivalent.

<a name="change_password-3"></a>

### change_password/3 ###

`change_password(RealmUri, Username, New) -> any()`

<a name="change_password-4"></a>

### change_password/4 ###

`change_password(RealmUri, Username, New, Old) -> any()`

<a name="disable-2"></a>

### disable/2 ###

<pre><code>
disable(RealmUri::<a href="#type-uri">uri()</a>, User::<a href="#type-t">t()</a>) -&gt; ok | {error, any()}
</code></pre>
<br />

Sets the value of the `enabled` property to `false`.
See [`is_enabled/2`](#is_enabled-2).

<a name="enable-2"></a>

### enable/2 ###

<pre><code>
enable(RealmUri::<a href="#type-uri">uri()</a>, User::<a href="#type-t">t()</a>) -&gt; ok | {error, any()}
</code></pre>
<br />

Sets the value of the `enabled` property to `true`.
See [`is_enabled/2`](#is_enabled-2).

<a name="exists-2"></a>

### exists/2 ###

<pre><code>
exists(RealmUri::<a href="#type-uri">uri()</a>, Username::binary()) -&gt; boolean()
</code></pre>
<br />

<a name="fetch-2"></a>

### fetch/2 ###

<pre><code>
fetch(RealmUri::<a href="#type-uri">uri()</a>, Username::binary()) -&gt; <a href="#type-t">t()</a> | no_return()
</code></pre>
<br />

<a name="groups-1"></a>

### groups/1 ###

`groups(X1) -> any()`

Returns the group names the user `User` is member of.

<a name="has_authorized_keys-1"></a>

### has_authorized_keys/1 ###

<pre><code>
has_authorized_keys(User::<a href="#type-t">t()</a>) -&gt; boolean()
</code></pre>
<br />

Returns `true` if user `User` has a authorized keys.
Otherwise returns `false`.
See [`authorized_keys/1`](#authorized_keys-1).

<a name="has_password-1"></a>

### has_password/1 ###

<pre><code>
has_password(User::<a href="#type-t">t()</a>) -&gt; boolean()
</code></pre>
<br />

Returns `true` if user `User` has a password. Otherwise returns `false`.

<a name="is_enabled-1"></a>

### is_enabled/1 ###

<pre><code>
is_enabled(User::<a href="#type-t">t()</a>) -&gt; boolean()
</code></pre>
<br />

Returns `true` if user `User` is active. Otherwise returns `false`.
A user that is not active cannot establish a session.
See [`enable/3`](#enable-3) and [`disable/3`](#disable-3).

<a name="is_enabled-2"></a>

### is_enabled/2 ###

<pre><code>
is_enabled(RealmUri::<a href="#type-uri">uri()</a>, Username::binary()) -&gt; boolean()
</code></pre>
<br />

Returns `true` if user identified with `Username` is enabled. Otherwise
returns `false`.
A user that is not enabled cannot establish a session.
See [`enable/2`](#enable-2) and [`disable/3`](#disable-3).

<a name="is_member-2"></a>

### is_member/2 ###

<pre><code>
is_member(Name0::<a href="bondy_rbac_group.md#type-name">bondy_rbac_group:name()</a>, User::<a href="#type-t">t()</a>) -&gt; boolean()
</code></pre>
<br />

Returns `true` if user `User` is a member of the group named
`Name`. Otherwise returns `false`.

<a name="is_sso_user-1"></a>

### is_sso_user/1 ###

<pre><code>
is_sso_user(User::<a href="#type-t">t()</a>) -&gt; boolean()
</code></pre>
<br />

Returns `true` if user `User` is managed in a SSO Realm, `false` if it
is locally managed.

<a name="list-1"></a>

### list/1 ###

<pre><code>
list(RealmUri::<a href="#type-uri">uri()</a>) -&gt; [<a href="#type-t">t()</a>]
</code></pre>
<br />

<a name="list-2"></a>

### list/2 ###

<pre><code>
list(RealmUri::<a href="#type-uri">uri()</a>, Opts::<a href="#type-list_opts">list_opts()</a>) -&gt; [<a href="#type-t">t()</a>]
</code></pre>
<br />

<a name="lookup-2"></a>

### lookup/2 ###

<pre><code>
lookup(RealmUri::<a href="#type-uri">uri()</a>, Username::binary()) -&gt; <a href="#type-t">t()</a> | {error, not_found}
</code></pre>
<br />

<a name="meta-1"></a>

### meta/1 ###

<pre><code>
meta(User::<a href="#type-t">t()</a>) -&gt; map()
</code></pre>
<br />

Returns the metadata map associated with the user `User`.

<a name="new-1"></a>

### new/1 ###

<pre><code>
new(Data::map()) -&gt; User::<a href="#type-t">t()</a>
</code></pre>
<br />

<a name="new-2"></a>

### new/2 ###

<pre><code>
new(Data::map(), Opts::<a href="#type-new_opts">new_opts()</a>) -&gt; User::<a href="#type-t">t()</a>
</code></pre>
<br />

<a name="normalise_username-1"></a>

### normalise_username/1 ###

<pre><code>
normalise_username(Term::<a href="#type-username">username()</a>) -&gt; <a href="#type-username">username()</a> | no_return()
</code></pre>
<br />

<a name="password-1"></a>

### password/1 ###

<pre><code>
password(User::<a href="#type-t">t()</a>) -&gt; <a href="#type-maybe">maybe</a>(<a href="bondy_password.md#type-future">bondy_password:future()</a> | <a href="bondy_password.md#type-t">bondy_password:t()</a>)
</code></pre>
<br />

Returns the password object or `undefined` if the user does not have a
password. See [`bondy_password`](bondy_password.md).

<a name="remove-2"></a>

### remove/2 ###

<pre><code>
remove(RealmUri::<a href="#type-uri">uri()</a>, Username0::binary() | map()) -&gt; ok | {error, {no_such_user, <a href="#type-username">username()</a>} | reserved_name}
</code></pre>
<br />

<a name="remove_group-3"></a>

### remove_group/3 ###

<pre><code>
remove_group(RealmUri::<a href="#type-uri">uri()</a>, Users::all | <a href="#type-t">t()</a> | [<a href="#type-t">t()</a>] | <a href="#type-username">username()</a> | [<a href="#type-username">username()</a>], Groupname::<a href="bondy_rbac_group.md#type-name">bondy_rbac_group:name()</a>) -&gt; ok
</code></pre>
<br />

Removes groups `Groupnames` from users `Users` in realm with uri
`RealmUri`.

<a name="remove_groups-3"></a>

### remove_groups/3 ###

<pre><code>
remove_groups(RealmUri::<a href="#type-uri">uri()</a>, Users::all | <a href="#type-t">t()</a> | [<a href="#type-t">t()</a>] | <a href="#type-username">username()</a> | [<a href="#type-username">username()</a>], Groupnames::[<a href="bondy_rbac_group.md#type-name">bondy_rbac_group:name()</a>]) -&gt; ok
</code></pre>
<br />

Removes groups `Groupnames` from users `Users` in realm with uri
`RealmUri`.

<a name="resolve-1"></a>

### resolve/1 ###

<pre><code>
resolve(User::<a href="#type-t">t()</a>) -&gt; Resolved::<a href="#type-t">t()</a> | no_return()
</code></pre>
<br />

If the user `User` is not sso-managed, returns `User` unmodified.
Otherwise, fetches the user's credentials, the enabled status and additional
metadata from the SSO Realm and merges it into `User` using the following
procedure:

* Copies the `password` and `authorized_keys` from the SSO user into `User`.
* Adds the `meta` contents from the SSO user to a key names `sso` to the
`User` `meta` map.
* Sets the `enabled` property by performing the conjunction (logical AND) of
both user records.

The call fails with an exception if the SSO user associated with `User` was
not found.

<a name="sso_realm_uri-1"></a>

### sso_realm_uri/1 ###

<pre><code>
sso_realm_uri(User::<a href="#type-t">t()</a>) -&gt; <a href="#type-maybe">maybe</a>(<a href="#type-uri">uri()</a>)
</code></pre>
<br />

Returns the URI of the Same Sign-on Realm in case the user is a SSO
user. Otherwise, returns `undefined`.

<a name="to_external-1"></a>

### to_external/1 ###

<pre><code>
to_external(User::<a href="#type-t">t()</a>) -&gt; <a href="#type-external">external()</a>
</code></pre>
<br />

Returns the external representation of the user `User`.

<a name="unknown-2"></a>

### unknown/2 ###

<pre><code>
unknown(RealmUri::<a href="#type-uri">uri()</a>, Usernames::[<a href="#type-username">username()</a>]) -&gt; Unknown::[<a href="#type-username">username()</a>]
</code></pre>
<br />

Takes a list of usernames and returns any that can't be found.

<a name="update-3"></a>

### update/3 ###

<pre><code>
update(RealmUri::<a href="#type-uri">uri()</a>, Username::binary(), Data::map()) -&gt; {ok, NewUser::<a href="#type-t">t()</a>} | {error, <a href="#type-update_error">update_error()</a>}
</code></pre>
<br />

Updates an existing user.
This change is globally replicated.

<a name="update-4"></a>

### update/4 ###

<pre><code>
update(RealmUri::<a href="#type-uri">uri()</a>, UserOrUsername::<a href="#type-t">t()</a> | binary(), Data::map(), Opts::<a href="#type-update_opts">update_opts()</a>) -&gt; {ok, NewUser::<a href="#type-t">t()</a>} | {error, any()}
</code></pre>
<br />

Updates an existing user.
This change is globally replicated.

<a name="username-1"></a>

### username/1 ###

`username(X1) -> any()`

Returns the group names the user's username.

