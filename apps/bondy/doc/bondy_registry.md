

# Module bondy_registry #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

An in-memory registry for PubSub subscriptions and Routed RPC registrations,
providing pattern matching capabilities including support for WAMP's
version 2.0 match policies (exact, prefix and wilcard).

__Behaviours:__ [`gen_server`](gen_server.md).

<a name="description"></a>

## Description ##

The registry is stored both in memory (tuplespace) and disk (plum_db).
Also a trie-based indexed is used for exact and prefix matching currently
while support for wilcard matching is soon to be supported.

This module also provides a singleton server to perform the initialisation
of the tuplespace from the plum_db copy.
The tuplespace library protects the ets tables that constitute the in-memory
store while the art library also protectes the ets tables behind the trie,
so they can survive in case the singleton dies.
<a name="types"></a>

## Data Types ##




### <a name="type-continuation">continuation()</a> ###


<pre><code>
continuation() = {<a href="bondy_registry_entry.md#type-entry_type">bondy_registry_entry:entry_type()</a>, <a href="plum_db.md#type-continuation">plum_db:continuation()</a>}
</code></pre>




### <a name="type-eot">eot()</a> ###


<pre><code>
eot() = ?EOT
</code></pre>




### <a name="type-task">task()</a> ###


<pre><code>
task() = fun((<a href="bondy_registry_entry.md#type-details_map">bondy_registry_entry:details_map()</a>, <a href="bondy_context.md#type-t">bondy_context:t()</a>) -&gt; ok)
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#add-4">add/4</a></td><td>
Adds an entry to the registry.</td></tr><tr><td valign="top"><a href="#add_local_subscription-4">add_local_subscription/4</a></td><td>A function used internally by Bondy to register local subscribers
and callees.</td></tr><tr><td valign="top"><a href="#code_change-3">code_change/3</a></td><td></td></tr><tr><td valign="top"><a href="#entries-1">entries/1</a></td><td>
Continues returning the list of entries owned by a session started with
<a href="#entries-4"><code>entries/4</code></a>.</td></tr><tr><td valign="top"><a href="#entries-2">entries/2</a></td><td>
Returns the list of entries owned by the the active session.</td></tr><tr><td valign="top"><a href="#entries-4">entries/4</a></td><td>
Returns the complete list of entries owned by a session matching
RealmUri and SessionId.</td></tr><tr><td valign="top"><a href="#entries-5">entries/5</a></td><td>
Works like <a href="#entries-3"><code>entries/3</code></a>, but only returns a limited (Limit) number of
entries.</td></tr><tr><td valign="top"><a href="#handle_call-3">handle_call/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_cast-2">handle_cast/2</a></td><td></td></tr><tr><td valign="top"><a href="#handle_info-2">handle_info/2</a></td><td></td></tr><tr><td valign="top"><a href="#info-0">info/0</a></td><td>Returns information about the registry.</td></tr><tr><td valign="top"><a href="#info-1">info/1</a></td><td></td></tr><tr><td valign="top"><a href="#init-0">init/0</a></td><td></td></tr><tr><td valign="top"><a href="#init-1">init/1</a></td><td></td></tr><tr><td valign="top"><a href="#lookup-1">lookup/1</a></td><td></td></tr><tr><td valign="top"><a href="#lookup-3">lookup/3</a></td><td></td></tr><tr><td valign="top"><a href="#lookup-4">lookup/4</a></td><td></td></tr><tr><td valign="top"><a href="#match-1">match/1</a></td><td></td></tr><tr><td valign="top"><a href="#match-3">match/3</a></td><td>
Calls <a href="#match-4"><code>match/4</code></a>.</td></tr><tr><td valign="top"><a href="#match-4">match/4</a></td><td>
Returns the entries matching either a topic or procedure Uri according to
each entry's configured match specification.</td></tr><tr><td valign="top"><a href="#remove-1">remove/1</a></td><td></td></tr><tr><td valign="top"><a href="#remove-3">remove/3</a></td><td></td></tr><tr><td valign="top"><a href="#remove-4">remove/4</a></td><td></td></tr><tr><td valign="top"><a href="#remove_all-2">remove_all/2</a></td><td>
Removes all entries matching the context's realm and session_id (if any).</td></tr><tr><td valign="top"><a href="#remove_all-3">remove_all/3</a></td><td>
Removes all entries matching the context's realm and session_id (if any).</td></tr><tr><td valign="top"><a href="#remove_all-4">remove_all/4</a></td><td>Removes all registry entries of type Type, for a {RealmUri, Node
SessionId} relation.</td></tr><tr><td valign="top"><a href="#start_link-0">start_link/0</a></td><td></td></tr><tr><td valign="top"><a href="#terminate-2">terminate/2</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="add-4"></a>

