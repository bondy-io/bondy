

# Module bondy_registry_entry #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##




### <a name="type-details_map">details_map()</a> ###


<pre><code>
details_map() = #{id =&gt; <a href="#type-id">id()</a>, created =&gt; <a href="calendar.md#type-date">calendar:date()</a>, uri =&gt; <a href="#type-uri">uri()</a>, match =&gt; binary()}
</code></pre>




### <a name="type-entry_key">entry_key()</a> ###


<pre><code>
entry_key() = #entry_key{realm_uri = <a href="#type-uri">uri()</a> | _, node = node(), session_id = <a href="#type-id">id()</a> | _ | undefined, entry_id = <a href="#type-id">id()</a> | _, type = <a href="#type-entry_type">entry_type()</a>}
</code></pre>




### <a name="type-entry_type">entry_type()</a> ###


<pre><code>
entry_type() = registration | subscription
</code></pre>




### <a name="type-t">t()</a> ###


__abstract datatype__: `t()`

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#created-1">created/1</a></td><td>
Returns the time when this entry was created.</td></tr><tr><td valign="top"><a href="#get_option-3">get_option/3</a></td><td></td></tr><tr><td valign="top"><a href="#id-1">id/1</a></td><td>
Returns the value of the subscription's or registration's id
property.</td></tr><tr><td valign="top"><a href="#is_entry-1">is_entry/1</a></td><td></td></tr><tr><td valign="top"><a href="#is_local-1">is_local/1</a></td><td>Returns true if the entry represents a local peer.</td></tr><tr><td valign="top"><a href="#key-1">key/1</a></td><td>
Returns the value of the subscription's or registration's realm_uri property.</td></tr><tr><td valign="top"><a href="#key_pattern-3">key_pattern/3</a></td><td></td></tr><tr><td valign="top"><a href="#key_pattern-5">key_pattern/5</a></td><td></td></tr><tr><td valign="top"><a href="#match_policy-1">match_policy/1</a></td><td>
Returns the match_policy used by this subscription or regitration.</td></tr><tr><td valign="top"><a href="#new-4">new/4</a></td><td></td></tr><tr><td valign="top"><a href="#new-5">new/5</a></td><td></td></tr><tr><td valign="top"><a href="#node-1">node/1</a></td><td>
Returns the value of the subscription's or registration's session_id
property.</td></tr><tr><td valign="top"><a href="#options-1">options/1</a></td><td>
Returns the value of the 'options' property of the entry.</td></tr><tr><td valign="top"><a href="#pattern-4">pattern/4</a></td><td></td></tr><tr><td valign="top"><a href="#pattern-6">pattern/6</a></td><td></td></tr><tr><td valign="top"><a href="#peer_id-1">peer_id/1</a></td><td>
Returns the peer_id() of the subscription or registration.</td></tr><tr><td valign="top"><a href="#pid-1">pid/1</a></td><td>
Returns the value of the subscription's or registration's session_id
property.</td></tr><tr><td valign="top"><a href="#realm_uri-1">realm_uri/1</a></td><td>
Returns the value of the subscription's or registration's realm_uri property.</td></tr><tr><td valign="top"><a href="#session_id-1">session_id/1</a></td><td>
Returns the value of the subscription's or registration's session_id
property.</td></tr><tr><td valign="top"><a href="#to_details_map-1">to_details_map/1</a></td><td>
Converts the entry into a map according to the WAMP protocol Details
dictionary format.</td></tr><tr><td valign="top"><a href="#to_map-1">to_map/1</a></td><td>
Converts the entry into a map.</td></tr><tr><td valign="top"><a href="#type-1">type/1</a></td><td>
Returns the type of the entry, the atom 'registration' or 'subscription'.</td></tr><tr><td valign="top"><a href="#uri-1">uri/1</a></td><td>
Returns the uri this entry is about i.e.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="created-1"></a>

### created/1 ###

<pre><code>
created(Entry::<a href="#type-t">t()</a>) -&gt; pos_integer()
</code></pre>
<br />

Returns the time when this entry was created. Its value is a timestamp in
seconds.

<a name="get_option-3"></a>

### get_option/3 ###

<pre><code>
get_option(Entry::<a href="#type-t">t()</a>, Key::any(), Default::any()) -&gt; any()
</code></pre>
<br />

<a name="id-1"></a>

### id/1 ###

<pre><code>
id(Entry::<a href="#type-t">t()</a> | <a href="#type-entry_key">entry_key()</a>) -&gt; <a href="#type-id">id()</a> | _
</code></pre>
<br />

Returns the value of the subscription's or registration's id
property.

<a name="is_entry-1"></a>

### is_entry/1 ###

`is_entry(Entry) -> any()`

<a name="is_local-1"></a>

### is_local/1 ###

<pre><code>
is_local(Entry::<a href="#type-t">t()</a> | <a href="#type-entry_key">entry_key()</a>) -&gt; boolean()
</code></pre>
<br />

Returns true if the entry represents a local peer

<a name="key-1"></a>

### key/1 ###

<pre><code>
key(Entry::<a href="#type-t">t()</a>) -&gt; <a href="#type-uri">uri()</a>
</code></pre>
<br />

