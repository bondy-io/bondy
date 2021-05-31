

# Module bondy_http_gateway_utils #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##




### <a name="type-state_fun">state_fun()</a> ###


<pre><code>
state_fun() = fun((any()) -&gt; any())
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#location_uri-2">location_uri/2</a></td><td></td></tr><tr><td valign="top"><a href="#set_resp_link_header-2">set_resp_link_header/2</a></td><td></td></tr><tr><td valign="top"><a href="#set_resp_link_header-4">set_resp_link_header/4</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="location_uri-2"></a>

### location_uri/2 ###

<pre><code>
location_uri(ID::binary(), Req::<a href="cowboy_req.md#type-req">cowboy_req:req()</a>) -&gt; URI::binary()
</code></pre>
<br />

<a name="set_resp_link_header-2"></a>

### set_resp_link_header/2 ###

<pre><code>
set_resp_link_header(L::[{binary(), iodata(), iodata()}], Req::<a href="cowboy_req.md#type-req">cowboy_req:req()</a>) -&gt; NewReq::<a href="cowboy_req.md#type-req">cowboy_req:req()</a>
</code></pre>
<br />

<a name="set_resp_link_header-4"></a>

### set_resp_link_header/4 ###

<pre><code>
set_resp_link_header(URI::binary(), Rel::iodata(), Title::iodata(), Req::<a href="cowboy_req.md#type-req">cowboy_req:req()</a>) -&gt; NewReq::<a href="cowboy_req.md#type-req">cowboy_req:req()</a>
</code></pre>
<br />

