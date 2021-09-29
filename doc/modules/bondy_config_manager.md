

# Module bondy_config_manager #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)

A server that takes care of initialising the Bondy configuration
with a set of statically define (and thus private) configuration options.

__Behaviours:__ [`gen_server`](gen_server.md).

<a name="description"></a>

## Description ##
All the logic is handled by the [`bondy_config`](bondy_config.md) helper module.
<a name="functions"></a>

## Function Details ##

<a name="code_change-3"></a>

### code_change/3 ###

`code_change(OldVsn, State, Extra) -> any()`

<a name="handle_call-3"></a>

### handle_call/3 ###

`handle_call(Event, From, State) -> any()`

<a name="handle_cast-2"></a>

### handle_cast/2 ###

`handle_cast(Event, State) -> any()`

<a name="handle_info-2"></a>

### handle_info/2 ###

`handle_info(Info, State) -> any()`

<a name="init-1"></a>

### init/1 ###

`init(X1) -> any()`

<a name="start_link-0"></a>

### start_link/0 ###

`start_link() -> any()`

Starts the config manager process

<a name="terminate-2"></a>

### terminate/2 ###

`terminate(Reason, State) -> any()`

