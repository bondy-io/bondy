%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_password_scram).
-moduledoc """
This module provides the functions and algorithms to operate with the
Salted Challenge-Reponse Mechanism data structures.
""".

-define(SALT_LENGTH, 16).

-type data() :: #{
    salt := binary(),
    stored_key := binary(),
    server_key := binary()
}.
-type params() :: #{
    kdf := kdf(),
    iterations := non_neg_integer(),
    memory => non_neg_integer(),
    hash_function := hash_fun(),
    hash_length := non_neg_integer(),
    salt := binary(),
    salt_length := non_neg_integer()
}.
%% OPTION RETIRED UNTIL NEW IMPLEMENTATION IS DONE
-type kdf() :: pbkdf2.
-type hash_fun() :: sha256.

-export_type([data/0]).
-export_type([params/0]).

-export([auth_message/5]).
-export([auth_message/7]).
-export([check_proof/4]).
-export([compare/2]).
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

-spec new(binary(), params(), fun((data(), params()) -> bondy_password:t())) ->
    bondy_password:t() | no_return().

new(String, Params0, Builder) when is_function(Builder, 2) ->
    Params1 = validate_params(Params0),

    {Salt, Params} =
        case maps:take(salt, Params1) of
            {Bytes, Params2} ->
                byte_size(Bytes) == salt_length() orelse error(badarg),
                %% REVIEW salt as based64
                {Bytes, Params2};
            error ->
                {salt(), Params1}
        end,

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

-spec verify_string(binary(), data(), params()) -> boolean().

verify_string(String, Data, Params) ->
    #{
        salt := Salt,
        stored_key := StoredKey
    } = Data,

    SPassword = salted_password(String, Salt, Params),
    ClientKey = client_key(SPassword),
    CStoredKey = stored_key(ClientKey),
    compare(CStoredKey, StoredKey).

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

-spec hash_function() -> atom().

hash_function() ->
    sha256.

-spec hash_length() -> integer().

hash_length() ->
    32.

-spec salt_length() -> integer().

salt_length() ->
    ?SALT_LENGTH.

-spec salt() -> Salt :: binary().

salt() ->
    %% REVIEW salt as based64
    crypto:strong_rand_bytes(salt_length()).

-spec server_nonce(ClientNonce :: binary()) -> ServerNonce :: binary().

server_nonce(ClientNonce) ->
    <<ClientNonce/binary, (crypto:strong_rand_bytes(16))/binary>>.

-spec salted_password(
    Password :: binary(),
    Salt :: binary(),
    Params :: params()
) -> SaltedPassword :: binary().

salted_password(Password, Salt, #{kdf := pbkdf2} = Params) ->
    Normalised = stringprep:resourceprep(Password),
    #{
        iterations := Iterations,
        hash_function := HashFun,
        hash_length := HashLen
    } = Params,

    crypto:pbkdf2_hmac(HashFun, Normalised, Salt, Iterations, HashLen).

-spec client_key(SaltedPassword :: binary()) -> ClientKey :: binary().

client_key(SaltedPassword) ->
    crypto:mac(hmac, hash_function(), SaltedPassword, <<"Client Key">>).

-spec stored_key(ClientKey :: binary()) -> StoredKey :: binary().

stored_key(ClientKey) ->
    crypto:hash(hash_function(), ClientKey).

-spec client_signature(StoredKey :: binary(), AuthMessage :: binary()) ->
    ClientSignature :: binary().

client_signature(StoredKey, AuthMessage) when
    is_binary(StoredKey), is_binary(AuthMessage)
->
    crypto:mac(hmac, hash_function(), StoredKey, AuthMessage).

-doc """
Constant-time comparison of two binaries.

Mirrors `bondy_wamp_cra:compare/2`. The length check is required because
`crypto:hash_equals/2` raises `badarg` on operands of different sizes, and a
SCRAM proof arrives from the wire at whatever length the client chose. A
length difference is already known to the sender, so answering `false` early
reveals nothing; equal-length operands take the constant-time path, which is
what stops the comparison leaking where two same-length values first differ.
""".
-spec compare(binary(), binary()) -> boolean().

compare(A, B) when is_binary(A), is_binary(B), byte_size(A) =:= byte_size(B) ->
    crypto:hash_equals(A, B);
