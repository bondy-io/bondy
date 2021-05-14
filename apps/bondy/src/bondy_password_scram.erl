%% =============================================================================
%%  bondy_password_scram.erl -
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
%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_password_scram).


-type data()      ::  #{
    salt := binary(),
    stored_key := binary(),
    server_key := binary()
}.
-type params()    ::  #{
    kdf := kdf(),
    iterations := non_neg_integer(),
    memory => non_neg_integer(),
    hash_function := hash_fun(),
    hash_length := non_neg_integer(),
    salt_length := non_neg_integer()
}.
-type kdf()             ::  pbkdf2 | argon2id13.
-type hash_fun()        ::  sha256.

-export_type([data/0]).
-export_type([params/0]).

-export([auth_message/5]).
-export([auth_message/7]).
-export([check_proof/4]).
-export([client_key/1]).
-export([client_proof/2]).
-export([client_signature/2]).
-export([hash_function/0]).
-export([hash_length/0]).
-export([new/3]).
-export([recovered_client_key/2]).
-export([recovered_stored_key/1]).
-export([salt/0]).
-export([salt_length/0]).
-export([salted_password/3]).
-export([server_key/1]).
-export([server_nonce/1]).
-export([server_signature/2]).
-export([stored_key/1]).
-export([validate_params/1]).
-export([verify_string/3]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(binary(), params(), fun((data(), params()) -> bondy_password:t())) ->
    bondy_password:t() | no_return().

new(String, Params0, Builder) when is_function(Builder, 2) ->
    Params = validate_params(Params0),
    Salt = salt(),
    SPassword = salted_password(String, Salt, Params),
    ServerKey = server_key(SPassword),
    ClientKey = client_key(SPassword),
    StoredKey = stored_key(ClientKey),
    Data = #{
        salt => Salt,
        stored_key => StoredKey,
        server_key => ServerKey
    },

    Builder(Data, Params).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec verify_string(binary(), data(), params()) -> boolean().

verify_string(String, Data, Params) ->
    #{
        salt := Salt,
        stored_key := StoredKey
    } = Data,

    SPassword = salted_password(String, Salt, Params),
    ClientKey = client_key(SPassword),
    CStoredKey = stored_key(ClientKey),
    CStoredKey =:= StoredKey.


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
    Params3 = validate_memory(Params2),
    maps:merge(Params3, Static).


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
-spec salt() -> Salt :: binary().

salt() ->
    enacl:randombytes(salt_length()).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec server_nonce(ClientNonce :: binary()) -> ServerNonce :: binary().

server_nonce(ClientNonce) ->
    <<ClientNonce/binary, (enacl:randombytes(16))/binary>>.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec salted_password(
    Password :: binary(),
    Salt :: binary(),
    Params :: params()) -> SaltedPassword :: binary().

salted_password(Password, Salt, #{kdf := argon2id13} = Params) ->
    Normalized = stringprep:resourceprep(Password),
    #{
        kdf := KDF,
        iterations := Iterations,
        memory := Memory
    } = Params,
    enacl:pwhash(Normalized, Salt, Iterations, Memory, KDF);

salted_password(Password, Salt, #{kdf := pbkdf2} = Params) ->
    Normalized = stringprep:resourceprep(Password),
    #{
        iterations := Iterations,
        hash_function := HashFun,
        hash_length := HashLen
    } = Params,

    {ok, SaltedPassword} = pbkdf2:pbkdf2(
        HashFun, Normalized, Salt, Iterations, HashLen
    ),
    SaltedPassword.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec client_key(SaltedPassword :: binary()) -> ClientKey :: binary().

client_key(SaltedPassword) ->
    crypto:mac(hmac, hash_function(), SaltedPassword, <<"Client Key">>).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec stored_key(ClientKey :: binary()) -> StoredKey :: binary().

stored_key(ClientKey) ->
    crypto:hash(hash_function(), ClientKey).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec client_signature(StoredKey :: binary(), AuthMessage :: binary()) ->
    ClientSignature :: binary().

client_signature(StoredKey, AuthMessage) ->
    crypto:mac(hmac, hash_function(), StoredKey, AuthMessage).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec client_proof(ClientKey :: binary(), ClientSignature :: binary()) ->
    ClientProof :: binary().

client_proof(ClientKey, ClientSignature)
when is_binary(ClientKey), is_binary(ClientSignature) ->
    crypto:exor(ClientKey, ClientSignature).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec recovered_client_key(
    ReceivedClientProof :: binary(), ClientSignature :: binary()) ->
    RecoveredClientKey :: binary().

recovered_client_key(ReceivedClientProof, ClientSignature)
when is_binary(ReceivedClientProof) andalso is_binary(ClientSignature) ->
    crypto:exor(ReceivedClientProof, ClientSignature).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec recovered_stored_key(RecoveredClientKey :: binary()) ->
    RecoveredStoredKey :: binary().

recovered_stored_key(RecoveredClientKey) when is_binary(RecoveredClientKey) ->
    crypto:hash(hash_function(), RecoveredClientKey).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec server_key(SaltedPassword :: binary()) -> ServerKey :: binary().

server_key(SaltedPassword) ->
    crypto:mac(hmac, hash_function(), SaltedPassword, <<"Server Key">>).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec server_signature(ServerKey :: binary(), AuthMessage :: binary()) ->
    ClientSignature :: binary().

server_signature(ServerKey, AuthMessage) ->
    crypto:mac(hmac, hash_function(), ServerKey, AuthMessage).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec check_proof(
    ProvidedProof :: binary(),
    ClientProof :: binary(),
    ClientSignature :: binary(),
    StoredKey :: binary()) ->
    boolean().

