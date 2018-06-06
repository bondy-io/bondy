

# Module bondy_api_gateway #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##




### <a name="type-listener">listener()</a> ###


<pre><code>
listener() = api_gateway_http | api_gateway_https | admin_api_http | admin_api_https
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#delete-1">delete/1</a></td><td></td></tr><tr><td valign="top"><a href="#dispatch_table-1">dispatch_table/1</a></td><td></td></tr><tr><td valign="top"><a href="#list-0">list/0</a></td><td></td></tr><tr><td valign="top"><a href="#load-1">load/1</a></td><td>
Parses the provided Spec, stores it in the metadata store and calls
rebuild_dispatch_tables/0.</td></tr><tr><td valign="top"><a href="#lookup-1">lookup/1</a></td><td></td></tr><tr><td valign="top"><a href="#start_admin_listeners-0">start_admin_listeners/0</a></td><td></td></tr><tr><td valign="top"><a href="#start_listeners-0">start_listeners/0</a></td><td>
Conditionally start the public http and https listeners based on the
configuration.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="delete-1"></a>

### delete/1 ###

<pre><code>
delete(Id::binary()) -&gt; ok
</code></pre>
<br />

<a name="dispatch_table-1"></a>

### dispatch_table/1 ###

<pre><code>
dispatch_table(Listener::<a href="#type-listener">listener()</a>) -&gt; any()
</code></pre>
<br />

<a name="list-0"></a>

### list/0 ###

<pre><code>
list() -&gt; [ParsedSpec::#{}]
</code></pre>
<br />

<a name="load-1"></a>

### load/1 ###

<pre><code>
load(Map::<a href="file.md#type-filename">file:filename()</a> | #{}) -&gt; ok | {error, invalid_specification_format | any()}
</code></pre>
<br />

Parses the provided Spec, stores it in the metadata store and calls
rebuild_dispatch_tables/0.

<a name="lookup-1"></a>

### lookup/1 ###

<pre><code>
lookup(Id::binary()) -&gt; #{} | {error, not_found}
</code></pre>
<br />

<a name="start_admin_listeners-0"></a>

### start_admin_listeners/0 ###

`start_admin_listeners() -> any()`

<a name="start_listeners-0"></a>

### start_listeners/0 ###

`start_listeners() -> any()`

Conditionally start the public http and https listeners based on the
configuration. This will load any default Bondy api specs.
Notice this is not the way to start the admin api listeners see
[`start_admin_listeners()`](#type-start_admin_listeners) for that.

