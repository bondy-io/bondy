

# Module bondy_wamp_protocol #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

.

<a name="types"></a>

## Data Types ##




### <a name="type-state">state()</a> ###


<pre><code>
state() = #wamp_state{subprotocol = <a href="#type-subprotocol">subprotocol()</a> | undefined, authmethod = any(), state_name = <a href="#type-state_name">state_name()</a>, context = <a href="bondy_context.md#type-t">bondy_context:t()</a> | undefined} | undefined
</code></pre>




### <a name="type-state_name">state_name()</a> ###


<pre><code>
state_name() = closed | establishing | challenging | failed | established | shutting_down
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#agent-1">agent/1</a></td><td></td></tr><tr><td valign="top"><a href="#handle_inbound-2">handle_inbound/2</a></td><td>
Handles wamp frames, decoding 1 or more messages, routing them and replying
when required.</td></tr><tr><td valign="top"><a href="#handle_outbound-2">handle_outbound/2</a></td><td></td></tr><tr><td valign="top"><a href="#init-3">init/3</a></td><td></td></tr><tr><td valign="top"><a href="#peer-1">peer/1</a></td><td></td></tr><tr><td valign="top"><a href="#peer_id-1">peer_id/1</a></td><td></td></tr><tr><td valign="top"><a href="#session_id-1">session_id/1</a></td><td></td></tr><tr><td valign="top"><a href="#terminate-1">terminate/1</a></td><td></td></tr><tr><td valign="top"><a href="#validate_subprotocol-1">validate_subprotocol/1</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="agent-1"></a>

### agent/1 ###

<pre><code>
agent(Wamp_state::<a href="#type-state">state()</a>) -&gt; <a href="#type-id">id()</a>
</code></pre>
<br />

<a name="handle_inbound-2"></a>

### handle_inbound/2 ###

<pre><code>
handle_inbound(Data::binary(), St::<a href="#type-state">state()</a>) -&gt; {ok, <a href="#type-state">state()</a>} | {stop, <a href="#type-state">state()</a>} | {stop, [binary()], <a href="#type-state">state()</a>} | {reply, [binary()], <a href="#type-state">state()</a>}
</code></pre>
<br />

Handles wamp frames, decoding 1 or more messages, routing them and replying
when required.

<a name="handle_outbound-2"></a>

### handle_outbound/2 ###

<pre><code>
handle_outbound(Result::<a href="wamp_message.md#type-message">wamp_message:message()</a>, St0::<a href="#type-state">state()</a>) -&gt; {ok, binary(), <a href="#type-state">state()</a>} | {stop, <a href="#type-state">state()</a>} | {stop, binary(), <a href="#type-state">state()</a>} | {stop, binary(), <a href="#type-state">state()</a>, After::non_neg_integer()}
</code></pre>
<br />

<a name="init-3"></a>

### init/3 ###

<pre><code>
init(Term::binary() | <a href="#type-subprotocol">subprotocol()</a>, Peer::<a href="bondy_session.md#type-peer">bondy_session:peer()</a>, Opts::map()) -&gt; {ok, <a href="#type-state">state()</a>} | {error, any(), <a href="#type-state">state()</a>}
</code></pre>
<br />

<a name="peer-1"></a>

### peer/1 ###

<pre><code>
peer(Wamp_state::<a href="#type-state">state()</a>) -&gt; {<a href="inet.md#type-ip_address">inet:ip_address()</a>, <a href="inet.md#type-port_number">inet:port_number()</a>}
</code></pre>
<br />

<a name="peer_id-1"></a>

### peer_id/1 ###

<pre><code>
peer_id(Wamp_state::<a href="#type-state">state()</a>) -&gt; <a href="#type-peer_id">peer_id()</a>
</code></pre>
<br />

<a name="session_id-1"></a>

### session_id/1 ###

<pre><code>
session_id(Wamp_state::<a href="#type-state">state()</a>) -&gt; <a href="#type-id">id()</a>
</code></pre>
<br />

<a name="terminate-1"></a>

### terminate/1 ###

<pre><code>
terminate(St::<a href="#type-state">state()</a>) -&gt; ok
</code></pre>
<br />

<a name="validate_subprotocol-1"></a>

### validate_subprotocol/1 ###

<pre><code>
validate_subprotocol(T::binary() | <a href="#type-subprotocol">subprotocol()</a>) -&gt; {ok, <a href="#type-subprotocol">subprotocol()</a>} | {error, invalid_subprotocol}
</code></pre>
<br />