### add/4 ###

<pre><code>
add(Type::<a href="bondy_registry_entry.md#type-entry_type">bondy_registry_entry:entry_type()</a>, Uri::<a href="#type-uri">uri()</a>, Options::map(), Ctxt::<a href="bondy_context.md#type-t">bondy_context:t()</a>) -&gt; {ok, <a href="bondy_registry_entry.md#type-details_map">bondy_registry_entry:details_map()</a>, IsFirstEntry::boolean()} | {error, {already_exists, <a href="bondy_registry_entry.md#type-details_map">bondy_registry_entry:details_map()</a>}}
</code></pre>
<br />

Adds an entry to the registry.

Adding an already existing entry is treated differently based on whether the
entry is a registration or a subscription.

According to the WAMP specification, in the case of a subscription that was
already added before by the same _Subscriber_, the _Broker_ should not fail
and answer with a "SUBSCRIBED" message, containing the existing
"Subscription|id". So in this case this function returns
{ok, bondy_registry_entry:details_map(), boolean()}.

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

<a name="add_local_subscription-4"></a>

### add_local_subscription/4 ###

<pre><code>
add_local_subscription(RealmUri::<a href="#type-uri">uri()</a>, Uri::<a href="#type-uri">uri()</a>, Opts::map(), Pid::pid()) -&gt; {ok, <a href="bondy_registry_entry.md#type-details_map">bondy_registry_entry:details_map()</a>, IsFirstEntry::boolean()} | {error, {already_exists, <a href="bondy_registry_entry.md#type-details_map">bondy_registry_entry:details_map()</a>}}
</code></pre>
<br />

A function used internally by Bondy to register local subscribers
and callees.

<a name="code_change-3"></a>

### code_change/3 ###

`code_change(OldVsn, State, Extra) -> any()`

<a name="entries-1"></a>

### entries/1 ###

<pre><code>
entries(X1::<a href="#type-continuation">continuation()</a>) -&gt; {[<a href="bondy_registry_entry.md#type-t">bondy_registry_entry:t()</a>], <a href="#type-continuation">continuation()</a> | <a href="#type-eot">eot()</a>}
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
entries(Type::<a href="bondy_registry_entry.md#type-entry_type">bondy_registry_entry:entry_type()</a>, Ctxt::<a href="bondy_context.md#type-t">bondy_context:t()</a>) -&gt; [<a href="bondy_registry_entry.md#type-t">bondy_registry_entry:t()</a>]
</code></pre>
<br />

Returns the list of entries owned by the the active session.

