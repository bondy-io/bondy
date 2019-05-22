

# Module bondy_api_gateway #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

__Behaviours:__ [`gen_server`](gen_server.md).

<a name="types"></a>

## Data Types ##




### <a name="type-listener">listener()</a> ###


<pre><code>
listener() = api_gateway_http | api_gateway_https | admin_api_http | admin_api_https
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#apply_config-0">apply_config/0</a></td><td>
Parses the apis provided by the configuration file
('bondy.api_gateway.config_file'), stores the apis in the metadata store
and calls rebuild_dispatch_tables/0.</td></tr><tr><td valign="top"><a href="#code_change-3">code_change/3</a></td><td></td></tr><tr><td valign="top"><a href="#delete-1">delete/1</a></td><td>Deletes the API Specification object identified by <code>Id</code>.</td></tr><tr><td valign="top"><a href="#dispatch_table-1">dispatch_table/1</a></td><td>Returns the current dispatch configured in Cowboy for the
given Listener.</td></tr><tr><td valign="top"><a href="#handle_call-3">handle_call/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_cast-2">handle_cast/2</a></td><td></td></tr><tr><td valign="top"><a href="#handle_info-2">handle_info/2</a></td><td></td></tr><tr><td valign="top"><a href="#init-1">init/1</a></td><td></td></tr><tr><td valign="top"><a href="#list-0">list/0</a></td><td>Returns the list of all stored API Specification objects.</td></tr><tr><td valign="top"><a href="#load-1">load/1</a></td><td>
Parses the provided Spec, stores it in the metadata store and calls
rebuild_dispatch_tables/0.</td></tr><tr><td valign="top"><a href="#lookup-1">lookup/1</a></td><td>Returns the API Specification object identified by <code>Id</code>.</td></tr><tr><td valign="top"><a href="#rebuild_dispatch_tables-0">rebuild_dispatch_tables/0</a></td><td>
Loads all configured API specs from the metadata store and rebuilds the
Cowboy dispatch table by calling cowboy_router:compile/1 and updating the
environment.</td></tr><tr><td valign="top"><a href="#resume_admin_listeners-0">resume_admin_listeners/0</a></td><td></td></tr><tr><td valign="top"><a href="#resume_listeners-0">resume_listeners/0</a></td><td></td></tr><tr><td valign="top"><a href="#start_admin_listeners-0">start_admin_listeners/0</a></td><td></td></tr><tr><td valign="top"><a href="#start_link-0">start_link/0</a></td><td></td></tr><tr><td valign="top"><a href="#start_listeners-0">start_listeners/0</a></td><td>
Conditionally start the public http and https listeners based on the
configuration.</td></tr><tr><td valign="top"><a href="#stop_admin_listeners-0">stop_admin_listeners/0</a></td><td></td></tr><tr><td valign="top"><a href="#stop_listeners-0">stop_listeners/0</a></td><td></td></tr><tr><td valign="top"><a href="#suspend_admin_listeners-0">suspend_admin_listeners/0</a></td><td></td></tr><tr><td valign="top"><a href="#suspend_listeners-0">suspend_listeners/0</a></td><td></td></tr><tr><td valign="top"><a href="#terminate-2">terminate/2</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="apply_config-0"></a>

### apply_config/0 ###

<pre><code>
apply_config() -&gt; ok | {error, invalid_specification_format | any()}
</code></pre>
<br />

Parses the apis provided by the configuration file
('bondy.api_gateway.config_file'), stores the apis in the metadata store
and calls rebuild_dispatch_tables/0.

<a name="code_change-3"></a>

### code_change/3 ###

`code_change(OldVsn, State, Extra) -> any()`

<a name="delete-1"></a>

### delete/1 ###

<pre><code>
delete(Id::binary()) -&gt; ok
</code></pre>
<br />

Deletes the API Specification object identified by `Id`.

<a name="dispatch_table-1"></a>

### dispatch_table/1 ###

<pre><code>
dispatch_table(Listener::<a href="#type-listener">listener()</a>) -&gt; any()
</code></pre>
<br />

Returns the current dispatch configured in Cowboy for the
given Listener.

<a name="handle_call-3"></a>

### handle_call/3 ###

`handle_call(Event, From, State) -> any()`

<a name="handle_cast-2"></a>

### handle_cast/2 ###

`handle_cast(Event, State) -> any()`

<a name="handle_info-2"></a>

### handle_info/2 ###

`handle_info(Info, State) -> any()`

<a name="init-1"></a>

### init/1 ###

`init(X1) -> any()`

<a name="list-0"></a>

### list/0 ###

<pre><code>
list() -&gt; [ParsedSpec::map()]
</code></pre>
<br />

Returns the list of all stored API Specification objects.

<a name="load-1"></a>

### load/1 ###

<pre><code>
load(Term::<a href="file.md#type-filename">file:filename()</a> | map()) -&gt; ok | {error, invalid_specification_format | any()}
</code></pre>
<br />

Parses the provided Spec, stores it in the metadata store and calls
rebuild_dispatch_tables/0.

<a name="lookup-1"></a>

### lookup/1 ###

<pre><code>
lookup(Id::binary()) -&gt; map() | {error, not_found}
</code></pre>
<br />

Returns the API Specification object identified by `Id`.

<a name="rebuild_dispatch_tables-0"></a>

### rebuild_dispatch_tables/0 ###

`rebuild_dispatch_tables() -> any()`

Loads all configured API specs from the metadata store and rebuilds the
Cowboy dispatch table by calling cowboy_router:compile/1 and updating the
environment.

<a name="resume_admin_listeners-0"></a>

### resume_admin_listeners/0 ###

<pre><code>
resume_admin_listeners() -&gt; ok
</code></pre>
<br />

<a name="resume_listeners-0"></a>

### resume_listeners/0 ###

<pre><code>
resume_listeners() -&gt; ok
</code></pre>
<br />

<a name="start_admin_listeners-0"></a>

### start_admin_listeners/0 ###

`start_admin_listeners() -> any()`

<a name="start_link-0"></a>

### start_link/0 ###

`start_link() -> any()`

<a name="start_listeners-0"></a>

### start_listeners/0 ###

<pre><code>
start_listeners() -&gt; ok
</code></pre>
<br />

Conditionally start the public http and https listeners based on the
configuration. This will load any default Bondy api specs.
Notice this is not the way to start the admin api listeners see
[`start_admin_listeners()`](#type-start_admin_listeners) for that.

<a name="stop_admin_listeners-0"></a>

### stop_admin_listeners/0 ###

<pre><code>
stop_admin_listeners() -&gt; ok
</code></pre>
<br />

<a name="stop_listeners-0"></a>

### stop_listeners/0 ###

<pre><code>
stop_listeners() -&gt; ok
</code></pre>
<br />

<a name="suspend_admin_listeners-0"></a>

### suspend_admin_listeners/0 ###

<pre><code>
suspend_admin_listeners() -&gt; ok
</code></pre>
<br />

<a name="suspend_listeners-0"></a>

### suspend_listeners/0 ###

<pre><code>
suspend_listeners() -&gt; ok
</code></pre>
<br />

<a name="terminate-2"></a>

### terminate/2 ###

`terminate(Reason, State) -> any()`

