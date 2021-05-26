

# Module bondy_broker #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)

This module implements the capabilities of a Broker.

<a name="description"></a>

## Description ##
It is used by
[`bondy_router`](bondy_router.md).<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#close_context-1">close_context/1</a></td><td></td></tr><tr><td valign="top"><a href="#features-0">features/0</a></td><td></td></tr><tr><td valign="top"><a href="#handle_message-2">handle_message/2</a></td><td>
Handles a wamp message.</td></tr><tr><td valign="top"><a href="#handle_peer_message-4">handle_peer_message/4</a></td><td>Handles a message sent by a peer node through the
bondy_peer_wamp_forwarder.</td></tr><tr><td valign="top"><a href="#is_feature_enabled-1">is_feature_enabled/1</a></td><td>Returns true if feature F is enabled by the broker.</td></tr><tr><td valign="top"><a href="#publish-5">publish/5</a></td><td></td></tr><tr><td valign="top"><a href="#publish-6">publish/6</a></td><td></td></tr><tr><td valign="top"><a href="#subscribe-3">subscribe/3</a></td><td></td></tr><tr><td valign="top"><a href="#subscribe-4">subscribe/4</a></td><td>For internal use.</td></tr><tr><td valign="top"><a href="#unsubscribe-1">unsubscribe/1</a></td><td>For internal Bondy use.</td></tr><tr><td valign="top"><a href="#unsubscribe-2">unsubscribe/2</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="close_context-1"></a>

### close_context/1 ###

<pre><code>
close_context(Ctxt::<a href="bondy_context.md#type-t">bondy_context:t()</a>) -&gt; <a href="bondy_context.md#type-t">bondy_context:t()</a>
</code></pre>
<br />

<a name="features-0"></a>

### features/0 ###

<pre><code>
features() -&gt; map()
</code></pre>
<br />

<a name="handle_message-2"></a>

### handle_message/2 ###

<pre><code>
handle_message(M::<a href="#type-wamp_message">wamp_message()</a>, Ctxt::<a href="bondy_context.md#type-t">bondy_context:t()</a>) -&gt; ok | no_return()
</code></pre>
<br />

Handles a wamp message. This function is called by the bondy_router module.
The message might be handled synchronously (it is performed by the calling
process i.e. the transport handler) or asynchronously (by sending the
message to the broker worker pool).

<a name="handle_peer_message-4"></a>

### handle_peer_message/4 ###

<pre><code>
handle_peer_message(Publish::<a href="#type-wamp_publish">wamp_publish()</a>, To::<a href="#type-remote_peer_id">remote_peer_id()</a>, From::<a href="#type-remote_peer_id">remote_peer_id()</a>, Opts::map()) -&gt; ok | no_return()
</code></pre>
<br />

Handles a message sent by a peer node through the
bondy_peer_wamp_forwarder.

<a name="is_feature_enabled-1"></a>

### is_feature_enabled/1 ###

<pre><code>
is_feature_enabled(F::binary()) -&gt; boolean()
</code></pre>
<br />

Returns true if feature F is enabled by the broker.

<a name="publish-5"></a>

### publish/5 ###

<pre><code>
publish(Opts::map(), TopicUri::{Realm::<a href="#type-uri">uri()</a>, TopicUri::<a href="#type-uri">uri()</a>} | <a href="#type-uri">uri()</a>, Args::[], ArgsKw::map(), Ctxt::<a href="bondy_context.md#type-t">bondy_context:t()</a>) -&gt; {ok, <a href="#type-id">id()</a>} | {error, any()}
</code></pre>
<br />

<a name="publish-6"></a>

### publish/6 ###

<pre><code>
publish(ReqId::<a href="#type-id">id()</a>, Opts::map(), TopicUri::{Realm::<a href="#type-uri">uri()</a>, TopicUri::<a href="#type-uri">uri()</a>} | <a href="#type-uri">uri()</a>, Args::list(), ArgsKw::map(), RealmUri::<a href="bondy_context.md#type-t">bondy_context:t()</a> | <a href="#type-uri">uri()</a>) -&gt; {ok, <a href="#type-id">id()</a>} | {error, any()}
</code></pre>
<br />

<a name="subscribe-3"></a>

### subscribe/3 ###

`subscribe(RealmUri, Opts, Topic) -> any()`

<a name="subscribe-4"></a>

### subscribe/4 ###

<pre><code>
subscribe(RealmUri::<a href="#type-uri">uri()</a>, Opts::map(), Topic::<a href="#type-uri">uri()</a>, Fun::pid() | function()) -&gt; {ok, <a href="#type-id">id()</a>} | {ok, <a href="#type-id">id()</a>, pid()} | {error, already_exists | any()}
</code></pre>
<br />

For internal use.
If the last argument is a function, spawns a supervised instance of a
bondy_subscriber by calling bondy_subscribers_sup:start_subscriber/4.
The new process, calls subscribe/4 passing its pid as last argument.

If the last argument is a pid, it registers the pid as a subscriber
(a.k.a a local subscription)

<a name="unsubscribe-1"></a>

### unsubscribe/1 ###

<pre><code>
unsubscribe(Subscriber::pid()) -&gt; ok | {error, not_found}
</code></pre>
<br />

For internal Bondy use.
Terminates the process identified by Pid by
bondy_subscribers_sup:terminate_subscriber/1

<a name="unsubscribe-2"></a>

### unsubscribe/2 ###

<pre><code>
unsubscribe(SubsId::<a href="#type-id">id()</a>, RealmUri::<a href="bondy_context.md#type-t">bondy_context:t()</a> | <a href="#type-uri">uri()</a>) -&gt; ok | {error, not_found}
</code></pre>
<br />

