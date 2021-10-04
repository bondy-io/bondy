

# Module bondy_peer_wamp_forwarder #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)

A gen_server that forwards INVOCATION (their RESULT or ERROR), INTERRUPT
and EVENT messages between WAMP clients connected to different Bondy peers
(nodes).

__Behaviours:__ [`gen_server`](gen_server.md).

<a name="description"></a>

## Description ##

```
  +-------------------------+                    +-------------------------+
  |         node_1          |                    |         node_2          |
  |                         |                    |                         |
  |                         |                    |                         |
  | +---------------------+ |    cast_message    | +---------------------+ |
  | |partisan_peer_service| |                    | |partisan_peer_service| |
  | |      _manager       |<+--------------------+>|      _manager       | |
  | |                     | |                    | |                     | |
  | +---------------------+ |                    | +---------------------+ |
  |    ^          |         |                    |         |          ^    |
  |    |          v         |                    |         v          |    |
  |    |  +---------------+ |                    | +---------------+  |    |
  |    |  |bondy_peer_wamp| |                    | |bondy_peer_wamp|  |    |
  |    |  |  _forwarder   | |                    | |  _forwarder   |  |    |
  |    |  |               | |                    | |               |  |    |
  |    |  +---------------+ |                    | +---------------+  |    |
  |    |          |         |                    |         |          |    |
  |    |          |         |                    |         |          |    |
  |    |          |         |                    |         |          |    |
  |    |          v         |                    |         v          |    |
  | +---------------------+ |                    | +---------------------+ |
  | |       Worker        | |                    | |       Worker        | |
  | |    (router_pool)    | |                    | |    (router_pool)    | |
  | |                     | |                    | |                     | |
  | |                     | |                    | |                     | |
  | |                     | |                    | |                     | |
  | |                     | |                    | |                     | |
  | |                     | |                    | |                     | |
  | |                     | |                    | |                     | |
  | |                     | |                    | |                     | |
  | +---------------------+ |                    | +---------------------+ |
  |         ^    |          |                    |          |   ^          |
  |         |    |          |                    |          |   |          |
  |         |    v          |                    |          v   |          |
  | +---------------------+ |                    | +---------------------+ |
  | |bondy_wamp_*_handler | |                    | |bondy_wamp_*_handler | |
  | |                     | |                    | |                     | |
  | |                     | |                    | |                     | |
  | +---------------------+ |                    | +---------------------+ |
  |         ^    |          |                    |          |   ^          |
  |         |    |          |                    |          |   |          |
  +---------+----+----------+                    +----------+---+----------+
            |    |                                          |   |
            |    |                                          |   |
       CALL |    | RESULT | ERROR                INVOCATION |   | YIELD
            |    |                                          |   |
            |    v                                          v   |
  +-------------------------+                    +-------------------------+
  |         Caller          |                    |         Callee          |
  |                         |                    |                         |
  |                         |                    |                         |
  +-------------------------+                    +-------------------------+
```

<a name="functions"></a>

## Function Details ##

<a name="async_forward-4"></a>

### async_forward/4 ###

<pre><code>
async_forward(From::<a href="#type-remote_peer_id">remote_peer_id()</a>, To::<a href="#type-remote_peer_id">remote_peer_id()</a>, Mssg::<a href="#type-wamp_message">wamp_message()</a>, Opts::map()) -&gt; {ok, <a href="#type-id">id()</a>} | no_return()
</code></pre>
<br />

<a name="broadcast-4"></a>

### broadcast/4 ###

<pre><code>
broadcast(From::<a href="#type-peer_id">peer_id()</a>, Nodes::[node()], M::<a href="#type-wamp_message">wamp_message()</a>, Opts::map()) -&gt; {ok, Good::[node()], Bad::[node()]}
</code></pre>
<br />

<a name="code_change-3"></a>

### code_change/3 ###

`code_change(OldVsn, State, Extra) -> any()`

<a name="forward-4"></a>

### forward/4 ###

<pre><code>
forward(From::<a href="#type-remote_peer_id">remote_peer_id()</a>, To::<a href="#type-remote_peer_id">remote_peer_id()</a>, Mssg::<a href="#type-wamp_message">wamp_message()</a>, Opts::map()) -&gt; ok | no_return()
</code></pre>
<br />

Forwards a wamp message to a peer (cluster node).
It returns `ok` when the remote bondy_peer_wamp_forwarder acknoledges the
reception of the message, but it does not imply the message handler has
actually received the message.

This only works for PUBLISH, ERROR, INTERRUPT, INVOCATION and RESULT WAMP
message types. It will fail with an exception if another type is passed
as the third argument.

This is equivalent to calling async_forward/3 and then yield/2.

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

<a name="receive_ack-2"></a>

### receive_ack/2 ###

<pre><code>
receive_ack(Id::<a href="#type-remote_peer_id">remote_peer_id()</a>, Timeout::timeout()) -&gt; ok | no_return()
</code></pre>
<br />

<a name="start_link-0"></a>

### start_link/0 ###

<pre><code>
start_link() -&gt; {ok, pid()} | ignore | {error, term()}
</code></pre>
<br />

<a name="terminate-2"></a>

### terminate/2 ###

`terminate(Reason, State) -> any()`

