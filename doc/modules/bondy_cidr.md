

# Module bondy_cidr #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##


<a name="t()"></a>


### t() ###


<pre><code>
t() = {<a href="inet.md#type-ip_address">inet:ip_address()</a>, non_neg_integer()}
</code></pre>


<a name="functions"></a>

## Function Details ##

<a name="anchor_mask-1"></a>

### anchor_mask/1 ###

<pre><code>
anchor_mask(CIDR::<a href="#type-t">t()</a>) -&gt; <a href="#type-t">t()</a>
</code></pre>
<br />

returns the real bottom of a netmask. Eg if 192.168.1.1/16 is
provided, return 192.168.0.0/16

<a name="is_type-1"></a>

### is_type/1 ###

<pre><code>
is_type(Term::binary()) -&gt; <a href="#type-t">t()</a> | no_return()
</code></pre>
<br />

Returns `true` if term `Term` is a valid CIDR notation representation in
erlang. Otherwise returns `false`.

<a name="mask-1"></a>

### mask/1 ###

<pre><code>
mask(X1::<a href="#type-t">t()</a>) -&gt; Subnet::binary()
</code></pre>
<br />

<a name="match-2"></a>

### match/2 ###

<pre><code>
match(Left::<a href="#type-t">t()</a>, Right::<a href="#type-t">t()</a>) -&gt; <a href="#type-t">t()</a> | no_return()
</code></pre>
<br />

Returns `true` if `Left` and `Right` are CIDR notation representations
in erlang and they match. Otherwise returns false.

<a name="parse-1"></a>

### parse/1 ###

<pre><code>
parse(Bin::binary()) -&gt; <a href="#type-t">t()</a> | no_return()
</code></pre>
<br />

Parses a binary string representation of a CIDR notation and returns its
erlang representation as a tuple `t()`.
Fails with a badarg exception if the binary `Bin` is not a valid input.

