

# Module bondy_app #
* [Function Index](#index)
* [Function Details](#functions)

__Behaviours:__ [`application`](application.md).

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#prep_stop-1">prep_stop/1</a></td><td>Application behaviour callback.</td></tr><tr><td valign="top"><a href="#start-2">start/2</a></td><td>Application behaviour callback.</td></tr><tr><td valign="top"><a href="#start_phase-3">start_phase/3</a></td><td>Application behaviour callback.</td></tr><tr><td valign="top"><a href="#stop-0">stop/0</a></td><td>A convenience function.</td></tr><tr><td valign="top"><a href="#stop-1">stop/1</a></td><td>Application behaviour callback.</td></tr><tr><td valign="top"><a href="#vsn-0">vsn/0</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="prep_stop-1"></a>

### prep_stop/1 ###

`prep_stop(State) -> any()`

Application behaviour callback

<a name="start-2"></a>

### start/2 ###

`start(Type, Args) -> any()`

Application behaviour callback

<a name="start_phase-3"></a>

### start_phase/3 ###

`start_phase(X1, X2, X3) -> any()`

Application behaviour callback.
The order in which this function is called with the different phases is
defined in the bondy_app.src file.

<a name="stop-0"></a>

### stop/0 ###

`stop() -> any()`

A convenience function. Calls `init:stop/0`

<a name="stop-1"></a>

### stop/1 ###

`stop(State) -> any()`

Application behaviour callback

<a name="vsn-0"></a>

### vsn/0 ###

<pre><code>
vsn() -&gt; list()
</code></pre>
<br />

