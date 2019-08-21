

# Module bondy_security_pw #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##




### <a name="type-auth_name">auth_name()</a> ###


<pre><code>
auth_name() = pbkdf2
</code></pre>




### <a name="type-hash_fun">hash_fun()</a> ###


<pre><code>
hash_fun() = sha256
</code></pre>




### <a name="type-t">t()</a> ###


<pre><code>
t() = #{version =&gt; binary(), auth_name =&gt; <a href="#type-auth_name">auth_name()</a>, hash_func =&gt; <a href="#type-hash_fun">hash_fun()</a>, hash_pass =&gt; binary(), hash_len =&gt; ?KEY_LEN, iterations =&gt; non_neg_integer(), salt =&gt; binary()}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#check_password-2">check_password/2</a></td><td></td></tr><tr><td valign="top"><a href="#hash_len-1">hash_len/1</a></td><td></td></tr><tr><td valign="top"><a href="#new-1">new/1</a></td><td>Hash a plaintext password, returning t().</td></tr><tr><td valign="top"><a href="#new-5">new/5</a></td><td></td></tr><tr><td valign="top"><a href="#to_map-1">to_map/1</a></td><td></td></tr><tr><td valign="top"><a href="#upgrade-2">upgrade/2</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="check_password-2"></a>

### check_password/2 ###

<pre><code>
check_password(String::binary() | {hash, binary()}, PW::<a href="#type-t">t()</a>) -&gt; boolean()
</code></pre>
<br />

<a name="hash_len-1"></a>

### hash_len/1 ###

<pre><code>
hash_len(PW::<a href="#type-t">t()</a>) -&gt; pos_integer()
</code></pre>
<br />

<a name="new-1"></a>

### new/1 ###

<pre><code>
new(String::binary()) -&gt; <a href="#type-t">t()</a>
</code></pre>
<br />

Hash a plaintext password, returning t().

<a name="new-5"></a>

### new/5 ###

<pre><code>
new(String::binary(), Salt::binary(), AuthName::<a href="#type-auth_name">auth_name()</a>, HashFun::<a href="#type-hash_fun">hash_fun()</a>, HashIter::pos_integer()) -&gt; <a href="#type-t">t()</a>
</code></pre>
<br />

<a name="to_map-1"></a>

### to_map/1 ###

<pre><code>
to_map(L::<a href="proplist.md#type-proplist">proplist:proplist()</a>) -&gt; <a href="#type-t">t()</a>
</code></pre>
<br />

<a name="upgrade-2"></a>

### upgrade/2 ###

<pre><code>
upgrade(String::binary(), Pass::<a href="#type-t">t()</a> | <a href="proplists.md#type-proplist">proplists:proplist()</a>) -&gt; <a href="#type-t">t()</a>
</code></pre>
<br />

