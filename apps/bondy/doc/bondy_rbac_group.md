

# Module bondy_rbac_group #
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
add_error() = no_such_realm | reserved_name | already_exists
</code></pre>




### <a name="type-external">external()</a> ###


<pre><code>
external() = <a href="#type-t">t()</a>
</code></pre>




### <a name="type-list_opts">list_opts()</a> ###


<pre><code>
list_opts() = #{limit =&gt; pos_integer()}
</code></pre>




### <a name="type-name">name()</a> ###


<pre><code>
name() = binary() | anonymous | all
</code></pre>




### <a name="type-t">t()</a> ###


<pre><code>
t() = #{type =&gt; group, version =&gt; binary(), name =&gt; binary() | anonymous, groups =&gt; [binary()], meta =&gt; #{binary() =&gt; any()}}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#add-2">add/2</a></td><td></td></tr><tr><td valign="top"><a href="#add_group-3">add_group/3</a></td><td>Adds group named <code>Groupname</code> to gropus <code>Groups</code> in realm with uri
<code>RealmUri</code>.</td></tr><tr><td valign="top"><a href="#add_groups-3">add_groups/3</a></td><td>Adds groups <code>Groupnames</code> to gropus <code>Groups</code> in realm with uri
<code>RealmUri</code>.</td></tr><tr><td valign="top"><a href="#add_or_update-2">add_or_update/2</a></td><td>Adds a new user or updates an existing one.</td></tr><tr><td valign="top"><a href="#exists-2">exists/2</a></td><td></td></tr><tr><td valign="top"><a href="#fetch-2">fetch/2</a></td><td></td></tr><tr><td valign="top"><a href="#groups-1">groups/1</a></td><td>Returns the group names the user <code>User</code> is member of.</td></tr><tr><td valign="top"><a href="#is_member-2">is_member/2</a></td><td>Returns <code>true</code> if group <code>Group</code> is a member of the group named
<code>Name</code>.</td></tr><tr><td valign="top"><a href="#list-1">list/1</a></td><td></td></tr><tr><td valign="top"><a href="#list-2">list/2</a></td><td></td></tr><tr><td valign="top"><a href="#lookup-2">lookup/2</a></td><td></td></tr><tr><td valign="top"><a href="#meta-1">meta/1</a></td><td>Returns the metadata map associated with the group <code>Group</code>.</td></tr><tr><td valign="top"><a href="#name-1">name/1</a></td><td>Returns the group names the user's username.</td></tr><tr><td valign="top"><a href="#new-1">new/1</a></td><td></td></tr><tr><td valign="top"><a href="#normalise_name-1">normalise_name/1</a></td><td></td></tr><tr><td valign="top"><a href="#remove-2">remove/2</a></td><td></td></tr><tr><td valign="top"><a href="#remove_group-3">remove_group/3</a></td><td>Removes groups <code>Groupnames</code> from gropus <code>Groups</code> in realm with uri
<code>RealmUri</code>.</td></tr><tr><td valign="top"><a href="#remove_groups-3">remove_groups/3</a></td><td>Removes groups <code>Groupnames</code> from gropus <code>Groups</code> in realm with uri
<code>RealmUri</code>.</td></tr><tr><td valign="top"><a href="#to_external-1">to_external/1</a></td><td>Returns the external representation of the user <code>User</code>.</td></tr><tr><td valign="top"><a href="#unknown-2">unknown/2</a></td><td>Takes a list of groupnames and returns any that can't be found.</td></tr><tr><td valign="top"><a href="#update-3">update/3</a></td><td>
Name cannot be a reserved name.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="add-2"></a>

### add/2 ###

<pre><code>
add(RealmUri::<a href="#type-uri">uri()</a>, Group::<a href="#type-t">t()</a>) -&gt; {ok, <a href="#type-t">t()</a>} | {error, any()}
</code></pre>
<br />

<a name="add_group-3"></a>

### add_group/3 ###

<pre><code>
add_group(RealmUri::<a href="#type-uri">uri()</a>, Groups::all | <a href="#type-t">t()</a> | [<a href="#type-t">t()</a>] | <a href="#type-name">name()</a> | [<a href="#type-name">name()</a>], Groupname::<a href="#type-name">name()</a>) -&gt; ok
</code></pre>
<br />

Adds group named `Groupname` to gropus `Groups` in realm with uri
`RealmUri`.

<a name="add_groups-3"></a>

### add_groups/3 ###

<pre><code>
add_groups(RealmUri::<a href="#type-uri">uri()</a>, Groups::all | <a href="#type-t">t()</a> | [<a href="#type-t">t()</a>] | <a href="#type-name">name()</a> | [<a href="#type-name">name()</a>], Groupnames::[<a href="#type-name">name()</a>]) -&gt; ok
</code></pre>
<br />

