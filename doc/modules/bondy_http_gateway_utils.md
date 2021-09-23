

# Module bondy_http_gateway_utils #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##


<a name="state_fun()"></a>


### state_fun() ###


<pre><code>
state_fun() = fun((any()) -&gt; any())
</code></pre>


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

