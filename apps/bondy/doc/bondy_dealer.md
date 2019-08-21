

# Module bondy_dealer #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)

This module implements the capabilities of a Dealer.

<a name="description"></a>

## Description ##

It is used by
[`bondy_router`](bondy_router.md).

A Dealer is one of the two roles a Router plays. In particular a Dealer is
the middleman between an Caller and a Callee in an RPC interaction,
i.e. it works as a generic router for remote procedure calls
decoupling Callers and Callees.

Callees register the procedures they provide with Dealers.  Callers
initiate procedure calls first to Dealers.  Dealers route calls
incoming from Callers to Callees implementing the procedure called,
and route call results back from Callees to Callers.

A Caller issues calls to remote procedures by providing the procedure
URI and any arguments for the call. The Callee will execute the
procedure using the supplied arguments to the call and return the
result of the call to the Caller.

The Caller and Callee will usually implement all business logic, while the
Dealer works as a generic router for remote procedure calls
decoupling Callers and Callees.

Bondy does not provide message transformations to ensure stability and
safety.
As such, any required transformations should be handled by Callers and
Callees directly (notice that a Callee can act as a middleman implementing
the required transformations).

The message flow between _Callees_ and a _Dealer_ for registering and
unregistering endpoints to be called over RPC involves the following
messages:

1.  "REGISTER"
2.  "REGISTERED"
3.  "UNREGISTER"
4.  "UNREGISTERED"
5.  "ERROR"

```
         ,------.          ,------.               ,------.
         |Caller|          |Dealer|               |Callee|
         `--+---'          `--+---'               `--+---'
            |                 |                      |
            |                 |                      |
            |                 |       REGISTER       |
            |                 | &lt;---------------------
            |                 |                      |
            |                 |  REGISTERED or ERROR |
            |                 | ---------------------&gt;
            |                 |                      |
            |                 |                      |
            |                 |                      |
            |                 |                      |
            |                 |                      |
            |                 |      UNREGISTER      |
            |                 | &lt;---------------------
            |                 |                      |
            |                 | UNREGISTERED or ERROR|
            |                 | ---------------------&gt;
         ,--+---.          ,--+---.               ,--+---.
         |Caller|          |Dealer|               |Callee|
         `------'          `------'               `------'
```

# Calling and Invocations

The message flow between _Callers_, a _Dealer_ and _Callees_ for
calling procedures and invoking endpoints involves the following
messages:

1. "CALL"

2. "RESULT"

3. "INVOCATION"

4. "YIELD"

5. "ERROR"

```
         ,------.          ,------.          ,------.
         |Caller|          |Dealer|          |Callee|
         `--+---'          `--+---'          `--+---'
            |       CALL      |                 |
            | ----------------&gt;                 |
            |                 |                 |
            |                 |    INVOCATION   |
            |                 | ----------------&gt;
            |                 |                 |
            |                 |  YIELD or ERROR |
            |                 | %lt;----------------
            |                 |                 |
            | RESULT or ERROR |                 |
            | %lt;----------------                 |
         ,--+---.          ,--+---.          ,--+---.
         |Caller|          |Dealer|          |Callee|
         `------'          `------'          `------'
```

The execution of remote procedure calls is asynchronous, and there
may be more than one call outstanding.  A call is called outstanding
(from the point of view of the _Caller_), when a (final) result or
error has not yet been received by the _Caller_.

# Remote Procedure Call Ordering

Regarding *Remote Procedure Calls*, the ordering guarantees are as
follows:

If _Callee A_ has registered endpoints for both *Procedure 1* and
*Procedure 2*, and _Caller B_ first issues a *Call 1* to *Procedure
1* and then a *Call 2* to *Procedure 2*, and both calls are routed to
_Callee A_, then _Callee A_ will first receive an invocation
corresponding to *Call 1* and then *Call 2*. This also holds if
*Procedure 1* and *Procedure 2* are identical.

In other words, WAMP guarantees ordering of invocations between any
given _pair_ of _Caller_ and _Callee_. The current implementation
relies on Distributed Erlang which guarantees message ordering betweeen
processes in different nodes.

There are no guarantees on the order of call results and errors in
relation to _different_ calls, since the execution of calls upon
different invocations of endpoints in _Callees_ are running
independently.  A first call might require an expensive, long-running
computation, whereas a second, subsequent call might finish
immediately.

Further, if _Callee A_ registers for *Procedure 1*, the "REGISTERED"
message will be sent by _Dealer_ to _Callee A_ before any
"INVOCATION" message for *Procedure 1*.

There is no guarantee regarding the order of return for multiple
subsequent register requests.  A register request might require the
_Dealer_ to do a time-consuming lookup in some database, whereas
another register request second might be permissible immediately.<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#callees-1">callees/1</a></td><td></td></tr><tr><td valign="top"><a href="#callees-2">callees/2</a></td><td></td></tr><tr><td valign="top"><a href="#callees-3">callees/3</a></td><td></td></tr><tr><td valign="top"><a href="#close_context-1">close_context/1</a></td><td></td></tr><tr><td valign="top"><a href="#features-0">features/0</a></td><td></td></tr><tr><td valign="top"><a href="#handle_message-2">handle_message/2</a></td><td></td></tr><tr><td valign="top"><a href="#handle_peer_message-4">handle_peer_message/4</a></td><td>Handles inbound messages received from a peer (node).</td></tr><tr><td valign="top"><a href="#is_feature_enabled-1">is_feature_enabled/1</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="callees-1"></a>

### callees/1 ###

<pre><code>
callees(RealmUri::<a href="#type-uri">uri()</a>) -&gt; [map()] | no_return()
</code></pre>
<br />

<a name="callees-2"></a>

### callees/2 ###

<pre><code>
callees(RealmUri::<a href="#type-uri">uri()</a>, ProcedureUri::<a href="#type-uri">uri()</a>) -&gt; [map()] | no_return()
</code></pre>
<br />

<a name="callees-3"></a>

### callees/3 ###

<pre><code>
callees(RealmUri::<a href="#type-uri">uri()</a>, ProcedureUri::<a href="#type-uri">uri()</a>, Opts::map()) -&gt; [map()] | no_return()
</code></pre>
<br />

<a name="close_context-1"></a>

### close_context/1 ###

<pre><code>
close_context(Ctxt::<a href="bondy_context.md#type-t">bondy_context:t()</a>) -&gt; <a href="bondy_context.md#type-t">bondy_context:t()</a>
</code></pre>
<br />

<a name="features-0"></a>

### features/0 ###

<pre><code>
features() -&gt; map()
</code></pre>
<br />

<a name="handle_message-2"></a>

### handle_message/2 ###

<pre><code>
handle_message(M::<a href="#type-wamp_message">wamp_message()</a>, Ctxt::map()) -&gt; ok | no_return()
</code></pre>
<br />

<a name="handle_peer_message-4"></a>

### handle_peer_message/4 ###

<pre><code>
handle_peer_message(Yield::<a href="#type-wamp_message">wamp_message()</a>, To::<a href="#type-remote_peer_id">remote_peer_id()</a>, From::<a href="#type-remote_peer_id">remote_peer_id()</a>, Opts::map()) -&gt; ok | no_return()
</code></pre>
<br />

Handles inbound messages received from a peer (node).

<a name="is_feature_enabled-1"></a>

### is_feature_enabled/1 ###

<pre><code>
is_feature_enabled(F::binary()) -&gt; boolean()
</code></pre>
<br />

