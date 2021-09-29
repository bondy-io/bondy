

# Module bondy_rpc_promise #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##


<a name="dequeue_fun()"></a>


### dequeue_fun() ###


<pre><code>
dequeue_fun() = fun((empty | {ok, <a href="#type-t">t()</a>}) -&gt; any())
</code></pre>


<a name="match_opts()"></a>


### match_opts() ###


<pre><code>
match_opts() = #{id =&gt; <a href="#type-id">id()</a>, caller =&gt; <a href="#type-peer_id">peer_id()</a>, callee =&gt; <a href="#type-peer_id">peer_id()</a>}
</code></pre>


<a name="t()"></a>


### t() ###


__abstract datatype__: `t()`


<a name="functions"></a>

## Function Details ##

<a name="call_id-1"></a>

### call_id/1 ###

`call_id(Bondy_rpc_promise) -> any()`

<a name="callee-1"></a>

### callee/1 ###

<pre><code>
callee(Bondy_rpc_promise::<a href="#type-t">t()</a>) -&gt; <a href="#type-peer_id">peer_id()</a>
</code></pre>
<br />

<a name="caller-1"></a>

### caller/1 ###

<pre><code>
caller(Bondy_rpc_promise::<a href="#type-t">t()</a>) -&gt; <a href="#type-peer_id">peer_id()</a>
</code></pre>
<br />

<a name="dequeue_call-2"></a>

### dequeue_call/2 ###

<pre><code>
dequeue_call(CallId::<a href="#type-id">id()</a>, Caller::<a href="#type-peer_id">peer_id()</a>) -&gt; empty | {ok, <a href="#type-t">t()</a>}
</code></pre>
<br />

Dequeues the promise that matches the Id for the IdType in Ctxt.

<a name="dequeue_call-3"></a>

### dequeue_call/3 ###

<pre><code>
dequeue_call(CallId::<a href="#type-id">id()</a>, Caller::<a href="#type-peer_id">peer_id()</a>, Fun::<a href="#type-dequeue_fun">dequeue_fun()</a>) -&gt; any()
</code></pre>
<br />

Dequeues the promise that matches the Id for the IdType in Ctxt.

<a name="dequeue_invocation-2"></a>

### dequeue_invocation/2 ###

<pre><code>
dequeue_invocation(CallId::<a href="#type-id">id()</a>, Callee::<a href="#type-peer_id">peer_id()</a>) -&gt; empty | {ok, <a href="#type-t">t()</a>}
</code></pre>
<br />

<a name="dequeue_invocation-3"></a>

### dequeue_invocation/3 ###

<pre><code>
dequeue_invocation(CallId::<a href="#type-id">id()</a>, Callee::<a href="#type-peer_id">peer_id()</a>, Fun::<a href="#type-dequeue_fun">dequeue_fun()</a>) -&gt; any()
</code></pre>
<br />

<a name="enqueue-3"></a>

### enqueue/3 ###

`enqueue(RealmUri, Bondy_rpc_promise, Timeout) -> any()`

<a name="flush-1"></a>

### flush/1 ###

<pre><code>
flush(Caller::<a href="#type-local_peer_id">local_peer_id()</a>) -&gt; ok
</code></pre>
<br />

Removes all pending promises from the queue for the Caller's SessionId

<a name="invocation_id-1"></a>

### invocation_id/1 ###

`invocation_id(Bondy_rpc_promise) -> any()`

<a name="new-3"></a>

### new/3 ###

<pre><code>
new(InvocationId::<a href="#type-id">id()</a>, Callee::<a href="#type-remote_peer_id">remote_peer_id()</a>, Ctxt::<a href="bondy_context.md#type-t">bondy_context:t()</a>) -&gt; <a href="#type-t">t()</a>
</code></pre>
<br />

Creates a new promise for a remote invocation

<a name="new-5"></a>

### new/5 ###

<pre><code>
new(InvocationId::<a href="#type-id">id()</a>, CallId::<a href="#type-id">id()</a>, ProcUri::<a href="#type-uri">uri()</a>, Callee::<a href="#type-peer_id">peer_id()</a>, Ctxt::<a href="bondy_context.md#type-t">bondy_context:t()</a>) -&gt; <a href="#type-t">t()</a>
</code></pre>
<br />

Creates a new promise for a local call - invocation

<a name="peek_call-2"></a>

### peek_call/2 ###

<pre><code>
peek_call(CallId::<a href="#type-id">id()</a>, Caller::<a href="#type-peer_id">peer_id()</a>) -&gt; empty | {ok, <a href="#type-t">t()</a>}
</code></pre>
<br />

Reads the promise that matches the Id for the IdType in Ctxt.

<a name="peek_invocation-2"></a>

### peek_invocation/2 ###

<pre><code>
peek_invocation(InvocationId::<a href="#type-id">id()</a>, Callee::<a href="#type-peer_id">peer_id()</a>) -&gt; empty | {ok, <a href="#type-t">t()</a>}
</code></pre>
<br />

Reads the promise that matches the Id for the IdType in Ctxt.

<a name="procedure_uri-1"></a>

### procedure_uri/1 ###

`procedure_uri(Bondy_rpc_promise) -> any()`

<a name="queue_size-0"></a>

### queue_size/0 ###

`queue_size() -> any()`

<a name="timestamp-1"></a>

### timestamp/1 ###

`timestamp(Bondy_rpc_promise) -> any()`

