

# Module bondy_auth #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

This module provides the behaviour to be implemented by the
authentication methods used by Bondy.

__This module defines the `bondy_auth` behaviour.__<br /> Required callback functions: `init/1`, `requirements/0`, `challenge/3`, `authenticate/4`.

<a name="description"></a>

## Description ##
The module provides the functions
required to setup an authentication context, compute a challenge (in the
case of challenge-response methods and authenticate a user based on the
selected method out of the available methods offered by the Realm and
restricted by the access control system and the user's password capabilities.
<a name="types"></a>

## Data Types ##




### <a name="type-context">context()</a> ###


<pre><code>
context() = #{session_id =&gt; <a href="#type-id">id()</a> | undefined, realm_uri =&gt; <a href="#type-uri">uri()</a>, user =&gt; <a href="bondy_rbac_user.md#type-t">bondy_rbac_user:t()</a> | undefined, user_id =&gt; binary() | undefined, available_methods =&gt; [binary()], role =&gt; binary(), roles =&gt; [binary()], conn_ip =&gt; [{ip, <a href="inet.md#type-ip_address">inet:ip_address()</a>}], provider =&gt; binary(), method =&gt; binary(), callback_mod =&gt; module(), callback_mod_state =&gt; term()}
</code></pre>




### <a name="type-requirements">requirements()</a> ###


<pre><code>
requirements() = #{identification =&gt; boolean, password =&gt; {true, #{protocols =&gt; [cra | scram]}} | boolean(), authorized_keys =&gt; boolean()}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#authenticate-4">authenticate/4</a></td><td></td></tr><tr><td valign="top"><a href="#available_methods-1">available_methods/1</a></td><td></td></tr><tr><td valign="top"><a href="#available_methods-2">available_methods/2</a></td><td>Returns the sublist of <code>List</code> containing only the available
authentication methods that can be used with user <code>User</code> in realm <code>Realm</code>
when connecting from the current IP Address.</td></tr><tr><td valign="top"><a href="#challenge-3">challenge/3</a></td><td></td></tr><tr><td valign="top"><a href="#conn_ip-1">conn_ip/1</a></td><td></td></tr><tr><td valign="top"><a href="#init-5">init/5</a></td><td></td></tr><tr><td valign="top"><a href="#method-1">method/1</a></td><td></td></tr><tr><td valign="top"><a href="#method_info-0">method_info/0</a></td><td></td></tr><tr><td valign="top"><a href="#method_info-1">method_info/1</a></td><td></td></tr><tr><td valign="top"><a href="#methods-0">methods/0</a></td><td></td></tr><tr><td valign="top"><a href="#provider-1">provider/1</a></td><td></td></tr><tr><td valign="top"><a href="#realm_uri-1">realm_uri/1</a></td><td></td></tr><tr><td valign="top"><a href="#role-1">role/1</a></td><td></td></tr><tr><td valign="top"><a href="#roles-1">roles/1</a></td><td></td></tr><tr><td valign="top"><a href="#session_id-1">session_id/1</a></td><td></td></tr><tr><td valign="top"><a href="#user-1">user/1</a></td><td></td></tr><tr><td valign="top"><a href="#user_id-1">user_id/1</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="authenticate-4"></a>

### authenticate/4 ###

<pre><code>
authenticate(Method::binary(), Signature::binary(), DataIn::map(), Ctxt::<a href="#type-context">context()</a>) -&gt; {ok, ReturnExtra::map(), NewCtxt::<a href="#type-context">context()</a>} | {error, Reason::any()}
</code></pre>
<br />

<a name="available_methods-1"></a>

### available_methods/1 ###

<pre><code>
available_methods(X1::<a href="#type-context">context()</a>) -&gt; [binary()]
</code></pre>
<br />

<a name="available_methods-2"></a>

### available_methods/2 ###

<pre><code>
available_methods(List::[binary()], Ctxt::<a href="#type-context">context()</a>) -&gt; [binary()]
</code></pre>
<br />

Returns the sublist of `List` containing only the available
authentication methods that can be used with user `User` in realm `Realm`
when connecting from the current IP Address.

<a name="challenge-3"></a>

### challenge/3 ###

<pre><code>
challenge(Method::binary(), DataIn::map(), Ctxt::<a href="#type-context">context()</a>) -&gt; {ok, ChallengeData::map(), NewCtxt::<a href="#type-context">context()</a>} | {ok, NewCtxt::<a href="#type-context">context()</a>} | {error, Reason::any()}
</code></pre>
<br />

<a name="conn_ip-1"></a>

### conn_ip/1 ###

<pre><code>
conn_ip(X1::<a href="#type-context">context()</a>) -&gt; [{ip, <a href="inet.md#type-ip_address">inet:ip_address()</a>}]
</code></pre>
<br />

<a name="init-5"></a>

### init/5 ###

<pre><code>
init(SessionId::<a href="#type-id">id()</a>, Realm::<a href="bondy_realm.md#type-t">bondy_realm:t()</a> | <a href="#type-uri">uri()</a>, UserId::binary() | anonymous, Roles::all | binary() | [binary()] | undefined, Peer::{<a href="inet.md#type-ip_address">inet:ip_address()</a>, <a href="inet.md#type-port_number">inet:port_number()</a>}) -&gt; {ok, <a href="#type-context">context()</a>} | {error, no_such_user | no_such_realm | no_such_group} | no_return()
</code></pre>
<br />

<a name="method-1"></a>

### method/1 ###

<pre><code>
method(X1::<a href="#type-context">context()</a>) -&gt; [binary()]
</code></pre>
<br />

<a name="method_info-0"></a>

### method_info/0 ###

<pre><code>
method_info() -&gt; map()
</code></pre>
<br />

<a name="method_info-1"></a>

### method_info/1 ###

<pre><code>
method_info(Method::binary()) -&gt; map() | no_return()
</code></pre>
<br />

<a name="methods-0"></a>

### methods/0 ###

<pre><code>
methods() -&gt; [binary()]
</code></pre>
<br />

<a name="provider-1"></a>

### provider/1 ###

<pre><code>
provider(X1::<a href="#type-context">context()</a>) -&gt; [binary()]
</code></pre>
<br />

<a name="realm_uri-1"></a>

### realm_uri/1 ###

<pre><code>
realm_uri(X1::<a href="#type-context">context()</a>) -&gt; <a href="#type-uri">uri()</a>
</code></pre>
<br />

<a name="role-1"></a>

### role/1 ###

<pre><code>
role(X1::<a href="#type-context">context()</a>) -&gt; binary()
</code></pre>
<br />

<a name="roles-1"></a>

### roles/1 ###

<pre><code>
roles(X1::<a href="#type-context">context()</a>) -&gt; [binary()]
</code></pre>
<br />

<a name="session_id-1"></a>

### session_id/1 ###

<pre><code>
session_id(X1::<a href="#type-context">context()</a>) -&gt; <a href="#type-id">id()</a>
</code></pre>
<br />

<a name="user-1"></a>

### user/1 ###

<pre><code>
user(X1::<a href="#type-context">context()</a>) -&gt; <a href="bondy_rbac_user.md#type-t">bondy_rbac_user:t()</a> | undefined
</code></pre>
<br />

<a name="user_id-1"></a>

### user_id/1 ###

<pre><code>
user_id(X1::<a href="#type-context">context()</a>) -&gt; binary() | undefined
</code></pre>
<br />

