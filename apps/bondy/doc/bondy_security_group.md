

# Module bondy_security_group #
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


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#add-2">add/2</a></td><td></td></tr><tr><td valign="top"><a href="#add_or_update-2">add_or_update/2</a></td><td></td></tr><tr><td valign="top"><a href="#fetch-2">fetch/2</a></td><td></td></tr><tr><td valign="top"><a href="#list-1">list/1</a></td><td></td></tr><tr><td valign="top"><a href="#lookup-2">lookup/2</a></td><td></td></tr><tr><td valign="top"><a href="#remove-2">remove/2</a></td><td></td></tr><tr><td valign="top"><a href="#update-3">update/3</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="add-2"></a>

### add/2 ###

<pre><code>
add(RealmUri::<a href="#type-uri">uri()</a>, Group::<a href="#type-t">t()</a>) -&gt; ok | {error, any()}
</code></pre>
<br />

<a name="add_or_update-2"></a>

### add_or_update/2 ###

<pre><code>
add_or_update(RealmUri::<a href="#type-uri">uri()</a>, Group::<a href="#type-t">t()</a>) -&gt; ok
</code></pre>
<br />

<a name="fetch-2"></a>

### fetch/2 ###

<pre><code>
fetch(RealmUri::<a href="#type-uri">uri()</a>, Name::list() | binary()) -&gt; <a href="#type-t">t()</a> | no_return()
</code></pre>
<br />

<a name="list-1"></a>

### list/1 ###

<pre><code>
list(RealmUri::<a href="#type-uri">uri()</a>) -&gt; [<a href="#type-t">t()</a>]
</code></pre>
<br />

<a name="lookup-2"></a>

### lookup/2 ###

<pre><code>
lookup(RealmUri::<a href="#type-uri">uri()</a>, Name::list() | binary()) -&gt; <a href="#type-t">t()</a> | {error, not_found}
</code></pre>
<br />

<a name="remove-2"></a>

### remove/2 ###

<pre><code>
remove(RealmUri::<a href="#type-uri">uri()</a>, Name::binary()) -&gt; ok | {error, any()}
</code></pre>
<br />

<a name="update-3"></a>

### update/3 ###

<pre><code>
update(RealmUri::<a href="#type-uri">uri()</a>, Name::binary(), Group0::<a href="#type-t">t()</a>) -&gt; ok
</code></pre>
<br />

