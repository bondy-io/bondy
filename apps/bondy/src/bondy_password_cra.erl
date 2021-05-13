%% =============================================================================
%%  bondy_password_cra.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================

-module(bondy_password_cra).

-type params()    ::  #{
    kdf := kdf(),
    iterations := non_neg_integer(),
    hash_function := hash_fun(),
    hash_length := non_neg_integer(),
    salt_length := non_neg_integer()
}.
-type kdf()             ::  pbkdf2.
-type hash_fun()        ::  sha256.

-export_type([params/0]).

-export([compare/2]).
-export([hash_function/0]).
-export([hash_length/0]).
-export([nonce/0]).
-export([nonce_length/0]).
-export([salt/0]).
-export([salt_length/0]).
-export([salted_password/3]).
-export([validate_params/1]).




%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec validate_params(Params :: params()) ->
    Validated :: params() | no_return().

validate_params(Params0) ->
    Static = #{
        hash_function => hash_function(),
        hash_length => hash_length(),
        salt_length => salt_length()
    },
    Params1 = validate_kdf(Params0),
    Params2 = validate_iterations(Params1),
    maps:merge(Params2, Static).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec hash_function() -> atom().

hash_function() ->
    sha256.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec hash_length() -> integer().

hash_length() ->
    32.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec salt_length() -> integer().

salt_length() ->
    16.

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec nonce_length() -> integer().

nonce_length() ->
    16.


%% -----------------------------------------------------------------------------
%% @doc A base64 encoded 128-bit random value.
%% @end
%% -----------------------------------------------------------------------------
-spec salt() -> binary().

salt() ->
    enacl:randombytes(salt_length()).


%% -----------------------------------------------------------------------------
%% @doc A base64 encoded 128-bit random value.
%% @end
%% -----------------------------------------------------------------------------
-spec nonce() -> binary().

nonce() ->
    base64:encode(enacl:randombytes(nonce_length())).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec salted_password(binary(), binary(), map()) -> binary().

salted_password(Password, Salt, #{kdf := pbkdf2} = Params) ->
    #{
        iterations := Iterations,
        hash_function := HashFun,
        hash_length := HashLen
    } = Params,

    {ok, SaltedPassword} = pbkdf2:pbkdf2(
        HashFun, Password, Salt, Iterations, HashLen
    ),
    SaltedPassword.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec compare(binary(), binary()) -> boolean().

compare(A, B) ->
    pbkdf2:compare_secure(pbkdf2:to_hex(A), pbkdf2:to_hex(B)).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
validate_kdf(#{kdf := pbkdf2} = Params) ->
    Params;

validate_kdf(#{kdf := _}) ->
    error({invalid_argument, kdf});

validate_kdf(Params) ->
    Default = bondy_config:get([security, password, cra, kdf]),
    maps:put(kdf, Default, Params).


%% @private
validate_iterations(#{iterations := N} = Params)
when N >= 4096 andalso N =< 65536 ->
    Params;

validate_iterations(#{iterations := _}) ->
    exit({invalid_argument, iterations});

validate_iterations(Params) ->
    Default = bondy_config:get([security, password, pbkdf2, iterations]),
    maps:put(iterations, Default, Params).