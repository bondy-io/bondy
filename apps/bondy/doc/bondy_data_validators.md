

# Module bondy_data_validators #
* [Function Index](#index)
* [Function Details](#functions)

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#authorized_key-1">authorized_key/1</a></td><td></td></tr><tr><td valign="top"><a href="#cidr-1">cidr/1</a></td><td></td></tr><tr><td valign="top"><a href="#existing_atom-1">existing_atom/1</a></td><td></td></tr><tr><td valign="top"><a href="#groupname-1">groupname/1</a></td><td></td></tr><tr><td valign="top"><a href="#groupnames-1">groupnames/1</a></td><td>Allows reserved names like "all", "anonymous", etc.</td></tr><tr><td valign="top"><a href="#password-1">password/1</a></td><td></td></tr><tr><td valign="top"><a href="#permission-1">permission/1</a></td><td></td></tr><tr><td valign="top"><a href="#policy_resource-1">policy_resource/1</a></td><td></td></tr><tr><td valign="top"><a href="#realm_uri-1">realm_uri/1</a></td><td></td></tr><tr><td valign="top"><a href="#rolename-1">rolename/1</a></td><td></td></tr><tr><td valign="top"><a href="#rolenames-1">rolenames/1</a></td><td>Allows reserved names like "all", "anonymous", etc.</td></tr><tr><td valign="top"><a href="#strict_groupname-1">strict_groupname/1</a></td><td></td></tr><tr><td valign="top"><a href="#strict_username-1">strict_username/1</a></td><td>Does not allow reserved namess.</td></tr><tr><td valign="top"><a href="#username-1">username/1</a></td><td>Allows reserved names like "all", "anonymous", etc.</td></tr><tr><td valign="top"><a href="#usernames-1">usernames/1</a></td><td>Allows reserved names like "all", "anonymous", etc.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="authorized_key-1"></a>

### authorized_key/1 ###

<pre><code>
authorized_key(Term::binary()) -&gt; {ok, binary()} | boolean()
</code></pre>
<br />

<a name="cidr-1"></a>

### cidr/1 ###

<pre><code>
cidr(Term::binary() | tuple()) -&gt; {ok, <a href="bondy_cidr.md#type-t">bondy_cidr:t()</a>} | boolean()
</code></pre>
<br />

<a name="existing_atom-1"></a>

### existing_atom/1 ###

<pre><code>
existing_atom(Term::binary() | atom()) -&gt; {ok, term()} | boolean()
</code></pre>
<br />

<a name="groupname-1"></a>

### groupname/1 ###

<pre><code>
groupname(Bin::binary()) -&gt; boolean()
</code></pre>
<br />

<a name="groupnames-1"></a>

### groupnames/1 ###

<pre><code>
groupnames(List::[binary()]) -&gt; {ok, [binary()]} | false
</code></pre>
<br />

Allows reserved names like "all", "anonymous", etc

<a name="password-1"></a>

### password/1 ###

<pre><code>
password(Term::binary() | fun(() -&gt; binary()) | map()) -&gt; {ok, <a href="bondy_password.md#type-future">bondy_password:future()</a>} | boolean()
</code></pre>
<br />

<a name="permission-1"></a>

### permission/1 ###

<pre><code>
permission(Term::binary()) -&gt; boolean()
</code></pre>
<br />

<a name="policy_resource-1"></a>

### policy_resource/1 ###

<pre><code>
policy_resource(Term::<a href="#type-uri">uri()</a> | any) -&gt; {ok, term()} | boolean()
</code></pre>
<br />

<a name="realm_uri-1"></a>

### realm_uri/1 ###

<pre><code>
realm_uri(Term::binary()) -&gt; boolean()
</code></pre>
<br />

<a name="rolename-1"></a>

### rolename/1 ###

<pre><code>
rolename(Bin::binary()) -&gt; {ok, binary() | all | anonymous} | boolean()
</code></pre>
<br />

<a name="rolenames-1"></a>

### rolenames/1 ###

<pre><code>
rolenames(Term::[binary()] | binary()) -&gt; {ok, [binary()]} | false
</code></pre>
<br />

Allows reserved names like "all", "anonymous", etc

<a name="strict_groupname-1"></a>

### strict_groupname/1 ###

<pre><code>
strict_groupname(Bin::binary()) -&gt; boolean()
</code></pre>
<br />

<a name="strict_username-1"></a>

### strict_username/1 ###

<pre><code>
strict_username(Term::binary()) -&gt; {ok, term()} | boolean()
</code></pre>
<br />

Does not allow reserved namess

<a name="username-1"></a>

### username/1 ###

<pre><code>
username(Term::binary()) -&gt; {ok, term()} | boolean()
</code></pre>
<br />

Allows reserved names like "all", "anonymous", etc

<a name="usernames-1"></a>

### usernames/1 ###

<pre><code>
usernames(Term::[binary()] | binary()) -&gt; {ok, [binary()]} | boolean()
</code></pre>
<br />

Allows reserved names like "all", "anonymous", etc