compare(A, B) when is_binary(A), is_binary(B) ->
    false.

-doc """
Computes the client proof out of the client key `Key` and the client signature
`Signature`. See `client_key/2` and `client_signature/2` respectively.
""".
-spec client_proof(Key :: binary(), Signature :: binary()) ->
    ClientProof :: binary().

client_proof(Key, Signature) when is_binary(Key), is_binary(Signature) ->
    crypto:exor(Key, Signature).

-spec recovered_client_key(
    ClientProof :: binary(), ClientSignature :: binary()
) ->
    RecoveredClientKey :: binary().

recovered_client_key(ClientProof, ClientSignature) when
    is_binary(ClientProof) andalso is_binary(ClientSignature)
->
    crypto:exor(ClientProof, ClientSignature).

-spec recovered_stored_key(RecoveredClientKey :: binary()) ->
    RecoveredStoredKey :: binary().

recovered_stored_key(RecoveredClientKey) when is_binary(RecoveredClientKey) ->
    crypto:hash(hash_function(), RecoveredClientKey).

-spec server_key(SaltedPassword :: binary()) -> ServerKey :: binary().

server_key(SaltedPassword) ->
    crypto:mac(hmac, hash_function(), SaltedPassword, <<"Server Key">>).

-spec server_signature(ServerKey :: binary(), AuthMessage :: binary()) ->
    ClientSignature :: binary().

server_signature(ServerKey, AuthMessage) ->
    crypto:mac(hmac, hash_function(), ServerKey, AuthMessage).

-spec check_proof(
    ProvidedProof :: binary(),
    ClientProof :: binary(),
    ClientSignature :: binary(),
    StoredKey :: binary()
) ->
    boolean().

check_proof(ProvidedProof, ClientProof, ClientSignature, StoredKey) ->
    %% SECURITY: both comparisons are constant time. The first short-circuits
    %% the common case; the second recovers the stored key from the proof.
    %% `client_proof/2` is `crypto:exor/2`, which raises on operands of
    %% different sizes, so a proof of the wrong length is rejected here rather
    %% than crashing the caller.
    compare(ProvidedProof, ClientProof) orelse
        byte_size(ProvidedProof) =:= byte_size(ClientSignature) andalso
            compare(
                stored_key(client_proof(ProvidedProof, ClientSignature)),
                StoredKey
            ).

auth_message(AuthId, ClientNonce, ServerNonce, Salt, Iterations) ->
    auth_message(AuthId, ClientNonce, ServerNonce, Salt, Iterations, "", "").

auth_message(
    AuthId, ClientNonce, ServerNonce, Salt, Iterations, CBindName, CBindData
) ->
    iolist_to_binary([
        client_first_bare(AuthId, ClientNonce),
        ",",
        server_first(ServerNonce, Salt, Iterations),
        ",",
        client_final_no_proof(CBindName, CBindData, ServerNonce)
    ]).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
validate_kdf(#{kdf := pbkdf2} = Params) ->
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
    N >= 4096 andalso N =< 10000000 orelse
        error({invalid_argument, iterations}),
    N;
iterations_to_integer(_, _) ->
    error({invalid_argument, iterations}).

%% @private
memory_to_integer(pbkdf2, _) ->
    undefined;
memory_to_integer(_, _) ->
    error({invalid_argument, memory}).

%% @private
client_first_bare(AuthId, ClientNonce) ->
    [
        "n=",
        stringprep:resourceprep(escape(AuthId)),
        ",",
        "r=",
        base64:encode(ClientNonce)
    ].

%% @private
server_first(ServerNonce, Salt, Iterations) ->
    [
        "r=",
        base64:encode(ServerNonce),
        ",",
        "s=",
        base64:encode(Salt),
        ",",
        "i=",
        integer_to_binary(Iterations)
    ].

%% @private
client_final_no_proof(CBindName, CBindData, ServerNonce) ->
    CBindFlag = channel_binding_flag(CBindName),
    CBindInput = channel_binding_input(CBindFlag, CBindData),
    [
        "c=",
        base64:encode(iolist_to_binary(CBindInput)),
        ",",
        "r=",
        base64:encode(ServerNonce)
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
