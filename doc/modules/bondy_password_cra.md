

# Module bondy_password_cra #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##


<a name="data()"></a>


### data() ###


<pre><code>
data() = #{salt =&gt; binary(), salted_password =&gt; binary()}
</code></pre>


<a name="hash_fun()"></a>


### hash_fun() ###


<pre><code>
hash_fun() = sha256
</code></pre>


<a name="kdf()"></a>


### kdf() ###


<pre><code>
kdf() = pbkdf2
</code></pre>


<a name="params()"></a>


### params() ###


<pre><code>
params() = #{kdf =&gt; <a href="#type-kdf">kdf()</a>, iterations =&gt; non_neg_integer(), hash_function =&gt; <a href="#type-hash_fun">hash_fun()</a>, hash_length =&gt; non_neg_integer(), salt_length =&gt; non_neg_integer()}
</code></pre>


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