Adds groups `Groupnames` to gropus `Groups` in realm with uri
`RealmUri`.

<a name="add_or_update-2"></a>

### add_or_update/2 ###

<pre><code>
add_or_update(RealmUri::<a href="#type-uri">uri()</a>, Gropu::<a href="#type-t">t()</a>) -&gt; {ok, <a href="#type-t">t()</a>} | {error, <a href="#type-add_error">add_error()</a>}
</code></pre>
<br />

Adds a new user or updates an existing one.
This change is globally replicated.

<a name="exists-2"></a>

### exists/2 ###

<pre><code>
exists(RealmUri::<a href="#type-uri">uri()</a>, Name::list() | binary()) -&gt; boolean()
</code></pre>
<br />

<a name="fetch-2"></a>

### fetch/2 ###

<pre><code>
fetch(RealmUri::<a href="#type-uri">uri()</a>, Name::list() | binary()) -&gt; <a href="#type-t">t()</a> | no_return()
</code></pre>
<br />

<a name="groups-1"></a>

### groups/1 ###

<pre><code>
groups(X1::<a href="#type-t">t()</a>) -&gt; [<a href="#type-name">name()</a>]
</code></pre>
<br />

Returns the group names the user `User` is member of.

<a name="is_member-2"></a>

### is_member/2 ###

<pre><code>
is_member(Name::<a href="#type-name">name()</a>, Group::<a href="#type-t">t()</a>) -&gt; boolean()
</code></pre>
<br />

Returns `true` if group `Group` is a member of the group named
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
lookup(RealmUri::<a href="#type-uri">uri()</a>, Name0::list() | binary()) -&gt; <a href="#type-t">t()</a> | {error, not_found}
</code></pre>
<br />

<a name="meta-1"></a>

### meta/1 ###

<pre><code>
meta(Group::<a href="#type-t">t()</a>) -&gt; map()
</code></pre>
<br />

Returns the metadata map associated with the group `Group`.

<a name="name-1"></a>

### name/1 ###

<pre><code>
name(X1::<a href="#type-t">t()</a>) -&gt; <a href="#type-name">name()</a>
</code></pre>
<br />

Returns the group names the user's username.

<a name="new-1"></a>

### new/1 ###

<pre><code>
new(Data::map()) -&gt; Group::<a href="#type-t">t()</a>
</code></pre>
<br />

<a name="normalise_name-1"></a>

### normalise_name/1 ###

<pre><code>
normalise_name(Term::<a href="#type-name">name()</a>) -&gt; <a href="#type-name">name()</a> | no_return()
</code></pre>
<br />

<a name="remove-2"></a>

### remove/2 ###

<pre><code>
remove(RealmUri::<a href="#type-uri">uri()</a>, Name::binary() | map()) -&gt; ok | {error, unknown_group | reserved_name}
</code></pre>
<br />

<a name="remove_group-3"></a>

### remove_group/3 ###

<pre><code>
remove_group(RealmUri::<a href="#type-uri">uri()</a>, Groups::all | <a href="#type-t">t()</a> | [<a href="#type-t">t()</a>] | <a href="#type-name">name()</a> | [<a href="#type-name">name()</a>], Groupname::<a href="#type-name">name()</a>) -&gt; ok
</code></pre>
<br />

Removes groups `Groupnames` from gropus `Groups` in realm with uri
`RealmUri`.

<a name="remove_groups-3"></a>

### remove_groups/3 ###

<pre><code>
remove_groups(RealmUri::<a href="#type-uri">uri()</a>, Groups::all | <a href="#type-t">t()</a> | [<a href="#type-t">t()</a>] | <a href="#type-name">name()</a> | [<a href="#type-name">name()</a>], Groupnames::[<a href="#type-name">name()</a>]) -&gt; ok
</code></pre>
<br />

Removes groups `Groupnames` from gropus `Groups` in realm with uri
`RealmUri`.

<a name="to_external-1"></a>

### to_external/1 ###

<pre><code>
to_external(Group::<a href="#type-t">t()</a>) -&gt; <a href="#type-external">external()</a>
</code></pre>
<br />

Returns the external representation of the user `User`.

<a name="unknown-2"></a>

### unknown/2 ###

<pre><code>
unknown(RealmUri::<a href="#type-uri">uri()</a>, Names::[binary()]) -&gt; Unknown::[binary()]
</code></pre>
<br />

Takes a list of groupnames and returns any that can't be found.

<a name="update-3"></a>

### update/3 ###

<pre><code>
update(RealmUri::<a href="#type-uri">uri()</a>, Name::binary(), Data::map()) -&gt; {ok, NewUser::<a href="#type-t">t()</a>} | {error, any()}
</code></pre>
<br />

Name cannot be a reserved name. See [`bondy_rbac:is_reserved_name/1`](bondy_rbac.md#is_reserved_name-1).

