

# Module bondy_subscriber #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)

This module implements a supervised process (gen_server) that acts as a
local (internal) WAMP subscriber that when received an EVENT applies the
user provided function.

__Behaviours:__ [`gen_server`](gen_server.md).

<a name="description"></a>

## Description ##
It is used by bondy_broker:subscribe/4 and bondy_broker:unsubscribe/1.
<a name="functions"></a>

## Function Details ##

<a name="code_change-3"></a>

### code_change/3 ###

`code_change(OldVsn, State, Extra) -> any()`

<a name="handle_call-3"></a>

### handle_call/3 ###

`handle_call(Event, From, State) -> any()`

<a name="handle_cast-2"></a>

### handle_cast/2 ###

`handle_cast(Event, State) -> any()`

<a name="handle_event-2"></a>

### handle_event/2 ###

`handle_event(Subscriber, Event) -> any()`

<a name="handle_event_sync-2"></a>

### handle_event_sync/2 ###

`handle_event_sync(Subscriber, Event) -> any()`

<a name="handle_info-2"></a>

### handle_info/2 ###

`handle_info(Event, State) -> any()`

<a name="info-1"></a>

### info/1 ###

`info(Subscriber) -> any()`

<a name="init-1"></a>

### init/1 ###

`init(X1) -> any()`

<a name="pid-1"></a>

### pid/1 ###

`pid(Id) -> any()`

<a name="start_link-5"></a>

### start_link/5 ###

<pre><code>
start_link(Id::<a href="#type-id">id()</a>, RealmUri::<a href="#type-uri">uri()</a>, Opts::map(), Topic::<a href="#type-uri">uri()</a>, Fun::function()) -&gt; {ok, pid()} | {error, any()}
</code></pre>
<br />

<a name="terminate-2"></a>

### terminate/2 ###

`terminate(Reason, State) -> any()`

