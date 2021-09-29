

# Module bondy_config #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)

An implementation of app_config behaviour.

__Behaviours:__ [`app_config`](app_config.md).

<a name="functions"></a>

## Function Details ##

<a name="get-1"></a>

### get/1 ###

<pre><code>
get(Key::list() | atom() | tuple()) -&gt; term()
</code></pre>
<br />

<a name="get-2"></a>

### get/2 ###

<pre><code>
get(Key::list() | atom() | tuple(), Default::term()) -&gt; term()
</code></pre>
<br />

<a name="init-0"></a>

### init/0 ###

`init() -> any()`

<a name="set-2"></a>

### set/2 ###

<pre><code>
set(Key::<a href="key_value.md#type-key">key_value:key()</a> | tuple(), Value::term()) -&gt; ok
</code></pre>
<br />

