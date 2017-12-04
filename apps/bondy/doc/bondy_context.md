

# Module bondy_context #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

A Bondy Context lets you access information that defines the state of an
interaction.

<a name="description"></a>

## Description ##

In a typical interacion, several actors or objects have a hand
in what is going on e.g. bondy_session, wamp_realm, etc.

The Bondy Context is passed as an argument through the whole request-response
loop to provide access to that information.
<a name="types"></a>

## Data Types ##




### <a name="type-context">context()</a> ###


<pre><code>
context() = #{id =&gt; <a href="#type-id">id()</a>, realm_uri =&gt; <a href="#type-uri">uri()</a>, session =&gt; <a href="bondy_session.md#type-session">bondy_session:session()</a> | undefined, peer =&gt; <a href="bondy_session.md#type-peer">bondy_session:peer()</a>, authmethod =&gt; binary(), authid =&gt; binary(), roles =&gt; #{}, goodbye_initiated =&gt; boolean(), challenge_sent =&gt; {true, AuthMethod::any()} | false, awaiting_calls =&gt; <a href="sets.md#type-set">sets:set()</a>, request_id =&gt; <a href="#type-id">id()</a>, request_timeout =&gt; non_neg_integer(), request_details =&gt; #{}, user_info =&gt; #{}}
</code></pre>




### <a name="type-subprotocol_2">subprotocol_2()</a> ###


<pre><code>
subprotocol_2() = <a href="#type-subprotocol">subprotocol()</a> | {http, text, json | msgpack}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#add_awaiting_call-2">add_awaiting_call/2</a></td><td></td></tr><tr><td valign="top"><a href="#awaiting_calls-1">awaiting_calls/1</a></td><td>
Returns a list containing the identifiers for the calls the peer performed
and it is still awaiting a response for.</td></tr><tr><td valign="top"><a href="#close-1">close/1</a></td><td>
Closes the context.</td></tr><tr><td valign="top"><a href="#has_session-1">has_session/1</a></td><td>
Returns true if the context is associated with a session,
false otherwise.</td></tr><tr><td valign="top"><a href="#is_feature_enabled-3">is_feature_enabled/3</a></td><td>
Returns true if the feature Feature is enabled for role Role.</td></tr><tr><td valign="top"><a href="#new-0">new/0</a></td><td>
Initialises a new context.</td></tr><tr><td valign="top"><a href="#new-2">new/2</a></td><td></td></tr><tr><td valign="top"><a href="#peer-1">peer/1</a></td><td>
Returns the peer of the provided context.</td></tr><tr><td valign="top"><a href="#peer_id-1">peer_id/1</a></td><td></td></tr><tr><td valign="top"><a href="#realm_uri-1">realm_uri/1</a></td><td>
Returns the realm uri of the provided context.</td></tr><tr><td valign="top"><a href="#remove_awaiting_call-2">remove_awaiting_call/2</a></td><td></td></tr><tr><td valign="top"><a href="#request_id-1">request_id/1</a></td><td>
Returns the current request id.</td></tr><tr><td valign="top"><a href="#request_timeout-1">request_timeout/1</a></td><td>
Returns the current request timeout.</td></tr><tr><td valign="top"><a href="#reset-1">reset/1</a></td><td>
Resets the context.</td></tr><tr><td valign="top"><a href="#roles-1">roles/1</a></td><td>
Returns the roles of the provided context.</td></tr><tr><td valign="top"><a href="#session-1">session/1</a></td><td>
Fetches and returns the bondy_session for the associated sessionId.</td></tr><tr><td valign="top"><a href="#session_id-1">session_id/1</a></td><td>
Returns the sessionId of the provided context or 'undefined'
if there is none.</td></tr><tr><td valign="top"><a href="#set_peer-2">set_peer/2</a></td><td>
Set the peer to the provided context.</td></tr><tr><td valign="top"><a href="#set_request_id-2">set_request_id/2</a></td><td>
Sets the current request id to the provided context.</td></tr><tr><td valign="top"><a href="#set_request_timeout-2">set_request_timeout/2</a></td><td>
Sets the current request timeout to the provided context.</td></tr><tr><td valign="top"><a href="#set_roles-2">set_roles/2</a></td><td>
Sets the roles to the provided context.</td></tr><tr><td valign="top"><a href="#set_session-2">set_session/2</a></td><td>
Sets the sessionId to the provided context.</td></tr><tr><td valign="top"><a href="#set_subprotocol-2">set_subprotocol/2</a></td><td>
Set the peer to the provided context.</td></tr><tr><td valign="top"><a href="#subprotocol-1">subprotocol/1</a></td><td>
Returns the peer of the provided context.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="add_awaiting_call-2"></a>

### add_awaiting_call/2 ###

<pre><code>
add_awaiting_call(C::<a href="#type-context">context()</a>, Id::<a href="#type-id">id()</a>) -&gt; ok
</code></pre>
<br />

<a name="awaiting_calls-1"></a>

### awaiting_calls/1 ###

<pre><code>
awaiting_calls(X1::<a href="#type-context">context()</a>) -&gt; [<a href="#type-id">id()</a>]
</code></pre>
<br />

Returns a list containing the identifiers for the calls the peer performed
and it is still awaiting a response for.  This is used by the internal rpc
mechanism which is based on promises.

<a name="close-1"></a>

### close/1 ###

<pre><code>
close(Ctxt0::<a href="#type-context">context()</a>) -&gt; ok
</code></pre>
<br />

