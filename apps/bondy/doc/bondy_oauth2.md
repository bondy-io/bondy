

# Module bondy_oauth2 #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##




### <a name="type-error">error()</a> ###


<pre><code>
error() = oauth2_invalid_grant | unknown_realm
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#decode_jwt-1">decode_jwt/1</a></td><td></td></tr><tr><td valign="top"><a href="#generate_fragment-1">generate_fragment/1</a></td><td></td></tr><tr><td valign="top"><a href="#issue_token-5">issue_token/5</a></td><td></td></tr><tr><td valign="top"><a href="#refresh_token-3">refresh_token/3</a></td><td>
After refreshing a token, the previous refresh token will be revoked.</td></tr><tr><td valign="top"><a href="#revoke_token-3">revoke_token/3</a></td><td></td></tr><tr><td valign="top"><a href="#verify_jwt-2">verify_jwt/2</a></td><td></td></tr><tr><td valign="top"><a href="#verify_jwt-3">verify_jwt/3</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="decode_jwt-1"></a>

### decode_jwt/1 ###

<pre><code>
decode_jwt(JWT::binary()) -&gt; #{}
</code></pre>
<br />

<a name="generate_fragment-1"></a>

### generate_fragment/1 ###

<pre><code>
generate_fragment(N::non_neg_integer()) -&gt; binary()
</code></pre>
<br />

<a name="issue_token-5"></a>

### issue_token/5 ###

<pre><code>
issue_token(RealmUri::<a href="bondy_realm.md#type-uri">bondy_realm:uri()</a>, Issuer::binary(), Username::binary(), Groups::[binary()], Meta::#{}) -&gt; {ok, AccessToken::binary(), RefreshToken::binary(), Claims::#{}} | {error, any()}
</code></pre>
<br />

<a name="refresh_token-3"></a>

### refresh_token/3 ###

`refresh_token(RealmUri, Issuer, RefreshToken) -> any()`

After refreshing a token, the previous refresh token will be revoked

<a name="revoke_token-3"></a>

### revoke_token/3 ###

<pre><code>
revoke_token(RealmUri::<a href="bondy_realm.md#type-uri">bondy_realm:uri()</a>, Issuer::binary(), RefreshToken::binary()) -&gt; ok
</code></pre>
<br />

<a name="verify_jwt-2"></a>

### verify_jwt/2 ###

<pre><code>
verify_jwt(RealmUri::binary(), JWT::binary()) -&gt; {ok, #{}} | {error, <a href="#type-error">error()</a>}
</code></pre>
<br />

<a name="verify_jwt-3"></a>

### verify_jwt/3 ###

<pre><code>
verify_jwt(RealmUri::binary(), JWT::binary(), Match0::#{}) -&gt; {ok, #{}} | {error, <a href="#type-error">error()</a>}
</code></pre>
<br />

