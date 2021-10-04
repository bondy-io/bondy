

# Module bondy_prometheus #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)

We follow https://prometheus.io/docs/practices/naming/.

__Behaviours:__ [`gen_event`](gen_event.md), [`prometheus_collector`](prometheus_collector.md).

<a name="functions"></a>

## Function Details ##

<a name="code_change-3"></a>

### code_change/3 ###

`code_change(OldVsn, State, Extra) -> any()`

<a name="collect_mf-2"></a>

### collect_mf/2 ###

<pre><code>
collect_mf(Registry::<a href="prometheus_registry.md#type-registry">prometheus_registry:registry()</a>, Callback::<a href="prometheus_collector.md#type-callback">prometheus_collector:callback()</a>) -&gt; ok
</code></pre>
<br />

<a name="days_duration_buckets-0"></a>

### days_duration_buckets/0 ###

`days_duration_buckets() -> any()`

<a name="deregister_cleanup-1"></a>

### deregister_cleanup/1 ###

`deregister_cleanup(X1) -> any()`

<a name="handle_call-2"></a>

### handle_call/2 ###

`handle_call(Event, State) -> any()`

<a name="handle_event-2"></a>

### handle_event/2 ###

`handle_event(Event, State) -> any()`

<a name="handle_info-2"></a>

### handle_info/2 ###

`handle_info(Info, State) -> any()`

<a name="hours_duration_buckets-0"></a>

### hours_duration_buckets/0 ###

`hours_duration_buckets() -> any()`

<a name="init-1"></a>

### init/1 ###

`init(X1) -> any()`

<a name="microseconds_duration_buckets-0"></a>

### microseconds_duration_buckets/0 ###

`microseconds_duration_buckets() -> any()`

<a name="milliseconds_duration_buckets-0"></a>

### milliseconds_duration_buckets/0 ###

`milliseconds_duration_buckets() -> any()`

<a name="minutes_duration_buckets-0"></a>

### minutes_duration_buckets/0 ###

`minutes_duration_buckets() -> any()`

<a name="report-0"></a>

### report/0 ###

`report() -> any()`

<a name="seconds_duration_buckets-0"></a>

### seconds_duration_buckets/0 ###

`seconds_duration_buckets() -> any()`

<a name="terminate-2"></a>

### terminate/2 ###

`terminate(Reason, State) -> any()`

