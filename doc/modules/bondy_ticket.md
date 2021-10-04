

# Module bondy_ticket #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

This module implements the functions to issue and manage authentication
tickets.

<a name="description"></a>

## Description ##

An authentication ticket (**ticket**) is a signed (and possibly encrypted)
assertion of a user's identity, that a client can use to authenticate the
user without the need to ask it to re-enter its credentials.

Tickets MUST be issued by a session that was opened using an authentication
method that is neither `ticket` nor `anonymous` authentication.

### Claims

* id: provides a unique identifier for the ticket.
* issued_by: identifies the principal that issued the ticket. Most
of the time this is an application identifier (a.k.asl username or client_id)
but sometimes can be the WAMP session's username (a.k.a `authid`).
* authid: identifies the principal that is the subject of the ticket.
The Claims in a ticket are normally statements. This is the WAMP session's
username (a.k.a `authid`).
* authrealm: identifies the recipients that the ticket is intended for.
The value is `RealmUri`.
* expires_at: identifies the expiration time on or after which
the ticket MUST NOT be accepted for processing.  The processing of the "exp"
claim requires that the current date/time MUST be before the expiration date/
time listed in the "exp" claim. Bondy considers a small leeway of 2 mins by
default.
* issued_at: identifies the time at which the ticket was issued.
This claim can be used to determine the age of the ticket. Its value is a
timestamp in seconds.
* issued_on: the bondy nodename in which the ticket was issued.
* scope: the scope of the ticket, consisting of
* realm: If `undefined` the ticket grants access to all realms the user
has access to by the authrealm (an SSO realm). Otherwise, the value is the
realm this ticket is valid on.

## Claims Storage