Returns the value of the subscription's or registration's realm_uri property.

<a name="key_pattern-3"></a>

### key_pattern/3 ###

`key_pattern(Type, RealmUri, SessionId) -> any()`

<a name="key_pattern-5"></a>

### key_pattern/5 ###

`key_pattern(Type, RealmUri, Node, SessionId, EntryId) -> any()`

<a name="match_policy-1"></a>

### match_policy/1 ###

<pre><code>
match_policy(Entry::<a href="#type-t">t()</a>) -&gt; binary()
</code></pre>
<br />

Returns the match_policy used by this subscription or regitration.

<a name="new-4"></a>

### new/4 ###

<pre><code>
new(Type::<a href="#type-entry_type">entry_type()</a>, X2::<a href="#type-peer_id">peer_id()</a>, Uri::<a href="#type-uri">uri()</a>, Options::map()) -&gt; <a href="#type-t">t()</a>
</code></pre>
<br />

<a name="new-5"></a>

### new/5 ###

<pre><code>
new(Type::<a href="#type-entry_type">entry_type()</a>, RegId::<a href="#type-id">id()</a>, X3::<a href="#type-peer_id">peer_id()</a>, Uri::<a href="#type-uri">uri()</a>, Options::map()) -&gt; <a href="#type-t">t()</a>
</code></pre>
<br />

<a name="node-1"></a>

### node/1 ###

<pre><code>
node(Entry::<a href="#type-t">t()</a> | <a href="#type-entry_key">entry_key()</a>) -&gt; atom()
</code></pre>
<br />

Returns the value of the subscription's or registration's session_id
property.

<a name="options-1"></a>

### options/1 ###

<pre><code>
options(Entry::<a href="#type-t">t()</a>) -&gt; map()
</code></pre>
<br />

Returns the value of the 'options' property of the entry.

<a name="pattern-4"></a>

### pattern/4 ###

<pre><code>
pattern(Type::<a href="#type-entry_type">entry_type()</a>, RealmUri::<a href="#type-uri">uri()</a>, EntryId::<a href="#type-id">id()</a>, Options::map()) -&gt; <a href="#type-t">t()</a>
</code></pre>
<br />

<a name="pattern-6"></a>

### pattern/6 ###

<pre><code>
pattern(Type::<a href="#type-entry_type">entry_type()</a>, RealmUri::<a href="#type-uri">uri()</a>, Node::atom(), SessionId::<a href="#type-id">id()</a>, Uri::<a href="#type-uri">uri()</a>, Options::map()) -&gt; <a href="#type-t">t()</a>
</code></pre>
<br />

<a name="peer_id-1"></a>

### peer_id/1 ###

<pre><code>
peer_id(Entry::<a href="#type-t">t()</a> | <a href="#type-entry_key">entry_key()</a>) -&gt; <a href="#type-peer_id">peer_id()</a>
</code></pre>
<br />

Returns the peer_id() of the subscription or registration

<a name="pid-1"></a>

### pid/1 ###

<pre><code>
pid(Entry::<a href="#type-t">t()</a> | <a href="#type-entry_key">entry_key()</a>) -&gt; pid()
</code></pre>
<br />

Returns the value of the subscription's or registration's session_id
property.

<a name="realm_uri-1"></a>

### realm_uri/1 ###

<pre><code>
realm_uri(Entry::<a href="#type-t">t()</a> | <a href="#type-entry_key">entry_key()</a>) -&gt; <a href="#type-uri">uri()</a> | undefined
</code></pre>
<br />

Returns the value of the subscription's or registration's realm_uri property.

<a name="session_id-1"></a>

### session_id/1 ###

<pre><code>
session_id(Entry::<a href="#type-t">t()</a> | <a href="#type-entry_key">entry_key()</a>) -&gt; <a href="#type-id">id()</a> | undefined
</code></pre>
<br />

Returns the value of the subscription's or registration's session_id
property.

<a name="to_details_map-1"></a>

### to_details_map/1 ###

<pre><code>
to_details_map(Entry::<a href="#type-t">t()</a>) -&gt; <a href="#type-details_map">details_map()</a>
</code></pre>
<br />

Converts the entry into a map according to the WAMP protocol Details
dictionary format.

<a name="to_map-1"></a>

### to_map/1 ###

<pre><code>
to_map(Entry::<a href="#type-t">t()</a>) -&gt; <a href="#type-details_map">details_map()</a>
</code></pre>
<br />

Converts the entry into a map

<a name="type-1"></a>

### type/1 ###

<pre><code>
type(Entry::<a href="#type-t">t()</a> | <a href="#type-entry_key">entry_key()</a>) -&gt; <a href="#type-entry_type">entry_type()</a>
</code></pre>
<br />

Returns the type of the entry, the atom 'registration' or 'subscription'.

<a name="uri-1"></a>

### uri/1 ###

<pre><code>
uri(Entry::<a href="#type-t">t()</a>) -&gt; <a href="#type-uri">uri()</a>
</code></pre>
<br />

Returns the uri this entry is about i.e. either a subscription topic_uri or
a registration procedure_uri.

