

# Module bondy_broker_bridge_manager #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

This module provides event bridging functionality, allowing
a supervised process (implemented via bondy_subscriber) to subscribe to WAMP
events and process and/or forward those events to an external system,
e.g.

__Behaviours:__ [`gen_server`](gen_server.md).

<a name="description"></a>

## Description ##

publish to another message broker.

A subscription can be created at runtime using the `subscribe/5`,
or at system boot time by setting the application's `config_file`
environment variable which should have the filename of a valid
Broker Bridge Specification File.

Each broker bridge is implemented as a module implementing the
bondy_broker_bridge behaviour.

## Action Specification Map.

## `mops` Evaluation Context

The mops context is map containing the following:

```
     erlang
  #{
      <<"broker">> => #{
          <<"node">> => binary()
          <<"agent">> => binary()
      },
      <<"event">> => #{
          <<"realm">> => uri(),
          <<"topic">> => uri(),
          <<"subscription_id">> => integer(),
          <<"publication_id">> => integer(),
          <<"details">> => map(), % WAMP EVENT.details
          <<"arguments">> => list(),
          <<"arguments_kw">> => map(),
          <<"ingestion_timestamp">> => integer()
      }
  }.
```

## Broker Bridge Specification File.

Example:

```
     json
  {
      "id":"com.leapsight.test",
      "meta":{},
      "subscriptions" : [
          {
              "bridge": "bondy_kafka_bridge",
              "match": {
                  "realm": "com.leapsight.test",
                  "topic" : "com.leapsight.example_event",
                  "options": {"match": "exact"}
              },
              "action": {
                  "type": "produce_sync",
                  "topic": "{{kafka.topics.wamp_events}}",
                  "key": "\"{{event.topic}}/{{event.publication_id}}\"",
                  "value": "{{event}}",
                  "options" : {
                      "client_id": "default",
                      "acknowledge": true,
                      "required_acks": "all",
                      "partition": null,
                      "partitioner": {
                          "algorithm": "fnv32a",
                          "value": "\"{{event.topic}}/{{event.publication_id}}\""
                      },
                      "encoding": "json"
                  }
              }
          }
      ]
  }
```


<a name="types"></a>

## Data Types ##


<a name="bridge()"></a>


### bridge() ###


<pre><code>
bridge() = map()
</code></pre>


<a name="subscription_detail()"></a>


### subscription_detail() ###


<pre><code>
subscription_detail() = map()
</code></pre>


<a name="functions"></a>

## Function Details ##

<a name="bridge-1"></a>

### bridge/1 ###

<pre><code>
bridge(Mod::module()) -&gt; [<a href="#type-bridge">bridge()</a>]
</code></pre>
<br />

Returns the bridge configuration identified by its module name.

<a name="bridges-0"></a>

### bridges/0 ###

<pre><code>
bridges() -&gt; [<a href="#type-bridge">bridge()</a>]
</code></pre>
<br />

Lists all the configured bridge configurations.

<a name="code_change-3"></a>

### code_change/3 ###

`code_change(OldVsn, State, Extra) -> any()`

<a name="handle_call-3"></a>

### handle_call/3 ###

`handle_call(Event, From, State) -> any()`

<a name="handle_cast-2"></a>

### handle_cast/2 ###

`handle_cast(Event, State) -> any()`

<a name="handle_continue-2"></a>

### handle_continue/2 ###

`handle_continue(X1, State0) -> any()`

<a name="handle_info-2"></a>

### handle_info/2 ###

`handle_info(Info, State) -> any()`

<a name="init-1"></a>

### init/1 ###

`init(X1) -> any()`

<a name="load-1"></a>

### load/1 ###

<pre><code>
load(Term::<a href="file.md#type-filename">file:filename()</a> | map()) -&gt; ok | {error, invalid_specification_format | any()}
</code></pre>
<br />

Parses the provided Broker Bridge Specification and creates all the
provided subscriptions.

<a name="start_link-0"></a>

### start_link/0 ###

`start_link() -> any()`

Internal function called by bondy_broker_bridge_sup.

<a name="subscribe-5"></a>

### subscribe/5 ###

<pre><code>
subscribe(RealmUri::<a href="#type-uri">uri()</a>, Opts::map(), Topic::<a href="#type-uri">uri()</a>, Bridge::module(), Spec::map()) -&gt; {ok, <a href="#type-id">id()</a>} | {error, already_exists}
</code></pre>
<br />

Creates a subscription using bondy_broker.
This results in a new supervised bondy_subscriber processed that subcribes
to {Realm, Topic} and forwards any received publication (event) to the
bridge identified by `Bridge`.

Returns the tuple {ok, Pid} where Pid is the pid() of the supervised process
or the tuple {error, Reason}.

<a name="subscriptions-1"></a>

### subscriptions/1 ###

<pre><code>
subscriptions(BridgeId::<a href="#type-bridge">bridge()</a>) -&gt; [<a href="#type-subscription_detail">subscription_detail()</a>]
</code></pre>
<br />

<a name="terminate-2"></a>

### terminate/2 ###

`terminate(Reason, State) -> any()`

<a name="unsubscribe-1"></a>

### unsubscribe/1 ###

<pre><code>
unsubscribe(Id::<a href="#type-id">id()</a>) -&gt; ok | {error, not_found}
</code></pre>
<br />

<a name="validate_spec-1"></a>

### validate_spec/1 ###

<pre><code>
validate_spec(Map::map()) -&gt; {ok, map()} | {error, any()}
</code></pre>
<br />

