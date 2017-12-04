

# Module bondy_api_oauth2_handler #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##




### <a name="type-state">state()</a> ###


<pre><code>
state() = #{realm_uri =&gt; binary(), client_id =&gt; binary()}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#allowed_methods-2">allowed_methods/2</a></td><td></td></tr><tr><td valign="top"><a href="#content_types_accepted-2">content_types_accepted/2</a></td><td></td></tr><tr><td valign="top"><a href="#content_types_provided-2">content_types_provided/2</a></td><td></td></tr><tr><td valign="top"><a href="#init-2">init/2</a></td><td></td></tr><tr><td valign="top"><a href="#is_authorized-2">is_authorized/2</a></td><td></td></tr><tr><td valign="top"><a href="#options-2">options/2</a></td><td></td></tr><tr><td valign="top"><a href="#resource_existed-2">resource_existed/2</a></td><td></td></tr><tr><td valign="top"><a href="#resource_exists-2">resource_exists/2</a></td><td></td></tr><tr><td valign="top"><a href="#to_json-2">to_json/2</a></td><td></td></tr><tr><td valign="top"><a href="#to_msgpack-2">to_msgpack/2</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="allowed_methods-2"></a>

### allowed_methods/2 ###

`allowed_methods(Req, St) -> any()`

<a name="content_types_accepted-2"></a>

### content_types_accepted/2 ###

`content_types_accepted(Req, St) -> any()`

<a name="content_types_provided-2"></a>

### content_types_provided/2 ###

`content_types_provided(Req, St) -> any()`

<a name="init-2"></a>

### init/2 ###

`init(Req, St) -> any()`

<a name="is_authorized-2"></a>

### is_authorized/2 ###

`is_authorized(Req0, St0) -> any()`

<a name="options-2"></a>

### options/2 ###

`options(Req, State) -> any()`

<a name="resource_existed-2"></a>

### resource_existed/2 ###

`resource_existed(Req, St) -> any()`

<a name="resource_exists-2"></a>

### resource_exists/2 ###

`resource_exists(Req, St) -> any()`

<a name="to_json-2"></a>

### to_json/2 ###

`to_json(Req, St) -> any()`

<a name="to_msgpack-2"></a>

### to_msgpack/2 ###

`to_msgpack(Req, St) -> any()`

