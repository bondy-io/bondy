

# Module bondy_data_validators #
* [Function Index](#index)
* [Function Details](#functions)

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

