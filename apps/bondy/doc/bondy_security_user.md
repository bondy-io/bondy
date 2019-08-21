

# Module bondy_security_user #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##




### <a name="type-t">t()</a> ###


<pre><code>
t() = map()
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#add-2">add/2</a></td><td></td></tr><tr><td valign="top"><a href="#add_or_update-2">add_or_update/2</a></td><td></td></tr><tr><td valign="top"><a href="#add_source-5">add_source/5</a></td><td></td></tr><tr><td valign="top"><a href="#change_password-3">change_password/3</a></td><td></td></tr><tr><td valign="top"><a href="#change_password-4">change_password/4</a></td><td></td></tr><tr><td valign="top"><a href="#fetch-2">fetch/2</a></td><td></td></tr><tr><td valign="top"><a href="#groups-1">groups/1</a></td><td></td></tr><tr><td valign="top"><a href="#has_password-1">has_password/1</a></td><td></td></tr><tr><td valign="top"><a href="#has_users-1">has_users/1</a></td><td></td></tr><tr><td valign="top"><a href="#list-1">list/1</a></td><td></td></tr><tr><td valign="top"><a href="#lookup-2">lookup/2</a></td><td></td></tr><tr><td valign="top"><a href="#password-2">password/2</a></td><td></td></tr><tr><td valign="top"><a href="#remove-2">remove/2</a></td><td></td></tr><tr><td valign="top"><a href="#remove_source-3">remove_source/3</a></td><td></td></tr><tr><td valign="top"><a href="#update-3">update/3</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="add-2"></a>

### add/2 ###

<pre><code>
add(RealmUri::<a href="#type-uri">uri()</a>, User::<a href="#type-t">t()</a>) -&gt; ok | {error, map()}
</code></pre>
<br />

<a name="add_or_update-2"></a>

### add_or_update/2 ###

<pre><code>
add_or_update(RealmUri::<a href="#type-uri">uri()</a>, User::<a href="#type-t">t()</a>) -&gt; ok
</code></pre>
<br />

<a name="add_source-5"></a>

### add_source/5 ###

<pre><code>
add_source(RealmUri::<a href="#type-uri">uri()</a>, Username::binary(), CIDR::<a href="bondy_security.md#type-cidr">bondy_security:cidr()</a>, Source::atom(), Options::list()) -&gt; ok
</code></pre>
<br />

<a name="change_password-3"></a>

### change_password/3 ###

`change_password(RealmUri, Username, New) -> any()`

<a name="change_password-4"></a>

### change_password/4 ###

`change_password(RealmUri, Username, New, Old) -> any()`

<a name="fetch-2"></a>

### fetch/2 ###

<pre><code>
fetch(RealmUri::<a href="#type-uri">uri()</a>, Id::binary()) -&gt; <a href="#type-t">t()</a> | no_return()
</code></pre>
<br />

<a name="groups-1"></a>

### groups/1 ###

`groups(X1) -> any()`

<a name="has_password-1"></a>

### has_password/1 ###

`has_password(X1) -> any()`

<a name="has_users-1"></a>

### has_users/1 ###

`has_users(RealmUri) -> any()`

<a name="list-1"></a>

### list/1 ###

<pre><code>
list(RealmUri::<a href="#type-uri">uri()</a>) -&gt; [<a href="#type-t">t()</a>]
</code></pre>
<br />

<a name="lookup-2"></a>

### lookup/2 ###

<pre><code>
lookup(RealmUri::<a href="#type-uri">uri()</a>, Id::binary()) -&gt; <a href="#type-t">t()</a> | {error, not_found}
</code></pre>
<br />

<a name="password-2"></a>

### password/2 ###

<pre><code>
password(RealmUri::<a href="#type-uri">uri()</a>, Username::<a href="#type-t">t()</a> | <a href="#type-id">id()</a>) -&gt; <a href="bondy_security_pw.md#type-t">bondy_security_pw:t()</a> | no_return()
</code></pre>
<br />

<a name="remove-2"></a>

### remove/2 ###

<pre><code>
remove(RealmUri::<a href="#type-uri">uri()</a>, Username::binary() | map()) -&gt; ok | {error, {unknown_user, binary()}}
</code></pre>
<br />

<a name="remove_source-3"></a>

### remove_source/3 ###

<pre><code>
remove_source(RealmUri::<a href="#type-uri">uri()</a>, Usernames::[binary()] | all, CIDR::<a href="bondy_security.md#type-cidr">bondy_security:cidr()</a>) -&gt; ok
</code></pre>
<br />

<a name="update-3"></a>

### update/3 ###

<pre><code>
update(RealmUri::<a href="#type-uri">uri()</a>, Username::binary(), User0::<a href="#type-t">t()</a>) -&gt; {ok, <a href="#type-t">t()</a>} | {error, any()}
</code></pre>
<br />

