

# Module bondy_cli #
* [Function Index](#index)
* [Function Details](#functions)

__Behaviours:__ [`clique_handler`](clique_handler.md).

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#add_group-1">add_group/1</a></td><td></td></tr><tr><td valign="top"><a href="#add_source-1">add_source/1</a></td><td></td></tr><tr><td valign="top"><a href="#add_user-1">add_user/1</a></td><td></td></tr><tr><td valign="top"><a href="#alter_group-1">alter_group/1</a></td><td></td></tr><tr><td valign="top"><a href="#alter_user-1">alter_user/1</a></td><td></td></tr><tr><td valign="top"><a href="#ciphers-1">ciphers/1</a></td><td></td></tr><tr><td valign="top"><a href="#command-1">command/1</a></td><td></td></tr><tr><td valign="top"><a href="#del_group-1">del_group/1</a></td><td></td></tr><tr><td valign="top"><a href="#del_source-1">del_source/1</a></td><td></td></tr><tr><td valign="top"><a href="#del_user-1">del_user/1</a></td><td></td></tr><tr><td valign="top"><a href="#grant-1">grant/1</a></td><td></td></tr><tr><td valign="top"><a href="#load_api-3">load_api/3</a></td><td></td></tr><tr><td valign="top"><a href="#load_schema-0">load_schema/0</a></td><td></td></tr><tr><td valign="top"><a href="#parse_cidr-1">parse_cidr/1</a></td><td></td></tr><tr><td valign="top"><a href="#print_grants-1">print_grants/1</a></td><td></td></tr><tr><td valign="top"><a href="#print_group-1">print_group/1</a></td><td></td></tr><tr><td valign="top"><a href="#print_groups-1">print_groups/1</a></td><td></td></tr><tr><td valign="top"><a href="#print_sources-1">print_sources/1</a></td><td></td></tr><tr><td valign="top"><a href="#print_user-1">print_user/1</a></td><td></td></tr><tr><td valign="top"><a href="#print_users-1">print_users/1</a></td><td></td></tr><tr><td valign="top"><a href="#register-0">register/0</a></td><td></td></tr><tr><td valign="top"><a href="#register_cli-0">register_cli/0</a></td><td></td></tr><tr><td valign="top"><a href="#register_node_finder-0">register_node_finder/0</a></td><td></td></tr><tr><td valign="top"><a href="#revoke-1">revoke/1</a></td><td></td></tr><tr><td valign="top"><a href="#security_disable-1">security_disable/1</a></td><td></td></tr><tr><td valign="top"><a href="#security_enable-1">security_enable/1</a></td><td></td></tr><tr><td valign="top"><a href="#security_status-1">security_status/1</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="add_group-1"></a>

### add_group/1 ###

`add_group(Options) -> any()`

<a name="add_source-1"></a>

### add_source/1 ###

`add_source(Options) -> any()`

<a name="add_user-1"></a>

### add_user/1 ###

`add_user(Options) -> any()`

<a name="alter_group-1"></a>

### alter_group/1 ###

`alter_group(Options) -> any()`

<a name="alter_user-1"></a>

### alter_user/1 ###

`alter_user(Options) -> any()`

<a name="ciphers-1"></a>

### ciphers/1 ###

`ciphers(X1) -> any()`

<a name="command-1"></a>

### command/1 ###

`command(Cmd) -> any()`

<a name="del_group-1"></a>

### del_group/1 ###

`del_group(X1) -> any()`

<a name="del_source-1"></a>

### del_source/1 ###

`del_source(X1) -> any()`

<a name="del_user-1"></a>

### del_user/1 ###

`del_user(X1) -> any()`

<a name="grant-1"></a>

### grant/1 ###

`grant(X1) -> any()`

<a name="load_api-3"></a>

### load_api/3 ###

`load_api(X1, X2, X3) -> any()`

<a name="load_schema-0"></a>

### load_schema/0 ###

<pre><code>
load_schema() -&gt; ok
</code></pre>
<br />

<a name="parse_cidr-1"></a>

### parse_cidr/1 ###

<pre><code>
parse_cidr(CIDR::string()) -&gt; {<a href="inet.md#type-ip_address">inet:ip_address()</a>, non_neg_integer()}
</code></pre>
<br />

<a name="print_grants-1"></a>

### print_grants/1 ###

`print_grants(X1) -> any()`

<a name="print_group-1"></a>

### print_group/1 ###

`print_group(X1) -> any()`

<a name="print_groups-1"></a>

### print_groups/1 ###

`print_groups(X1) -> any()`

<a name="print_sources-1"></a>

### print_sources/1 ###

`print_sources(X1) -> any()`

<a name="print_user-1"></a>

### print_user/1 ###

`print_user(X1) -> any()`

<a name="print_users-1"></a>

### print_users/1 ###

`print_users(X1) -> any()`

<a name="register-0"></a>

### register/0 ###

`register() -> any()`

<a name="register_cli-0"></a>

### register_cli/0 ###

<pre><code>
register_cli() -&gt; ok
</code></pre>
<br />

<a name="register_node_finder-0"></a>

### register_node_finder/0 ###

<pre><code>
register_node_finder() -&gt; true
</code></pre>
<br />

<a name="revoke-1"></a>

### revoke/1 ###

`revoke(X1) -> any()`

<a name="security_disable-1"></a>

### security_disable/1 ###

`security_disable(X1) -> any()`

<a name="security_enable-1"></a>

### security_enable/1 ###

`security_enable(X1) -> any()`

<a name="security_status-1"></a>

### security_status/1 ###

`security_status(X1) -> any()`

