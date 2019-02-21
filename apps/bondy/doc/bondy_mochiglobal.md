

# Module bondy_mochiglobal #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)

Abuse module constant pools as a "read-only shared heap" (since erts 5.6)
[[1]](http://www.erlang.org/pipermail/erlang-questions/2009-March/042503.html).

Copyright (c) 2010 Mochi Media, Inc.

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the "Software"),
to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.

__Authors:__ Bob Ippolito ([`bob@mochimedia.com`](mailto:bob@mochimedia.com)).

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#delete-1">delete/1</a></td><td>Delete term stored at K, no-op if non-existent.</td></tr><tr><td valign="top"><a href="#get-1">get/1</a></td><td>Equivalent to <a href="#get-2"><tt>get(K, undefined)</tt></a>.</td></tr><tr><td valign="top"><a href="#get-2">get/2</a></td><td>Get the term for K or return Default.</td></tr><tr><td valign="top"><a href="#put-2">put/2</a></td><td>Store term V at K, replaces an existing term if present.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="delete-1"></a>

### delete/1 ###

<pre><code>
delete(K::atom()) -&gt; boolean()
</code></pre>
<br />

Delete term stored at K, no-op if non-existent.

<a name="get-1"></a>

### get/1 ###

<pre><code>
get(K::atom()) -&gt; any() | undefined
</code></pre>
<br />

Equivalent to [`get(K, undefined)`](#get-2).

<a name="get-2"></a>

### get/2 ###

<pre><code>
get(K::atom(), T) -&gt; any() | T
</code></pre>
<br />

Get the term for K or return Default.

<a name="put-2"></a>

### put/2 ###

<pre><code>
put(K::atom(), V::any()) -&gt; ok
</code></pre>
<br />

Store term V at K, replaces an existing term if present.

