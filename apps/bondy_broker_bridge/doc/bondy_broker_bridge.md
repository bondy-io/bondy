

# Module bondy_broker_bridge #
* [Description](#description)

This module defines the behaviour for providing event bridging
functionality, allowing
a supervised process (implemented via bondy_subscriber) to consume WAMP
events based on a normal subscription to publish (or
produce) those events to an external system, e.g.

__This module defines the `bondy_broker_bridge` behaviour.__<br /> Required callback functions: `init/1`, `validate_action/1`, `apply_action/1`, `terminate/2`.

<a name="description"></a>

## Description ##

another message broker, by
previously applying a transformation specification based on a templating
language..

Each broker bridge is implemented as a callback module exporting a
predefined set of callback functions.

