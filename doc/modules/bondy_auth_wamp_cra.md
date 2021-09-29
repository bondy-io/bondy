

# Module bondy_auth_wamp_cra #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

__Behaviours:__ [`bondy_auth`](bondy_auth.md).

<a name="types"></a>

## Data Types ##


<a name="challenge_error()"></a>


### challenge_error() ###


<pre><code>
challenge_error() = missing_pubkey | no_matching_pubkey
</code></pre>


<a name="state()"></a>


### state() ###


<pre><code>
state() = map()
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
challenge(DataIn::map(), Ctxt::<a href="bondy_auth.md#type-context">bondy_auth:context()</a>, CBState::<a href="#type-state">state()</a>) -&gt; {ok, DataOut::map(), CBState::term()} | {error, <a href="#type-challenge_error">challenge_error()</a>, CBState::term()}
</code></pre>
<br />

<a name="init-1"></a>

### init/1 ###

<pre><code>
init(Ctxt::<a href="bondy_auth.md#type-context">bondy_auth:context()</a>) -&gt; {ok, State::<a href="#type-state">state()</a>} | {error, Reason::any()}
</code></pre>
<br />

<a name="requirements-0"></a>

### requirements/0 ###

<pre><code>
requirements() -&gt; map()
</code></pre>
<br />

