

# Module bondy_registry #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

An in-memory registry for PubSub subscriptions and RPC registrations,
providing pattern matching capabilities including support for WAMP's
version 2.0 match policies (exact, prefix and wilcard).

<a name="types"></a>

## Data Types ##




### <a name="type-continuation">continuation()</a> ###


<pre><code>
continuation() = {<a href="#type-entry_type">entry_type()</a>, <a href="etc.md#type-continuation">etc:continuation()</a>}
</code></pre>




### <a name="type-details_map">details_map()</a> ###


<pre><code>
details_map() = #{id =&gt; <a href="#type-id">id()</a>, created =&gt; <a href="calendar.md#type-date">calendar:date()</a>, uri =&gt; <a href="#type-uri">uri()</a>, match =&gt; binary()}
</code></pre>




### <a name="type-entry">entry()</a> ###


<pre><code>
entry() = #entry{key = <a href="#type-entry_key">entry_key()</a>, type = <a href="#type-entry_type">entry_type()</a>, uri = <a href="#type-uri">uri()</a> | atom(), match_policy = binary(), criteria = [{'=:=', Field::binary(), Value::any()}] | atom(), created = <a href="calendar.md#type-date_time">calendar:date_time()</a> | atom(), options = #{} | atom()}
</code></pre>




### <a name="type-entry_key">entry_key()</a> ###


<pre><code>
entry_key() = {RealmUri::<a href="#type-uri">uri()</a>, SessionId::<a href="#type-id">id()</a> | atom(), EntryId::<a href="#type-id">id()</a> | atom()}
</code></pre>




### <a name="type-entry_type">entry_type()</a> ###


<pre><code>
entry_type() = registration | subscription
</code></pre>




### <a name="type-eot">eot()</a> ###


<pre><code>
eot() = '?EOT'
</code></pre>




### <a name="type-task">task()</a> ###


<pre><code>
task() = fun((<a href="#type-details_map">details_map()</a>, <a href="bondy_context.md#type-context">bondy_context:context()</a>) -&gt; ok)
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#add-4">add/4</a></td><td>
Adds an entry to the registry.</td></tr><tr><td valign="top"><a href="#created-1">created/1</a></td><td>
Returns the time when this entry was created.</td></tr><tr><td valign="top"><a href="#criteria-1">criteria/1</a></td><td>
Not used at the moment.</td></tr><tr><td valign="top"><a href="#entries-1">entries/1</a></td><td>
Continues returning the list of entries owned by a session started with
<a href="#entries-4"><code>entries/4</code></a>.</td></tr><tr><td valign="top"><a href="#entries-2">entries/2</a></td><td>
Returns the list of entries owned by the the active session.</td></tr><tr><td valign="top"><a href="#entries-3">entries/3</a></td><td>
Returns the complete list of entries owned by a session matching
RealmUri and SessionId.</td></tr><tr><td valign="top"><a href="#entries-4">entries/4</a></td><td>
Works like <a href="#entries-3"><code>entries/3</code></a>, but only returns a limited (Limit) number of
entries.</td></tr><tr><td valign="top"><a href="#entry_id-1">entry_id/1</a></td><td>
Returns the value of the subscription's or registration's entry_id
property.</td></tr><tr><td valign="top"><a href="#lookup-3">lookup/3</a></td><td>
Lookup an entry by Type, Id (Registration or Subscription Id) and Ctxt.</td></tr><tr><td valign="top"><a href="#lookup-4">lookup/4</a></td><td></td></tr><tr><td valign="top"><a href="#match-1">match/1</a></td><td></td></tr><tr><td valign="top"><a href="#match-3">match/3</a></td><td>
Calls <a href="#match-4"><code>match/4</code></a>.</td></tr><tr><td valign="top"><a href="#match-4">match/4</a></td><td>
Returns the entries matching either a topic or procedure Uri according to
each entry's configured match specification.</td></tr><tr><td valign="top"><a href="#match_policy-1">match_policy/1</a></td><td>
Returns the match_policy used by this subscription or regitration.</td></tr><tr><td valign="top"><a href="#options-1">options/1</a></td><td>
Returns the value of the 'options' property of the entry.</td></tr><tr><td valign="top"><a href="#realm_uri-1">realm_uri/1</a></td><td>
Returns the value of the subscription's or registration's realm_uri property.</td></tr><tr><td valign="top"><a href="#remove-3">remove/3</a></td><td></td></tr><tr><td valign="top"><a href="#remove-4">remove/4</a></td><td></td></tr><tr><td valign="top"><a href="#remove_all-2">remove_all/2</a></td><td>
Removes all entries matching the context's realm and session_id (if any).</td></tr><tr><td valign="top"><a href="#remove_all-3">remove_all/3</a></td><td>
Removes all entries matching the context's realm and session_id (if any).</td></tr><tr><td valign="top"><a href="#session_id-1">session_id/1</a></td><td>
Returns the value of the subscription's or registration's session_id
property.</td></tr><tr><td valign="top"><a href="#to_details_map-1">to_details_map/1</a></td><td>
Converts the entry into a map according to the WAMP protocol Details
dictionary format.</td></tr><tr><td valign="top"><a href="#type-1">type/1</a></td><td>
Returns the type of the entry, the atom 'registration' or 'subscription'.</td></tr><tr><td valign="top"><a href="#uri-1">uri/1</a></td><td>
Returns the uri this entry is about i.e.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="add-4"></a>

