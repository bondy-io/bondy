

# Module bondy_peer_discovery_dns_agent #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)

An implementation of the [`bondy_peer_discovery_agent`](bondy_peer_discovery_agent.md) behaviour
that uses DNS for service discovery.

__Behaviours:__ [`bondy_peer_discovery_agent`](bondy_peer_discovery_agent.md).

<a name="description"></a>

## Description ##

It is enabled by using the following options in the bondy.conf file

```
     shell
  cluster.peer_discovery_agent.type = bondy_peer_discovery_dns_agent
  cluster.peer_discovery_agent.config.service_name = my-service-name
```

Where service_name is the service to be used by the DNS lookup.
<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#init-1">init/1</a></td><td></td></tr><tr><td valign="top"><a href="#lookup-2">lookup/2</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="init-1"></a>

### init/1 ###

<pre><code>
init(Opts::map()) -&gt; {ok, State::any()} | {error, Reason::any()}
</code></pre>
<br />

<a name="lookup-2"></a>

### lookup/2 ###

<pre><code>
lookup(State::any(), Timeout::timeout()) -&gt; {ok, [<a href="bondy_peer_service.md#type-peer">bondy_peer_service:peer()</a>], NewState::any()} | {error, Reason::any(), NewState::any()}
</code></pre>
<br />

