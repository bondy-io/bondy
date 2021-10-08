

# Module bondy_event_handler_watcher_sup #
* [Function Index](#index)
* [Function Details](#functions)

__Behaviours:__ [`supervisor`](supervisor.md).

<a name="functions"></a>

## Function Details ##

<a name="init-1"></a>

### init/1 ###

`init(X1) -> any()`

<a name="start_link-0"></a>

### start_link/0 ###

`start_link() -> any()`

<a name="start_watcher-2"></a>

### start_watcher/2 ###

<pre><code>
start_watcher(Manager::module(), Cmd::{swap, OldHandler::{module(), any()}, NewHandler::{module(), any()}}) -&gt; ok | {error, any()}
</code></pre>
<br />

<a name="start_watcher-3"></a>

### start_watcher/3 ###

<pre><code>
start_watcher(Manager::module(), Handler::module(), Args::any()) -&gt; ok | {error, any()}
</code></pre>
<br />

<a name="terminate_watcher-1"></a>

### terminate_watcher/1 ###

`terminate_watcher(Watcher) -> any()`
