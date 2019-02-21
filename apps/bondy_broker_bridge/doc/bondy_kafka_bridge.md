

# Module bondy_kafka_bridge #
* [Function Index](#index)
* [Function Details](#functions)

__Behaviours:__ [`bondy_broker_bridge`](bondy_broker_bridge.md).

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#apply_action-1">apply_action/1</a></td><td>Evaluates the action specification <code>Action</code> against the context
<code>Ctxt</code> using <code>mops</code> and produces to Kafka.</td></tr><tr><td valign="top"><a href="#init-1">init/1</a></td><td>Initialises the Kafka clients provided by the configuration.</td></tr><tr><td valign="top"><a href="#terminate-2">terminate/2</a></td><td></td></tr><tr><td valign="top"><a href="#validate_action-1">validate_action/1</a></td><td>Validates the action specification.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="apply_action-1"></a>

### apply_action/1 ###

`apply_action(Action) -> any()`

Evaluates the action specification `Action` against the context
`Ctxt` using `mops` and produces to Kafka.

<a name="init-1"></a>

### init/1 ###

`init(Config) -> any()`

Initialises the Kafka clients provided by the configuration.

<a name="terminate-2"></a>

### terminate/2 ###

`terminate(Reason, State) -> any()`

<a name="validate_action-1"></a>

### validate_action/1 ###

`validate_action(Action0) -> any()`

Validates the action specification.
An action spec is a map containing the following keys:

* `type :: binary()` - either `<<"produce">>` or `<<"produce_sync">>`. Optional, the default value is `<<"produce">>`.
* `topic :: binary()` - the Kafka topic we should produce to.
* `key :: binary()` - the kafka message's key
* `value :: any()` - the kafka message's value
* `options :: map()` - a map containing the following keys

```
     erlang
  #{
      <<"type">> <<"produce">>,
      <<"topic": <<"com.magenta.wamp_events",
      <<"key": "\"{{event.topic}}/{{event.publication_id}}\"",
      <<"value": "{{event}}",
      <<"options" : {
          <<"client_id": "default",
          <<"acknowledge": true,
          <<"required_acks": "all",
          <<"partition": null,
          <<"partitioner": {
              "algorithm": "fnv32a",
              "value": "\"{{event.topic}}/{{event.publication_id}}\""
          },
          <<"encoding">>: <<"json">>
      }
  }
```