This function is equivalent to calling [`entries/2`](#entries-2) with the RealmUri
and SessionId extracted from the Context.

<a name="entries-4"></a>

### entries/4 ###

<pre><code>
entries(Type::<a href="bondy_registry_entry.md#type-entry_type">bondy_registry_entry:entry_type()</a>, RealmUri::<a href="#type-uri">uri()</a>, Node::atom(), SessionId::<a href="#type-id">id()</a>) -&gt; [<a href="bondy_registry_entry.md#type-t">bondy_registry_entry:t()</a>]
</code></pre>
<br />

Returns the complete list of entries owned by a session matching
RealmUri and SessionId.

Use [`entries/3`](#entries-3) and [`entries/1`](#entries-1) to limit the number
of entries returned.

<a name="entries-5"></a>

### entries/5 ###

<pre><code>
entries(Type::<a href="bondy_registry_entry.md#type-entry_type">bondy_registry_entry:entry_type()</a>, Realm::<a href="#type-uri">uri()</a>, Node::atom(), SessionId::<a href="#type-id">id()</a>, Limit::pos_integer()) -&gt; {[<a href="bondy_registry_entry.md#type-t">bondy_registry_entry:t()</a>], <a href="#type-continuation">continuation()</a> | <a href="#type-eot">eot()</a>}
</code></pre>
<br />

Works like [`entries/3`](#entries-3), but only returns a limited (Limit) number of
entries. Term Continuation can then be used in subsequent calls to entries/1
to get the next chunk of entries.

<a name="handle_call-3"></a>

### handle_call/3 ###

`handle_call(Event, From, State0) -> any()`

<a name="handle_cast-2"></a>

### handle_cast/2 ###

`handle_cast(Event, State) -> any()`

<a name="handle_info-2"></a>

### handle_info/2 ###

`handle_info(Info, State) -> any()`

<a name="info-0"></a>

### info/0 ###

`info() -> any()`

Returns information about the registry

<a name="info-1"></a>

### info/1 ###

`info(X1) -> any()`

<a name="init-0"></a>

### init/0 ###

`init() -> any()`

<a name="init-1"></a>

### init/1 ###

`init(X1) -> any()`

<a name="lookup-1"></a>

### lookup/1 ###

<pre><code>
lookup(Key::<a href="bondy_registry_entry.md#type-entry_key">bondy_registry_entry:entry_key()</a>) -&gt; any()
</code></pre>
<br />

<a name="lookup-3"></a>

### lookup/3 ###

`lookup(Type, EntryId, RealmUri) -> any()`

<a name="lookup-4"></a>

### lookup/4 ###

`lookup(Type, EntryId, RealmUri, Details) -> any()`

<a name="match-1"></a>

### match/1 ###

<pre><code>
match(X1::<a href="#type-continuation">continuation()</a>) -&gt; {[<a href="bondy_registry_entry.md#type-t">bondy_registry_entry:t()</a>], <a href="#type-continuation">continuation()</a>} | <a href="#type-eot">eot()</a>
</code></pre>
<br />

<a name="match-3"></a>

### match/3 ###

<pre><code>
match(Type::<a href="bondy_registry_entry.md#type-entry_type">bondy_registry_entry:entry_type()</a>, Uri::<a href="#type-uri">uri()</a>, RealmUri::<a href="#type-uri">uri()</a>) -&gt; {[<a href="bondy_registry_entry.md#type-t">bondy_registry_entry:t()</a>], <a href="#type-continuation">continuation()</a>} | <a href="#type-eot">eot()</a>
</code></pre>
<br />

Calls [`match/4`](#match-4).

<a name="match-4"></a>

### match/4 ###

<pre><code>
match(Type::<a href="bondy_registry_entry.md#type-entry_type">bondy_registry_entry:entry_type()</a>, Uri::<a href="#type-uri">uri()</a>, RealmUri::<a href="#type-uri">uri()</a>, Opts::map()) -&gt; {[<a href="bondy_registry_entry.md#type-t">bondy_registry_entry:t()</a>], <a href="#type-continuation">continuation()</a>} | <a href="#type-eot">eot()</a>
</code></pre>
<br />

Returns the entries matching either a topic or procedure Uri according to
each entry's configured match specification.

This function is used by the Broker to return all subscriptions that match a
topic. And in case of registrations it is used by the Dealer to return all
registrations matching a procedure.

<a name="remove-1"></a>

### remove/1 ###

<pre><code>
remove(Entry::<a href="bondy_registry_entry.md#type-t">bondy_registry_entry:t()</a>) -&gt; ok
</code></pre>
<br />

<a name="remove-3"></a>

### remove/3 ###

<pre><code>
remove(Type::<a href="bondy_registry_entry.md#type-entry_type">bondy_registry_entry:entry_type()</a>, EntryId::<a href="#type-id">id()</a>, Ctxt::<a href="bondy_context.md#type-t">bondy_context:t()</a>) -&gt; ok | {error, not_found}
</code></pre>
<br />

<a name="remove-4"></a>

### remove/4 ###

<pre><code>
remove(Type::<a href="bondy_registry_entry.md#type-entry_type">bondy_registry_entry:entry_type()</a>, EntryId::<a href="#type-id">id()</a>, Ctxt::<a href="bondy_context.md#type-t">bondy_context:t()</a>, Task::<a href="#type-task">task()</a> | undefined) -&gt; ok
</code></pre>
<br />

<a name="remove_all-2"></a>

### remove_all/2 ###

<pre><code>
remove_all(Type::<a href="bondy_registry_entry.md#type-entry_type">bondy_registry_entry:entry_type()</a>, Ctxt::<a href="bondy_context.md#type-t">bondy_context:t()</a>) -&gt; ok
</code></pre>
<br />

Removes all entries matching the context's realm and session_id (if any).

<a name="remove_all-3"></a>

### remove_all/3 ###

<pre><code>
remove_all(Type::<a href="bondy_registry_entry.md#type-entry_type">bondy_registry_entry:entry_type()</a>, Ctxt::<a href="bondy_context.md#type-t">bondy_context:t()</a>, Task::<a href="#type-task">task()</a> | undefined) -&gt; ok
</code></pre>
<br />

Removes all entries matching the context's realm and session_id (if any).

<a name="remove_all-4"></a>

### remove_all/4 ###

<pre><code>
remove_all(Type::<a href="bondy_registry_entry.md#type-entry_type">bondy_registry_entry:entry_type()</a>, RealmUri::<a href="#type-uri">uri()</a>, Node::atom(), SessionId::<a href="#type-id">id()</a>) -&gt; [<a href="bondy_registry_entry.md#type-t">bondy_registry_entry:t()</a>]
</code></pre>
<br />

Removes all registry entries of type Type, for a {RealmUri, Node
SessionId} relation.

<a name="start_link-0"></a>

### start_link/0 ###

`start_link() -> any()`

<a name="terminate-2"></a>

### terminate/2 ###

`terminate(Reason, State) -> any()`

