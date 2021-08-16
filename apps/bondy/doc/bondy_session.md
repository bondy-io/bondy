

# Module bondy_session #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

A Session (wamp session) is a transient conversation between two
WAMP Peers attached to a Realm and running over a Transport.

<a name="description"></a>

## Description ##

Bondy implementation ties the lifetime of the underlying transport connection
for a WAMP connection to that of a WAMP Session
i.e. establish a new transport-layer connection as part of each new
session establishment.

A Bondy Session is a not an application Session and is not a store for
application specific content (an application session store should be
implemented as a service i.e. a Callee).

Currently sessions are not persistent i.e. if the connection closes the
session data will be lost.

<a name="types"></a>

## Data Types ##




### <a name="type-details">details()</a> ###


<pre><code>
details() = #{session =&gt; <a href="#type-id">id()</a>, authid =&gt; <a href="#type-id">id()</a>, authrole =&gt; binary(), authmethod =&gt; binary(), authprovider =&gt; binary(), transport =&gt; #{peername =&gt; binary()}}
</code></pre>




### <a name="type-peer">peer()</a> ###


<pre><code>
peer() = {<a href="inet.md#type-ip_address">inet:ip_address()</a>, <a href="inet.md#type-port_number">inet:port_number()</a>}
</code></pre>




### <a name="type-quota_window">quota_window()</a> ###


<pre><code>
quota_window() = #quota_window{limit = pos_integer(), renews = pos_integer(), remaining = pos_integer(), duration = pos_integer()}
</code></pre>




### <a name="type-rate_window">rate_window()</a> ###


<pre><code>
rate_window() = #rate_window{limit = pos_integer(), duration = pos_integer()}
</code></pre>




### <a name="type-session_opts">session_opts()</a> ###


<pre><code>
session_opts() = #{roles =&gt; map()}
</code></pre>




### <a name="type-t">t()</a> ###


<pre><code>
t() = #session{id = <a href="#type-id">id()</a>, realm_uri = <a href="#type-uri">uri()</a>, node = atom(), pid = pid() | undefined, peer = <a href="#type-peer">peer()</a> | undefined, agent = binary(), seq = non_neg_integer(), roles = map() | undefined, security_enabled = boolean(), is_anonymous = boolean(), authid = binary() | undefined, authrole = binary() | undefined, authroles = [binary()], authmethod = binary() | undefined, rbac_context = <a href="bondy_rbac.md#type-context">bondy_rbac:context()</a> | undefined, created = pos_integer(), expires_in = pos_integer() | infinity, rate = <a href="#type-rate_window">rate_window()</a>, quota = <a href="#type-quota_window">quota_window()</a>}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#agent-1">agent/1</a></td><td></td></tr><tr><td valign="top"><a href="#authid-1">authid/1</a></td><td></td></tr><tr><td valign="top"><a href="#authmethod-1">authmethod/1</a></td><td></td></tr><tr><td valign="top"><a href="#close-1">close/1</a></td><td></td></tr><tr><td valign="top"><a href="#created-1">created/1</a></td><td>Returns the time at which the session was created, Its value is a
timestamp in seconds.</td></tr><tr><td valign="top"><a href="#fetch-1">fetch/1</a></td><td>
Retrieves the session identified by Id from the tuplespace.</td></tr><tr><td valign="top"><a href="#id-1">id/1</a></td><td></td></tr><tr><td valign="top"><a href="#incr_seq-1">incr_seq/1</a></td><td></td></tr><tr><td valign="top"><a href="#info-1">info/1</a></td><td></td></tr><tr><td valign="top"><a href="#is_security_enabled-1">is_security_enabled/1</a></td><td></td></tr><tr><td valign="top"><a href="#list-0">list/0</a></td><td></td></tr><tr><td valign="top"><a href="#list-1">list/1</a></td><td></td></tr><tr><td valign="top"><a href="#list_peer_ids-1">list_peer_ids/1</a></td><td></td></tr><tr><td valign="top"><a href="#list_peer_ids-2">list_peer_ids/2</a></td><td></td></tr><tr><td valign="top"><a href="#lookup-1">lookup/1</a></td><td>
Retrieves the session identified by Id from the tuplespace or 'not_found'
if it doesn't exist.</td></tr><tr><td valign="top"><a href="#lookup-2">lookup/2</a></td><td>
Retrieves the session identified by Id from the tuplespace or 'not_found'
if it doesn't exist.</td></tr><tr><td valign="top"><a href="#new-3">new/3</a></td><td>Creates a new transient session (not persisted).</td></tr><tr><td valign="top"><a href="#new-4">new/4</a></td><td></td></tr><tr><td valign="top"><a href="#node-1">node/1</a></td><td>
Returns the node of the process managing the transport that the session
identified by Id runs on.</td></tr><tr><td valign="top"><a href="#open-3">open/3</a></td><td>
Creates a new session provided the RealmUri exists or can be dynamically
created.</td></tr><tr><td valign="top"><a href="#open-4">open/4</a></td><td>
Creates a new session provided the RealmUri exists or can be dynamically
created.</td></tr><tr><td valign="top"><a href="#peer-1">peer/1</a></td><td></td></tr><tr><td valign="top"><a href="#peer_id-1">peer_id/1</a></td><td>Returns the identifier for the owner of this session.</td></tr><tr><td valign="top"><a href="#pid-1">pid/1</a></td><td>
Returns the pid of the process managing the transport that the session
identified by Id runs on.</td></tr><tr><td valign="top"><a href="#rbac_context-1">rbac_context/1</a></td><td></td></tr><tr><td valign="top"><a href="#realm_uri-1">realm_uri/1</a></td><td></td></tr><tr><td valign="top"><a href="#roles-1">roles/1</a></td><td></td></tr><tr><td valign="top"><a href="#size-0">size/0</a></td><td>
Returns the number of sessions in the tuplespace.</td></tr><tr><td valign="top"><a href="#to_external-1">to_external/1</a></td><td></td></tr><tr><td valign="top"><a href="#update-1">update/1</a></td><td></td></tr><tr><td valign="top"><a href="#user-1">user/1</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="agent-1"></a>