check_proof(ProvidedProof, ClientProof, _, _)
when ProvidedProof =:= ClientProof ->
    true;

check_proof(ProvidedProof, _, ClientSignature, StoredKey) ->
    stored_key(client_proof(ProvidedProof, ClientSignature)) =:= StoredKey.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
auth_message(AuthId, ClientNonce, RouterNonce, Salt, Iterations) ->
    auth_message(AuthId, ClientNonce, RouterNonce, Salt, Iterations, "", "").


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
auth_message(
    AuthId, ClientNonce, RouterNonce, Salt, Iterations, CBindName, CBindData) ->

    iolist_to_binary([
        client_first_bare(AuthId, ClientNonce), ",",
        server_first(RouterNonce, Salt, Iterations), ",",
        client_final_no_proof(CBindName, CBindData, RouterNonce)
    ]).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
validate_kdf(#{kdf := pbkdf2} = Params) ->
    Params;

validate_kdf(#{kdf := argon2id13} = Params) ->
    Params;

validate_kdf(#{kdf := _}) ->
    error({invalid_argument, kdf});

validate_kdf(Params) ->
    Default = bondy_config:get([security, password, scram, kdf]),
    maps:put(kdf, Default, Params).


%% @private
validate_iterations(#{kdf := KDF, iterations := Value} = Params) ->
    N = iterations_to_integer(KDF, Value),
    maps:put(iterations, N, Params);

validate_iterations(#{kdf := KDF} = Params) ->
    Default = iterations_to_integer(
        KDF,
        bondy_config:get([security, password, KDF, iterations])
    ),
    maps:put(iterations, Default, Params).


%% @private
validate_memory(#{kdf := KDF, memory := Value} = Params) ->
    N = memory_to_integer(KDF, Value),
    maps:put(memory, N, Params);

validate_memory(#{kdf := KDF} = Params) ->
    Default = memory_to_integer(
        KDF,
        bondy_config:get([security, password, KDF, memory], undefined)
    ),
    maps:put(memory, Default, Params).


%% @private
iterations_to_integer(pbkdf2, N) when is_integer(N) ->
    N >= 4096 andalso N =< 65536 orelse error({invalid_argument, iterations}),
    N;

iterations_to_integer(argon2id13, Name) when is_atom(Name) ->
    %% We convert names to their values according to
    %% https://github.com/jedisct1/libsodium/blob/master/src/libsodium/include/sodium/crypto_pwhash_argon2id.h
    case Name of
        interactive -> 2;
        moderate -> 3;
        sensitive -> 4;
        _ -> error({invalid_argument, iterations})
    end;

iterations_to_integer(argon2id13, N) when is_integer(N) ->
    N >= 1 andalso N =< 4294967295 orelse error({invalid_argument, iterations}),
    N;

iterations_to_integer(_, _) ->
    error({invalid_argument, iterations}).


%% @private
memory_to_integer(pbkdf2, _) ->
    undefined;

memory_to_integer(argon2id13, undefined) ->
    memory_to_integer(argon2id13, interactive);

memory_to_integer(argon2id13, Name) when is_atom(Name) ->
    %% We convert names to their values according to
    %% https://github.com/jedisct1/libsodium/blob/master/src/libsodium/include/sodium/crypto_pwhash_argon2id.h
    case Name of
        interactive -> 67108864;
        moderate -> 268435456;
        sensitive -> 1073741824;
        _ -> error({invalid_argument, memory})
    end;

memory_to_integer(argon2id13, N) when is_integer(N) ->
    %% Notice that the underlying library (libsodium) allows up to
    %% 4398046510080 but we have restricted this value to avoid a configuration
    %% error to enable a DoS attack.
    N >= 8192 andalso N =< 1073741824 orelse error({invalid_argument, memory}),
    N;

memory_to_integer(_, _) ->
    error({invalid_argument, memory}).



%% @private
client_first_bare(AuthId, Nonce) ->
    [
        "n=", stringprep:resourceprep(escape(AuthId)), ",",
        "r=", base64:encode(Nonce)
    ].


%% @private
server_first(RouterNonce, Salt, Iterations) ->
    [
        "r=", RouterNonce, ",",
        "s=", base64:encode(Salt), ",",
        "i=", integer_to_binary(Iterations)
    ].


%% @private
client_final_no_proof(CBindName, CBindData, RouterNonce) ->
    CBindFlag = channel_binding_flag(CBindName),
    CBindInput = channel_binding_input(CBindFlag, CBindData),
    [
        "c=", CBindInput, ",",
        "r=", base64:encode(RouterNonce)
    ].


%% @private
channel_binding_input(CBindFlag, "") ->
    channel_binding_input(CBindFlag, undefined);

channel_binding_input(CBindFlag, undefined) ->
    [CBindFlag, ",,", ""];

channel_binding_input(CBindFlag, CBindData) ->
    [CBindFlag, ",,", base64:decode(CBindData)].


%% @private
channel_binding_flag("") ->
    channel_binding_flag(undefined);

channel_binding_flag(undefined) ->
    ["n"];

channel_binding_flag(CBindName) ->
    ["p=", CBindName].


%% @private
%% Replace every occurrence of "," and "=" in the given string
%% with "=2C" and "=3D" respectively.
escape(Bin0) ->
    Bin1 = binary:replace(Bin0, <<"=">>, <<"=3D">>, [global]),
    binary:replace(Bin1, <<",">>, <<"=2C">>, [global]).