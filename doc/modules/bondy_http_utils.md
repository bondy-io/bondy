

# Module bondy_http_utils #
* [Function Index](#index)
* [Function Details](#functions)

<a name="functions"></a>

## Function Details ##

<a name="client_ip-1"></a>

### client_ip/1 ###

<pre><code>
client_ip(Req::<a href="cowboy_req.md#type-req">cowboy_req:req()</a>) -&gt; binary() | undefined
</code></pre>
<br />

Returns a binary representation of the IP or `<<"unknown">>`.

<a name="forwarded_for-1"></a>

### forwarded_for/1 ###

<pre><code>
forwarded_for(Req::<a href="cowboy_req.md#type-req">cowboy_req:req()</a>) -&gt; binary() | undefined
</code></pre>
<br />

<a name="meta_headers-0"></a>

### meta_headers/0 ###

<pre><code>
meta_headers() -&gt; map()
</code></pre>
<br />

<a name="real_ip-1"></a>

### real_ip/1 ###

<pre><code>
real_ip(Req::<a href="cowboy_req.md#type-req">cowboy_req:req()</a>) -&gt; binary() | undefined
</code></pre>
<br />

<a name="set_meta_headers-1"></a>

### set_meta_headers/1 ###

<pre><code>
set_meta_headers(Req::<a href="cowboy_req.md#type-req">cowboy_req:req()</a>) -&gt; NewReq::<a href="cowboy_req.md#type-req">cowboy_req:req()</a>
</code></pre>
<br />