### agent/1 ###

<pre><code>
agent(Session::<a href="#type-t">t()</a>) -&gt; binary() | undefined
</code></pre>
<br />

<a name="authid-1"></a>

### authid/1 ###

<pre><code>
authid(Session::<a href="#type-t">t()</a>) -&gt; <a href="bondy_rbac_user.md#type-username">bondy_rbac_user:username()</a>
</code></pre>
<br />

<a name="authmethod-1"></a>

### authmethod/1 ###

<pre><code>
authmethod(Session::<a href="#type-t">t()</a>) -&gt; binary()
</code></pre>
<br />

<a name="close-1"></a>

### close/1 ###

<pre><code>
close(Session::<a href="#type-t">t()</a>) -&gt; ok
</code></pre>
<br />

<a name="created-1"></a>

### created/1 ###

<pre><code>
created(Session::<a href="#type-t">t()</a>) -&gt; pos_integer()
</code></pre>
<br />

Returns the time at which the session was created, Its value is a
timestamp in seconds.

<a name="fetch-1"></a>

### fetch/1 ###

<pre><code>
fetch(Id::<a href="#type-id">id()</a>) -&gt; <a href="#type-t">t()</a> | no_return()
</code></pre>
<br />

Retrieves the session identified by Id from the tuplespace. If the session
does not exist it fails with reason '{badarg, Id}'.

<a name="id-1"></a>

### id/1 ###

<pre><code>
id(Session::<a href="#type-t">t()</a>) -&gt; <a href="#type-id">id()</a>
</code></pre>
<br />

<a name="incr_seq-1"></a>

### incr_seq/1 ###

<pre><code>
incr_seq(Session::<a href="#type-id">id()</a> | <a href="#type-t">t()</a>) -&gt; map()
</code></pre>
<br />

<a name="info-1"></a>

### info/1 ###

<pre><code>
info(Session::<a href="#type-t">t()</a>) -&gt; <a href="#type-details">details()</a>
</code></pre>
<br />

<a name="is_security_enabled-1"></a>

### is_security_enabled/1 ###

<pre><code>
is_security_enabled(Session::<a href="#type-t">t()</a>) -&gt; boolean()
</code></pre>
<br />

<a name="list-0"></a>

### list/0 ###

`list() -> any()`

<a name="list-1"></a>

### list/1 ###

`list(X1) -> any()`

<a name="list_peer_ids-1"></a>

### list_peer_ids/1 ###

`list_peer_ids(N) -> any()`

<a name="list_peer_ids-2"></a>

### list_peer_ids/2 ###

`list_peer_ids(RealmUri, N) -> any()`

<a name="lookup-1"></a>

### lookup/1 ###

<pre><code>
lookup(Id::<a href="#type-id">id()</a>) -&gt; <a href="#type-t">t()</a> | {error, not_found}
</code></pre>
<br />

Retrieves the session identified by Id from the tuplespace or 'not_found'
if it doesn't exist.

<a name="lookup-2"></a>

### lookup/2 ###

<pre><code>
lookup(RealmUri::<a href="#type-uri">uri()</a>, Id::<a href="#type-id">id()</a>) -&gt; <a href="#type-t">t()</a> | {error, not_found}
</code></pre>
<br />

Retrieves the session identified by Id from the tuplespace or 'not_found'
if it doesn't exist.

<a name="new-3"></a>

### new/3 ###

