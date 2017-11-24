

# Module bondy_config #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)

.

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#api_gateway-0">api_gateway/0</a></td><td></td></tr><tr><td valign="top"><a href="#automatically_create_realms-0">automatically_create_realms/0</a></td><td></td></tr><tr><td valign="top"><a href="#connection_lifetime-0">connection_lifetime/0</a></td><td></td></tr><tr><td valign="top"><a href="#coordinator_timeout-0">coordinator_timeout/0</a></td><td></td></tr><tr><td valign="top"><a href="#is_router-0">is_router/0</a></td><td></td></tr><tr><td valign="top"><a href="#load_regulation_enabled-0">load_regulation_enabled/0</a></td><td></td></tr><tr><td valign="top"><a href="#priv_dir-0">priv_dir/0</a></td><td>
Returns the app's priv dir.</td></tr><tr><td valign="top"><a href="#request_timeout-0">request_timeout/0</a></td><td></td></tr><tr><td valign="top"><a href="#router_pool-0">router_pool/0</a></td><td>
Returns a proplist containing the following keys:.</td></tr><tr><td valign="top"><a href="#tcp_acceptors_pool_size-0">tcp_acceptors_pool_size/0</a></td><td></td></tr><tr><td valign="top"><a href="#tcp_max_connections-0">tcp_max_connections/0</a></td><td></td></tr><tr><td valign="top"><a href="#tcp_port-0">tcp_port/0</a></td><td></td></tr><tr><td valign="top"><a href="#tls_acceptors_pool_size-0">tls_acceptors_pool_size/0</a></td><td></td></tr><tr><td valign="top"><a href="#tls_files-0">tls_files/0</a></td><td></td></tr><tr><td valign="top"><a href="#tls_max_connections-0">tls_max_connections/0</a></td><td></td></tr><tr><td valign="top"><a href="#tls_port-0">tls_port/0</a></td><td></td></tr><tr><td valign="top"><a href="#ws_compress_enabled-0">ws_compress_enabled/0</a></td><td>
x-webkit-deflate-frame compression draft which is being used by some
browsers to reduce the size of data being transmitted supported by Cowboy.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="api_gateway-0"></a>

### api_gateway/0 ###

`api_gateway() -> any()`

<a name="automatically_create_realms-0"></a>

### automatically_create_realms/0 ###

`automatically_create_realms() -> any()`

<a name="connection_lifetime-0"></a>

### connection_lifetime/0 ###

<pre><code>
connection_lifetime() -&gt; session | connection
</code></pre>
<br />

<a name="coordinator_timeout-0"></a>

### coordinator_timeout/0 ###

<pre><code>
coordinator_timeout() -&gt; pos_integer()
</code></pre>
<br />

<a name="is_router-0"></a>

### is_router/0 ###

<pre><code>
is_router() -&gt; boolean()
</code></pre>
<br />

<a name="load_regulation_enabled-0"></a>

### load_regulation_enabled/0 ###

<pre><code>
load_regulation_enabled() -&gt; boolean()
</code></pre>
<br />

<a name="priv_dir-0"></a>

### priv_dir/0 ###

`priv_dir() -> any()`

Returns the app's priv dir

<a name="request_timeout-0"></a>

### request_timeout/0 ###

`request_timeout() -> any()`

<a name="router_pool-0"></a>

### router_pool/0 ###

<pre><code>
router_pool() -&gt; list()
</code></pre>
<br />

Returns a proplist containing the following keys:

* type - can be one of the following:
* permanent - the pool contains a (size) number of permanent workers
under a supervision tree. This is the "events as messages" design pattern.
* transient - the pool contains a (size) number of supervisors each one
supervision a transient process. This is the "events as messages" design
pattern.
* size - The number of workers used by the load regulation system
for the provided pool
* capacity - The usage limit enforced by the load regulation system for the provided pool

<a name="tcp_acceptors_pool_size-0"></a>

### tcp_acceptors_pool_size/0 ###

`tcp_acceptors_pool_size() -> any()`

<a name="tcp_max_connections-0"></a>

### tcp_max_connections/0 ###

`tcp_max_connections() -> any()`

<a name="tcp_port-0"></a>

### tcp_port/0 ###

`tcp_port() -> any()`

<a name="tls_acceptors_pool_size-0"></a>

### tls_acceptors_pool_size/0 ###

`tls_acceptors_pool_size() -> any()`

<a name="tls_files-0"></a>

### tls_files/0 ###

`tls_files() -> any()`

<a name="tls_max_connections-0"></a>

### tls_max_connections/0 ###

`tls_max_connections() -> any()`

<a name="tls_port-0"></a>

### tls_port/0 ###

`tls_port() -> any()`

<a name="ws_compress_enabled-0"></a>

### ws_compress_enabled/0 ###

`ws_compress_enabled() -> any()`

x-webkit-deflate-frame compression draft which is being used by some
browsers to reduce the size of data being transmitted supported by Cowboy.

