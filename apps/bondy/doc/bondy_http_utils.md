

# Module bondy_http_utils #
* [Function Index](#index)
* [Function Details](#functions)

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#client_ip-1">client_ip/1</a></td><td>Returns a binary representation of the IP or <code><<"unknown">></code>.</td></tr><tr><td valign="top"><a href="#forwarded_for-1">forwarded_for/1</a></td><td></td></tr><tr><td valign="top"><a href="#real_ip-1">real_ip/1</a></td><td></td></tr></table>


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

<a name="real_ip-1"></a>

### real_ip/1 ###

<pre><code>
real_ip(Req::<a href="cowboy_req.md#type-req">cowboy_req:req()</a>) -&gt; binary() | undefined
</code></pre>
<br />

