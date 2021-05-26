

# Module bondy_password_cra #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##




### <a name="type-data">data()</a> ###


<pre><code>
data() = #{salt =&gt; binary(), salted_password =&gt; binary()}
</code></pre>




### <a name="type-hash_fun">hash_fun()</a> ###


<pre><code>
hash_fun() = sha256
</code></pre>




### <a name="type-kdf">kdf()</a> ###


<pre><code>
kdf() = pbkdf2
</code></pre>




### <a name="type-params">params()</a> ###


<pre><code>
params() = #{kdf =&gt; <a href="#type-kdf">kdf()</a>, iterations =&gt; non_neg_integer(), hash_function =&gt; <a href="#type-hash_fun">hash_fun()</a>, hash_length =&gt; non_neg_integer(), salt_length =&gt; non_neg_integer()}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#compare-2">compare/2</a></td><td></td></tr><tr><td valign="top"><a href="#hash_function-0">hash_function/0</a></td><td></td></tr><tr><td valign="top"><a href="#hash_length-0">hash_length/0</a></td><td></td></tr><tr><td valign="top"><a href="#new-3">new/3</a></td><td></td></tr><tr><td valign="top"><a href="#nonce-0">nonce/0</a></td><td>A base64 encoded 128-bit random value.</td></tr><tr><td valign="top"><a href="#nonce_length-0">nonce_length/0</a></td><td></td></tr><tr><td valign="top"><a href="#salt-0">salt/0</a></td><td>A base64 encoded 128-bit random value.</td></tr><tr><td valign="top"><a href="#salt_length-0">salt_length/0</a></td><td></td></tr><tr><td valign="top"><a href="#salted_password-3">salted_password/3</a></td><td>Returns the 64 encoded salted password.</td></tr><tr><td valign="top"><a href="#validate_params-1">validate_params/1</a></td><td></td></tr><tr><td valign="top"><a href="#verify_string-3">verify_string/3</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="compare-2"></a>

### compare/2 ###

<pre><code>
compare(A::binary(), B::binary()) -&gt; boolean()
</code></pre>
<br />

<a name="hash_function-0"></a>

### hash_function/0 ###

<pre><code>
hash_function() -&gt; atom()
</code></pre>
<br />

<a name="hash_length-0"></a>

### hash_length/0 ###

<pre><code>
hash_length() -&gt; integer()
</code></pre>
<br />

<a name="new-3"></a>

### new/3 ###

<pre><code>
new(Password::binary(), Params0::<a href="#type-params">params()</a>, Builder::fun((<a href="#type-data">data()</a>, <a href="#type-params">params()</a>) -&gt; <a href="bondy_password.md#type-t">bondy_password:t()</a>)) -&gt; <a href="bondy_password.md#type-t">bondy_password:t()</a> | no_return()
</code></pre>
<br />

<a name="nonce-0"></a>

### nonce/0 ###

<pre><code>
nonce() -&gt; binary()
</code></pre>
<br />

A base64 encoded 128-bit random value.

<a name="nonce_length-0"></a>

### nonce_length/0 ###

<pre><code>
nonce_length() -&gt; integer()
</code></pre>
<br />

<a name="salt-0"></a>

### salt/0 ###

<pre><code>
salt() -&gt; binary()
</code></pre>
<br />

A base64 encoded 128-bit random value.

<a name="salt_length-0"></a>

### salt_length/0 ###

<pre><code>
salt_length() -&gt; integer()
</code></pre>
<br />

<a name="salted_password-3"></a>

### salted_password/3 ###

<pre><code>
salted_password(Password::binary(), Salt::binary(), Params::map()) -&gt; binary()
</code></pre>
<br />

Returns the 64 encoded salted password.

<a name="validate_params-1"></a>

### validate_params/1 ###

<pre><code>
validate_params(Params::<a href="#type-params">params()</a>) -&gt; Validated::<a href="#type-params">params()</a> | no_return()
</code></pre>
<br />

<a name="verify_string-3"></a>

### verify_string/3 ###

<pre><code>
verify_string(String::binary(), Data::<a href="#type-data">data()</a>, Params::<a href="#type-params">params()</a>) -&gt; boolean()
</code></pre>
<br />

