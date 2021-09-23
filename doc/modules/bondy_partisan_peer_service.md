

# Module bondy_partisan_peer_service #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)

Based on: github.com/lasp-lang/lasp/...lasp_partisan_peer_service.erl.

__Behaviours:__ [`bondy_peer_service`](bondy_peer_service.md).

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

`leave(Node) -> any()`

Leave the cluster.

<a name="manager-0"></a>

### manager/0 ###

`manager() -> any()`

<a name="members-0"></a>

### members/0 ###

`members() -> any()`

<a name="mynode-0"></a>

### mynode/0 ###

`mynode() -> any()`

<a name="myself-0"></a>

### myself/0 ###

`myself() -> any()`

<a name="stop-0"></a>

### stop/0 ###

`stop() -> any()`

Stop node.

<a name="stop-1"></a>

### stop/1 ###

`stop(Reason) -> any()`

Stop node for a given reason.

