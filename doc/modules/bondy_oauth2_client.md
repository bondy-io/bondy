

# Module bondy_oauth2_client #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##


<a name="t()"></a>


### t() ###


<pre><code>
t() = <a href="bondy_rbac_user.md#type-t">bondy_rbac_user:t()</a>
</code></pre>


<a name="functions"></a>

## Function Details ##

<a name="add-2"></a>

### add/2 ###

<pre><code>
add(RealmUri::<a href="#type-uri">uri()</a>, Data::map()) -&gt; {ok, map()} | {error, atom() | map()}
</code></pre>
<br />

Adds an API client to realm RealmUri.
Creates a new user adding it to the `api_clients` group.

<a name="remove-2"></a>

### remove/2 ###

<pre><code>
remove(RealmUri::<a href="#type-uri">uri()</a>, ClientId::binary()) -&gt; ok
</code></pre>
<br />

<a name="to_external-1"></a>

### to_external/1 ###

<pre><code>
to_external(Map::<a href="#type-t">t()</a>) -&gt; map()
</code></pre>
<br />

<a name="update-3"></a>

### update/3 ###

<pre><code>
update(RealmUri::<a href="#type-uri">uri()</a>, ClientId::binary(), Data0::map()) -&gt; {ok, <a href="#type-t">t()</a>} | {error, term()} | no_return()
</code></pre>
<br />

