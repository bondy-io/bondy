

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


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#close_context-1">close_context/1</a></td><td></td></tr><tr><td valign="top"><a href="#features-0">features/0</a></td><td></td></tr><tr><td valign="top"><a href="#handle_call-2">handle_call/2</a></td><td>
Handles the following META API wamp calls:.</td></tr><tr><td valign="top"><a href="#handle_message-2">handle_message/2</a></td><td>
Handles a wamp message.</td></tr><tr><td valign="top"><a href="#is_feature_enabled-1">is_feature_enabled/1</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="close_context-1"></a>

### close_context/1 ###

<pre><code>
close_context(Ctxt::<a href="bondy_context.md#type-context">bondy_context:context()</a>) -&gt; <a href="bondy_context.md#type-context">bondy_context:context()</a>
</code></pre>
<br />

<a name="features-0"></a>

### features/0 ###

<pre><code>
features() -&gt; #{}
</code></pre>
<br />

<a name="handle_call-2"></a>

### handle_call/2 ###

<pre><code>
handle_call(Call::<a href="#type-wamp_call">wamp_call()</a>, Ctxt::<a href="bondy_context.md#type-context">bondy_context:context()</a>) -&gt; ok | no_return()
</code></pre>
<br />

Handles the following META API wamp calls:

* "wamp.subscription.list": Retrieves subscription IDs listed according to match policies.
* "wamp.subscription.lookup": Obtains the subscription (if any) managing a topic, according to some match policy.
* "wamp.subscription.match": Retrieves a list of IDs of subscriptions matching a topic URI, irrespective of match policy.
* "wamp.subscription.get": Retrieves information on a particular subscription.
* "wamp.subscription.list_subscribers": Retrieves a list of session IDs for sessions currently attached to the subscription.
* "wamp.subscription.count_subscribers": Obtains the number of sessions currently attached to the subscription.

<a name="handle_message-2"></a>

### handle_message/2 ###

<pre><code>
handle_message(M::<a href="#type-wamp_message">wamp_message()</a>, Ctxt::<a href="bondy_context.md#type-context">bondy_context:context()</a>) -&gt; ok
</code></pre>
<br />

Handles a wamp message. This function is called by the bondy_router module.
The message might be handled synchronously (it is performed by the calling
process i.e. the transport handler) or asynchronously (by sending the
message to the broker worker pool).

<a name="is_feature_enabled-1"></a>

### is_feature_enabled/1 ###

<pre><code>
is_feature_enabled(F::binary()) -&gt; boolean()
</code></pre>
<br />

