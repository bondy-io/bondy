

# Module bondy_session_manager #
* [Function Index](#index)
* [Function Details](#functions)

__Behaviours:__ [`gen_server`](gen_server.md).

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#close-1">close/1</a></td><td></td></tr><tr><td valign="top"><a href="#code_change-3">code_change/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_call-3">handle_call/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_cast-2">handle_cast/2</a></td><td></td></tr><tr><td valign="top"><a href="#handle_info-2">handle_info/2</a></td><td></td></tr><tr><td valign="top"><a href="#init-1">init/1</a></td><td></td></tr><tr><td valign="top"><a href="#open-4">open/4</a></td><td>
Creates a new session provided the RealmUri exists or can be dynamically
created.</td></tr><tr><td valign="top"><a href="#start_link-0">start_link/0</a></td><td></td></tr><tr><td valign="top"><a href="#terminate-2">terminate/2</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="close-1"></a>

### close/1 ###

<pre><code>
close(Session::<a href="bondy_session.md#type-t">bondy_session:t()</a>) -&gt; ok
</code></pre>
<br />

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

<a name="open-4"></a>

### open/4 ###

<pre><code>
open(Id::<a href="bondy_session.md#type-id">bondy_session:id()</a>, Peer::<a href="bondy_session.md#type-peer">bondy_session:peer()</a>, RealmOrUri::<a href="#type-uri">uri()</a> | <a href="bondy_realm.md#type-t">bondy_realm:t()</a>, Opts::<a href="bondy_session.md#type-session_opts">bondy_session:session_opts()</a>) -&gt; <a href="bondy_session.md#type-t">bondy_session:t()</a> | no_return()
</code></pre>
<br />

Creates a new session provided the RealmUri exists or can be dynamically
created.
It calls [`bondy_session:new/4`](bondy_session.md#new-4) which will fail with an exception
if the realm does not exist or cannot be created.

This function also sets up a monitor for the calling process which is
assummed to be the client connection process e.g. WAMP connection. In case
the connection crashes it performs the cleanup of any session data that
should not be retained.
-----------------------------------------------------------------------------

<a name="start_link-0"></a>

### start_link/0 ###

`start_link() -> any()`

<a name="terminate-2"></a>

### terminate/2 ###

`terminate(Reason, State) -> any()`

