

# Module bondy_kafka_bridge #
* [Function Index](#index)
* [Function Details](#functions)

__Behaviours:__ [`bondy_broker_bridge`](bondy_broker_bridge.md).

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

* `type :: binary()` - `<<"produce_sync">>`. Optional, the default value is `<<"produce_sync">>`.
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

