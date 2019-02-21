

# Module bondy_security #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##




### <a name="type-bucket">bucket()</a> ###


<pre><code>
bucket() = {binary(), binary()} | binary()
</code></pre>




### <a name="type-cidr">cidr()</a> ###


<pre><code>
cidr() = {<a href="inet.md#type-ip_address">inet:ip_address()</a>, non_neg_integer()}
</code></pre>




### <a name="type-context">context()</a> ###


<pre><code>
context() = #context{realm_uri = binary(), username = binary(), grants = [{any(), any()}], epoch = <a href="erlang.md#type-timestamp">erlang:timestamp()</a>}
</code></pre>




### <a name="type-metadata_key">metadata_key()</a> ###


<pre><code>
metadata_key() = binary()
</code></pre>




### <a name="type-metadata_value">metadata_value()</a> ###


<pre><code>
metadata_value() = term()
</code></pre>




### <a name="type-options">options()</a> ###


<pre><code>
options() = [{<a href="#type-metadata_key">metadata_key()</a>, <a href="#type-metadata_value">metadata_value()</a>}]
</code></pre>




### <a name="type-permission">permission()</a> ###


<pre><code>
permission() = {binary()} | {binary(), <a href="#type-bucket">bucket()</a>}
</code></pre>




### <a name="type-userlist">userlist()</a> ###


<pre><code>
userlist() = all | [binary()]
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#add_grant-4">add_grant/4</a></td><td></td></tr><tr><td valign="top"><a href="#add_group-3">add_group/3</a></td><td></td></tr><tr><td valign="top"><a href="#add_revoke-4">add_revoke/4</a></td><td></td></tr><tr><td valign="top"><a href="#add_source-5">add_source/5</a></td><td></td></tr><tr><td valign="top"><a href="#add_user-3">add_user/3</a></td><td></td></tr><tr><td valign="top"><a href="#alter_group-3">alter_group/3</a></td><td></td></tr><tr><td valign="top"><a href="#alter_user-3">alter_user/3</a></td><td></td></tr><tr><td valign="top"><a href="#authenticate-4">authenticate/4</a></td><td></td></tr><tr><td valign="top"><a href="#check_permission-2">check_permission/2</a></td><td></td></tr><tr><td valign="top"><a href="#check_permissions-2">check_permissions/2</a></td><td></td></tr><tr><td valign="top"><a href="#context_to_map-1">context_to_map/1</a></td><td></td></tr><tr><td valign="top"><a href="#del_group-2">del_group/2</a></td><td></td></tr><tr><td valign="top"><a href="#del_source-3">del_source/3</a></td><td></td></tr><tr><td valign="top"><a href="#del_user-2">del_user/2</a></td><td></td></tr><tr><td valign="top"><a href="#disable-1">disable/1</a></td><td></td></tr><tr><td valign="top"><a href="#enable-1">enable/1</a></td><td></td></tr><tr><td valign="top"><a href="#find_bucket_grants-3">find_bucket_grants/3</a></td><td></td></tr><tr><td valign="top"><a href="#find_one_user_by_metadata-3">find_one_user_by_metadata/3</a></td><td></td></tr><tr><td valign="top"><a href="#find_unique_user_by_metadata-3">find_unique_user_by_metadata/3</a></td><td></td></tr><tr><td valign="top"><a href="#find_user-2">find_user/2</a></td><td></td></tr><tr><td valign="top"><a href="#get_ciphers-1">get_ciphers/1</a></td><td></td></tr><tr><td valign="top"><a href="#get_grants-1">get_grants/1</a></td><td></td></tr><tr><td valign="top"><a href="#get_realm_uri-1">get_realm_uri/1</a></td><td></td></tr><tr><td valign="top"><a href="#get_username-1">get_username/1</a></td><td></td></tr><tr><td valign="top"><a href="#group_grants-2">group_grants/2</a></td><td></td></tr><tr><td valign="top"><a href="#is_enabled-1">is_enabled/1</a></td><td></td></tr><tr><td valign="top"><a href="#list-2">list/2</a></td><td></td></tr><tr><td valign="top"><a href="#lookup_group-2">lookup_group/2</a></td><td></td></tr><tr><td valign="top"><a href="#lookup_user-2">lookup_user/2</a></td><td></td></tr><tr><td valign="top"><a href="#lookup_user_sources-2">lookup_user_sources/2</a></td><td></td></tr><tr><td valign="top"><a href="#print_ciphers-1">print_ciphers/1</a></td><td></td></tr><tr><td valign="top"><a href="#print_grants-2">print_grants/2</a></td><td></td></tr><tr><td valign="top"><a href="#print_group-2">print_group/2</a></td><td></td></tr><tr><td valign="top"><a href="#print_groups-1">print_groups/1</a></td><td></td></tr><tr><td valign="top"><a href="#print_sources-1">print_sources/1</a></td><td></td></tr><tr><td valign="top"><a href="#print_user-2">print_user/2</a></td><td></td></tr><tr><td valign="top"><a href="#print_users-1">print_users/1</a></td><td></td></tr><tr><td valign="top"><a href="#set_ciphers-2">set_ciphers/2</a></td><td></td></tr><tr><td valign="top"><a href="#status-1">status/1</a></td><td></td></tr><tr><td valign="top"><a href="#user_grants-2">user_grants/2</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="add_grant-4"></a>

