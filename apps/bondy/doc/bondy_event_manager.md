

# Module bondy_event_manager #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)

This module is used by Bondy to manage event handlers and notify them of
events.

<a name="description"></a>

## Description ##
It implements the "watched" handler capability i.e.
`add_watched_handler/2,3`, `swap_watched_handler/2,3`.
In addition, this module mirrors most of the gen_event API and adds variants
with two arguments were the first argument is the defaul event manager
(`bondy_event_manager`).<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#add_handler-2">add_handler/2</a></td><td>Adds an event handler.</td></tr><tr><td valign="top"><a href="#add_handler-3">add_handler/3</a></td><td>Adds an event handler.</td></tr><tr><td valign="top"><a href="#add_sup_handler-2">add_sup_handler/2</a></td><td>Adds a supervised event handler.</td></tr><tr><td valign="top"><a href="#add_sup_handler-3">add_sup_handler/3</a></td><td>Adds a supervised event handler.</td></tr><tr><td valign="top"><a href="#add_watched_handler-2">add_watched_handler/2</a></td><td>Adds a watched event handler.</td></tr><tr><td valign="top"><a href="#add_watched_handler-3">add_watched_handler/3</a></td><td>Adds a supervised event handler.</td></tr><tr><td valign="top"><a href="#notify-1">notify/1</a></td><td>A util function.</td></tr><tr><td valign="top"><a href="#notify-2">notify/2</a></td><td>A util function.</td></tr><tr><td valign="top"><a href="#swap_handler-2">swap_handler/2</a></td><td>A util function.</td></tr><tr><td valign="top"><a href="#swap_handler-3">swap_handler/3</a></td><td>A util function.</td></tr><tr><td valign="top"><a href="#swap_sup_handler-2">swap_sup_handler/2</a></td><td>A util function.</td></tr><tr><td valign="top"><a href="#swap_sup_handler-3">swap_sup_handler/3</a></td><td>A util function.</td></tr><tr><td valign="top"><a href="#swap_watched_handler-2">swap_watched_handler/2</a></td><td>A util function.</td></tr><tr><td valign="top"><a href="#swap_watched_handler-3">swap_watched_handler/3</a></td><td>Replaces an event handler in event manager <code>Manager</code> in the same way as
<code>swap_sup_handler/3</code>.</td></tr><tr><td valign="top"><a href="#sync_notify-1">sync_notify/1</a></td><td>A util function.</td></tr><tr><td valign="top"><a href="#sync_notify-2">sync_notify/2</a></td><td>A util function.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="add_handler-2"></a>

### add_handler/2 ###

`add_handler(Handler, Args) -> any()`

Adds an event handler.
Calls `gen_event:add_handler(?MODULE, Handler, Args)`.

<a name="add_handler-3"></a>

### add_handler/3 ###

`add_handler(Manager, Handler, Args) -> any()`

Adds an event handler.
Calls `gen_event:add_handler(Manager, Handler, Args)`.

<a name="add_sup_handler-2"></a>

### add_sup_handler/2 ###

`add_sup_handler(Handler, Args) -> any()`

Adds a supervised event handler.
Calls `gen_event:add_sup_handler(?MODULE, Handler, Args)`.

<a name="add_sup_handler-3"></a>

### add_sup_handler/3 ###

`add_sup_handler(Manager, Handler, Args) -> any()`

Adds a supervised event handler.
Calls `gen_event:add_sup_handler(?MODULE, Handler, Args)`.

<a name="add_watched_handler-2"></a>

### add_watched_handler/2 ###

`add_watched_handler(Handler, Args) -> any()`

Adds a watched event handler.
As opposed to `add_sup_handler/2` which monitors the caller, this function
calls `bondy_event_handler_watcher_sup:start_watcher(Handler, Args)` which
spawns a supervised process (`bondy_event_handler_watcher`) which calls
`add_sup_handler/2`. If the handler crashes, `bondy_event_handler_watcher`
will re-install it in the event manager.

<a name="add_watched_handler-3"></a>

### add_watched_handler/3 ###

`add_watched_handler(Manager, Handler, Args) -> any()`

Adds a supervised event handler.
As opposed to `add_sup_handler/2` which monitors the caller, this function
calls `bondy_event_handler_watcher_sup:start_watcher(Handler, Args)` which
spawns a supervised process (`bondy_event_handler_watcher`) which calls
`add_sup_handler/2`. If the handler crashes, `bondy_event_handler_watcher`
will re-install it in the event manager.

<a name="notify-1"></a>

### notify/1 ###

`notify(Event) -> any()`

A util function. Equivalent to calling
`notify(bondy_event_manager, Event)`

<a name="notify-2"></a>

### notify/2 ###

`notify(Manager, Event) -> any()`

A util function. Equivalent to calling
`gen_event:notify(bondy_event_manager, Event)`

<a name="swap_handler-2"></a>

### swap_handler/2 ###

`swap_handler(OldHandler, NewHandler) -> any()`

A util function. Equivalent to calling
`swap_handler(bondy_event_manager, OldHandler, NewHandler)`

<a name="swap_handler-3"></a>

### swap_handler/3 ###

`swap_handler(Manager, OldHandler, NewHandler) -> any()`

A util function. Equivalent to calling `gen_event:swap_handler/3`

<a name="swap_sup_handler-2"></a>

### swap_sup_handler/2 ###

`swap_sup_handler(OldHandler, NewHandler) -> any()`

A util function. Equivalent to calling
`swap_sup_handler(bondy_event_manager, OldHandler, NewHandler)`

<a name="swap_sup_handler-3"></a>

### swap_sup_handler/3 ###

`swap_sup_handler(Manager, OldHandler, NewHandler) -> any()`

A util function. Equivalent to calling `gen_event:swap_sup_handler/3`

<a name="swap_watched_handler-2"></a>

### swap_watched_handler/2 ###

`swap_watched_handler(OldHandler, NewHandler) -> any()`

A util function. Equivalent to calling
`swap_watched_handler(bondy_event_manager, OldHandler, NewHandler)`

<a name="swap_watched_handler-3"></a>

### swap_watched_handler/3 ###

`swap_watched_handler(Manager, OldHandler, NewHandler) -> any()`

Replaces an event handler in event manager `Manager` in the same way as
`swap_sup_handler/3`. However, this function
calls `bondy_event_handler_watcher_sup:start_watcher(Handler, Args)` which
spawns a supervised process (`bondy_event_handler_watcher`) which is the one
calling calls `swap_sup_handler/2`.
If the handler crashes or terminates with a reason other than `normal` or
`shutdown`, `bondy_event_handler_watcher` will re-install it in
the event manager.

<a name="sync_notify-1"></a>

### sync_notify/1 ###

`sync_notify(Event) -> any()`

A util function. Equivalent to calling
`sync_notify(bondy_event_manager, Event)`

<a name="sync_notify-2"></a>

### sync_notify/2 ###

`sync_notify(Manager, Event) -> any()`

A util function. Equivalent to calling
`gen_event:sync_notify(bondy_event_manager, Event)`

