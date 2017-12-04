

# Module bondy #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

.

<a name="types"></a>

## Data Types ##




### <a name="type-wamp_error_map">wamp_error_map()</a> ###


<pre><code>
wamp_error_map() = #{error_uri =&gt; <a href="#type-uri">uri()</a>, details =&gt; #{}, arguments =&gt; list(), arguments_kw =&gt; #{}}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#ack-2">ack/2</a></td><td>
Acknowledges the reception of a WAMP message.</td></tr><tr><td valign="top"><a href="#call-5">call/5</a></td><td>
A blocking call.</td></tr><tr><td valign="top"><a href="#send-2">send/2</a></td><td>
Sends a message to a WAMP peer.</td></tr><tr><td valign="top"><a href="#send-3">send/3</a></td><td>
Sends a message to a peer.</td></tr><tr><td valign="top"><a href="#start-0">start/0</a></td><td>
Starts bondy.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="ack-2"></a>

### ack/2 ###

<pre><code>
ack(Pid::pid(), Ref::reference()) -&gt; ok
</code></pre>
<br />

Acknowledges the reception of a WAMP message. This function should be used by
the peer transport module to acknowledge the reception of a message sent with
[`send/3`](#send-3).

<a name="call-5"></a>

### call/5 ###

<pre><code>
call(ProcedureUri::binary(), Opts::#{}, Args::list() | undefined, ArgsKw::#{} | undefined, Ctxt0::<a href="bondy_context.md#type-context">bondy_context:context()</a>) -&gt; {ok, #{}, <a href="bondy_context.md#type-context">bondy_context:context()</a>} | {error, <a href="#type-wamp_error_map">wamp_error_map()</a>, <a href="bondy_context.md#type-context">bondy_context:context()</a>}
</code></pre>
<br />

A blocking call.

<a name="send-2"></a>

### send/2 ###

<pre><code>
send(PeerId::<a href="#type-peer_id">peer_id()</a>, M::<a href="#type-wamp_message">wamp_message()</a>) -&gt; ok
</code></pre>
<br />

Sends a message to a WAMP peer.
It calls `send/3` with a an empty map for Options.

<a name="send-3"></a>

### send/3 ###

<pre><code>
send(P::<a href="#type-peer_id">peer_id()</a>, M::<a href="#type-wamp_message">wamp_message()</a>, Opts::#{}) -&gt; ok | no_return()
</code></pre>
<br />

Sends a message to a peer.
If the transport is not open it fails with an exception.
This function is used by the router (dealer | broker) to send WAMP messages
to peers.
Opts is a map with the following keys:

* timeout - timeout in milliseconds (defaults to 10000)
* enqueue (boolean) - if the peer is not reachable and this value is true,
bondy will enqueue the message so that the peer can resume the session and
consume all enqueued messages.

<a name="start-0"></a>

### start/0 ###

`start() -> any()`

Starts bondy

