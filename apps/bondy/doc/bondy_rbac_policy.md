

# Module bondy_rbac_policy #
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




### <a name="type-external">external()</a> ###


<pre><code>
external() = <a href="#type-t">t()</a>
</code></pre>




### <a name="type-permission">permission()</a> ###


<pre><code>
permission() = [{any(), any()}]
</code></pre>




### <a name="type-resource">resource()</a> ###


<pre><code>
resource() = any | binary() | {Uri::<a href="#type-uri">uri()</a>, MatchStrategy::binary()}
</code></pre>




### <a name="type-t">t()</a> ###


<pre><code>
t() = #{type =&gt; policy, version =&gt; binary(), uri =&gt; binary(), match =&gt; binary(), resource =&gt; any | {binary(), binary()}, roles =&gt; [binary()], permissions =&gt; [binary()]}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#grant-2">grant/2</a></td><td>
**Use cases**.</td></tr><tr><td valign="top"><a href="#group_permissions-2">group_permissions/2</a></td><td></td></tr><tr><td valign="top"><a href="#new-1">new/1</a></td><td>Validates the data for a grant or revoke request.</td></tr><tr><td valign="top"><a href="#permissions-3">permissions/3</a></td><td></td></tr><tr><td valign="top"><a href="#revoke-2">revoke/2</a></td><td></td></tr><tr><td valign="top"><a href="#revoke_group-2">revoke_group/2</a></td><td></td></tr><tr><td valign="top"><a href="#revoke_user-2">revoke_user/2</a></td><td></td></tr><tr><td valign="top"><a href="#to_external-1">to_external/1</a></td><td>Returns the external representation of the policy <code>Policy</code>.</td></tr><tr><td valign="top"><a href="#user_permissions-2">user_permissions/2</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="grant-2"></a>

### grant/2 ###

<pre><code>
grant(RealmUri::<a href="#type-uri">uri()</a>, Map0::map()) -&gt; ok | {error, Reason::any()}
</code></pre>
<br />

**Use cases**

```
  grant <permissions> on any to all|{<user>|<group>[,...]}
  grant <permissions> on {<resource>, <exact|prefix|wildcard>} to all|{<user>|<group>[,...]}
```

<a name="group_permissions-2"></a>

### group_permissions/2 ###

<pre><code>
group_permissions(RealmUri::<a href="#type-uri">uri()</a>, Name::binary()) -&gt; [<a href="#type-t">t()</a>]
</code></pre>
<br />

<a name="new-1"></a>

### new/1 ###

<pre><code>
new(Data::map()) -&gt; Policy::map() | no_return()
</code></pre>
<br />

Validates the data for a grant or revoke request.

<a name="permissions-3"></a>

### permissions/3 ###

<pre><code>
permissions(RealmUri::<a href="#type-uri">uri()</a>, Name::binary(), RoleType::user | group) -&gt; [<a href="#type-t">t()</a>]
</code></pre>
<br />

<a name="revoke-2"></a>

### revoke/2 ###

<pre><code>
revoke(RealmUri::<a href="#type-uri">uri()</a>, Map0::map()) -&gt; ok | {error, Reason::any()}
</code></pre>
<br />

<a name="revoke_group-2"></a>

### revoke_group/2 ###

`revoke_group(RealmUri, Name) -> any()`

<a name="revoke_user-2"></a>

### revoke_user/2 ###

`revoke_user(RealmUri, Username) -> any()`

<a name="to_external-1"></a>

### to_external/1 ###

<pre><code>
to_external(Policy::<a href="#type-t">t()</a>) -&gt; <a href="#type-external">external()</a>
</code></pre>
<br />

Returns the external representation of the policy `Policy`.

<a name="user_permissions-2"></a>

### user_permissions/2 ###

<pre><code>
user_permissions(RealmUri::<a href="#type-uri">uri()</a>, Username::binary()) -&gt; [<a href="#type-t">t()</a>]
</code></pre>
<br />

