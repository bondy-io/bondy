

# Module bondy_wamp_ws_handler #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

A Cowboy WS handler.

<a name="description"></a>

## Description ##

Each WAMP message is transmitted as a separate WebSocket message
(not WebSocket frame)

The WAMP protocol MUST BE negotiated during the WebSocket opening
handshake between Peers using the WebSocket subprotocol negotiation
mechanism.

WAMP uses the following WebSocket subprotocol identifiers for
unbatched modes:

*  "wamp.2.json"
*  "wamp.2.msgpack"

With "wamp.2.json", _all_ WebSocket messages MUST BE of type *text*
(UTF8 encoded arguments_kw) and use the JSON message serialization.

With "wamp.2.msgpack", _all_ WebSocket messages MUST BE of type
*binary* and use the MsgPack message serialization.

To avoid incompatibilities merely due to naming conflicts with
WebSocket subprotocol identifiers, implementers SHOULD register
identifiers for additional serialization formats with the official
WebSocket subprotocol registry.
<a name="types"></a>

## Data Types ##




### <a name="type-state">state()</a> ###


<pre><code>
state() = #state{frame_type = <a href="bondy_wamp_protocol.md#type-frame_type">bondy_wamp_protocol:frame_type()</a>, protocol_state = <a href="bondy_wamp_protocol.md#type-state">bondy_wamp_protocol:state()</a> | undefined, hibernate = boolean()}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#init-2">init/2</a></td><td></td></tr><tr><td valign="top"><a href="#terminate-3">terminate/3</a></td><td>
Termination.</td></tr><tr><td valign="top"><a href="#websocket_handle-2">websocket_handle/2</a></td><td>
Handles frames sent by client.</td></tr><tr><td valign="top"><a href="#websocket_info-2">websocket_info/2</a></td><td>
Handles internal erlang messages and WAMP messages BONDY wants to send to the
client.</td></tr><tr><td valign="top"><a href="#websocket_init-1">websocket_init/1</a></td><td>
Initialises the WS connection.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="init-2"></a>

### init/2 ###

<pre><code>
init(Req0::<a href="cowboy_req.md#type-req">cowboy_req:req()</a>, State::<a href="#type-state">state()</a>) -&gt; {ok | module(), <a href="cowboy_req.md#type-req">cowboy_req:req()</a>, <a href="#type-state">state()</a>} | {module(), <a href="cowboy_req.md#type-req">cowboy_req:req()</a>, <a href="#type-state">state()</a>, hibernate} | {module(), <a href="cowboy_req.md#type-req">cowboy_req:req()</a>, <a href="#type-state">state()</a>, timeout()} | {module(), <a href="cowboy_req.md#type-req">cowboy_req:req()</a>, <a href="#type-state">state()</a>, timeout(), hibernate}
</code></pre>
<br />

<a name="terminate-3"></a>

### terminate/3 ###

`terminate(X1, Req, St) -> any()`

Termination

<a name="websocket_handle-2"></a>

### websocket_handle/2 ###

`websocket_handle(Data, State) -> any()`

Handles frames sent by client

<a name="websocket_info-2"></a>

### websocket_info/2 ###

`websocket_info(X1, St) -> any()`

Handles internal erlang messages and WAMP messages BONDY wants to send to the
client. See [`bondy:send/2`](bondy.md#send-2).

<a name="websocket_init-1"></a>

### websocket_init/1 ###

`websocket_init(State) -> any()`

Initialises the WS connection.

