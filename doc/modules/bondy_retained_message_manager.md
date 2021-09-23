

# Module bondy_retained_message_manager #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)

Implements Eviction amogst other things.

__Behaviours:__ [`gen_server`](gen_server.md).

<a name="functions"></a>

## Function Details ##

<a name="code_change-3"></a>

### code_change/3 ###

`code_change(OldVsn, State, Extra) -> any()`

<a name="counters-1"></a>

### counters/1 ###

<pre><code>
counters(Realm::<a href="#type-uri">uri()</a>) -&gt; #{messages =&gt; integer(), memory =&gt; integer()}
</code></pre>
<br />

<a name="decr_counters-3"></a>

### decr_counters/3 ###

`decr_counters(Realm, N, Size) -> any()`

<a name="default_ttl-0"></a>

### default_ttl/0 ###

`default_ttl() -> any()`

Default TTL for retained messages.

<a name="get-2"></a>

### get/2 ###

<pre><code>
get(Realm::<a href="#type-uri">uri()</a>, Topic::<a href="#type-uri">uri()</a>) -&gt; <a href="bondy_retained_message.md#type-t">bondy_retained_message:t()</a> | undefined
</code></pre>
<br />

<a name="handle_call-3"></a>

### handle_call/3 ###

`handle_call(Event, From, State) -> any()`

<a name="handle_cast-2"></a>

### handle_cast/2 ###

`handle_cast(Event, State) -> any()`

<a name="handle_info-2"></a>

### handle_info/2 ###

`handle_info(Info, State) -> any()`

<a name="incr_counters-3"></a>

### incr_counters/3 ###

`incr_counters(Realm, N, Size) -> any()`

<a name="init-1"></a>

### init/1 ###

`init(X1) -> any()`

<a name="match-1"></a>

### match/1 ###

<pre><code>
match(Cont::<a href="bondy_retained_message.md#type-continuation">bondy_retained_message:continuation()</a>) -&gt; {[<a href="bondy_retained_message.md#type-t">bondy_retained_message:t()</a>] | <a href="bondy_retained_message.md#type-continuation">bondy_retained_message:continuation()</a>} | <a href="bondy_retained_message.md#type-eot">bondy_retained_message:eot()</a>
</code></pre>
<br />

<a name="match-4"></a>

### match/4 ###

<pre><code>
match(Realm::<a href="#type-uri">uri()</a>, Topic::<a href="#type-uri">uri()</a>, SessionId::<a href="#type-id">id()</a>, Strategy::binary()) -&gt; {[<a href="bondy_retained_message.md#type-t">bondy_retained_message:t()</a>], <a href="bondy_retained_message.md#type-continuation">bondy_retained_message:continuation()</a>} | <a href="bondy_retained_message.md#type-eot">bondy_retained_message:eot()</a>
</code></pre>
<br />

<a name="match-5"></a>

### match/5 ###

<pre><code>
match(Realm::<a href="#type-uri">uri()</a>, Topic::<a href="#type-uri">uri()</a>, SessionId::<a href="#type-id">id()</a>, Strategy::binary(), Opts::<a href="/Volumes/Work/Leapsight/bondy/_build/default/lib/plum_db/doc/plum_db.md#type-fold_opts">plum_db:fold_opts()</a>) -&gt; {[<a href="bondy_retained_message.md#type-t">bondy_retained_message:t()</a>], <a href="bondy_retained_message.md#type-continuation">bondy_retained_message:continuation()</a>} | <a href="bondy_retained_message.md#type-eot">bondy_retained_message:eot()</a>
</code></pre>
<br />

<a name="max_memory-0"></a>

### max_memory/0 ###

`max_memory() -> any()`

Maximum space in memory used by retained messages.
Once the max has been reached no more events will be stored.
A value of 0 means no limit is enforced.

<a name="max_message_size-0"></a>

### max_message_size/0 ###

`max_message_size() -> any()`

The max size for an event message.
All events whose size exceeds this value will not be retained.

<a name="max_messages-0"></a>

### max_messages/0 ###

`max_messages() -> any()`

Maximum number of messages that can be store in a Bondy node.
Once the max has been reached no more events will be stored.
A value of 0 means no limit is enforced.

<a name="put-4"></a>

### put/4 ###

<pre><code>
put(Realm::<a href="#type-uri">uri()</a>, Topic::<a href="#type-uri">uri()</a>, Event::<a href="#type-wamp_event">wamp_event()</a>, MatchOpts::<a href="bondy_retained_message.md#type-match_opts">bondy_retained_message:match_opts()</a>) -&gt; ok
</code></pre>
<br />

<a name="put-5"></a>

### put/5 ###

<pre><code>
put(Realm::<a href="#type-uri">uri()</a>, Topic::<a href="#type-uri">uri()</a>, Event::<a href="#type-wamp_event">wamp_event()</a>, MatchOpts::<a href="bondy_retained_message.md#type-match_opts">bondy_retained_message:match_opts()</a>, TTL::non_neg_integer() | undefined) -&gt; ok
</code></pre>
<br />

<a name="start_link-0"></a>

### start_link/0 ###

`start_link() -> any()`

<a name="take-2"></a>

### take/2 ###

<pre><code>
take(Realm::<a href="#type-uri">uri()</a>, Topic::<a href="#type-uri">uri()</a>) -&gt; <a href="bondy_retained_message.md#type-t">bondy_retained_message:t()</a> | undefined
</code></pre>
<br />

<a name="terminate-2"></a>

### terminate/2 ###

`terminate(Reason, State) -> any()`

