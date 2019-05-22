

# Module bondy_utils #
* [Function Index](#index)
* [Function Details](#functions)

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#bin_to_pid-1">bin_to_pid/1</a></td><td></td></tr><tr><td valign="top"><a href="#elapsed_time-2">elapsed_time/2</a></td><td>Returns the elapsed time since Timestamp expressed in the
desired TimeUnit.</td></tr><tr><td valign="top"><a href="#foreach-2">foreach/2</a></td><td></td></tr><tr><td valign="top"><a href="#generate_fragment-1">generate_fragment/1</a></td><td></td></tr><tr><td valign="top"><a href="#get_flake_id-0">get_flake_id/0</a></td><td>Calls flake_server:id/0 and returns the generated ID.</td></tr><tr><td valign="top"><a href="#get_id-1">get_id/1</a></td><td>
IDs in the _global scope_ MUST be drawn _randomly_ from a _uniform
distribution_ over the complete range [0, 2^53].</td></tr><tr><td valign="top"><a href="#get_nonce-0">get_nonce/0</a></td><td></td></tr><tr><td valign="top"><a href="#get_random_string-2">get_random_string/2</a></td><td>
borrowed from
http://blog.teemu.im/2009/11/07/generating-random-strings-in-erlang/.</td></tr><tr><td valign="top"><a href="#is_uuid-1">is_uuid/1</a></td><td></td></tr><tr><td valign="top"><a href="#log-5">log/5</a></td><td></td></tr><tr><td valign="top"><a href="#maybe_encode-2">maybe_encode/2</a></td><td></td></tr><tr><td valign="top"><a href="#merge_map_flags-2">merge_map_flags/2</a></td><td>
The call will fail with a {badkey, any()} exception is any key found in M1
is not present in M2.</td></tr><tr><td valign="top"><a href="#pid_to_bin-1">pid_to_bin/1</a></td><td></td></tr><tr><td valign="top"><a href="#timeout-1">timeout/1</a></td><td></td></tr><tr><td valign="top"><a href="#to_binary_keys-1">to_binary_keys/1</a></td><td></td></tr><tr><td valign="top"><a href="#uuid-0">uuid/0</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="bin_to_pid-1"></a>

### bin_to_pid/1 ###

`bin_to_pid(Bin) -> any()`

<a name="elapsed_time-2"></a>

### elapsed_time/2 ###

<pre><code>
elapsed_time(Timestamp::integer(), TimeUnit::<a href="erlang.md#type-time_unit">erlang:time_unit()</a>) -&gt; integer()
</code></pre>
<br />

Returns the elapsed time since Timestamp expressed in the
desired TimeUnit.

<a name="foreach-2"></a>

### foreach/2 ###

<pre><code>
foreach(Fun::fun((Elem::term()) -&gt; term()), Cont::?EOT | {[term()], any()} | any()) -&gt; ok
</code></pre>
<br />

<a name="generate_fragment-1"></a>

### generate_fragment/1 ###

<pre><code>
generate_fragment(N::non_neg_integer()) -&gt; binary()
</code></pre>
<br />

<a name="get_flake_id-0"></a>

### get_flake_id/0 ###

<pre><code>
get_flake_id() -&gt; binary()
</code></pre>
<br />

Calls flake_server:id/0 and returns the generated ID.

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

<a name="log-5"></a>

### log/5 ###

<pre><code>
log(Level::atom(), Prefix::binary() | list(), Head::list(), WampMessage::<a href="#type-wamp_message">wamp_message()</a>, Ctxt::<a href="bondy_context.md#type-t">bondy_context:t()</a>) -&gt; ok
</code></pre>
<br />

<a name="maybe_encode-2"></a>

### maybe_encode/2 ###

`maybe_encode(Enc, Term) -> any()`

<a name="merge_map_flags-2"></a>

### merge_map_flags/2 ###

`merge_map_flags(M1, M2) -> any()`

The call will fail with a {badkey, any()} exception is any key found in M1
is not present in M2.

<a name="pid_to_bin-1"></a>

### pid_to_bin/1 ###

`pid_to_bin(Pid) -> any()`

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

