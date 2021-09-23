

# Module bondy_rbac #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

### WAMP Permissions:.

<a name="description"></a>

## Description ##

* "wamp.register"
* "wamp.unregister"
* "wamp.call"
* "wamp.cancel"
* "wamp.subscribe"
* "wamp.unsubscribe"
* "wamp.publish"
* "wamp.disclose_caller"
* "wamp.disclose_publisher"

### Reserved Names
Reserved names are role (user or group) or resource names that act as
keywords in RBAC in either binary or atom forms and thus cannot be used.

The following is the list of all reserved names.

* all - group
* anonymous - the anonymous user and group
* any - use to denote a resource
* from - use to denote a resource
* on - not used
* to - use to denote a resource
%% **Note:**
Usernames and group names are stored in lower case. All functions in this
module are case sensitice so when using the functions in this module make
sure the inputs you provide are in lowercase to. If you need to convert your
input to lowercase use [`string:casefold/1`](string.md#casefold-1).
<a name="types"></a>

## Data Types ##


<a name="context()"></a>


### context() ###


<pre><code>
context() = #bondy_rbac_context{realm_uri = binary(), username = binary(), grants = [<a href="#type-grant">grant()</a>], epoch = integer(), is_anonymous = boolean()}
</code></pre>


<a name="grant()"></a>


### grant() ###


<pre><code>
grant() = {<a href="#type-normalised_resource">normalised_resource()</a>, [Permission::<a href="#type-permission">permission()</a>]}
</code></pre>


<a name="normalised_resource()"></a>


### normalised_resource() ###


<pre><code>
normalised_resource() = any | {Uri::<a href="#type-uri">uri()</a>, MatchStrategy::binary()}
</code></pre>


<a name="permission()"></a>


### permission() ###


<pre><code>
permission() = binary()
</code></pre>


<a name="request()"></a>


### request() ###


<pre><code>
request() = #{type =&gt; request, roles =&gt; [<a href="#type-rolename">rolename()</a>], permissions =&gt; [binary()], resources =&gt; [<a href="#type-normalised_resource">normalised_resource()</a>]}
</code></pre>


<a name="request_data()"></a>


### request_data() ###


<pre><code>
request_data() = map()
</code></pre>


<a name="resource()"></a>


### resource() ###


<pre><code>
resource() = any | binary() | #{uri =&gt; binary(), strategy =&gt; binary()} | <a href="#type-normalised_resource">normalised_resource()</a>
</code></pre>


<a name="rolename()"></a>


### rolename() ###


<pre><code>
rolename() = all | <a href="bondy_rbac_user.md#type-username">bondy_rbac_user:username()</a> | <a href="bondy_rbac_group.md#type-name">bondy_rbac_group:name()</a>
</code></pre>


<a name="functions"></a>

## Function Details ##

<a name="authorize-2"></a>

### authorize/2 ###

<pre><code>
authorize(Permission::binary(), Ctxt::<a href="bondy_context.md#type-t">bondy_context:t()</a> | <a href="#type-context">context()</a>) -&gt; ok | no_return()
</code></pre>
<br />

Returns 'ok' or an exception.

<a name="authorize-3"></a>

### authorize/3 ###

<pre><code>
authorize(Permission::binary(), Resource::binary() | any, Bondy_rbac_context::<a href="bondy_context.md#type-t">bondy_context:t()</a> | <a href="#type-context">context()</a>) -&gt; ok | no_return()
</code></pre>
<br />

Returns 'ok' or an exception.

<a name="get_anonymous_context-1"></a>

### get_anonymous_context/1 ###

<pre><code>
get_anonymous_context(Ctxt::<a href="bondy_context.md#type-t">bondy_context:t()</a>) -&gt; <a href="#type-context">context()</a>
</code></pre>
<br />

<a name="get_anonymous_context-2"></a>

### get_anonymous_context/2 ###

`get_anonymous_context(RealmUri, Username) -> any()`

<a name="get_context-1"></a>

### get_context/1 ###

<pre><code>
get_context(Ctxt::<a href="bondy_context.md#type-t">bondy_context:t()</a>) -&gt; <a href="#type-context">context()</a>
</code></pre>
<br />

<a name="get_context-2"></a>

### get_context/2 ###

`get_context(RealmUri, Username) -> any()`

Contexts are only valid until the GRANT epoch changes, and it will
change whenever a GRANT or a REVOKE is performed. This is a little coarse
grained right now, but it'll do for the moment.

<a name="grant-2"></a>

### grant/2 ###

<pre><code>
grant(RealmUri::<a href="#type-uri">uri()</a>, Request::<a href="#type-request">request()</a> | map()) -&gt; ok | {error, Reason::any()} | no_return()
</code></pre>
<br />

**Use cases**

```
  grant <permissions> on any to all|{<user>|<group>[,...]}
  grant <permissions> on {<resource>, <exact|prefix|wildcard>} to all|{<user>|<group>[,...]}
```

<a name="grants-3"></a>

### grants/3 ###

<pre><code>
grants(RealmUri::<a href="#type-uri">uri()</a>, Name::binary(), RoleType::user | group) -&gt; [<a href="#type-grant">grant()</a>]
</code></pre>
<br />

<a name="group_grants-2"></a>

### group_grants/2 ###

<pre><code>
group_grants(RealmUri::<a href="#type-uri">uri()</a>, Name::binary()) -&gt; [<a href="#type-grant">grant()</a>]
</code></pre>
<br />

<a name="is_reserved_name-1"></a>

### is_reserved_name/1 ###

<pre><code>
is_reserved_name(Term::binary() | atom()) -&gt; boolean() | no_return()
</code></pre>
<br />

Returns true if term is a reserved name in binary or atom form.

**Reserved names:**

* all
* anonymous
* any
* from
* on
* to

<a name="normalize_name-1"></a>

### normalize_name/1 ###

<pre><code>
normalize_name(Term::binary() | atom()) -&gt; boolean() | no_return()
</code></pre>
<br />

Normalizes the utf8 binary `Bin` into a Normalized Form of compatibly
equivalent Decomposed characters according to the Unicode standard and
converts it to a case-agnostic comparable string.

<a name="refresh_context-1"></a>

### refresh_context/1 ###

<pre><code>
refresh_context(Ctxt::<a href="bondy_context.md#type-t">bondy_context:t()</a>) -&gt; {boolean(), <a href="#type-context">context()</a>}
</code></pre>
<br />

<a name="request-1"></a>

### request/1 ###

<pre><code>
request(Data::<a href="#type-request_data">request_data()</a>) -&gt; Request::<a href="#type-request">request()</a> | no_return()
</code></pre>
<br />

Validates the data for a grant or revoke request.

<a name="revoke-2"></a>

### revoke/2 ###

<pre><code>
revoke(RealmUri::<a href="#type-uri">uri()</a>, Request::<a href="#type-request">request()</a> | map()) -&gt; ok | {error, Reason::any()} | no_return()
</code></pre>
<br />

<a name="revoke_group-2"></a>

### revoke_group/2 ###

`revoke_group(RealmUri, Name) -> any()`

<a name="revoke_user-2"></a>

### revoke_user/2 ###

`revoke_user(RealmUri, Username) -> any()`

<a name="user_grants-2"></a>

### user_grants/2 ###

<pre><code>
user_grants(RealmUri::<a href="#type-uri">uri()</a>, Username::binary()) -&gt; [<a href="#type-grant">grant()</a>]
</code></pre>
<br />

