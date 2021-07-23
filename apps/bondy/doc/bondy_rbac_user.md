

# Module bondy_rbac_user #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

**Note:**
Usernames and group names are stored in lower case.

<a name="description"></a>

## Description ##
All functions in this
module are case sensitice so when using the functions in this module make
sure the inputs you provide are in lowercase to. If you need to convert your
input to lowercase use [`string:casefold/1`](string.md#casefold-1).
<a name="types"></a>

## Data Types ##




### <a name="type-add_error">add_error()</a> ###


<pre><code>
add_error() = no_such_realm | reserved_name | role_exists
</code></pre>




### <a name="type-external">external()</a> ###


<pre><code>
external() = #{type =&gt; ?TYPE, version =&gt; binary(), username =&gt; <a href="#type-username">username()</a>, groups =&gt; [binary()], has_password =&gt; boolean(), has_authorized_keys =&gt; boolean(), meta =&gt; #{binary() =&gt; any()}}
</code></pre>




### <a name="type-list_opts">list_opts()</a> ###


<pre><code>
list_opts() = #{limit =&gt; pos_integer()}
</code></pre>




### <a name="type-new_opts">new_opts()</a> ###


<pre><code>
new_opts() = #{password_opts =&gt; <a href="bondy_password.md#type-opts">bondy_password:opts()</a>}
</code></pre>




### <a name="type-t">t()</a> ###


<pre><code>
t() = #{type =&gt; ?TYPE, version =&gt; binary(), username =&gt; <a href="#type-username">username()</a>, groups =&gt; [binary()], password =&gt; <a href="bondy_password.md#type-future">bondy_password:future()</a> | <a href="bondy_password.md#type-t">bondy_password:t()</a>, authorized_keys =&gt; [binary()], meta =&gt; #{binary() =&gt; any()}}
</code></pre>




### <a name="type-username">username()</a> ###


<pre><code>
username() = binary() | anonymous
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#add-2">add/2</a></td><td>Adds a new user to the RBAC store.</td></tr><tr><td valign="top"><a href="#add_or_update-2">add_or_update/2</a></td><td>Adds a new user or updates an existing one.</td></tr><tr><td valign="top"><a href="#authorized_keys-1">authorized_keys/1</a></td><td>Returns the list of authorized keys for this user.</td></tr><tr><td valign="top"><a href="#change_password-3">change_password/3</a></td><td></td></tr><tr><td valign="top"><a href="#change_password-4">change_password/4</a></td><td></td></tr><tr><td valign="top"><a href="#fetch-2">fetch/2</a></td><td></td></tr><tr><td valign="top"><a href="#groups-1">groups/1</a></td><td>Returns the group names the user <code>User</code> is member of.</td></tr><tr><td valign="top"><a href="#has_authorized_keys-1">has_authorized_keys/1</a></td><td>Returns <code>true</code> if user <code>User</code> has a authorized keys.</td></tr><tr><td valign="top"><a href="#has_password-1">has_password/1</a></td><td>Returns <code>true</code> if user <code>User</code> has a password.</td></tr><tr><td valign="top"><a href="#is_member-2">is_member/2</a></td><td>Returns <code>true</code> if user <code>User</code> is a member of the group named
<code>Name</code>.</td></tr><tr><td valign="top"><a href="#list-1">list/1</a></td><td></td></tr><tr><td valign="top"><a href="#list-2">list/2</a></td><td></td></tr><tr><td valign="top"><a href="#lookup-2">lookup/2</a></td><td></td></tr><tr><td valign="top"><a href="#meta-1">meta/1</a></td><td>Returns the metadata map associated with the user <code>User</code>.</td></tr><tr><td valign="top"><a href="#new-1">new/1</a></td><td></td></tr><tr><td valign="top"><a href="#new-2">new/2</a></td><td></td></tr><tr><td valign="top"><a href="#normalise_username-1">normalise_username/1</a></td><td></td></tr><tr><td valign="top"><a href="#password-1">password/1</a></td><td>Returns the password object or <code>undefined</code> if the user does not have a
password.</td></tr><tr><td valign="top"><a href="#remove-2">remove/2</a></td><td></td></tr><tr><td valign="top"><a href="#remove_group-2">remove_group/2</a></td><td>Removes group named <code>Groupname</code> from all users in realm with uri
<code>RealmUri</code>.</td></tr><tr><td valign="top"><a href="#to_external-1">to_external/1</a></td><td>Returns the external representation of the user <code>User</code>.</td></tr><tr><td valign="top"><a href="#unknown-2">unknown/2</a></td><td>Takes a list of usernames and returns any that can't be found.</td></tr><tr><td valign="top"><a href="#update-3">update/3</a></td><td></td></tr><tr><td valign="top"><a href="#username-1">username/1</a></td><td>Returns the group names the user's username.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="add-2"></a>

### add/2 ###

<pre><code>
add(RealmUri::<a href="#type-uri">uri()</a>, User::<a href="#type-t">t()</a>) -&gt; ok | {error, <a href="#type-add_error">add_error()</a>}
</code></pre>
<br />

Adds a new user to the RBAC store.
This record is globally replicated.

<a name="add_or_update-2"></a>

### add_or_update/2 ###

<pre><code>
add_or_update(RealmUri::<a href="#type-uri">uri()</a>, User::<a href="#type-t">t()</a>) -&gt; {ok, <a href="#type-t">t()</a>} | {error, <a href="#type-add_error">add_error()</a>}
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

`change_password(RealmUri, Username, Old, X4) -> any()`

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

<a name="is_member-2"></a>

### is_member/2 ###

<pre><code>
is_member(Name0::<a href="bondy_rbac_group.md#type-name">bondy_rbac_group:name()</a>, User::<a href="#type-t">t()</a>) -&gt; boolean()
</code></pre>
<br />

Returns `true` if user `User` is a member of the group named
`Name`. Otherwise returns `false`.

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
password(User::<a href="#type-t">t()</a>) -&gt; <a href="bondy_password.md#type-future">bondy_password:future()</a> | <a href="bondy_password.md#type-t">bondy_password:t()</a> | undefined
</code></pre>
<br />

Returns the password object or `undefined` if the user does not have a
password. See [`bondy_password`](bondy_password.md).

<a name="remove-2"></a>

### remove/2 ###

<pre><code>
remove(RealmUri::<a href="#type-uri">uri()</a>, Username0::binary() | map()) -&gt; ok | {error, unknown_user | reserved_name}
</code></pre>
<br />

<a name="remove_group-2"></a>

### remove_group/2 ###

<pre><code>
remove_group(RealmUri::<a href="#type-uri">uri()</a>, Groupname::<a href="bondy_rbac_group.md#type-name">bondy_rbac_group:name()</a>) -&gt; ok
</code></pre>
<br />

Removes group named `Groupname` from all users in realm with uri
`RealmUri`.

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
update(RealmUri::<a href="#type-uri">uri()</a>, Username::binary(), Data::map()) -&gt; {ok, NewUser::<a href="#type-t">t()</a>} | {error, any()}
</code></pre>
<br />

<a name="username-1"></a>

### username/1 ###

`username(X1) -> any()`

Returns the group names the user's username.
