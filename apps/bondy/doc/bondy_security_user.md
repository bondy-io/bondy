

# Module bondy_security_user #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##




### <a name="type-user">user()</a> ###


<pre><code>
user() = #{}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#add-2">add/2</a></td><td></td></tr><tr><td valign="top"><a href="#add_source-5">add_source/5</a></td><td></td></tr><tr><td valign="top"><a href="#change_password-3">change_password/3</a></td><td></td></tr><tr><td valign="top"><a href="#change_password-4">change_password/4</a></td><td></td></tr><tr><td valign="top"><a href="#fetch-2">fetch/2</a></td><td></td></tr><tr><td valign="top"><a href="#groups-1">groups/1</a></td><td></td></tr><tr><td valign="top"><a href="#list-1">list/1</a></td><td></td></tr><tr><td valign="top"><a href="#lookup-2">lookup/2</a></td><td></td></tr><tr><td valign="top"><a href="#password-2">password/2</a></td><td></td></tr><tr><td valign="top"><a href="#remove-2">remove/2</a></td><td></td></tr><tr><td valign="top"><a href="#remove_source-3">remove_source/3</a></td><td></td></tr><tr><td valign="top"><a href="#update-3">update/3</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="add-2"></a>

### add/2 ###

<pre><code>
add(RealmUri::<a href="#type-uri">uri()</a>, User0::<a href="#type-user">user()</a>) -&gt; ok | {error, #{}}
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
fetch(RealmUri::<a href="#type-uri">uri()</a>, Id::binary()) -&gt; <a href="#type-user">user()</a> | no_return()
</code></pre>
<br />

<a name="groups-1"></a>

### groups/1 ###

`groups(X1) -> any()`

<a name="list-1"></a>

### list/1 ###

<pre><code>
list(RealmUri::<a href="#type-uri">uri()</a>) -&gt; [<a href="#type-user">user()</a>]
</code></pre>
<br />

<a name="lookup-2"></a>

### lookup/2 ###

<pre><code>
lookup(RealmUri::<a href="#type-uri">uri()</a>, Id::binary()) -&gt; <a href="#type-user">user()</a> | {error, not_found}
</code></pre>
<br />

<a name="password-2"></a>

### password/2 ###

<pre><code>
password(RealmUri::<a href="#type-uri">uri()</a>, Username::<a href="#type-user">user()</a> | <a href="#type-id">id()</a>) -&gt; #{} | no_return()
</code></pre>
<br />

<a name="remove-2"></a>

### remove/2 ###

<pre><code>
remove(RealmUri::<a href="#type-uri">uri()</a>, Id::binary() | #{}) -&gt; ok | {error, {unknown_user, binary()}}
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
update(RealmUri::<a href="#type-uri">uri()</a>, Username::binary(), User0::<a href="#type-user">user()</a>) -&gt; ok
</code></pre>
<br />

