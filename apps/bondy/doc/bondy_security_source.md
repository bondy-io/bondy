

# Module bondy_security_source #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##




### <a name="type-source">source()</a> ###


<pre><code>
source() = map()
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#add-2">add/2</a></td><td></td></tr><tr><td valign="top"><a href="#list-1">list/1</a></td><td></td></tr><tr><td valign="top"><a href="#list-2">list/2</a></td><td></td></tr><tr><td valign="top"><a href="#remove-3">remove/3</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="add-2"></a>

### add/2 ###

`add(RealmUri, Map0) -> any()`

<a name="list-1"></a>

### list/1 ###

<pre><code>
list(RealmUri::<a href="#type-uri">uri()</a>) -&gt; [<a href="#type-source">source()</a>]
</code></pre>
<br />

<a name="list-2"></a>

### list/2 ###

<pre><code>
list(RealmUri::<a href="#type-uri">uri()</a>, Username::binary() | all) -&gt; [<a href="#type-source">source()</a>]
</code></pre>
<br />

<a name="remove-3"></a>

### remove/3 ###

<pre><code>
remove(RealmUri::<a href="#type-uri">uri()</a>, Usernames::[binary()] | binary() | all, CIDR::<a href="bondy_security.md#type-cidr">bondy_security:cidr()</a>) -&gt; ok
</code></pre>
<br />

