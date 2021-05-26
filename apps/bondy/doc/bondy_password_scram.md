

# Module bondy_password_scram #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

This module provides the functions and algorithms to operate with the
Salted Challenge-Reponse Mechanism data structures.

<a name="types"></a>

## Data Types ##




### <a name="type-data">data()</a> ###


<pre><code>
data() = #{salt =&gt; binary(), stored_key =&gt; binary(), server_key =&gt; binary()}
</code></pre>




### <a name="type-hash_fun">hash_fun()</a> ###


<pre><code>
hash_fun() = sha256
</code></pre>




### <a name="type-kdf">kdf()</a> ###


<pre><code>
kdf() = pbkdf2 | argon2id13
</code></pre>




### <a name="type-params">params()</a> ###


<pre><code>
params() = #{kdf =&gt; <a href="#type-kdf">kdf()</a>, iterations =&gt; non_neg_integer(), memory =&gt; non_neg_integer(), hash_function =&gt; <a href="#type-hash_fun">hash_fun()</a>, hash_length =&gt; non_neg_integer(), salt_length =&gt; non_neg_integer()}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#auth_message-5">auth_message/5</a></td><td></td></tr><tr><td valign="top"><a href="#auth_message-7">auth_message/7</a></td><td></td></tr><tr><td valign="top"><a href="#check_proof-4">check_proof/4</a></td><td></td></tr><tr><td valign="top"><a href="#client_key-1">client_key/1</a></td><td></td></tr><tr><td valign="top"><a href="#client_proof-2">client_proof/2</a></td><td>computes the client proof out of the client key <code>Key</code> and the client
signature <code>Signature</code>.</td></tr><tr><td valign="top"><a href="#client_signature-2">client_signature/2</a></td><td></td></tr><tr><td valign="top"><a href="#hash_function-0">hash_function/0</a></td><td></td></tr><tr><td valign="top"><a href="#hash_length-0">hash_length/0</a></td><td></td></tr><tr><td valign="top"><a href="#new-3">new/3</a></td><td></td></tr><tr><td valign="top"><a href="#recovered_client_key-2">recovered_client_key/2</a></td><td></td></tr><tr><td valign="top"><a href="#recovered_stored_key-1">recovered_stored_key/1</a></td><td></td></tr><tr><td valign="top"><a href="#salt-0">salt/0</a></td><td></td></tr><tr><td valign="top"><a href="#salt_length-0">salt_length/0</a></td><td></td></tr><tr><td valign="top"><a href="#salted_password-3">salted_password/3</a></td><td></td></tr><tr><td valign="top"><a href="#server_key-1">server_key/1</a></td><td></td></tr><tr><td valign="top"><a href="#server_nonce-1">server_nonce/1</a></td><td></td></tr><tr><td valign="top"><a href="#server_signature-2">server_signature/2</a></td><td></td></tr><tr><td valign="top"><a href="#stored_key-1">stored_key/1</a></td><td></td></tr><tr><td valign="top"><a href="#validate_params-1">validate_params/1</a></td><td></td></tr><tr><td valign="top"><a href="#verify_string-3">verify_string/3</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="auth_message-5"></a>

### auth_message/5 ###

`auth_message(AuthId, ClientNonce, ServerNonce, Salt, Iterations) -> any()`

<a name="auth_message-7"></a>

### auth_message/7 ###

`auth_message(AuthId, ClientNonce, ServerNonce, Salt, Iterations, CBindName, CBindData) -> any()`

<a name="check_proof-4"></a>

### check_proof/4 ###

<pre><code>
check_proof(ProvidedProof::binary(), ClientProof::binary(), ClientSignature::binary(), StoredKey::binary()) -&gt; boolean()
</code></pre>
<br />

<a name="client_key-1"></a>

### client_key/1 ###

<pre><code>
client_key(SaltedPassword::binary()) -&gt; ClientKey::binary()
</code></pre>
<br />

<a name="client_proof-2"></a>

### client_proof/2 ###

<pre><code>
client_proof(Key::binary(), Signature::binary()) -&gt; ClientProof::binary()
</code></pre>
<br />

computes the client proof out of the client key `Key` and the client
signature `Signature`. See [`client_key/2`](#client_key-2) and
[`client_signature/2`](#client_signature-2) respectively.

<a name="client_signature-2"></a>

### client_signature/2 ###

<pre><code>
client_signature(StoredKey::binary(), AuthMessage::binary()) -&gt; ClientSignature::binary()
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
new(String::binary(), Params0::<a href="#type-params">params()</a>, Builder::fun((<a href="#type-data">data()</a>, <a href="#type-params">params()</a>) -&gt; <a href="bondy_password.md#type-t">bondy_password:t()</a>)) -&gt; <a href="bondy_password.md#type-t">bondy_password:t()</a> | no_return()
</code></pre>
<br />

<a name="recovered_client_key-2"></a>

### recovered_client_key/2 ###

<pre><code>
recovered_client_key(ClientProof::binary(), ClientSignature::binary()) -&gt; RecoveredClientKey::binary()
</code></pre>
<br />

<a name="recovered_stored_key-1"></a>

### recovered_stored_key/1 ###

<pre><code>
recovered_stored_key(RecoveredClientKey::binary()) -&gt; RecoveredStoredKey::binary()
</code></pre>
<br />

<a name="salt-0"></a>

### salt/0 ###

<pre><code>
salt() -&gt; Salt::binary()
</code></pre>
<br />

<a name="salt_length-0"></a>

### salt_length/0 ###

<pre><code>
salt_length() -&gt; integer()
</code></pre>
<br />

<a name="salted_password-3"></a>

### salted_password/3 ###

<pre><code>
salted_password(Password::binary(), Salt::binary(), Params::<a href="#type-params">params()</a>) -&gt; SaltedPassword::binary()
</code></pre>
<br />

<a name="server_key-1"></a>

### server_key/1 ###

<pre><code>
server_key(SaltedPassword::binary()) -&gt; ServerKey::binary()
</code></pre>
<br />

<a name="server_nonce-1"></a>

### server_nonce/1 ###

<pre><code>
server_nonce(ClientNonce::binary()) -&gt; ServerNonce::binary()
</code></pre>
<br />

<a name="server_signature-2"></a>

### server_signature/2 ###

<pre><code>
server_signature(ServerKey::binary(), AuthMessage::binary()) -&gt; ClientSignature::binary()
</code></pre>
<br />

<a name="stored_key-1"></a>

### stored_key/1 ###

<pre><code>
stored_key(ClientKey::binary()) -&gt; StoredKey::binary()
</code></pre>
<br />

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

