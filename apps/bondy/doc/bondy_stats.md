

# Module bondy_stats #
* [Function Index](#index)
* [Function Details](#functions)

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#init-0">init/0</a></td><td></td></tr><tr><td valign="top"><a href="#otp_release-0">otp_release/0</a></td><td></td></tr><tr><td valign="top"><a href="#socket_closed-3">socket_closed/3</a></td><td></td></tr><tr><td valign="top"><a href="#socket_error-2">socket_error/2</a></td><td></td></tr><tr><td valign="top"><a href="#socket_open-2">socket_open/2</a></td><td></td></tr><tr><td valign="top"><a href="#sys_driver_version-0">sys_driver_version/0</a></td><td></td></tr><tr><td valign="top"><a href="#sys_monitor_count-0">sys_monitor_count/0</a></td><td>
Count up all monitors, unfortunately has to obtain process_info
from all processes to work it out.</td></tr><tr><td valign="top"><a href="#system_architecture-0">system_architecture/0</a></td><td></td></tr><tr><td valign="top"><a href="#system_version-0">system_version/0</a></td><td></td></tr><tr><td valign="top"><a href="#update-1">update/1</a></td><td></td></tr><tr><td valign="top"><a href="#update-2">update/2</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="init-0"></a>

### init/0 ###

<pre><code>
init() -&gt; ok
</code></pre>
<br />

<a name="otp_release-0"></a>

### otp_release/0 ###

`otp_release() -> any()`

<a name="socket_closed-3"></a>

### socket_closed/3 ###

<pre><code>
socket_closed(Protocol::atom(), Transport::atom(), Duration::integer()) -&gt; ok
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

<a name="sys_driver_version-0"></a>

### sys_driver_version/0 ###

`sys_driver_version() -> any()`

<a name="sys_monitor_count-0"></a>

### sys_monitor_count/0 ###

`sys_monitor_count() -> any()`

Count up all monitors, unfortunately has to obtain process_info
from all processes to work it out.

<a name="system_architecture-0"></a>

### system_architecture/0 ###

`system_architecture() -> any()`

<a name="system_version-0"></a>

### system_version/0 ###

`system_version() -> any()`

<a name="update-1"></a>

### update/1 ###

<pre><code>
update(Event::tuple()) -&gt; ok
</code></pre>
<br />

<a name="update-2"></a>

### update/2 ###

<pre><code>
update(M::<a href="wamp_message.md#type-message">wamp_message:message()</a>, Ctxt::<a href="bondy_context.md#type-context">bondy_context:context()</a>) -&gt; ok
</code></pre>
<br />