Closes the context. This function calls [`bondy_session:close/1`](bondy_session.md#close-1)
and [`bondy_router:close_context/1`](bondy_router.md#close_context-1).

<a name="has_session-1"></a>

### has_session/1 ###

<pre><code>
has_session(X1::<a href="#type-context">context()</a>) -&gt; boolean()
</code></pre>
<br />

Returns true if the context is associated with a session,
false otherwise.

<a name="is_feature_enabled-3"></a>

### is_feature_enabled/3 ###

<pre><code>
is_feature_enabled(X1::<a href="#type-context">context()</a>, Role::atom(), Feature::binary()) -&gt; boolean()
</code></pre>
<br />

Returns true if the feature Feature is enabled for role Role.

<a name="new-0"></a>

### new/0 ###

<pre><code>
new() -&gt; <a href="#type-context">context()</a>
</code></pre>
<br />

Initialises a new context.

<a name="new-2"></a>

### new/2 ###

<pre><code>
new(Peer::<a href="bondy_session.md#type-peer">bondy_session:peer()</a>, Subprotocol::<a href="#type-subprotocol_2">subprotocol_2()</a>) -&gt; <a href="#type-context">context()</a>
</code></pre>
<br />

<a name="peer-1"></a>

### peer/1 ###

<pre><code>
peer(X1::<a href="#type-context">context()</a>) -&gt; <a href="bondy_session.md#type-peer">bondy_session:peer()</a>
</code></pre>
<br />

Returns the peer of the provided context.

<a name="peer_id-1"></a>

### peer_id/1 ###

<pre><code>
peer_id(X1::<a href="#type-context">context()</a>) -&gt; <a href="#type-peer_id">peer_id()</a>
</code></pre>
<br />

<a name="realm_uri-1"></a>

### realm_uri/1 ###

<pre><code>
realm_uri(X1::<a href="#type-context">context()</a>) -&gt; <a href="#type-uri">uri()</a>
</code></pre>
<br />

Returns the realm uri of the provided context.

<a name="remove_awaiting_call-2"></a>

### remove_awaiting_call/2 ###

<pre><code>
remove_awaiting_call(C::<a href="#type-context">context()</a>, Id::<a href="#type-id">id()</a>) -&gt; ok
</code></pre>
<br />

<a name="request_id-1"></a>

### request_id/1 ###

<pre><code>
request_id(X1::<a href="#type-context">context()</a>) -&gt; <a href="#type-id">id()</a>
</code></pre>
<br />

Returns the current request id.

<a name="request_timeout-1"></a>

### request_timeout/1 ###

<pre><code>
request_timeout(X1::<a href="#type-context">context()</a>) -&gt; non_neg_integer()
</code></pre>
<br />

Returns the current request timeout.

<a name="reset-1"></a>

### reset/1 ###

<pre><code>
reset(Ctxt::<a href="#type-context">context()</a>) -&gt; <a href="#type-context">context()</a>
</code></pre>
<br />

Resets the context. Returns a copy of Ctxt where the following attributes
have been reset: request_id, request_timeout.

<a name="roles-1"></a>

### roles/1 ###

<pre><code>
roles(X1::<a href="#type-context">context()</a>) -&gt; #{}
</code></pre>
<br />

Returns the roles of the provided context.

<a name="session-1"></a>

### session/1 ###

<pre><code>
session(X1::<a href="#type-context">context()</a>) -&gt; <a href="bondy_session.md#type-session">bondy_session:session()</a> | no_return()
</code></pre>
<br />

Fetches and returns the bondy_session for the associated sessionId.

<a name="session_id-1"></a>

### session_id/1 ###

<pre><code>
session_id(X1::<a href="#type-context">context()</a>) -&gt; <a href="#type-id">id()</a> | undefined
</code></pre>
<br />

Returns the sessionId of the provided context or 'undefined'
if there is none.

<a name="set_peer-2"></a>

### set_peer/2 ###

<pre><code>
set_peer(Ctxt::<a href="#type-context">context()</a>, Peer::<a href="bondy_session.md#type-peer">bondy_session:peer()</a>) -&gt; <a href="#type-context">context()</a>
</code></pre>
<br />

Set the peer to the provided context.

<a name="set_request_id-2"></a>

### set_request_id/2 ###

<pre><code>
set_request_id(Ctxt::<a href="#type-context">context()</a>, ReqId::<a href="#type-id">id()</a>) -&gt; <a href="#type-context">context()</a>
</code></pre>
<br />

Sets the current request id to the provided context.

<a name="set_request_timeout-2"></a>

### set_request_timeout/2 ###

<pre><code>
set_request_timeout(Ctxt::<a href="#type-context">context()</a>, Timeout::non_neg_integer()) -&gt; <a href="#type-context">context()</a>
</code></pre>
<br />

Sets the current request timeout to the provided context.

<a name="set_roles-2"></a>

### set_roles/2 ###

<pre><code>
set_roles(Ctxt::<a href="#type-context">context()</a>, Roles::#{}) -&gt; <a href="#type-context">context()</a>
</code></pre>
<br />

Sets the roles to the provided context.

<a name="set_session-2"></a>

### set_session/2 ###

<pre><code>
set_session(Ctxt::<a href="#type-context">context()</a>, S::<a href="bondy_session.md#type-session">bondy_session:session()</a>) -&gt; <a href="#type-context">context()</a>
</code></pre>
<br />

Sets the sessionId to the provided context.

<a name="set_subprotocol-2"></a>

### set_subprotocol/2 ###

<pre><code>
set_subprotocol(Ctxt::<a href="#type-context">context()</a>, S::<a href="#type-subprotocol_2">subprotocol_2()</a>) -&gt; <a href="#type-context">context()</a>
</code></pre>
<br />

Set the peer to the provided context.

<a name="subprotocol-1"></a>

### subprotocol/1 ###

<pre><code>
subprotocol(X1::<a href="#type-context">context()</a>) -&gt; <a href="#type-subprotocol_2">subprotocol_2()</a>
</code></pre>
<br />

Returns the peer of the provided context.

