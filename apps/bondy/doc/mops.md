

# Module mops #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

This module implements Mops, a very simple mustache-inspired expression
language.

<a name="description"></a>

## Description ##

All expressions in Mops are evaluated against a Context, an erlang `map()`
where all keys are of type `binary()`.

The following are the key characteristics and features:
*
<a name="types"></a>

## Data Types ##




### <a name="type-context">context()</a> ###


<pre><code>
context() = #{}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#eval-2">eval/2</a></td><td>
Evaluates **Term** using the context **Ctxt**
Returns **Term** in case the term is not a binary and does not contain a
mops expression.</td></tr><tr><td valign="top"><a href="#eval-3">eval/3</a></td><td></td></tr><tr><td valign="top"><a href="#is_proxy-1">is_proxy/1</a></td><td></td></tr><tr><td valign="top"><a href="#proxy-0">proxy/0</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="eval-2"></a>

### eval/2 ###

<pre><code>
eval(T::any(), Ctxt::<a href="#type-context">context()</a>) -&gt; any()
</code></pre>
<br />

Evaluates **Term** using the context **Ctxt**
Returns **Term** in case the term is not a binary and does not contain a
mops expression. Otherwise, it tries to evaluate the expression using the
**Ctxt**.

The following are example mops expressions and their meanings:
- `&lt;&lt;"{{foo}}"&gt;&gt;` - resolve the value for key `&lt;&lt;"foo"&gt;&gt;` in the context.
It fails if the context does not have a key named `&lt;&lt;"foo"&gt;&gt;`.
- `&lt;&lt;"\"{{foo}}\"&gt;&gt;` - return a string by resolving the value for key
`&lt;&lt;"foo"&gt;&gt;` in the context. It fails if the context does not have a key
named `&lt;&lt;"foo"&gt;&gt;`.
- `&lt;&lt;"{{foo.bar}}"&gt;&gt;` - resolve the value for key path in the context.
It fails if the context does not have a key named `&lt;&lt;"foo"&gt;&gt;` which has a value that is either a `function()` or a `map()` with a key named `&lt;&lt;"bar"&gt;&gt;`.
- `&lt;&lt;"{{foo |> integer}}"&gt;&gt;` - resolves the value for key `&lt;&lt;"foo"&gt;&gt;` in the
context and converts the result to an integer. If the result was a
`function()`, it returns a function composition.
It fails if the context does not have a key named `&lt;&lt;"foo"&gt;&gt;`

Examples:

```

  > mops:eval(foo, #{<<"foo">> => bar}).
  > foo
  > mops:eval(<<"foo">>, #{<<"foo">> => bar}).
  > <<"foo">>
  > mops:eval(1, #{<<"foo">> => bar}).
  > 1
  > mops:eval(<<"{{foo}}">>, #{<<"foo">> => bar}).
  > bar
  > mops:eval(<<"{{foo.bar}}">>, #{<<"foo">> => #{<<"bar">> => foobar}}).
  > foobar
```

<a name="eval-3"></a>

### eval/3 ###

<pre><code>
eval(T::any(), Ctxt::<a href="#type-context">context()</a>, Opts::#{}) -&gt; any()
</code></pre>
<br />

<a name="is_proxy-1"></a>

### is_proxy/1 ###

<pre><code>
is_proxy(X1::any()) -&gt; boolean()
</code></pre>
<br />

<a name="proxy-0"></a>

### proxy/0 ###

<pre><code>
proxy() -&gt; '$mops_proxy'
</code></pre>
<br />

