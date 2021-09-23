

# Module bondy_http_gateway_api_spec_parser #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

This module implements a parser for the Bondy API Specification Format which
is used to dynamically define one or more RESTful APIs.

<a name="description"></a>

## Description ##

The parser uses maps_utils:validate and a number of validation specifications
and as a result is its error reporting is not great but does its job.
The plan is to replace this with an ad-hoc parser to give the user more
useful error information.

## API Specification Format

### Host Spec

### API Spec

### Version Spec

### Path Spec

### Method Spec

### Action Spec

### Action Spec

<a name="types"></a>

## Data Types ##


<a name="route_match()"></a>


### route_match() ###


<pre><code>
route_match() = _ | iodata()
</code></pre>


<a name="route_path()"></a>


### route_path() ###


<pre><code>
route_path() = {Path::<a href="#type-route_match">route_match()</a>, Handler::module(), Opts::any()}
</code></pre>


<a name="route_rule()"></a>


### route_rule() ###


<pre><code>
route_rule() = {Host::<a href="#type-route_match">route_match()</a>, Paths::[<a href="#type-route_path">route_path()</a>]}
</code></pre>


<a name="functions"></a>

## Function Details ##

<a name="dispatch_table-1"></a>

### dispatch_table/1 ###

<pre><code>
dispatch_table(API::[map()] | map()) -&gt; [{Scheme::binary(), [<a href="#type-route_rule">route_rule()</a>]}] | no_return()
</code></pre>
<br />

Given a valid API Spec or list of Specs returned by [`parse/1`](#parse-1),
dynamically generates a cowboy dispatch table.

<a name="dispatch_table-2"></a>

### dispatch_table/2 ###

<pre><code>
dispatch_table(API::[map()] | map(), RulesToAdd::[<a href="#type-route_rule">route_rule()</a>]) -&gt; [{Scheme::binary(), [<a href="#type-route_rule">route_rule()</a>]}] | no_return()
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
parse(Map::map()) -&gt; map() | {error, invalid_specification_format} | no_return()
</code></pre>
<br />

Parses the Spec map returning a new valid spec where all defaults have been
applied and all variables have been replaced by either a value of a promise.
Fails with in case the Spec is invalid.

Variable replacepement is performed using our "mop" library.

