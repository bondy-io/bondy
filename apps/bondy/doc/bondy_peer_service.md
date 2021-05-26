

# Module bondy_peer_service #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

Based on: github.com/lasp-lang/lasp/...lasp_peer_service.erl.

__This module defines the `bondy_peer_service` behaviour.__<br /> Required callback functions: `forward_message/3`, `forward_message/4`, `forward_message/5`, `join/1`, `join/2`, `join/3`, `leave/0`, `leave/1`, `manager/0`, `members/0`, `myself/0`, `mynode/0`, `stop/0`, `stop/1`.

<a name="types"></a>

## Data Types ##




### <a name="type-peer">peer()</a> ###


<pre><code>
peer() = <a href="/Volumes/Work/Leapsight/bondy/_build/default/lib/plum_db/doc/plum_db_peer_service.md#type-partisan_peer">plum_db_peer_service:partisan_peer()</a>
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#forward_message-3">forward_message/3</a></td><td>Forward message to registered process on the remote side.</td></tr><tr><td valign="top"><a href="#forward_message-4">forward_message/4</a></td><td></td></tr><tr><td valign="top"><a href="#forward_message-5">forward_message/5</a></td><td></td></tr><tr><td valign="top"><a href="#join-1">join/1</a></td><td>Prepare node to join a cluster.</td></tr><tr><td valign="top"><a href="#join-2">join/2</a></td><td>Convert nodename to atom.</td></tr><tr><td valign="top"><a href="#join-3">join/3</a></td><td>Initiate join.</td></tr><tr><td valign="top"><a href="#leave-0">leave/0</a></td><td>Leave the cluster.</td></tr><tr><td valign="top"><a href="#leave-1">leave/1</a></td><td>Leave the cluster.</td></tr><tr><td valign="top"><a href="#manager-0">manager/0</a></td><td>Return manager.</td></tr><tr><td valign="top"><a href="#members-0">members/0</a></td><td>Return cluster members.</td></tr><tr><td valign="top"><a href="#mynode-0">mynode/0</a></td><td>Return myself.</td></tr><tr><td valign="top"><a href="#myself-0">myself/0</a></td><td>Return myself.</td></tr><tr><td valign="top"><a href="#peer_service-0">peer_service/0</a></td><td>Return the currently active peer service.</td></tr><tr><td valign="top"><a href="#peers-0">peers/0</a></td><td>The list of cluster members excluding ourselves.</td></tr><tr><td valign="top"><a href="#stop-0">stop/0</a></td><td>Stop node.</td></tr><tr><td valign="top"><a href="#stop-1">stop/1</a></td><td>Stop node for a given reason.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="forward_message-3"></a>

### forward_message/3 ###

`forward_message(Name, ServerRef, Message) -> any()`

Forward message to registered process on the remote side.

<a name="forward_message-4"></a>

### forward_message/4 ###

`forward_message(Name, Channel, ServerRef, Message) -> any()`

<a name="forward_message-5"></a>

### forward_message/5 ###

`forward_message(Name, Channel, ServerRef, Message, Opts) -> any()`

<a name="join-1"></a>

### join/1 ###

`join(Node) -> any()`

Prepare node to join a cluster.

<a name="join-2"></a>

### join/2 ###

`join(NodeStr, Auto) -> any()`

Convert nodename to atom.

<a name="join-3"></a>

### join/3 ###

`join(Node, X2, Auto) -> any()`

Initiate join. Nodes cannot join themselves.

<a name="leave-0"></a>

### leave/0 ###

`leave() -> any()`

Leave the cluster.

<a name="leave-1"></a>

### leave/1 ###

`leave(Peer) -> any()`

Leave the cluster.

<a name="manager-0"></a>

### manager/0 ###

`manager() -> any()`

Return manager.

<a name="members-0"></a>

### members/0 ###

`members() -> any()`

Return cluster members.

<a name="mynode-0"></a>

### mynode/0 ###

`mynode() -> any()`

Return myself.

<a name="myself-0"></a>

### myself/0 ###

`myself() -> any()`

Return myself.

<a name="peer_service-0"></a>

### peer_service/0 ###

`peer_service() -> any()`

Return the currently active peer service.

<a name="peers-0"></a>

### peers/0 ###

`peers() -> any()`

The list of cluster members excluding ourselves

<a name="stop-0"></a>

### stop/0 ###

`stop() -> any()`

Stop node.

<a name="stop-1"></a>

### stop/1 ###

`stop(Reason) -> any()`

Stop node for a given reason.

