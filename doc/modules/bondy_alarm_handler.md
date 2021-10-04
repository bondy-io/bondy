

# Module bondy_alarm_handler #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)

This module implements a replacement for OTP's default alarm_handler.

__Behaviours:__ [`gen_event`](gen_event.md).

<a name="functions"></a>

## Function Details ##

<a name="clear_alarm-1"></a>

### clear_alarm/1 ###

`clear_alarm(AlarmId) -> any()`

<a name="code_change-3"></a>

### code_change/3 ###

`code_change(OldVsn, State, Extra) -> any()`

<a name="get_alarms-0"></a>

### get_alarms/0 ###

`get_alarms() -> any()`

<a name="handle_call-2"></a>

### handle_call/2 ###

`handle_call(X1, State) -> any()`

<a name="handle_event-2"></a>

### handle_event/2 ###

`handle_event(Event, State0) -> any()`

<a name="handle_info-2"></a>

### handle_info/2 ###

`handle_info(Info, State) -> any()`

<a name="init-1"></a>

### init/1 ###

`init(X1) -> any()`

<a name="set_alarm-1"></a>

### set_alarm/1 ###

`set_alarm(Alarm) -> any()`

<a name="terminate-2"></a>

### terminate/2 ###

`terminate(Reason, State) -> any()`

