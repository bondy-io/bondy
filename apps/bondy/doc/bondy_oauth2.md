

# Module bondy_oauth2 #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

.

<a name="description"></a>

## Description ##

The following table documents the storage layout in plum_db of the token
data and its indices:

|Datum|Prefix|Key|Value|
|---|---|---|---|
|Refresh Token|{oauth2_refresh_tokens, Realm ++ "," ++ Issuer}|Token| TokenData|
|Refresh Token Index|{oauth2_refresh_tokens, Realm ++ "," ++ Issuer}|Token|Issuer|
|Refresh Token Index|{oauth2_refresh_tokens, Realm ++ "," ++ Issuer ++ "," ++ Username}|DeviceId| Token|

<a name="types"></a>

## Data Types ##




### <a name="type-error">error()</a> ###


<pre><code>
error() = oauth2_invalid_grant | no_such_realm
</code></pre>




### <a name="type-token_data">token_data()</a> ###


<pre><code>
token_data() = #bondy_oauth2_token{issuer = binary(), username = binary(), groups = [binary()], meta = map(), expires_in = pos_integer(), issued_at = pos_integer(), is_active = boolean}
</code></pre>




### <a name="type-token_type">token_type()</a> ###


<pre><code>
token_type() = access_token | refresh_token
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#decode_jwt-1">decode_jwt/1</a></td><td></td></tr><tr><td valign="top"><a href="#issue_token-6">issue_token/6</a></td><td>Generates an access token and a refresh token.</td></tr><tr><td valign="top"><a href="#issued_at-1">issued_at/1</a></td><td>Returns the timestamp for the token data.</td></tr><tr><td valign="top"><a href="#issuer-1">issuer/1</a></td><td>Returns the issuer a.k.a.</td></tr><tr><td valign="top"><a href="#lookup_token-3">lookup_token/3</a></td><td>Returns the data token_data() associated with <code>Token</code> or the tuple
<code>{error, not_found}</code>.</td></tr><tr><td valign="top"><a href="#rebuild_token_indices-2">rebuild_token_indices/2</a></td><td>Rebuilds refresh_token indices.</td></tr><tr><td valign="top"><a href="#refresh_token-3">refresh_token/3</a></td><td>
After refreshing a token, the previous refresh token will be revoked.</td></tr><tr><td valign="top"><a href="#revoke_dangling_tokens-2">revoke_dangling_tokens/2</a></td><td>Removes all refresh tokens whose user has been removed.</td></tr><tr><td valign="top"><a href="#revoke_refresh_token-3">revoke_refresh_token/3</a></td><td>Removes a refresh token from store using an index to match the function
arguments.</td></tr><tr><td valign="top"><a href="#revoke_refresh_token-4">revoke_refresh_token/4</a></td><td>Removes a refresh token from store using an index to match the function
arguments.</td></tr><tr><td valign="top"><a href="#revoke_refresh_tokens-2">revoke_refresh_tokens/2</a></td><td></td></tr><tr><td valign="top"><a href="#revoke_refresh_tokens-3">revoke_refresh_tokens/3</a></td><td></td></tr><tr><td valign="top"><a href="#revoke_token-4">revoke_token/4</a></td><td></td></tr><tr><td valign="top"><a href="#revoke_token-5">revoke_token/5</a></td><td></td></tr><tr><td valign="top"><a href="#revoke_tokens-3">revoke_tokens/3</a></td><td></td></tr><tr><td valign="top"><a href="#revoke_tokens-4">revoke_tokens/4</a></td><td></td></tr><tr><td valign="top"><a href="#verify_jwt-2">verify_jwt/2</a></td><td></td></tr><tr><td valign="top"><a href="#verify_jwt-3">verify_jwt/3</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="decode_jwt-1"></a>

### decode_jwt/1 ###

<pre><code>
decode_jwt(JWT::binary()) -&gt; map()
</code></pre>
<br />

<a name="issue_token-6"></a>

### issue_token/6 ###

<pre><code>
issue_token(GrantType::<a href="#type-token_type">token_type()</a>, RealmUri::<a href="bondy_realm.md#type-uri">bondy_realm:uri()</a>, Issuer::binary(), Username::binary(), Groups::[binary()], Meta::map()) -&gt; {ok, AccessToken::binary(), RefreshToken::binary(), Claims::map()} | {error, any()}
</code></pre>
<br />

Generates an access token and a refresh token.
The access token is a JWT whereas the refresh token is a binary.

The function stores the refresh token in the store and creates a number of
store indices.

<a name="issued_at-1"></a>

### issued_at/1 ###

<pre><code>
issued_at(Bondy_oauth2_token::<a href="#type-token_data">token_data()</a>) -&gt; pos_integer()
</code></pre>
<br />

Returns the timestamp for the token data.

<a name="issuer-1"></a>

### issuer/1 ###

<pre><code>
issuer(TokenData::<a href="#type-token_data">token_data()</a>) -&gt; binary()
</code></pre>
<br />

Returns the issuer a.k.a. ClientId of the token data.

