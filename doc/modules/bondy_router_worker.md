

# Module bondy_router_worker #
* [Function Index](#index)
* [Function Details](#functions)

__Behaviours:__ [`gen_server`](gen_server.md).

<a name="functions"></a>

## Function Details ##

<a name="cast-1"></a>

### cast/1 ###

`cast(Fun) -> any()`

<a name="code_change-3"></a>

### code_change/3 ###

`code_change(OldVsn, State, Extra) -> any()`

<a name="handle_call-3"></a>

### handle_call/3 ###

`handle_call(Event, From, State) -> any()`

<a name="handle_cast-2"></a>

### handle_cast/2 ###

`handle_cast(Fun, State) -> any()`

<a name="handle_info-2"></a>

### handle_info/2 ###

`handle_info(Info, State) -> any()`

<a name="init-1"></a>

### init/1 ###

`init(X1) -> any()`

<a name="start_pool-0"></a>

### start_pool/0 ###

<pre><code>
start_pool() -&gt; ok
</code></pre>
<br />

Starts a sidejob pool of workers according to the configuration
for the entry named 'router_pool'.

<a name="terminate-2"></a>

### terminate/2 ###

`terminate(Reason, State) -> any()`

