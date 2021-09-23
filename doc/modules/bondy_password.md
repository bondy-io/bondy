

# Module bondy_password #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

A Password object stores a fixed size salted hash of a user's password
and all the metadata required to re-compute the salted hash for comparing a
user input and for implementing several password-based authentication
protocols.

<a name="description"></a>

## Description ##
At the moment this module supports two protocols:
* WAMP Challenge-Response Authentication (CRA), and
* Salted Challenge-Response Authentication Mechanism (SCRAM)

<a name="types"></a>

## Data Types ##


<a name="data()"></a>


### data() ###


<pre><code>
data() = <a href="bondy_password_cra.md#type-data">bondy_password_cra:data()</a> | <a href="bondy_password_scram.md#type-data">bondy_password_scram:data()</a>
</code></pre>


<a name="future()"></a>


### future() ###


<pre><code>
future() = fun((<a href="#type-opts">opts()</a>) -&gt; <a href="#type-t">t()</a>)
</code></pre>


<a name="opts()"></a>


### opts() ###


<pre><code>
opts() = #{protocol =&gt; <a href="#type-protocol">protocol()</a>, params =&gt; <a href="#type-params">params()</a>}
</code></pre>


<a name="params()"></a>


### params() ###


<pre><code>
params() = <a href="bondy_password_cra.md#type-params">bondy_password_cra:params()</a> | <a href="bondy_password_scram.md#type-params">bondy_password_scram:params()</a>
</code></pre>


<a name="protocol()"></a>


### protocol() ###


<pre><code>
protocol() = cra | scram
</code></pre>


<a name="t()"></a>


### t() ###


<pre><code>
t() = #{type =&gt; password, version =&gt; binary(), protocol =&gt; <a href="#type-protocol">protocol()</a>, params =&gt; <a href="#type-params">params()</a>, data =&gt; <a href="#type-data">data()</a>}
</code></pre>


<a name="functions"></a>

## Function Details ##

<a name="data-1"></a>

### data/1 ###

<pre><code>
data(X1::<a href="#type-t">t()</a>) -&gt; <a href="#type-data">data()</a>
</code></pre>
<br />

<a name="default_opts-0"></a>

### default_opts/0 ###

<pre><code>
default_opts() -&gt; <a href="#type-opts">opts()</a>
</code></pre>
<br />

<a name="default_opts-1"></a>

### default_opts/1 ###

<pre><code>
default_opts(Protocol::<a href="#type-protocol">protocol()</a>) -&gt; <a href="#type-opts">opts()</a>
</code></pre>
<br />

<a name="from_term-1"></a>

### from_term/1 ###

<pre><code>
from_term(Term::<a href="proplist.md#type-proplist">proplist:proplist()</a> | map()) -&gt; <a href="#type-t">t()</a>
</code></pre>
<br />

<a name="future-1"></a>

### future/1 ###

<pre><code>
future(Password::binary()) -&gt; <a href="#type-future">future()</a>
</code></pre>
<br />

Creates a functional object that takes a single argument
`Opts :: opts()` that when applied calls `new(Password, Opts)`.

This is used for two reasons:
1. to encapsulate the string value of the password avoiding exposure i.e.
via logs; and
2. To delay the processing of the password until the value for `Opts` is
known.

`Password` must be a binary with a minimum size of 6 bytes and a maximum
size of 256 bytes, otherwise fails with error `invalid_password`.

Example:

```
     erlang
  > F = bondy_password:future(<<"MyBestKeptSecret">>).
  > bondy_password:new(F, Opts).
```

<a name="hash_length-1"></a>

### hash_length/1 ###

<pre><code>
hash_length(PW::<a href="#type-t">t()</a>) -&gt; pos_integer()
</code></pre>
<br />

<a name="is_type-1"></a>

### is_type/1 ###

<pre><code>
is_type(X1::<a href="#type-t">t()</a>) -&gt; boolean()
</code></pre>
<br />

<a name="new-2"></a>

### new/2 ###

<pre><code>
new(Future::binary() | <a href="#type-future">future()</a>, Opts::<a href="#type-opts">opts()</a>) -&gt; <a href="#type-t">t()</a> | no_return()
</code></pre>
<br />

Hash a plaintext password `Password` and the protocol and protocol
params defined in options `Opts`, returning t().

`Password` must be a binary with a minimum size of 6 bytes and a maximum
size of 256 bytes, otherwise fails with error `invalid_password`.

<a name="opts_validator-0"></a>

### opts_validator/0 ###

<pre><code>
opts_validator() -&gt; map()
</code></pre>
<br />

<a name="params-1"></a>

### params/1 ###

<pre><code>
params(X1::<a href="#type-t">t()</a>) -&gt; <a href="#type-params">params()</a>
</code></pre>
<br />

<a name="protocol-1"></a>

### protocol/1 ###

<pre><code>
protocol(X1::<a href="#type-t">t()</a>) -&gt; <a href="#type-protocol">protocol()</a> | undefined
</code></pre>
<br />

<a name="replace-2"></a>

### replace/2 ###

<pre><code>
replace(Password::binary() | <a href="#type-future">future()</a>, PW::<a href="#type-t">t()</a>) -&gt; <a href="#type-t">t()</a> | no_return()
</code></pre>
<br />

Returns a new password object from `String` applying the same protocol
and params found in password `PWD`.

<a name="upgrade-2"></a>

### upgrade/2 ###

<pre><code>
upgrade(String::tuple() | binary(), T0::map() | <a href="proplists.md#type-proplist">proplists:proplist()</a>) -&gt; {true, T1::<a href="#type-t">t()</a>} | false
</code></pre>
<br />

<a name="verify_hash-2"></a>

### verify_hash/2 ###

<pre><code>
verify_hash(Hash::binary(), Password::<a href="#type-t">t()</a>) -&gt; boolean()
</code></pre>
<br />

<a name="verify_string-2"></a>

### verify_string/2 ###

<pre><code>
verify_string(String::binary(), Password::<a href="#type-t">t()</a>) -&gt; boolean()
</code></pre>
<br />

