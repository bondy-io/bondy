

# Module bondy_prometheus_collector #
* [Function Index](#index)
* [Function Details](#functions)

__Behaviours:__ [`prometheus_collector`](prometheus_collector.md).

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#collect_metrics-2">collect_metrics/2</a></td><td></td></tr><tr><td valign="top"><a href="#collect_mf-2">collect_mf/2</a></td><td></td></tr><tr><td valign="top"><a href="#deregister_cleanup-1">deregister_cleanup/1</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="collect_metrics-2"></a>

### collect_metrics/2 ###

`collect_metrics(Key, X2) -> any()`

<a name="collect_mf-2"></a>

### collect_mf/2 ###

<pre><code>
collect_mf(Registry::<a href="prometheus_registry.md#type-registry">prometheus_registry:registry()</a>, CB::<a href="prometheus_collector.md#type-callback">prometheus_collector:callback()</a>) -&gt; ok
</code></pre>
<br />

<a name="deregister_cleanup-1"></a>

### deregister_cleanup/1 ###

`deregister_cleanup(X1) -> any()`

