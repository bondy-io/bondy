

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




### <a name="type-token_type">token_type()</a> ###


<pre><code>
token_type() = access_token | refresh_token
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#decode_jwt-1">decode_jwt/1</a></td><td></td></tr><tr><td valign="top"><a href="#generate_fragment-1">generate_fragment/1</a></td><td></td></tr><tr><td valign="top"><a href="#issue_token-6">issue_token/6</a></td><td>
Generates an access token and a refresh token.</td></tr><tr><td valign="top"><a href="#refresh_token-3">refresh_token/3</a></td><td>
After refreshing a token, the previous refresh token will be revoked.</td></tr><tr><td valign="top"><a href="#revoke_token-4">revoke_token/4</a></td><td></td></tr><tr><td valign="top"><a href="#revoke_user_token-5">revoke_user_token/5</a></td><td></td></tr><tr><td valign="top"><a href="#revoke_user_tokens-4">revoke_user_tokens/4</a></td><td></td></tr><tr><td valign="top"><a href="#verify_jwt-2">verify_jwt/2</a></td><td></td></tr><tr><td valign="top"><a href="#verify_jwt-3">verify_jwt/3</a></td><td></td></tr></table>


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

<a name="issue_token-6"></a>

### issue_token/6 ###

<pre><code>
issue_token(GrantType::<a href="#type-token_type">token_type()</a>, RealmUri::<a href="bondy_realm.md#type-uri">bondy_realm:uri()</a>, Issuer::binary(), Username::binary(), Groups::[binary()], Meta::#{}) -&gt; {ok, AccessToken::binary(), RefreshToken::binary(), Claims::#{}} | {error, any()}
</code></pre>
<br />

Generates an access token and a refresh token. The access token is a JWT
whereas the refresh token is a binary.
The function stores the refresh token in the store.

<a name="refresh_token-3"></a>

### refresh_token/3 ###

`refresh_token(RealmUri, Issuer, RefreshToken) -> any()`

After refreshing a token, the previous refresh token will be revoked

<a name="revoke_token-4"></a>

### revoke_token/4 ###

<pre><code>
revoke_token(Hint::<a href="#type-token_type">token_type()</a> | undefined, RealmUri::<a href="bondy_realm.md#type-uri">bondy_realm:uri()</a>, Issuer::binary(), TokenOrUsername::binary()) -&gt; ok | {error, unsupported_operation}
</code></pre>
<br />

<a name="revoke_user_token-5"></a>

### revoke_user_token/5 ###

<pre><code>
revoke_user_token(Hint::<a href="#type-token_type">token_type()</a> | undefined, RealmUri::<a href="bondy_realm.md#type-uri">bondy_realm:uri()</a>, Issuer::binary(), Username::binary(), DeviceId::non_neg_integer()) -&gt; ok | {error, unsupported_operation}
</code></pre>
<br />

<a name="revoke_user_tokens-4"></a>

### revoke_user_tokens/4 ###

<pre><code>
revoke_user_tokens(Hint::<a href="#type-token_type">token_type()</a> | undefined, RealmUri::<a href="bondy_realm.md#type-uri">bondy_realm:uri()</a>, Issuer::binary(), Username::binary()) -&gt; ok | {error, unsupported_operation | oauth2_invalid_grant}
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

