

# Module bondy_subscribers_sup #
* [Function Index](#index)
* [Function Details](#functions)

__Behaviours:__ [`supervisor`](supervisor.md).

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#init-1">init/1</a></td><td></td></tr><tr><td valign="top"><a href="#start_link-0">start_link/0</a></td><td></td></tr><tr><td valign="top"><a href="#start_subscriber-5">start_subscriber/5</a></td><td></td></tr><tr><td valign="top"><a href="#terminate_subscriber-1">terminate_subscriber/1</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="init-1"></a>

### init/1 ###

`init(X1) -> any()`

<a name="start_link-0"></a>

### start_link/0 ###

`start_link() -> any()`

<a name="start_subscriber-5"></a>

### start_subscriber/5 ###

<pre><code>
start_subscriber(Id::<a href="#type-id">id()</a>, RealmUri::<a href="#type-uri">uri()</a>, Opts::map(), Topic::<a href="#type-uri">uri()</a>, Fun::map() | function()) -&gt; {ok, pid()} | {error, any()}
</code></pre>
<br />

<a name="terminate_subscriber-1"></a>

### terminate_subscriber/1 ###

`terminate_subscriber(Subscriber) -> any()`

