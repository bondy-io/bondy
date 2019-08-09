%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Basho Technologies, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

% -module(riak_core_pw_auth).
-module(bondy_security_pw).

-define(VERSION, <<"1.1">>).

%% TOOD should make these configurable in app.config
-define(SALT_LENGTH, 16).
-define(HASH_ITERATIONS, 65536).

-define(HASH_FUNCTION, sha256).
-define(AUTH_NAME, pbkdf2).
-define(KEY_LEN, 32).

-type auth_name()   ::  pbkdf2.
-type hash_fun()    ::  sha256.

-type t()   ::   #{
    version := binary(),
    auth_name => auth_name(),
    hash_func => hash_fun(),
    hash_pass => binary(),
    hash_len => ?KEY_LEN,
    iterations => non_neg_integer(),
    salt => binary()
}.

-export_type([t/0]).

-export([check_password/2]).
%% -export([check_password/5]).
-export([new/1]).
-export([new/5]).
-export([to_map/1]).
-export([upgrade/2]).

-export([hash_len/1]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Hash a plaintext password, returning t().
%% @end
%% -----------------------------------------------------------------------------
-spec new(binary()) -> t().

new(String) when is_binary(String) ->
    Salt = base64:encode(crypto:strong_rand_bytes(?SALT_LENGTH)),
    new(String, Salt, ?AUTH_NAME, ?HASH_FUNCTION, ?HASH_ITERATIONS).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(binary(), binary(), auth_name(), hash_fun(), pos_integer()) -> t().

new(String, Salt, pbkdf2 = AuthName, HashFun, HashIter)
when is_binary(String) andalso is_binary(Salt) andalso HashIter > 0 ->
    {ok, HashedPass} = pbkdf2:pbkdf2(HashFun, String, Salt, HashIter, ?KEY_LEN),
    HexPass = base64:encode(HashedPass),

    #{
        version => ?VERSION,
        hash_pass => HexPass,
        hash_len => ?KEY_LEN,
        auth_name => AuthName,
        hash_func => HashFun,
        salt => Salt,
        iterations => HashIter
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec to_map(L :: proplist:proplist()) -> t().

to_map(L) when is_list(L) ->
    maybe_add_version(maps:from_list(L));

to_map(#{} = Map) ->
    maybe_add_version(Map).

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec hash_len(t()) -> pos_integer().

hash_len(#{version := <<"1.0">>, hash_pass := Val}) ->
    %% hash_pass is hex formatted, so two chars per original char
    byte_size(Val) / 2;

hash_len(#{version := _} = PW) ->
    maps:get(hash_len, PW);

hash_len(#{} = PW) ->
    hash_len(maybe_add_version(PW)).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec upgrade(binary(), t() | proplists:proplist()) -> t().

upgrade(String, Pass) when is_binary(String) andalso is_list(Pass) ->
    %% Previously we stored passwords as proplists
    %% we convert to map regardless of version and
    %% continue with upgrade recursively.
    upgrade(String, maps:from_list(Pass));

upgrade({hash, _}, Pass) when is_map(Pass) ->
    %% We need the original password to be able to upgrade
    Pass;

upgrade(String, #{version := <<"1.0">>} = Pass0) when is_binary(String) ->

    #{
        auth_name := AuthName,
        iterations := HashIter,
        salt := Salt0
    } = Pass0,

    %% In version 1.0 the Salt was an erlang binary
    %% while in Version 1.1 we migrated to a base64 encoded binary
    Salt1 = base64:encode(Salt0),

    %% Also hash_func was sha and in version 1.1 is sha256,
    %% so we need to rehash the password.
    {ok, HashedPass0} = pbkdf2:pbkdf2(
        ?HASH_FUNCTION, String, Salt1, HashIter, ?KEY_LEN),

    %% HashedPass was hex, now base64 encoded
    HashedPass1 = base64:encode(HashedPass0),

    Pass1 = #{
        version => <<"1.1">>,
        hash_pass => HashedPass1,
        hash_len => ?KEY_LEN,
        auth_name => AuthName,
        hash_func => ?HASH_FUNCTION,
        salt => Salt1,
        iterations => HashIter
    },

    %% We continue with upgrade recursively.
    upgrade(String, Pass1);

upgrade(_, #{version := ?VERSION} = Pass) ->
    %% We finished upgrading to latest version
    Pass;

upgrade(String, #{} = Pass) when is_binary(String) ->
    %% In version 1.0, we had no 'version' property, so we add it
    %% and continue with upgrade recursively.
    upgrade(String, add_version(Pass)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec check_password(binary() | {hash, binary()}, t()) -> boolean().

check_password({hash, Hash}, #{version := <<"1.0">>} = PW)
when is_binary(Hash) ->
    #{hash_pass := StoredHash} = PW,
    %% StoredHash is hex value
    pbkdf2:compare_secure(pbkdf2:to_hex(Hash), StoredHash);

check_password({hash, Hash}, #{version := _} = PW)
when is_binary(Hash) ->
    #{hash_pass := StoredHash} = PW,
    %% StoredHash is base64 encoded
    pbkdf2:compare_secure(pbkdf2:to_hex(Hash), pbkdf2:to_hex(StoredHash));

check_password(String, #{version := <<"1.0">>} = PW)
when is_binary(String) ->
    #{
        hash_pass := StoredHash,
        hash_func := HashFun,
        iterations := HashIter,
        salt := Salt
    } = PW,
    {ok, Hash} = pbkdf2:pbkdf2(HashFun, String, Salt, HashIter),
    %% StoredHash is hex value
    pbkdf2:compare_secure(pbkdf2:to_hex(Hash), StoredHash);

check_password(String, #{version := _} = PW)
when is_binary(String) ->
    #{
        hash_pass := StoredHash,
        hash_func := HashFun,
        iterations := HashIter,
        salt := Salt
    } = PW,
    HashLen = hash_len(PW),
    %% We use keylen in version > 1.0
    {ok, Hash0} = pbkdf2:pbkdf2(HashFun, String, Salt, HashIter, HashLen),

    %% HashedPass was hex, now base64 encoded
    Hash1 = base64:encode(Hash0),
    pbkdf2:compare_secure(pbkdf2:to_hex(Hash1), pbkdf2:to_hex(StoredHash));

check_password(Term, #{} = PW) ->
    %% No version number
    check_password(Term, add_version(PW)).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
maybe_add_version(#{version := _} = Pass) ->
    Pass;

maybe_add_version(#{} = Pass) ->
    add_version(Pass).

%% @private
add_version(#{} = Pass) ->
    maps:put(version, <<"1.0">>, Pass).