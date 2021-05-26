

# Module bondy_rbac_source #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

**Note:**
Usernames and group names are stored in lower case.

<a name="description"></a>

## Description ##
All functions in this
module are case sensitice so when using the functions in this module make
sure the inputs you provide are in lowercase to. If you need to convert your
input to lowercase use [`string:casefold/1`](string.md#casefold-1).
<a name="types"></a>

## Data Types ##




### <a name="type-assignment">assignment()</a> ###


<pre><code>
assignment() = #source_assignment{usernames = [binary() | all | anonymous], data = <a href="#type-t">t()</a>}
</code></pre>




### <a name="type-cidr">cidr()</a> ###


<pre><code>
cidr() = {<a href="inet.md#type-ip_address">inet:ip_address()</a>, non_neg_integer()}
</code></pre>




### <a name="type-external">external()</a> ###


<pre><code>
external() = <a href="#type-t">t()</a>
</code></pre>




### <a name="type-list_opts">list_opts()</a> ###


<pre><code>
list_opts() = #{limit =&gt; pos_integer()}
</code></pre>




### <a name="type-t">t()</a> ###


<pre><code>
t() = #{type =&gt; source, version =&gt; binary(), username =&gt; binary() | all | anonymous, cidr =&gt; <a href="#type-cidr">cidr()</a>, authmethod =&gt; binary(), meta =&gt; #{binary() =&gt; any()}}
</code></pre>




### <a name="type-user_source">user_source()</a> ###


<pre><code>
user_source() = #{type =&gt; source, version =&gt; binary(), username =&gt; binary() | all | anonymous, cidr =&gt; <a href="#type-cidr">cidr()</a>, authmethod =&gt; binary(), meta =&gt; #{binary() =&gt; any()}}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#add-2">add/2</a></td><td></td></tr><tr><td valign="top"><a href="#add-3">add/3</a></td><td></td></tr><tr><td valign="top"><a href="#authmethod-1">authmethod/1</a></td><td>Returns the authmethod associated withe the source.</td></tr><tr><td valign="top"><a href="#cidr-1">cidr/1</a></td><td>Returns the source's CIDR.</td></tr><tr><td valign="top"><a href="#list-1">list/1</a></td><td></td></tr><tr><td valign="top"><a href="#list-2">list/2</a></td><td></td></tr><tr><td valign="top"><a href="#match-2">match/2</a></td><td>Returns all the sources for user including the ones for speacial
use 'all'.</td></tr><tr><td valign="top"><a href="#match-3">match/3</a></td><td></td></tr><tr><td valign="top"><a href="#match_first-3">match_first/3</a></td><td>Returns the first matching source of all the sources available for
username <code>Username</code>.</td></tr><tr><td valign="top"><a href="#meta-1">meta/1</a></td><td>Returns the metadata associated with the source.</td></tr><tr><td valign="top"><a href="#new-1">new/1</a></td><td></td></tr><tr><td valign="top"><a href="#new_assignment-1">new_assignment/1</a></td><td></td></tr><tr><td valign="top"><a href="#remove-3">remove/3</a></td><td></td></tr><tr><td valign="top"><a href="#remove_all-2">remove_all/2</a></td><td></td></tr><tr><td valign="top"><a href="#to_external-1">to_external/1</a></td><td>Returns the external representation of the user <code>User</code>.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="add-2"></a>

### add/2 ###

<pre><code>
add(RealmUri::<a href="#type-uri">uri()</a>, Assignment::map() | <a href="#type-assignment">assignment()</a>) -&gt; ok | {error, any()}
</code></pre>
<br />

<a name="add-3"></a>

### add/3 ###

<pre><code>
add(Realmuri::<a href="#type-uri">uri()</a>, Usernames::[binary()] | all | anonymous, Assignment::map() | <a href="#type-assignment">assignment()</a>) -&gt; ok | {error, any()}
</code></pre>
<br />

<a name="authmethod-1"></a>

### authmethod/1 ###

`authmethod(X1) -> any()`

Returns the authmethod associated withe the source

<a name="cidr-1"></a>

### cidr/1 ###

`cidr(X1) -> any()`

Returns the source's CIDR.

<a name="list-1"></a>

### list/1 ###

<pre><code>
list(RealmUri::<a href="#type-uri">uri()</a>) -&gt; [<a href="#type-t">t()</a>]
</code></pre>
<br />

<a name="list-2"></a>

### list/2 ###

<pre><code>
list(RealmUri::<a href="#type-uri">uri()</a>, Opts::<a href="#type-list_opts">list_opts()</a>) -&gt; [<a href="#type-t">t()</a>]
</code></pre>
<br />

<a name="match-2"></a>

### match/2 ###

<pre><code>
match(RealmUri::<a href="#type-uri">uri()</a>, Username::binary() | all | anonymous) -&gt; [<a href="#type-t">t()</a>]
</code></pre>
<br />

Returns all the sources for user including the ones for speacial
use 'all'.

<a name="match-3"></a>

### match/3 ###

<pre><code>
match(RealmUri::<a href="#type-uri">uri()</a>, Username::binary() | all | anonymous, ConnIP::<a href="inet.md#type-ip_address">inet:ip_address()</a>) -&gt; [<a href="#type-t">t()</a>]
</code></pre>
<br />

<a name="match_first-3"></a>

### match_first/3 ###

<pre><code>
match_first(RealmUri::<a href="#type-uri">uri()</a>, Username::binary() | all | anonymous, ConnIP::<a href="inet.md#type-ip_address">inet:ip_address()</a>) -&gt; {ok, <a href="#type-t">t()</a>} | {error, nomatch}
</code></pre>
<br />

Returns the first matching source of all the sources available for
username `Username`.

<a name="meta-1"></a>

### meta/1 ###

`meta(X1) -> any()`

Returns the metadata associated with the source

<a name="new-1"></a>

### new/1 ###

<pre><code>
new(Data::map()) -&gt; Source::<a href="#type-t">t()</a>
</code></pre>
<br />

<a name="new_assignment-1"></a>

### new_assignment/1 ###

<pre><code>
new_assignment(Data::map()) -&gt; Source::<a href="#type-assignment">assignment()</a>
</code></pre>
<br />

<a name="remove-3"></a>

### remove/3 ###

<pre><code>
remove(RealmUri::<a href="#type-uri">uri()</a>, Usernames::[binary() | anonymous] | binary() | anonymous | all, CIDR::<a href="bondy_rbac_source.md#type-cidr">bondy_rbac_source:cidr()</a>) -&gt; ok
</code></pre>
<br />

<a name="remove_all-2"></a>

### remove_all/2 ###

<pre><code>
remove_all(RealmUri::<a href="#type-uri">uri()</a>, Username::binary()) -&gt; ok
</code></pre>
<br />

<a name="to_external-1"></a>

### to_external/1 ###

<pre><code>
to_external(Source::<a href="#type-t">t()</a>) -&gt; <a href="#type-external">external()</a>
</code></pre>
<br />

Returns the external representation of the user `User`.