### add_grant/4 ###

<pre><code>
add_grant(RealmUri::binary(), Usernames::<a href="#type-userlist">userlist()</a>, Bucket::<a href="#type-bucket">bucket()</a> | any, Grants::[binary()]) -&gt; ok | {error, term()}
</code></pre>
<br />

<a name="add_group-3"></a>

### add_group/3 ###

<pre><code>
add_group(RealmUri::binary(), Groupname::string(), Options::[{string(), term()}]) -&gt; ok | {error, {no_such_realm, <a href="#type-uri">uri()</a>} | reserved_name | role_exists | illegal_name_char}
</code></pre>
<br />

<a name="add_revoke-4"></a>

### add_revoke/4 ###

<pre><code>
add_revoke(RealmUri::binary(), Usernames::<a href="#type-userlist">userlist()</a>, Bucket::<a href="#type-bucket">bucket()</a> | any, Revokes::[string()]) -&gt; ok | {error, term()}
</code></pre>
<br />

<a name="add_source-5"></a>

### add_source/5 ###

<pre><code>
add_source(RealmUri::binary(), Users::<a href="#type-userlist">userlist()</a>, CIDR::{<a href="inet.md#type-ip_address">inet:ip_address()</a>, non_neg_integer()}, Source::atom(), Options::[{string(), term()}]) -&gt; ok | {error, term()}
</code></pre>
<br />

<a name="add_user-3"></a>

### add_user/3 ###

<pre><code>
add_user(RealmUri::binary(), Username::string(), Options::[{binary(), term()}]) -&gt; ok | {error, {no_such_realm, <a href="#type-uri">uri()</a>} | reserved_name | role_exists | illegal_name_char}
</code></pre>
<br />

<a name="alter_group-3"></a>

### alter_group/3 ###

<pre><code>
alter_group(RealmUri::binary(), Groupname::binary(), Options::[{binary(), term()}]) -&gt; ok | {error, term()}
</code></pre>
<br />

<a name="alter_user-3"></a>

### alter_user/3 ###

<pre><code>
alter_user(RealmUri::binary(), Username::binary(), Options::[{binary(), term()}]) -&gt; ok | {error, term()}
</code></pre>
<br />

<a name="authenticate-4"></a>

### authenticate/4 ###

<pre><code>
authenticate(RealmUri::<a href="#type-uri">uri()</a>, Username::binary(), Password::binary() | {hash, binary()}, ConnInfo::[{atom(), any()}]) -&gt; {ok, <a href="#type-context">context()</a>} | {error, {unknown_user, binary()} | {no_such_realm, <a href="#type-uri">uri()</a>} | missing_password | no_matching_sources}
</code></pre>
<br />

<a name="check_permission-2"></a>

### check_permission/2 ###

<pre><code>
check_permission(Permission::<a href="#type-permission">permission()</a>, Context::<a href="#type-context">context()</a>) -&gt; {true, <a href="#type-context">context()</a>} | {false, binary(), <a href="#type-context">context()</a>}
</code></pre>
<br />

<a name="check_permissions-2"></a>

### check_permissions/2 ###

`check_permissions(Permission, Ctx) -> any()`

<a name="context_to_map-1"></a>

### context_to_map/1 ###

`context_to_map(Context) -> any()`

<a name="del_group-2"></a>

### del_group/2 ###

<pre><code>
del_group(RealmUri::binary(), Groupname::binary()) -&gt; ok | {error, term()}
</code></pre>
<br />

<a name="del_source-3"></a>

### del_source/3 ###

`del_source(RealmUri, Users, CIDR) -> any()`

<a name="del_user-2"></a>

### del_user/2 ###

<pre><code>
del_user(RealmUri::binary(), Username::binary()) -&gt; ok | {error, term()}
</code></pre>
<br />

<a name="disable-1"></a>

### disable/1 ###

`disable(RealmUri) -> any()`

<a name="enable-1"></a>

### enable/1 ###

`enable(RealmUri) -> any()`

<a name="find_bucket_grants-3"></a>

### find_bucket_grants/3 ###

