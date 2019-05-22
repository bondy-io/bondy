

# Module bondy_wamp_event_manager #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)

This module provides a bridge between WAMP events and OTP events.

__Behaviours:__ [`gen_event`](gen_event.md).

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#add_callback-1">add_callback/1</a></td><td>Subscribe to a WAMP event with a callback function.</td></tr><tr><td valign="top"><a href="#add_handler-2">add_handler/2</a></td><td>Adds an event handler.</td></tr><tr><td valign="top"><a href="#add_sup_callback-1">add_sup_callback/1</a></td><td>Subscribe to a WAMP event with a supervised callback function.</td></tr><tr><td valign="top"><a href="#add_sup_handler-2">add_sup_handler/2</a></td><td>Adds a supervised event handler.</td></tr><tr><td valign="top"><a href="#code_change-3">code_change/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_call-2">handle_call/2</a></td><td></td></tr><tr><td valign="top"><a href="#handle_event-2">handle_event/2</a></td><td></td></tr><tr><td valign="top"><a href="#handle_info-2">handle_info/2</a></td><td></td></tr><tr><td valign="top"><a href="#init-1">init/1</a></td><td></td></tr><tr><td valign="top"><a href="#notify-2">notify/2</a></td><td>Notifies all event handlers of the event.</td></tr><tr><td valign="top"><a href="#start_link-0">start_link/0</a></td><td></td></tr><tr><td valign="top"><a href="#terminate-2">terminate/2</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="add_callback-1"></a>

### add_callback/1 ###

`add_callback(Fun) -> any()`

Subscribe to a WAMP event with a callback function.
The function needs to have two arguments representing the `topic_uri` and
the `wamp_event()` that has been published.

<a name="add_handler-2"></a>

### add_handler/2 ###

`add_handler(Handler, Args) -> any()`

Adds an event handler.
Calls `gen_event:add_handler(?MODULE, Handler, Args)`.
The handler will receive all WAMP events.

<a name="add_sup_callback-1"></a>

### add_sup_callback/1 ###

`add_sup_callback(Fun) -> any()`

Subscribe to a WAMP event with a supervised callback function.
The function needs to have two arguments representing the `topic_uri` and
the `wamp_event()` that has been published.

<a name="add_sup_handler-2"></a>

### add_sup_handler/2 ###

`add_sup_handler(Handler, Args) -> any()`

Adds a supervised event handler.
Calls `gen_event:add_sup_handler(?MODULE, Handler, Args)`.
The handler will receive all WAMP events.

<a name="code_change-3"></a>

### code_change/3 ###

`code_change(OldVsn, State, Extra) -> any()`

<a name="handle_call-2"></a>

### handle_call/2 ###

`handle_call(Event, State) -> any()`

<a name="handle_event-2"></a>

### handle_event/2 ###

`handle_event(X1, State) -> any()`

<a name="handle_info-2"></a>

### handle_info/2 ###

`handle_info(Info, State) -> any()`

<a name="init-1"></a>

### init/1 ###

`init(X1) -> any()`

<a name="notify-2"></a>

### notify/2 ###

`notify(Topic, Event) -> any()`

Notifies all event handlers of the event

<a name="start_link-0"></a>

### start_link/0 ###

`start_link() -> any()`

<a name="terminate-2"></a>

### terminate/2 ###

`terminate(Reason, State) -> any()`

