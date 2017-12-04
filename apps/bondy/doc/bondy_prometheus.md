

# Module bondy_prometheus #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)

We follow https://prometheus.io/docs/practices/naming/.

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#days_duration_buckets-0">days_duration_buckets/0</a></td><td></td></tr><tr><td valign="top"><a href="#hours_duration_buckets-0">hours_duration_buckets/0</a></td><td></td></tr><tr><td valign="top"><a href="#init-0">init/0</a></td><td></td></tr><tr><td valign="top"><a href="#microseconds_duration_buckets-0">microseconds_duration_buckets/0</a></td><td></td></tr><tr><td valign="top"><a href="#milliseconds_duration_buckets-0">milliseconds_duration_buckets/0</a></td><td></td></tr><tr><td valign="top"><a href="#minutes_duration_buckets-0">minutes_duration_buckets/0</a></td><td></td></tr><tr><td valign="top"><a href="#report-0">report/0</a></td><td></td></tr><tr><td valign="top"><a href="#seconds_duration_buckets-0">seconds_duration_buckets/0</a></td><td></td></tr><tr><td valign="top"><a href="#socket_closed-3">socket_closed/3</a></td><td></td></tr><tr><td valign="top"><a href="#socket_error-2">socket_error/2</a></td><td></td></tr><tr><td valign="top"><a href="#socket_open-2">socket_open/2</a></td><td></td></tr><tr><td valign="top"><a href="#wamp_message-2">wamp_message/2</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="days_duration_buckets-0"></a>

### days_duration_buckets/0 ###

`days_duration_buckets() -> any()`

<a name="hours_duration_buckets-0"></a>

### hours_duration_buckets/0 ###

`hours_duration_buckets() -> any()`

<a name="init-0"></a>

### init/0 ###

`init() -> any()`

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

<a name="socket_closed-3"></a>

### socket_closed/3 ###

<pre><code>
socket_closed(Protocol::atom(), Transport::atom(), Seconds::integer()) -&gt; ok
</code></pre>
<br />

<a name="socket_error-2"></a>

### socket_error/2 ###

<pre><code>
socket_error(Protocol::atom(), Transport::atom()) -&gt; ok
</code></pre>
<br />

<a name="socket_open-2"></a>

### socket_open/2 ###

<pre><code>
socket_open(Protocol::atom(), Transport::atom()) -&gt; ok
</code></pre>
<br />

<a name="wamp_message-2"></a>

### wamp_message/2 ###

<pre><code>
wamp_message(Abort::<a href="wamp_message.md#type-message">wamp_message:message()</a>, Ctxt::<a href="bondy_context.md#type-context">bondy_context:context()</a>) -&gt; ok
</code></pre>
<br />

