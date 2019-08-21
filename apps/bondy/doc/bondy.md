

# Module bondy #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##




### <a name="type-wamp_error_map">wamp_error_map()</a> ###


<pre><code>
wamp_error_map() = #{error_uri =&gt; <a href="#type-uri">uri()</a>, details =&gt; map(), arguments =&gt; list(), arguments_kw =&gt; map()}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#aae_exchanges-0">aae_exchanges/0</a></td><td></td></tr><tr><td valign="top"><a href="#ack-2">ack/2</a></td><td>
Acknowledges the reception of a WAMP message.</td></tr><tr><td valign="top"><a href="#call-5">call/5</a></td><td>
A blocking call.</td></tr><tr><td valign="top"><a href="#publish-5">publish/5</a></td><td></td></tr><tr><td valign="top"><a href="#send-2">send/2</a></td><td>
Sends a message to a WAMP peer.</td></tr><tr><td valign="top"><a href="#send-3">send/3</a></td><td>
Sends a message to a local WAMP peer.</td></tr><tr><td valign="top"><a href="#send-4">send/4</a></td><td></td></tr><tr><td valign="top"><a href="#start-0">start/0</a></td><td>
Starts bondy.</td></tr><tr><td valign="top"><a href="#subscribe-3">subscribe/3</a></td><td>Calls bondy_broker:subscribe/3.</td></tr><tr><td valign="top"><a href="#subscribe-4">subscribe/4</a></td><td>Calls bondy_broker:subscribe/4.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="aae_exchanges-0"></a>

### aae_exchanges/0 ###

`aae_exchanges() -> any()`

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
call(ProcedureUri::binary(), Opts::map(), Args::list() | undefined, ArgsKw::map() | undefined, Ctxt0::<a href="bondy_context.md#type-t">bondy_context:t()</a>) -&gt; {ok, map(), <a href="bondy_context.md#type-t">bondy_context:t()</a>} | {error, <a href="#type-wamp_error_map">wamp_error_map()</a>, <a href="bondy_context.md#type-t">bondy_context:t()</a>}
</code></pre>
<br />

A blocking call.

<a name="publish-5"></a>

### publish/5 ###

`publish(Opts, TopicUri, Args, ArgsKw, CtxtOrRealm) -> any()`

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
send(PeerId::<a href="#type-peer_id">peer_id()</a>, M::<a href="#type-wamp_message">wamp_message()</a>, Opts0::map()) -&gt; ok | no_return()
</code></pre>
<br />

Sends a message to a local WAMP peer.
If the transport is not open it fails with an exception.
This function is used by the router (dealer | broker) to send WAMP messages
to local peers.
Opts is a map with the following keys:

* timeout - timeout in milliseconds (defaults to 10000)
* enqueue (boolean) - if the peer is not reachable and this value is true,
bondy will enqueue the message so that the peer can resume the session and
consume all enqueued messages.

<a name="send-4"></a>

### send/4 ###

<pre><code>
send(From::<a href="#type-peer_id">peer_id()</a>, To::<a href="#type-peer_id">peer_id()</a>, M::<a href="#type-wamp_message">wamp_message()</a>, Opts0::map()) -&gt; ok | no_return()
</code></pre>
<br />

<a name="start-0"></a>

### start/0 ###

`start() -> any()`

Starts bondy

<a name="subscribe-3"></a>

### subscribe/3 ###

`subscribe(RealmUri, Opts, TopicUri) -> any()`

Calls bondy_broker:subscribe/3.

<a name="subscribe-4"></a>

### subscribe/4 ###

`subscribe(RealmUri, Opts, TopicUri, Fun) -> any()`

Calls bondy_broker:subscribe/4.