<a name="lookup_token-3"></a>

### lookup_token/3 ###

<pre><code>
lookup_token(Realm::<a href="bondy_realm.md#type-uri">bondy_realm:uri()</a>, Issuer::binary(), Token::binary()) -&gt; <a href="#type-token_data">token_data()</a> | {error, not_found}
</code></pre>
<br />

Returns the data token_data() associated with `Token` or the tuple
`{error, not_found}`.

<a name="rebuild_token_indices-2"></a>

### rebuild_token_indices/2 ###

`rebuild_token_indices(RealmUri, Issuer) -> any()`

Rebuilds refresh_token indices.
This function is used for db maintenance.

<a name="refresh_token-3"></a>

### refresh_token/3 ###

<pre><code>
refresh_token(Realm::<a href="bondy_realm.md#type-uri">bondy_realm:uri()</a>, Issuer::binary(), Token::binary()) -&gt; {ok, AccessToken::binary(), RefreshToken::binary(), Claims::map()} | {error, oauth2_invalid_grant}
</code></pre>
<br />

After refreshing a token, the previous refresh token will be revoked

<a name="revoke_dangling_tokens-2"></a>

### revoke_dangling_tokens/2 ###

`revoke_dangling_tokens(RealmUri, Issuer) -> any()`

Removes all refresh tokens whose user has been removed.
This function is used for db maintenance.

<a name="revoke_refresh_token-3"></a>

### revoke_refresh_token/3 ###

<pre><code>
revoke_refresh_token(Realm::<a href="bondy_realm.md#type-uri">bondy_realm:uri()</a>, IssuerOrData::binary() | <a href="#type-token_data">token_data()</a>, Token::binary()) -&gt; ok
</code></pre>
<br />

Removes a refresh token from store using an index to match the function
arguments.
This also removes all store indices.

<a name="revoke_refresh_token-4"></a>

### revoke_refresh_token/4 ###

<pre><code>
revoke_refresh_token(RealmUri::<a href="bondy_realm.md#type-uri">bondy_realm:uri()</a>, Issuer::binary(), Username::binary(), DeviceId::binary()) -&gt; ok
</code></pre>
<br />

Removes a refresh token from store using an index to match the function
arguments.
This also removes all store indices.

<a name="revoke_refresh_tokens-2"></a>

### revoke_refresh_tokens/2 ###

<pre><code>
revoke_refresh_tokens(RealmUri::<a href="bondy_realm.md#type-uri">bondy_realm:uri()</a>, Username::binary()) -&gt; ok
</code></pre>
<br />

<a name="revoke_refresh_tokens-3"></a>

### revoke_refresh_tokens/3 ###

<pre><code>
revoke_refresh_tokens(RealmUri::<a href="bondy_realm.md#type-uri">bondy_realm:uri()</a>, Issuer::binary(), Username::binary()) -&gt; ok
</code></pre>
<br />

<a name="revoke_token-4"></a>

### revoke_token/4 ###

<pre><code>
revoke_token(Hint::<a href="#type-token_type">token_type()</a> | undefined, RealmUri::<a href="bondy_realm.md#type-uri">bondy_realm:uri()</a>, Issuer::binary(), TokenOrUsername::binary()) -&gt; ok | {error, unsupported_operation}
</code></pre>
<br />

<a name="revoke_token-5"></a>

### revoke_token/5 ###

<pre><code>
revoke_token(Hint::<a href="#type-token_type">token_type()</a> | undefined, RealmUri::<a href="bondy_realm.md#type-uri">bondy_realm:uri()</a>, Issuer::binary(), Username::binary(), DeviceId::non_neg_integer()) -&gt; ok | {error, unsupported_operation}
</code></pre>
<br />

<a name="revoke_tokens-3"></a>

### revoke_tokens/3 ###

<pre><code>
revoke_tokens(Hint::<a href="#type-token_type">token_type()</a> | undefined, Realm::<a href="bondy_realm.md#type-uri">bondy_realm:uri()</a>, Username::binary()) -&gt; ok | {error, unsupported_operation}
</code></pre>
<br />

<a name="revoke_tokens-4"></a>

### revoke_tokens/4 ###

<pre><code>
revoke_tokens(Hint::<a href="#type-token_type">token_type()</a> | undefined, RealmUri::<a href="bondy_realm.md#type-uri">bondy_realm:uri()</a>, Issuer::binary(), Username::binary()) -&gt; ok | {error, unsupported_operation}
</code></pre>
<br />

<a name="verify_jwt-2"></a>

### verify_jwt/2 ###

<pre><code>
verify_jwt(RealmUri::binary(), JWT::binary()) -&gt; {ok, map()} | {error, <a href="#type-error">error()</a>}
</code></pre>
<br />

<a name="verify_jwt-3"></a>

### verify_jwt/3 ###

<pre><code>
verify_jwt(RealmUri::binary(), JWTString::binary(), MatchSpec::map()) -&gt; {ok, map()} | {error, <a href="#type-error">error()</a>}
</code></pre>
<br />

