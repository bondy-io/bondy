

# Module bondy_api_gateway_spec_parser #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

This module implements a parser for the Bondy API Specification Format which
is used to dynamically define one or more RESTful APIs.

<a name="description"></a>

## Description ##
== API Specification Format
=== Host Spec
=== API Spec
=== Version Spec
=== Path Spec
=== Method Spec
=== Action Spec
=== Action Spec
<a name="types"></a>

## Data Types ##




### <a name="type-route_match">route_match()</a> ###


<pre><code>
route_match() = '_' | iodata()
</code></pre>




### <a name="type-route_path">route_path()</a> ###


<pre><code>
route_path() = {Path::<a href="#type-route_match">route_match()</a>, Handler::module(), Opts::any()}
</code></pre>




### <a name="type-route_rule">route_rule()</a> ###


<pre><code>
route_rule() = {Host::<a href="#type-route_match">route_match()</a>, Paths::[<a href="#type-route_path">route_path()</a>]}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#dispatch_table-1">dispatch_table/1</a></td><td>
Given a valid API Spec or list of Specs returned by <a href="#parse-1"><code>parse/1</code></a>,
dynamically generates a cowboy dispatch table.</td></tr><tr><td valign="top"><a href="#dispatch_table-2">dispatch_table/2</a></td><td>
Given a list of valid API Specs returned by <a href="#parse-1"><code>parse/1</code></a> and
dynamically generates the cowboy dispatch table.</td></tr><tr><td valign="top"><a href="#from_file-1">from_file/1</a></td><td>
Loads a file and calls <a href="#parse-1"><code>parse/1</code></a>.</td></tr><tr><td valign="top"><a href="#parse-1">parse/1</a></td><td>
Parses the Spec map returning a new valid spec where all defaults have been
applied and all variables have been replaced by either a value of a promise.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="dispatch_table-1"></a>

### dispatch_table/1 ###

<pre><code>
dispatch_table(API::[#{}] | #{}) -&gt; [{Scheme::binary(), [<a href="#type-route_rule">route_rule()</a>]}] | no_return()
</code></pre>
<br />

Given a valid API Spec or list of Specs returned by [`parse/1`](#parse-1),
dynamically generates a cowboy dispatch table.

<a name="dispatch_table-2"></a>

### dispatch_table/2 ###

<pre><code>
dispatch_table(API::[#{}] | #{}, RulesToAdd::[<a href="#type-route_rule">route_rule()</a>]) -&gt; [{Scheme::binary(), [<a href="#type-route_rule">route_rule()</a>]}] | no_return()
</code></pre>
<br />

Given a list of valid API Specs returned by [`parse/1`](#parse-1) and
dynamically generates the cowboy dispatch table.
Notice this does not update the cowboy dispatch table. You will need to do
that yourself.

<a name="from_file-1"></a>

### from_file/1 ###

<pre><code>
from_file(Filename::<a href="file.md#type-filename">file:filename()</a>) -&gt; {ok, any()} | {error, any()}
</code></pre>
<br />

Loads a file and calls [`parse/1`](#parse-1).

<a name="parse-1"></a>

### parse/1 ###

<pre><code>
parse(Map::#{}) -&gt; #{} | no_return()
</code></pre>
<br />

Parses the Spec map returning a new valid spec where all defaults have been
applied and all variables have been replaced by either a value of a promise.
Fails with in case the Spec is invalid.

Variable replacepement is performed using our "mop" library.

