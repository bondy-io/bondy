

# Module bondy_wamp_raw_handler #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)

A ranch handler for the wamp protocol over either tcp or tls transports.

__Behaviours:__ [`gen_server`](gen_server.md), [`ranch_protocol`](ranch_protocol.md).

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#code_change-3">code_change/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_call-3">handle_call/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_cast-2">handle_cast/2</a></td><td></td></tr><tr><td valign="top"><a href="#handle_info-2">handle_info/2</a></td><td></td></tr><tr><td valign="top"><a href="#init-1">init/1</a></td><td></td></tr><tr><td valign="top"><a href="#start_link-4">start_link/4</a></td><td></td></tr><tr><td valign="top"><a href="#start_listeners-0">start_listeners/0</a></td><td>
Starts the tcp and tls raw socket listeners.</td></tr><tr><td valign="top"><a href="#terminate-2">terminate/2</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="code_change-3"></a>

### code_change/3 ###

`code_change(OldVsn, State, Extra) -> any()`

<a name="handle_call-3"></a>

### handle_call/3 ###

`handle_call(Msg, From, State) -> any()`

<a name="handle_cast-2"></a>

### handle_cast/2 ###

`handle_cast(Msg, State) -> any()`

<a name="handle_info-2"></a>

### handle_info/2 ###

`handle_info(Info, State) -> any()`

<a name="init-1"></a>

### init/1 ###

`init(X1) -> any()`

<a name="start_link-4"></a>

### start_link/4 ###

`start_link(Ref, Socket, Transport, Opts) -> any()`

<a name="start_listeners-0"></a>

### start_listeners/0 ###

<pre><code>
start_listeners() -&gt; ok
</code></pre>
<br />

Starts the tcp and tls raw socket listeners

<a name="terminate-2"></a>

### terminate/2 ###

`terminate(Reason, St) -> any()`