Claims for a ticket are stored in PlumDB using the prefix
`{bondy_ticket, Suffix :: binary()}` where Suffix is the concatenation of
the authentication realm's URI and the user's username (a.k.a `authid`) and
a key which is derived by the ticket's scope. The scope itself is the result
of the combination of the different options provided by the [`issue/2`](#issue-2)
function.

Thes decision to use this key as opposed to the ticket's unique identifier
is to bounds the number of tickets a user can have at any point in time in
order to reduce data storage and traffic.

### Ticket Scopes
A ticket can be issued using different scopes. The scope is determined based
on the options used to issue the ticket.

#### Local scope
The ticket was issued with `allow_sso` option set to `false` or when set to
`true` the user did not have SSO credentials, and the option `client_ticket`
was not provided.
The ticket can be used to authenticate on the session's realm only.

**Authorization**
To be able to issue this ticket, the session must have been granted the
permission `<<"bondy.issue">>` on the `<<"bondy.ticket.scope.local">>`
resource.

#### SSO Scope
The ticket was issued with `allow_sso` option set to `true` and the user has
SSO credentials, and the option `client_ticket` was not provided.
The ticket can be used to authenticate  on any realm the user has access to
through SSO.

**Authorization**
To be able to issue this ticket, the session must have been granted the
permission `<<"bondy.issue">>` on the `<<"bondy.ticket.scope.sso">>`
resource.

#### Client-Local scope
The ticket was issued with `allow_sso` option set to `false` or when set to
`true` the user did not have SSO credentials, and the option `client_ticket`
was provided having a valid ticket issued by a client
(a local or sso ticket).
The ticket can be used to authenticate on the session's realm only.

**Authorization**
To be able to issue this ticket, the session must have been granted the
permission `<<"bondy.issue">>` on the `<<"bondy.ticket.scope.client_local">>`
resource.

#### Client-SSO scope
The ticket was issued with `allow_sso` option set to `true` and the user has
SSO credentials, and the option `client_ticket` was provided having a valid
ticket issued by a client ( a local or sso ticket).
The ticket can be used to authenticate on any realm the user has access to
through SSO.

**Authorization**
To be able to issue this ticket, the session must have been granted the
permission `<<"bondy.issue">>` on the `<<"bondy.ticket.scope.client_local">>`
resource.

### Scope Summary
* `uri()` in the following table refers to the scope realm (not the
Authentication realm which is used in the prefix)

|SCOPE|Allow SSO|Client Ticket|Client Instance ID|Key|Value|
|---|---|---|---|---|---|
|Local|no|no|no|`uri()`|`claims()`|
|SSO|yes|no|no|`username()`|`claims()`|
|Client-Local|no|yes|no|`client_id()`|`[{uri(), claims()}]`|
|Client-Local|no|yes|yes|`client_id()`|`[{{uri(), instance_id()}, claims()}]`|
|Client-SSO|yes|yes|no|`client_id()`|`[{undefined, claims()}]`|
|Client-SSO|yes|yes|yes|`client_id()`|`[{{undefined, instance_id()}, claims()}]`|

### Permissions Summary
Issuing tickets requires the user to be granted certain permissions beyond the WAMP permission required to call the procedures.
|Scope|Permission|Resource|
|---|---|---|
|Local|`bondy.issue`|`bondy.ticket.scope.local`|
|SSO|`bondy.issue`|`bondy.ticket.scope.sso`|
|Client-Local|`bondy.issue`|`bondy.ticket.scope.client_local`|
|Client-SSO|`bondy.issue`|`bondy.ticket.scope.client_sso`|

<a name="types"></a>

## Data Types ##


<a name="authid()"></a>


### authid() ###


<pre><code>
authid() = <a href="bondy_rbac_user.md#type-username">bondy_rbac_user:username()</a>
</code></pre>


<a name="claims()"></a>


### claims() ###


<pre><code>
claims() = #{id =&gt; <a href="#type-ticket_id">ticket_id()</a>, authrealm =&gt; <a href="#type-uri">uri()</a>, authid =&gt; <a href="#type-authid">authid()</a>, authmethod =&gt; binary(), issued_by =&gt; <a href="#type-authid">authid()</a>, issued_on =&gt; node(), issued_at =&gt; pos_integer(), expires_at =&gt; pos_integer(), scope =&gt; <a href="#type-scope">scope()</a>, kid =&gt; binary()}
</code></pre>


<a name="issue_error()"></a>


### issue_error() ###


<pre><code>
issue_error() = {no_such_user, <a href="#type-authid">authid()</a>} | no_such_realm | invalid_request | invalid_ticket | not_authorized
</code></pre>


<a name="opts()"></a>


### opts() ###


<pre><code>
opts() = #{expiry_time_secs =&gt; pos_integer(), allow_sso =&gt; boolean(), client_ticket =&gt; <a href="#type-t">t()</a>, client_id =&gt; binary(), client_instance_id =&gt; binary()}
</code></pre>


<a name="scope()"></a>


### scope() ###


<pre><code>
scope() = #{realm =&gt; <a href="#type-maybe">maybe</a>(<a href="#type-uri">uri()</a>), client_id =&gt; <a href="#type-maybe">maybe</a>(<a href="#type-authid">authid()</a>), client_instance_id =&gt; <a href="#type-maybe">maybe</a>(binary())}
</code></pre>


<a name="t()"></a>


### t() ###


<pre><code>
t() = binary()
</code></pre>


<a name="ticket_id()"></a>


### ticket_id() ###


<pre><code>
ticket_id() = binary()
</code></pre>


<a name="functions"></a>

## Function Details ##

<a name="issue-2"></a>

### issue/2 ###

<pre><code>
issue(Session::<a href="bondy_session.md#type-t">bondy_session:t()</a>, Opts::<a href="#type-opts">opts()</a>) -&gt; {ok, Ticket::<a href="#type-t">t()</a>, Claims::<a href="#type-claims">claims()</a>} | {error, <a href="#type-issue_error">issue_error()</a>} | no_return()
</code></pre>
<br />

Issues a ticket to be used with the WAMP Ticket authentication
method. The function stores the ticket claims data and replicates it across
all nodes in the cluster.

The session `Session` must have been opened using an authentication
method that is neither `ticket` nor `anonymous` authentication.

The function takes an options map `opts()` that can contain the following
keys:
* `expiry_time_secs`: the expiration time on or after which the ticket MUST
NOT be accepted for processing. This is a request that might not be honoured
by the router as it depends on the router configuration, so the returned
value might defer.
To issue a client-scoped ticket, either the option `client_ticket` or
`client_id` must be present. The `client_ticket` option takes a valid ticket
issued by a different user (normally a
client). Otherwise the call will return the error tuple with reason
`invalid_request`.

<a name="lookup-3"></a>

### lookup/3 ###

<pre><code>
lookup(RealmUri::<a href="#type-uri">uri()</a>, Authid::<a href="bondy_rbac_user.md#type-username">bondy_rbac_user:username()</a>, Scope::<a href="#type-scope">scope()</a>) -&gt; {ok, Claims::<a href="#type-claims">claims()</a>} | {error, no_found}
</code></pre>
<br />

<a name="revoke-1"></a>

### revoke/1 ###

<pre><code>
revoke(Ticket::<a href="#type-maybe">maybe</a>(<a href="#type-t">t()</a>)) -&gt; ok | {error, any()}
</code></pre>
<br />

<a name="revoke_all-2"></a>

### revoke_all/2 ###

<pre><code>
revoke_all(RealmUri::<a href="#type-uri">uri()</a>, Authid::<a href="bondy_rbac_user.md#type-username">bondy_rbac_user:username()</a>) -&gt; ok
</code></pre>
<br />

Revokes all tickets issued to user with `Username` in realm `RealmUri`.
Notice that the ticket could have been issued by itself or by a client
application.

<a name="revoke_all-3"></a>

### revoke_all/3 ###

<pre><code>
revoke_all(RealmUri::<a href="#type-uri">uri()</a>, Username::all | <a href="bondy_rbac_user.md#type-username">bondy_rbac_user:username()</a>, Scope::<a href="#type-scope">scope()</a>) -&gt; ok
</code></pre>
<br />

Revokes all tickets issued to user with `Username` in realm `RealmUri`
matching the scope `Scope`.

<a name="verify-1"></a>

### verify/1 ###

<pre><code>
verify(Ticket::binary()) -&gt; {ok, <a href="#type-claims">claims()</a>} | {error, expired | invalid}
</code></pre>
<br />