<pre><code>
new(Peer::<a href="#type-peer">peer()</a>, RealmUri::<a href="#type-uri">uri()</a> | <a href="bondy_realm.md#type-t">bondy_realm:t()</a>, Opts::<a href="#type-session_opts">session_opts()</a>) -&gt; <a href="#type-t">t()</a> | no_return()
</code></pre>
<br />

Creates a new transient session (not persisted)

<a name="new-4"></a>

### new/4 ###

<pre><code>
new(Id::<a href="#type-id">id()</a>, Peer::<a href="#type-peer">peer()</a>, RealmUri::<a href="#type-uri">uri()</a> | <a href="bondy_realm.md#type-t">bondy_realm:t()</a>, Opts::<a href="#type-session_opts">session_opts()</a>) -&gt; <a href="#type-t">t()</a> | no_return()
</code></pre>
<br />

<a name="node-1"></a>

### node/1 ###

<pre><code>
node(Session::<a href="#type-t">t()</a>) -&gt; atom()
</code></pre>
<br />

Returns the node of the process managing the transport that the session
identified by Id runs on.

<a name="open-3"></a>

### open/3 ###

<pre><code>
open(Peer::<a href="#type-peer">peer()</a>, RealmUri::<a href="#type-uri">uri()</a> | <a href="bondy_realm.md#type-t">bondy_realm:t()</a>, Opts::<a href="#type-session_opts">session_opts()</a>) -&gt; <a href="#type-t">t()</a> | no_return()
</code></pre>
<br />

Creates a new session provided the RealmUri exists or can be dynamically
created. It assigns a new Id.
It calls [`bondy_utils:get_realm/1`](bondy_utils.md#get_realm-1) which will fail with an exception
if the realm does not exist or cannot be created
-----------------------------------------------------------------------------

<a name="open-4"></a>

### open/4 ###

<pre><code>
open(Id::<a href="#type-id">id()</a>, Peer::<a href="#type-peer">peer()</a>, RealmUri::<a href="#type-uri">uri()</a> | <a href="bondy_realm.md#type-t">bondy_realm:t()</a>, Opts::<a href="#type-session_opts">session_opts()</a>) -&gt; <a href="#type-t">t()</a> | no_return()
</code></pre>
<br />

Creates a new session provided the RealmUri exists or can be dynamically
created.
It calls [`bondy_utils:get_realm/1`](bondy_utils.md#get_realm-1) which will fail with an exception
if the realm does not exist or cannot be created
-----------------------------------------------------------------------------

<a name="peer-1"></a>

### peer/1 ###

<pre><code>
peer(Session::<a href="#type-t">t()</a>) -&gt; <a href="#type-peer">peer()</a>
</code></pre>
<br />

<a name="peer_id-1"></a>

### peer_id/1 ###

<pre><code>
peer_id(Session::<a href="#type-t">t()</a>) -&gt; <a href="#type-local_peer_id">local_peer_id()</a>
</code></pre>
<br />

Returns the identifier for the owner of this session

<a name="pid-1"></a>

### pid/1 ###

<pre><code>
pid(Session::<a href="#type-t">t()</a>) -&gt; pid()
</code></pre>
<br />

Returns the pid of the process managing the transport that the session
identified by Id runs on.

<a name="rbac_context-1"></a>

### rbac_context/1 ###

<pre><code>
rbac_context(Session::<a href="#type-id">id()</a> | <a href="#type-t">t()</a>) -&gt; <a href="bondy_rbac.md#type-context">bondy_rbac:context()</a>
</code></pre>
<br />

<a name="realm_uri-1"></a>

### realm_uri/1 ###

<pre><code>
realm_uri(Session::<a href="#type-id">id()</a> | <a href="#type-t">t()</a>) -&gt; <a href="#type-uri">uri()</a>
</code></pre>
<br />

<a name="roles-1"></a>

### roles/1 ###

<pre><code>
roles(Session::<a href="#type-id">id()</a> | <a href="#type-t">t()</a>) -&gt; map()
</code></pre>
<br />

<a name="size-0"></a>

### size/0 ###

<pre><code>
size() -&gt; non_neg_integer()
</code></pre>
<br />

Returns the number of sessions in the tuplespace.

<a name="to_external-1"></a>

### to_external/1 ###

<pre><code>
to_external(Session::<a href="#type-t">t()</a>) -&gt; <a href="#type-details">details()</a>
</code></pre>
<br />

<a name="update-1"></a>

### update/1 ###

<pre><code>
update(Session::<a href="#type-t">t()</a>) -&gt; ok
</code></pre>
<br />

<a name="user-1"></a>

### user/1 ###

<pre><code>
user(Session::<a href="#type-t">t()</a>) -&gt; <a href="bondy_rbac_user.md#type-t">bondy_rbac_user:t()</a>
</code></pre>
<br />

