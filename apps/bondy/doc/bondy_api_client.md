

# Module bondy_api_client #
* [Function Index](#index)
* [Function Details](#functions)

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#add-2">add/2</a></td><td>
Adds an API client to realm RealmUri.</td></tr><tr><td valign="top"><a href="#remove-2">remove/2</a></td><td></td></tr><tr><td valign="top"><a href="#update-3">update/3</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="add-2"></a>

### add/2 ###

<pre><code>
add(RealmUri::<a href="#type-uri">uri()</a>, Info0::map()) -&gt; {ok, map()} | {error, atom() | map()}
</code></pre>
<br />

Adds an API client to realm RealmUri.
Creates a new user adding it to the `api_clients` group.

<a name="remove-2"></a>

### remove/2 ###

<pre><code>
remove(RealmUri::<a href="#type-uri">uri()</a>, Id::list() | binary()) -&gt; ok
</code></pre>
<br />

<a name="update-3"></a>

### update/3 ###

<pre><code>
update(RealmUri::<a href="#type-uri">uri()</a>, ClientId::binary(), Info0::map()) -&gt; ok | {error, term()} | no_return()
</code></pre>
<br />

