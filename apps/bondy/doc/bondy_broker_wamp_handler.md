

# Module bondy_broker_wamp_handler #
* [Function Index](#index)
* [Function Details](#functions)

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#handle_call-2">handle_call/2</a></td><td>
Handles the following META API wamp calls:.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="handle_call-2"></a>

### handle_call/2 ###

<pre><code>
handle_call(Call::<a href="#type-wamp_call">wamp_call()</a>, Ctxt::<a href="bondy_context.md#type-t">bondy_context:t()</a>) -&gt; ok | no_return()
</code></pre>
<br />

Handles the following META API wamp calls:

* "wamp.subscription.list": Retrieves subscription IDs listed according to match policies.
* "wamp.subscription.lookup": Obtains the subscription (if any) managing a topic, according to some match policy.
* "wamp.subscription.match": Retrieves a list of IDs of subscriptions matching a topic URI, irrespective of match policy.
* "wamp.subscription.get": Retrieves information on a particular subscription.
* "wamp.subscription.list_subscribers": Retrieves a list of session IDs for sessions currently attached to the subscription.
* "wamp.subscription.count_subscribers": Obtains the number of sessions currently attached to the subscription.

