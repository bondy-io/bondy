

# Module bondy_backup #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

__Behaviours:__ [`gen_server`](gen_server.md).

<a name="types"></a>

## Data Types ##




### <a name="type-info">info()</a> ###


<pre><code>
info() = #{filename =&gt; <a href="file.md#type-filename">file:filename()</a>, timestamp =&gt; non_neg_integer()}
</code></pre>




### <a name="type-status">status()</a> ###


<pre><code>
status() = backup_in_progress | restore_in_progress | undefined
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#backup-1">backup/1</a></td><td>Backups up the database in the directory indicated by Path.</td></tr><tr><td valign="top"><a href="#code_change-3">code_change/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_call-3">handle_call/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_cast-2">handle_cast/2</a></td><td></td></tr><tr><td valign="top"><a href="#handle_info-2">handle_info/2</a></td><td></td></tr><tr><td valign="top"><a href="#init-1">init/1</a></td><td></td></tr><tr><td valign="top"><a href="#restore-1">restore/1</a></td><td>Restores a backup log.</td></tr><tr><td valign="top"><a href="#start_link-0">start_link/0</a></td><td></td></tr><tr><td valign="top"><a href="#status-0">status/0</a></td><td></td></tr><tr><td valign="top"><a href="#status-1">status/1</a></td><td></td></tr><tr><td valign="top"><a href="#terminate-2">terminate/2</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="backup-1"></a>

### backup/1 ###

<pre><code>
backup(Map0::<a href="file.md#type-filename_all">file:filename_all()</a> | map()) -&gt; {ok, <a href="#type-info">info()</a>} | {error, term()}
</code></pre>
<br />

Backups up the database in the directory indicated by Path.

<a name="code_change-3"></a>

### code_change/3 ###

`code_change(OldVsn, State, Extra) -> any()`

<a name="handle_call-3"></a>

### handle_call/3 ###

`handle_call(X1, From, State) -> any()`

<a name="handle_cast-2"></a>

### handle_cast/2 ###

`handle_cast(Event, State) -> any()`

<a name="handle_info-2"></a>

### handle_info/2 ###

`handle_info(Info, State) -> any()`

<a name="init-1"></a>

### init/1 ###

`init(X1) -> any()`

<a name="restore-1"></a>

### restore/1 ###

<pre><code>
restore(Map0::<a href="file.md#type-filename_all">file:filename_all()</a> | map()) -&gt; {ok, <a href="#type-info">info()</a>} | {error, term()}
</code></pre>
<br />

Restores a backup log.

<a name="start_link-0"></a>

### start_link/0 ###

`start_link() -> any()`

<a name="status-0"></a>

### status/0 ###

`status() -> any()`

<a name="status-1"></a>

### status/1 ###

<pre><code>
status(Map0::<a href="file.md#type-filename_all">file:filename_all()</a> | map()) -&gt; undefined | {<a href="#type-status">status()</a>, non_neg_integer()} | {error, unknown}
</code></pre>
<br />

<a name="terminate-2"></a>

### terminate/2 ###

`terminate(Reason, State) -> any()`