<pre><code>
find_bucket_grants(RealmUri::binary(), Bucket::<a href="#type-bucket">bucket()</a>, Type::user | group) -&gt; [{RoleName::string(), [<a href="#type-permission">permission()</a>]}] | {error, {no_such_realm, <a href="#type-uri">uri()</a>}}
</code></pre>
<br />

<a name="find_one_user_by_metadata-3"></a>

### find_one_user_by_metadata/3 ###

<pre><code>
find_one_user_by_metadata(RealmUri::binary(), Key::<a href="#type-metadata_key">metadata_key()</a>, Value::<a href="#type-metadata_value">metadata_value()</a>) -&gt; {Username::string(), <a href="#type-options">options()</a>} | {error, not_found | {no_such_realm, <a href="#type-uri">uri()</a>}}
</code></pre>
<br />

<a name="find_unique_user_by_metadata-3"></a>

### find_unique_user_by_metadata/3 ###

<pre><code>
find_unique_user_by_metadata(Realm::binary(), Key::<a href="#type-metadata_key">metadata_key()</a>, Value::<a href="#type-metadata_value">metadata_value()</a>) -&gt; {Username::string() | binary(), <a href="#type-options">options()</a>} | {error, not_found | not_unique | {no_such_realm, <a href="#type-uri">uri()</a>}}
</code></pre>
<br />

<a name="find_user-2"></a>

### find_user/2 ###

<pre><code>
find_user(RealmUri::binary(), Username::string()) -&gt; <a href="#type-options">options()</a> | {error, not_found | {no_such_realm, <a href="#type-uri">uri()</a>}}
</code></pre>
<br />

<a name="get_ciphers-1"></a>

### get_ciphers/1 ###

`get_ciphers(RealmUri) -> any()`

<a name="get_grants-1"></a>

### get_grants/1 ###

`get_grants(Context) -> any()`

<a name="get_realm_uri-1"></a>

### get_realm_uri/1 ###

`get_realm_uri(Context) -> any()`

<a name="get_username-1"></a>

### get_username/1 ###

`get_username(Context) -> any()`

<a name="group_grants-2"></a>

### group_grants/2 ###

`group_grants(RealmUri, Group) -> any()`

<a name="is_enabled-1"></a>

### is_enabled/1 ###

`is_enabled(RealmUri) -> any()`

<a name="list-2"></a>

### list/2 ###

<pre><code>
list(RealmUri::binary(), X2::user | group) -&gt; list()
</code></pre>
<br />

<a name="lookup_group-2"></a>

### lookup_group/2 ###

<pre><code>
lookup_group(RealmUri::binary(), Name::binary()) -&gt; tuple() | {error, {no_such_realm, <a href="#type-uri">uri()</a>} | not_found}
</code></pre>
<br />

<a name="lookup_user-2"></a>

### lookup_user/2 ###

<pre><code>
lookup_user(RealmUri::binary(), Username::binary()) -&gt; tuple() | {error, {no_such_realm, <a href="#type-uri">uri()</a>} | not_found}
</code></pre>
<br />

<a name="lookup_user_sources-2"></a>

### lookup_user_sources/2 ###

`lookup_user_sources(RealmUri, Username) -> any()`

<a name="print_ciphers-1"></a>

### print_ciphers/1 ###

`print_ciphers(RealmUri) -> any()`

<a name="print_grants-2"></a>

### print_grants/2 ###

<pre><code>
print_grants(RealmUri::<a href="#type-uri">uri()</a>, Rolename::string()) -&gt; ok | {error, term()}
</code></pre>
<br />

<a name="print_group-2"></a>

### print_group/2 ###

<pre><code>
print_group(RealmUri::<a href="#type-uri">uri()</a>, Group::string()) -&gt; ok | {error, term()}
</code></pre>
<br />

<a name="print_groups-1"></a>

### print_groups/1 ###

`print_groups(RealmUri) -> any()`

<a name="print_sources-1"></a>

### print_sources/1 ###

`print_sources(RealmUri) -> any()`

<a name="print_user-2"></a>

### print_user/2 ###

<pre><code>
print_user(RealmUri::<a href="#type-uri">uri()</a>, Username::string()) -&gt; ok | {error, term()}
</code></pre>
<br />

<a name="print_users-1"></a>

### print_users/1 ###

`print_users(RealmUri) -> any()`

<a name="set_ciphers-2"></a>

### set_ciphers/2 ###

`set_ciphers(RealmUri, CipherList) -> any()`

<a name="status-1"></a>

### status/1 ###

`status(RealmUri) -> any()`

<a name="user_grants-2"></a>

### user_grants/2 ###

`user_grants(RealmUri, Username) -> any()`