### add/4 ###

<pre><code>
add(Type::<a href="#type-entry_type">entry_type()</a>, Uri::<a href="#type-uri">uri()</a>, Options::#{}, Ctxt::<a href="bondy_context.md#type-context">bondy_context:context()</a>) -&gt; {ok, <a href="#type-details_map">details_map()</a>, IsFirstEntry::boolean()} | {error, {already_exists, <a href="#type-id">id()</a>}}
</code></pre>
<br />

Adds an entry to the registry.

Adding an already existing entry is treated differently based on whether the
entry is a registration or a subscription.

According to the WAMP specifictation, in the case of a subscription that was
already added before by the same _Subscriber_, the _Broker_ should not fail
and answer with a "SUBSCRIBED" message, containing the existing
"Subscription|id". So in this case this function returns
{ok, details_map(), boolean()}.

In case of a registration, as a default, only a single Callee may
register a procedure for an URI. However, when shared registrations are
supported, then the first Callee to register a procedure for a particular URI
MAY determine that additional registrations for this URI are allowed, and
what Invocation Rules to apply in case such additional registrations are
made.

This is configured through the 'invoke' options.
When invoke is not 'single', Dealer MUST fail all subsequent attempts to
register a procedure for the URI where the value for the invoke option does
not match that of the initial registration. Accordingly this function might
return an error tuple.

<a name="created-1"></a>

### created/1 ###

<pre><code>
created(Entry::<a href="#type-entry">entry()</a>) -&gt; <a href="calendar.md#type-date_time">calendar:date_time()</a>
</code></pre>
<br />

Returns the time when this entry was created.

<a name="criteria-1"></a>

### criteria/1 ###

<pre><code>
criteria(Entry::<a href="#type-entry">entry()</a>) -&gt; list()
</code></pre>
<br />

Not used at the moment

<a name="entries-1"></a>

### entries/1 ###

<pre><code>
entries(X1::<a href="#type-continuation">continuation()</a>) -&gt; {[<a href="#type-entry">entry()</a>], <a href="#type-continuation">continuation()</a> | <a href="#type-eot">eot()</a>}
</code></pre>
<br />

Continues returning the list of entries owned by a session started with
[`entries/4`](#entries-4).

The next chunk of the size specified in the initial entries/4 call is
returned together with a new Continuation, which can be used in subsequent
calls to this function.

When there are no more objects in the table, {[], '$end_of_table'} is
returned.

<a name="entries-2"></a>

### entries/2 ###

<pre><code>
entries(Type::<a href="#type-entry_type">entry_type()</a>, Ctxt::<a href="bondy_context.md#type-context">bondy_context:context()</a>) -&gt; [<a href="#type-entry">entry()</a>]
</code></pre>
<br />

Returns the list of entries owned by the the active session.

This function is equivalent to calling [`entries/2`](#entries-2) with the RealmUri
and SessionId extracted from the Context.

<a name="entries-3"></a>

### entries/3 ###

<pre><code>
entries(Type::<a href="#type-entry_type">entry_type()</a>, RealmUri::<a href="#type-uri">uri()</a>, SessionId::<a href="#type-id">id()</a>) -&gt; [<a href="#type-entry">entry()</a>]
</code></pre>
<br />

Returns the complete list of entries owned by a session matching
RealmUri and SessionId.

Use [`entries/3`](#entries-3) and [`entries/1`](#entries-1) to limit the number
of entries returned.

<a name="entries-4"></a>

### entries/4 ###

<pre><code>
entries(Type::<a href="#type-entry_type">entry_type()</a>, Realm::<a href="#type-uri">uri()</a>, SessionId::<a href="#type-id">id()</a>, Limit::pos_integer()) -&gt; {[<a href="#type-entry">entry()</a>], <a href="#type-continuation">continuation()</a> | <a href="#type-eot">eot()</a>}
</code></pre>
<br />

Works like [`entries/3`](#entries-3), but only returns a limited (Limit) number of
entries. Term Continuation can then be used in subsequent calls to entries/1
to get the next chunk of entries.

<a name="entry_id-1"></a>

### entry_id/1 ###

<pre><code>
entry_id(Entry::<a href="#type-entry">entry()</a>) -&gt; <a href="#type-id">id()</a>
</code></pre>
<br />

Returns the value of the subscription's or registration's entry_id
property.

<a name="lookup-3"></a>

### lookup/3 ###

<pre><code>
lookup(Type::<a href="#type-entry_type">entry_type()</a>, EntryId::<a href="#type-id">id()</a>, Ctxt::<a href="bondy_context.md#type-context">bondy_context:context()</a>) -&gt; <a href="#type-entry">entry()</a> | {error, not_found}
</code></pre>
<br />

Lookup an entry by Type, Id (Registration or Subscription Id) and Ctxt

<a name="lookup-4"></a>

### lookup/4 ###

<pre><code>
lookup(Type::<a href="#type-entry_type">entry_type()</a>, EntryId::<a href="#type-id">id()</a>, SessionId::<a href="#type-id">id()</a>, RealmUri::<a href="#type-uri">uri()</a>) -&gt; <a href="#type-entry">entry()</a> | {error, not_found}
</code></pre>
<br />

<a name="match-1"></a>

### match/1 ###

<pre><code>
match(X1::<a href="#type-continuation">continuation()</a>) -&gt; {[<a href="#type-entry">entry()</a>], <a href="#type-continuation">continuation()</a>} | <a href="#type-eot">eot()</a>
</code></pre>
<br />

<a name="match-3"></a>

### match/3 ###

<pre><code>
match(Type::<a href="#type-entry_type">entry_type()</a>, Uri::<a href="#type-uri">uri()</a>, Ctxt::<a href="bondy_context.md#type-context">bondy_context:context()</a>) -&gt; {[<a href="#type-entry">entry()</a>], <a href="#type-continuation">continuation()</a>} | <a href="#type-eot">eot()</a>
</code></pre>
<br />

Calls [`match/4`](#match-4).

<a name="match-4"></a>

### match/4 ###

<pre><code>
match(Type::<a href="#type-entry_type">entry_type()</a>, Uri::<a href="#type-uri">uri()</a>, Ctxt::<a href="bondy_context.md#type-context">bondy_context:context()</a>, Opts::#{}) -&gt; {[<a href="#type-entry">entry()</a>], <a href="#type-continuation">continuation()</a>} | <a href="#type-eot">eot()</a>
</code></pre>
<br />

Returns the entries matching either a topic or procedure Uri according to
each entry's configured match specification.

This function is used by the Broker to return all subscriptions that match a
topic. And in case of registrations it is used by the Dealer to return all
registrations matching a procedure.

<a name="match_policy-1"></a>

### match_policy/1 ###

<pre><code>
match_policy(Entry::<a href="#type-entry">entry()</a>) -&gt; binary()
</code></pre>
<br />

Returns the match_policy used by this subscription or regitration.

<a name="options-1"></a>

### options/1 ###

<pre><code>
options(Entry::<a href="#type-entry">entry()</a>) -&gt; #{}
</code></pre>
<br />

Returns the value of the 'options' property of the entry.

<a name="realm_uri-1"></a>

### realm_uri/1 ###

<pre><code>
realm_uri(Entry::<a href="#type-entry">entry()</a>) -&gt; <a href="#type-uri">uri()</a>
</code></pre>
<br />

Returns the value of the subscription's or registration's realm_uri property.

<a name="remove-3"></a>

### remove/3 ###

<pre><code>
remove(Type::<a href="#type-entry_type">entry_type()</a>, EntryId::<a href="#type-id">id()</a>, Ctxt::<a href="bondy_context.md#type-context">bondy_context:context()</a>) -&gt; ok | {error, not_found}
</code></pre>
<br />

<a name="remove-4"></a>

### remove/4 ###

<pre><code>
remove(Type::<a href="#type-entry_type">entry_type()</a>, EntryId::<a href="#type-id">id()</a>, Ctxt::<a href="bondy_context.md#type-context">bondy_context:context()</a>, Task::<a href="#type-task">task()</a> | undefined) -&gt; ok | {error, not_found}
</code></pre>
<br />

<a name="remove_all-2"></a>

### remove_all/2 ###

<pre><code>
remove_all(Type::<a href="#type-entry_type">entry_type()</a>, Ctxt::<a href="bondy_context.md#type-context">bondy_context:context()</a>) -&gt; ok
</code></pre>
<br />

Removes all entries matching the context's realm and session_id (if any).

<a name="remove_all-3"></a>

### remove_all/3 ###

<pre><code>
remove_all(Type::<a href="#type-entry_type">entry_type()</a>, Ctxt::<a href="bondy_context.md#type-context">bondy_context:context()</a>, Task::<a href="#type-task">task()</a> | undefined) -&gt; ok
</code></pre>
<br />

Removes all entries matching the context's realm and session_id (if any).

<a name="session_id-1"></a>

### session_id/1 ###

<pre><code>
session_id(Entry::<a href="#type-entry">entry()</a>) -&gt; <a href="#type-id">id()</a>
</code></pre>
<br />

Returns the value of the subscription's or registration's session_id
property.

<a name="to_details_map-1"></a>

### to_details_map/1 ###

<pre><code>
to_details_map(Entry::<a href="#type-entry">entry()</a>) -&gt; <a href="#type-details_map">details_map()</a>
</code></pre>
<br />

Converts the entry into a map according to the WAMP protocol Details
dictionary format.

<a name="type-1"></a>

### type/1 ###

<pre><code>
type(Entry::<a href="#type-entry">entry()</a>) -&gt; <a href="#type-entry_type">entry_type()</a>
</code></pre>
<br />

Returns the type of the entry, the atom 'registration' or 'subscription'.

<a name="uri-1"></a>

### uri/1 ###

<pre><code>
uri(Entry::<a href="#type-entry">entry()</a>) -&gt; <a href="#type-uri">uri()</a>
</code></pre>
<br />

Returns the uri this entry is about i.e. either a subscription topic_uri or
a registration procedure_uri.

