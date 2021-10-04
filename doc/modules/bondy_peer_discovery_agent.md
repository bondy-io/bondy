

# Module bondy_peer_discovery_agent #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)

This state machine is reponsible for discovering Bondy cluster peers
using the defined implementation backend (callback module).

__Behaviours:__ [`gen_statem`](gen_statem.md).

__This module defines the `bondy_peer_discovery_agent` behaviour.__<br /> Required callback functions: `init/1`, `lookup/2`.

<a name="description"></a>

## Description ##

Its behaviour can be configured using the `cluster.peer_discovery` family of
`bondy.conf` options.

If the agent is enabled (`cluster.peer_discovery.enabled`) and the Bondy node
has not yet joined a cluster, it will lookup for peers using the
defined implementation backend callback module
(`cluster.peer_discovery.type`).

<a name="functions"></a>

## Function Details ##

<a name="callback_mode-0"></a>

### callback_mode/0 ###

`callback_mode() -> any()`

<a name="code_change-4"></a>

### code_change/4 ###

`code_change(OldVsn, StateName, State, Extra) -> any()`

<a name="disable-0"></a>

### disable/0 ###

<pre><code>
disable() -&gt; boolean()
</code></pre>
<br />

<a name="disabled-3"></a>

### disabled/3 ###

`disabled(EventType, EventContent, State) -> any()`

<a name="discovering-3"></a>

### discovering/3 ###

`discovering(EventType, EventContent, State) -> any()`

In this state the agent uses the callback module to discover peers
by calling its lookup/2 callback.

<a name="enable-0"></a>

### enable/0 ###

<pre><code>
enable() -&gt; boolean()
</code></pre>
<br />

<a name="format_status-2"></a>

### format_status/2 ###

`format_status(Opts, X2) -> any()`

<a name="init-1"></a>

### init/1 ###

`init(X1) -> any()`

<a name="joined-3"></a>

### joined/3 ###

`joined(EventType, EventContent, State) -> any()`

<a name="lookup-0"></a>

### lookup/0 ###

`lookup() -> any()`

<a name="start-0"></a>

### start/0 ###

<pre><code>
start() -&gt; {ok, pid()} | ignore | {error, term()}
</code></pre>
<br />

<a name="start_link-0"></a>

### start_link/0 ###

<pre><code>
start_link() -&gt; {ok, pid()} | ignore | {error, term()}
</code></pre>
<br />

<a name="terminate-3"></a>

### terminate/3 ###

`terminate(Reason, StateName, State) -> any()`

