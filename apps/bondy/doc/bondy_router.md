

# Module bondy_router #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)

bondy_router provides the routing logic for all interactions.

<a name="description"></a>

## Description ##

In general bondy_router tries to handle all messages asynchronously.
It does it by
using either a static or a dynamic pool of workers based on configuration.
This module implements both type of workers as a gen_server (this module).
A static pool uses a set of supervised processes whereas a
dynamic pool spawns a new erlang process for each message. In both cases,
sidejob supervises the processes.
By default bondy_router uses a dynamic pool.

The pools are implemented using the sidejob library in order to provide
load regulation. Inn case a maximum pool capacity has been reached,
the router will handle the message synchronously i.e. blocking the
calling processes (usually the one that handles the transport connection
e.g. [`bondy_wamp_ws_handler`](bondy_wamp_ws_handler.md)).

The router also handles messages synchronously in those
cases where it needs to preserve message ordering guarantees.

This module handles only the concurrency and basic routing logic,
delegating the rest to either [`bondy_broker`](bondy_broker.md) or [`bondy_dealer`](bondy_dealer.md),
which implement the actual PubSub and RPC logic respectively.

```
  ,------.                                    ,------.
  | Peer |                                    | Peer |
  `--+---'                                    `--+---'
     |                                           |
     |               TCP established             |
     |<----------------------------------------->|
     |                                           |
     |               TLS established             |
     |+<--------------------------------------->+|
     |+                                         +|
     |+           WebSocket established         +|
     |+|<------------------------------------->|+|
     |+|                                       |+|
     |+|            WAMP established           |+|
     |+|+<----------------------------------->+|+|
     |+|+                                     +|+|
     |+|+                                     +|+|
     |+|+            WAMP closed              +|+|
     |+|+<----------------------------------->+|+|
     |+|                                       |+|
     |+|                                       |+|
     |+|            WAMP established           |+|
     |+|+<----------------------------------->+|+|
     |+|+                                     +|+|
     |+|+                                     +|+|
     |+|+            WAMP closed              +|+|
     |+|+<----------------------------------->+|+|
     |+|                                       |+|
     |+|           WebSocket closed            |+|
     |+|<------------------------------------->|+|
     |+                                         +|
     |+              TLS closed                 +|
     |+<--------------------------------------->+|
     |                                           |
     |               TCP closed                  |
     |<----------------------------------------->|
     |                                           |
  ,--+---.                                    ,--+---.
  | Peer |                                    | Peer |
  `------'                                    `------'
```

(Diagram copied from WAMP RFC Draft)
<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#agent-0">agent/0</a></td><td>
Returns the Bondy agent identification string.</td></tr><tr><td valign="top"><a href="#close_context-1">close_context/1</a></td><td></td></tr><tr><td valign="top"><a href="#forward-2">forward/2</a></td><td>
Forwards a WAMP message to the Dealer or Broker based on message type.</td></tr><tr><td valign="top"><a href="#handle_peer_message-1">handle_peer_message/1</a></td><td></td></tr><tr><td valign="top"><a href="#roles-0">roles/0</a></td><td></td></tr><tr><td valign="top"><a href="#shutdown-0">shutdown/0</a></td><td>Sends a GOODBYE message to all existing client connections.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="agent-0"></a>

### agent/0 ###

`agent() -> any()`

Returns the Bondy agent identification string

<a name="close_context-1"></a>

### close_context/1 ###

<pre><code>
close_context(Ctxt::<a href="bondy_context.md#type-t">bondy_context:t()</a>) -&gt; <a href="bondy_context.md#type-t">bondy_context:t()</a>
</code></pre>
<br />

<a name="forward-2"></a>

### forward/2 ###

<pre><code>
forward(M::<a href="#type-wamp_message">wamp_message()</a>, Ctxt::<a href="bondy_context.md#type-t">bondy_context:t()</a>) -&gt; {ok, <a href="bondy_context.md#type-t">bondy_context:t()</a>} | {reply, Reply::<a href="#type-wamp_message">wamp_message()</a>, <a href="bondy_context.md#type-t">bondy_context:t()</a>} | {stop, Reply::<a href="#type-wamp_message">wamp_message()</a>, <a href="bondy_context.md#type-t">bondy_context:t()</a>}
</code></pre>
<br />

Forwards a WAMP message to the Dealer or Broker based on message type.
The message might end up being handled synchronously
(performed by the calling process i.e. the transport handler)
or asynchronously (by sending the message to the router load regulated
worker pool).

<a name="handle_peer_message-1"></a>

### handle_peer_message/1 ###

<pre><code>
handle_peer_message(PM::<a href="bondy_peer_message.md#type-t">bondy_peer_message:t()</a>) -&gt; ok | no_return()
</code></pre>
<br />

<a name="roles-0"></a>

### roles/0 ###

<pre><code>
roles() -&gt; #{binary() =&gt; #{binary() =&gt; boolean()}}
</code></pre>
<br />

<a name="shutdown-0"></a>

### shutdown/0 ###

`shutdown() -> any()`

Sends a GOODBYE message to all existing client connections.
The client should reply with another GOODBYE within the configured time and
when it does or on timeout, Bondy will close the connection triggering the
cleanup of all the client sessions.

