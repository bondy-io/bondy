

# Module bondy_utils #
* [Function Index](#index)
* [Function Details](#functions)

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#get_id-1">get_id/1</a></td><td>
IDs in the _global scope_ MUST be drawn _randomly_ from a _uniform
distribution_ over the complete range [0, 2^53].</td></tr><tr><td valign="top"><a href="#get_nonce-0">get_nonce/0</a></td><td></td></tr><tr><td valign="top"><a href="#get_random_string-2">get_random_string/2</a></td><td>
borrowed from
http://blog.teemu.im/2009/11/07/generating-random-strings-in-erlang/.</td></tr><tr><td valign="top"><a href="#is_uuid-1">is_uuid/1</a></td><td></td></tr><tr><td valign="top"><a href="#maybe_encode-2">maybe_encode/2</a></td><td></td></tr><tr><td valign="top"><a href="#merge_map_flags-2">merge_map_flags/2</a></td><td>
The call will fail with a {badkey, any()} exception is any key found in M1
is not present in M2.</td></tr><tr><td valign="top"><a href="#timeout-1">timeout/1</a></td><td></td></tr><tr><td valign="top"><a href="#to_binary_keys-1">to_binary_keys/1</a></td><td></td></tr><tr><td valign="top"><a href="#uuid-0">uuid/0</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="get_id-1"></a>

### get_id/1 ###

<pre><code>
get_id(Scope::global | {router, <a href="#type-uri">uri()</a>} | {session, <a href="#type-id">id()</a>}) -&gt; <a href="#type-id">id()</a>
</code></pre>
<br />

IDs in the _global scope_ MUST be drawn _randomly_ from a _uniform
distribution_ over the complete range [0, 2^53]

<a name="get_nonce-0"></a>

### get_nonce/0 ###

`get_nonce() -> any()`

<a name="get_random_string-2"></a>

### get_random_string/2 ###

`get_random_string(Length, AllowedChars) -> any()`

borrowed from
http://blog.teemu.im/2009/11/07/generating-random-strings-in-erlang/

<a name="is_uuid-1"></a>

### is_uuid/1 ###

<pre><code>
is_uuid(Term::any()) -&gt; boolean()
</code></pre>
<br />

<a name="maybe_encode-2"></a>

### maybe_encode/2 ###

`maybe_encode(X1, Term) -> any()`

<a name="merge_map_flags-2"></a>

### merge_map_flags/2 ###

`merge_map_flags(M1, M2) -> any()`

The call will fail with a {badkey, any()} exception is any key found in M1
is not present in M2.

<a name="timeout-1"></a>

### timeout/1 ###

`timeout(X1) -> any()`

<a name="to_binary_keys-1"></a>

### to_binary_keys/1 ###

`to_binary_keys(Map) -> any()`

<a name="uuid-0"></a>

### uuid/0 ###

<pre><code>
uuid() -&gt; bitstring()
</code></pre>
<br />

