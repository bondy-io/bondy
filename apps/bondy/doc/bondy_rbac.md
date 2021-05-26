

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

<a name="types"></a>

## Data Types ##




### <a name="type-context">context()</a> ###


<pre><code>
context() = #bondy_rbac_context{realm_uri = binary(), username = binary(), permissions = [<a href="bondy_rbac_policy.md#type-permission">bondy_rbac_policy:permission()</a>], epoch = <a href="erlang.md#type-timestamp">erlang:timestamp()</a>, is_anonymous = boolean()}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#authorize-3">authorize/3</a></td><td>Returns 'ok' or an exception.</td></tr><tr><td valign="top"><a href="#get_anonymous_context-1">get_anonymous_context/1</a></td><td></td></tr><tr><td valign="top"><a href="#get_anonymous_context-2">get_anonymous_context/2</a></td><td></td></tr><tr><td valign="top"><a href="#get_context-1">get_context/1</a></td><td></td></tr><tr><td valign="top"><a href="#get_context-2">get_context/2</a></td><td>Contexts are only valid until the GRANT epoch changes, and it will
change whenever a GRANT or a REVOKE is performed.</td></tr><tr><td valign="top"><a href="#is_reserved_name-1">is_reserved_name/1</a></td><td>Returns true if term is a reserved name in binary or atom form.</td></tr><tr><td valign="top"><a href="#normalize_name-1">normalize_name/1</a></td><td>Normalizes the utf8 binary <code>Bin</code> into a Normalized Form of compatibly
equivalent Decomposed characters according to the Unicode standard and
converts it to a case-agnostic comparable string.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="authorize-3"></a>

### authorize/3 ###

<pre><code>
authorize(Permission::binary(), Resource::binary(), Ctxt::<a href="bondy_context.md#type-t">bondy_context:t()</a>) -&gt; ok | no_return()
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

