

# Module bondy_api_gateway_handler #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)

This module implements a generic Cowboy rest handler that handles a resource
specified using the Bondy API Gateway Specification Format (BAGS),
a JSON-based format for describing, producing and consuming
RESTful Web Services using Bondy.

<a name="description"></a>

## Description ##

For every path defined in a BAGS file, Bondy will configure and install a
Cowboy route using this module. The initial state of the module responds to
a contract between this module and the [`bondy_api_gateway_spec_parser`](bondy_api_gateway_spec_parser.md)
and contains the parsed and preprocessed definition of the paths
specification which this module uses to dynamically implement its behaviour.

See [`bondy_api_gateway`](bondy_api_gateway.md) for a detail description of the
Bondy API Gateway Specification Format.<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#allowed_methods-2">allowed_methods/2</a></td><td></td></tr><tr><td valign="top"><a href="#content_types_accepted-2">content_types_accepted/2</a></td><td></td></tr><tr><td valign="top"><a href="#content_types_provided-2">content_types_provided/2</a></td><td></td></tr><tr><td valign="top"><a href="#delete_completed-2">delete_completed/2</a></td><td></td></tr><tr><td valign="top"><a href="#delete_resource-2">delete_resource/2</a></td><td></td></tr><tr><td valign="top"><a href="#from_form_urlencoded-2">from_form_urlencoded/2</a></td><td></td></tr><tr><td valign="top"><a href="#from_json-2">from_json/2</a></td><td></td></tr><tr><td valign="top"><a href="#from_msgpack-2">from_msgpack/2</a></td><td></td></tr><tr><td valign="top"><a href="#init-2">init/2</a></td><td></td></tr><tr><td valign="top"><a href="#is_authorized-2">is_authorized/2</a></td><td></td></tr><tr><td valign="top"><a href="#options-2">options/2</a></td><td></td></tr><tr><td valign="top"><a href="#previously_existed-2">previously_existed/2</a></td><td></td></tr><tr><td valign="top"><a href="#resource_exists-2">resource_exists/2</a></td><td></td></tr><tr><td valign="top"><a href="#to_json-2">to_json/2</a></td><td></td></tr><tr><td valign="top"><a href="#to_msgpack-2">to_msgpack/2</a></td><td></td></tr></table>


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

<a name="delete_completed-2"></a>

### delete_completed/2 ###

`delete_completed(Req, St) -> any()`

<a name="delete_resource-2"></a>

### delete_resource/2 ###

`delete_resource(Req0, St0) -> any()`

<a name="from_form_urlencoded-2"></a>

### from_form_urlencoded/2 ###

`from_form_urlencoded(Req, St) -> any()`

<a name="from_json-2"></a>

### from_json/2 ###

`from_json(Req, St) -> any()`

<a name="from_msgpack-2"></a>

### from_msgpack/2 ###

`from_msgpack(Req, St) -> any()`

<a name="init-2"></a>

### init/2 ###

`init(Req, St0) -> any()`

<a name="is_authorized-2"></a>

### is_authorized/2 ###

`is_authorized(Req0, St0) -> any()`

<a name="options-2"></a>

### options/2 ###

`options(Req, St) -> any()`

<a name="previously_existed-2"></a>

### previously_existed/2 ###

`previously_existed(Req, St) -> any()`

<a name="resource_exists-2"></a>

### resource_exists/2 ###

`resource_exists(Req, St) -> any()`

<a name="to_json-2"></a>

### to_json/2 ###

`to_json(Req, St) -> any()`

<a name="to_msgpack-2"></a>

### to_msgpack/2 ###

`to_msgpack(Req, St) -> any()`

