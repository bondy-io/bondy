

# Module bondy_realm #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

An implementation of a WAMP realm.

<a name="description"></a>

## Description ##

A Realm is a routing and administrative domain, optionally
protected by authentication and authorization. Bondy messages are
only routed within a Realm.

Realms are persisted to disk and replicated across the cluster using the
plum_db subsystem.
<a name="types"></a>

## Data Types ##




### <a name="type-realm">realm()</a> ###


<pre><code>
realm() = #realm{uri = <a href="#type-uri">uri()</a>, description = binary(), authmethods = [binary()], private_keys = #{}, public_keys = #{}}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#add-1">add/1</a></td><td></td></tr><tr><td valign="top"><a href="#add-2">add/2</a></td><td></td></tr><tr><td valign="top"><a href="#auth_methods-1">auth_methods/1</a></td><td></td></tr><tr><td valign="top"><a href="#delete-1">delete/1</a></td><td></td></tr><tr><td valign="top"><a href="#disable_security-1">disable_security/1</a></td><td></td></tr><tr><td valign="top"><a href="#enable_security-1">enable_security/1</a></td><td></td></tr><tr><td valign="top"><a href="#fetch-1">fetch/1</a></td><td>
Retrieves the realm identified by Uri from the tuplespace.</td></tr><tr><td valign="top"><a href="#get-1">get/1</a></td><td>
Retrieves the realm identified by Uri from the tuplespace.</td></tr><tr><td valign="top"><a href="#get-2">get/2</a></td><td>
Retrieves the realm identified by Uri from the tuplespace.</td></tr><tr><td valign="top"><a href="#get_private_key-2">get_private_key/2</a></td><td></td></tr><tr><td valign="top"><a href="#get_public_key-2">get_public_key/2</a></td><td></td></tr><tr><td valign="top"><a href="#get_random_kid-1">get_random_kid/1</a></td><td></td></tr><tr><td valign="top"><a href="#is_security_enabled-1">is_security_enabled/1</a></td><td></td></tr><tr><td valign="top"><a href="#list-0">list/0</a></td><td></td></tr><tr><td valign="top"><a href="#lookup-1">lookup/1</a></td><td>
Retrieves the realm identified by Uri from the tuplespace or '{error, not_found}'
if it doesn't exist.</td></tr><tr><td valign="top"><a href="#public_keys-1">public_keys/1</a></td><td></td></tr><tr><td valign="top"><a href="#security_status-1">security_status/1</a></td><td></td></tr><tr><td valign="top"><a href="#select_auth_method-2">select_auth_method/2</a></td><td></td></tr><tr><td valign="top"><a href="#to_map-1">to_map/1</a></td><td></td></tr><tr><td valign="top"><a href="#uri-1">uri/1</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="add-1"></a>

### add/1 ###

<pre><code>
add(Uri::<a href="#type-uri">uri()</a>) -&gt; <a href="#type-realm">realm()</a>
</code></pre>
<br />

<a name="add-2"></a>

### add/2 ###

<pre><code>
add(Uri::<a href="#type-uri">uri()</a>, Opts::#{}) -&gt; <a href="#type-realm">realm()</a> | no_return()
</code></pre>
<br />

<a name="auth_methods-1"></a>

### auth_methods/1 ###

<pre><code>
auth_methods(Realm::<a href="#type-realm">realm()</a>) -&gt; [binary()]
</code></pre>
<br />

<a name="delete-1"></a>

### delete/1 ###

<pre><code>
delete(Uri::<a href="#type-uri">uri()</a>) -&gt; ok | {error, not_permitted}
</code></pre>
<br />

<a name="disable_security-1"></a>

### disable_security/1 ###

<pre><code>
disable_security(Realm::<a href="#type-realm">realm()</a>) -&gt; ok
</code></pre>
<br />

<a name="enable_security-1"></a>

### enable_security/1 ###

<pre><code>
enable_security(Realm::<a href="#type-realm">realm()</a>) -&gt; ok
</code></pre>
<br />

<a name="fetch-1"></a>

### fetch/1 ###

<pre><code>
fetch(Uri::<a href="#type-uri">uri()</a>) -&gt; <a href="#type-realm">realm()</a>
</code></pre>
<br />

Retrieves the realm identified by Uri from the tuplespace. If the realm
does not exist it fails with reason '{badarg, Uri}'.

<a name="get-1"></a>

### get/1 ###

<pre><code>
get(Uri::<a href="#type-uri">uri()</a>) -&gt; <a href="#type-realm">realm()</a>
</code></pre>
<br />

Retrieves the realm identified by Uri from the tuplespace. If the realm
does not exist it will add a new one for Uri.

<a name="get-2"></a>

### get/2 ###

<pre><code>
get(Uri::<a href="#type-uri">uri()</a>, Opts::#{}) -&gt; <a href="#type-realm">realm()</a>
</code></pre>
<br />

Retrieves the realm identified by Uri from the tuplespace. If the realm
does not exist it will create a new one for Uri.

<a name="get_private_key-2"></a>

### get_private_key/2 ###

<pre><code>
get_private_key(Realm::<a href="#type-realm">realm()</a>, Kid::integer()) -&gt; #{} | undefined
</code></pre>
<br />

<a name="get_public_key-2"></a>

### get_public_key/2 ###

<pre><code>
get_public_key(Realm::<a href="#type-realm">realm()</a>, Kid::integer()) -&gt; #{} | undefined
</code></pre>
<br />

<a name="get_random_kid-1"></a>

### get_random_kid/1 ###

`get_random_kid(Realm) -> any()`

<a name="is_security_enabled-1"></a>

### is_security_enabled/1 ###

<pre><code>
is_security_enabled(R::<a href="#type-realm">realm()</a>) -&gt; boolean()
</code></pre>
<br />

<a name="list-0"></a>

### list/0 ###

<pre><code>
list() -&gt; [<a href="#type-realm">realm()</a>]
</code></pre>
<br />

<a name="lookup-1"></a>

### lookup/1 ###

<pre><code>
lookup(Uri::<a href="#type-uri">uri()</a>) -&gt; <a href="#type-realm">realm()</a> | {error, not_found}
</code></pre>
<br />

Retrieves the realm identified by Uri from the tuplespace or '{error, not_found}'
if it doesn't exist.

<a name="public_keys-1"></a>

### public_keys/1 ###

<pre><code>
public_keys(Realm::<a href="#type-realm">realm()</a>) -&gt; [#{}]
</code></pre>
<br />

<a name="security_status-1"></a>

### security_status/1 ###

<pre><code>
security_status(Realm::<a href="#type-realm">realm()</a>) -&gt; enabled | disabled
</code></pre>
<br />

<a name="select_auth_method-2"></a>

### select_auth_method/2 ###

<pre><code>
select_auth_method(Realm::<a href="#type-realm">realm()</a>, Requested::[binary()]) -&gt; any()
</code></pre>
<br />

<a name="to_map-1"></a>

### to_map/1 ###

`to_map(Realm) -> any()`

<a name="uri-1"></a>

### uri/1 ###

<pre><code>
uri(Realm::<a href="#type-realm">realm()</a>) -&gt; <a href="#type-uri">uri()</a>
</code></pre>
<br />

