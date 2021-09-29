

# Module bondy_auth_anonymous #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

This module implements the [`bondy_auth`](bondy_auth.md) behaviour to allow access
to clients which connect without credentials assigning them the 'anonymous'
group.

__Behaviours:__ [`bondy_auth`](bondy_auth.md).

<a name="types"></a>

## Data Types ##


<a name="state()"></a>


### state() ###


<pre><code>
state() = #{user_id =&gt; binary() | undefined, role =&gt; binary(), roles =&gt; [binary()], conn_ip =&gt; [{ip, <a href="inet.md#type-ip_address">inet:ip_address()</a>}]}
</code></pre>


<a name="functions"></a>

## Function Details ##

<a name="authenticate-4"></a>

### authenticate/4 ###

<pre><code>
authenticate(Signature::binary(), DataIn::map(), Ctxt::<a href="bondy_auth.md#type-context">bondy_auth:context()</a>, CBState::<a href="#type-state">state()</a>) -&gt; {ok, DataOut::map(), CBState::<a href="#type-state">state()</a>} | {error, Reason::any(), CBState::<a href="#type-state">state()</a>}
</code></pre>
<br />

<a name="challenge-3"></a>

### challenge/3 ###

<pre><code>
challenge(Details::map(), AuthCtxt::<a href="bondy_auth.md#type-context">bondy_auth:context()</a>, State::<a href="#type-state">state()</a>) -&gt; {ok, NewState::<a href="#type-state">state()</a>} | {error, Reason::any(), NewState::<a href="#type-state">state()</a>}
</code></pre>
<br />

<a name="init-1"></a>

### init/1 ###

<pre><code>
init(Ctxt::<a href="bondy_auth.md#type-context">bondy_auth:context()</a>) -&gt; {ok, State::<a href="#type-state">state()</a>} | {error, Reason::any()}
</code></pre>
<br />

throws `invalid_context`

<a name="requirements-0"></a>

### requirements/0 ###

<pre><code>
requirements() -&gt; map()
</code></pre>
<br />

