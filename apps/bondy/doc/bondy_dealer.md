

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
         |Caller|          |Dealer|               |Callee|<code>--+---</code><code>--+---</code><code>--+---</code>
            |                 |                      |
            |                 |                      |
            |                 |       REGISTER       |
            |                 | <---------------------
            |                 |                      |
            |                 |  REGISTERED or ERROR |
            |                 | --------------------->
            |                 |                      |
            |                 |                      |
            |                 |                      |
            |                 |                      |
            |                 |                      |
            |                 |      UNREGISTER      |
            |                 | <---------------------
            |                 |                      |
            |                 | UNREGISTERED or ERROR|
            |                 | --------------------->
         ,--+---.          ,--+---.               ,--+---.
         |Caller|          |Dealer|               |Callee|<code>------</code><code>------</code><code>------</code><p></p>
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
         |Caller|          |Dealer|          |Callee|<code>--+---</code><code>--+---</code><code>--+---</code>
            |       CALL      |                 |
            | ---------------->                 |
            |                 |                 |
            |                 |    INVOCATION   |
            |                 | ---------------->
            |                 |                 |
            |                 |  YIELD or ERROR |
            |                 | %lt;----------------
            |                 |                 |
            | RESULT or ERROR |                 |
            | %lt;----------------                 |
         ,--+---.          ,--+---.          ,--+---.
         |Caller|          |Dealer|          |Callee|<code>------</code><code>------</code><code>------</code><p></p>
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
_Broker_ to do a time-consuming lookup in some database, whereas
another register request second might be permissible immediately.<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#close_context-1">close_context/1</a></td><td></td></tr><tr><td valign="top"><a href="#features-0">features/0</a></td><td></td></tr><tr><td valign="top"><a href="#handle_message-2">handle_message/2</a></td><td></td></tr><tr><td valign="top"><a href="#is_feature_enabled-1">is_feature_enabled/1</a></td><td></td></tr><tr><td valign="top"><a href="#register-3">register/3</a></td><td>
Registers an RPC endpoint.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="close_context-1"></a>

### close_context/1 ###

<pre><code>
close_context(Ctxt::<a href="bondy_context.md#type-context">bondy_context:context()</a>) -&gt; <a href="bondy_context.md#type-context">bondy_context:context()</a>
</code></pre>
<br />

<a name="features-0"></a>

### features/0 ###

<pre><code>
features() -&gt; #{}
</code></pre>
<br />

<a name="handle_message-2"></a>

### handle_message/2 ###

<pre><code>
handle_message(M::<a href="#type-wamp_message">wamp_message()</a>, Ctxt::#{}) -&gt; ok | no_return()
</code></pre>
<br />

<a name="is_feature_enabled-1"></a>

### is_feature_enabled/1 ###

<pre><code>
is_feature_enabled(F::binary()) -&gt; boolean()
</code></pre>
<br />

<a name="register-3"></a>

### register/3 ###

<pre><code>
register(ProcUri::<a href="#type-uri">uri()</a>, Options::#{}, Ctxt::<a href="bondy_context.md#type-context">bondy_context:context()</a>) -&gt; {ok, #{}} | {error, {not_authorized | procedure_already_exists, binary()}}
</code></pre>
<br />

Registers an RPC endpoint.
If the registration already exists, it fails with a
'procedure_already_exists', '{not_authorized, binary()}' error.

