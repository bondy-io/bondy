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
%% @doc A Password object stores a fixed size salted hash of a user's password
%% and all the metadata required to re-compute the salted hash for comparing a
%% user input and for implementing several password-based authentication
%% protocols.
%%
%% At the moment this module supports two protocols:
%% * WAMP Challenge-Response Authentication (CRA), and
%% * Salted Challenge-Response Authentication Mechanism (SCRAM)
%%
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_password).

%% We simply validate/convert the keys as maps_utils:validate does not have the
%% capability for nesting and unification yet
-define(OPTS_VALIDATOR, #{
    protocol => #{
        alias => <<"protocol">>,
        key => protocol,
        required => true,
        default => bondy_config:get([security, password, protocol]),
        datatype => {in, [cra, <<"cra">>, scram, <<"scram">>]},
        validator => fun bondy_data_validators:validate_existing_atom/1
    },
    params => #{
        alias => <<"params">>,
        key => params,
        required => false,
        datatype => map,
        validator => ?PARAMS_VALIDATOR
    }
}).

-define(PARAMS_VALIDATOR, #{
    kdf => #{
        alias => <<"kdf">>,
        key => kdf,
        required => true,
        default => bondy_config:get([security, password, scram, kdf]),
        datatype => {in, [pbkdf2, <<"pbkdf2">>, argon2id13, <<"argon2id13">>]},
        validator => fun bondy_data_validators:validate_existing_atom/1
    },
    iterations => #{
        alias => <<"iterations">>,
        key => iterations,
        required => false
    },
    memory => #{
        alias => <<"memory">>,
        key => memory,
        required => false
    }
}).


-define(VERSION, <<"1.2">>).


-type t()               ::  #{
                                version := binary(),
                                protocol := protocol(),
                                params := params(),
                                data := data()
                            }.
-type protocol()        ::  cra | scram.
-type params()          ::  bondy_password_cra:params()
                            | bondy_password_scram:params().
-type data()            ::  cra_data() | scram_data().
-type cra_data()        ::  #{
                                salt := binary(),
                                salted_password := binary()
                            }.
-type scram_data()      ::  #{
                                salt := binary(),
                                stored_key := binary(),
                                server_key := binary()
                            }.
-type opts()            ::  #{protocol := protocol(), params := params()}.


-export_type([t/0]).
-export_type([opts/0]).

-export([check_password/2]).
-export([new/1]).
-export([new/2]).

-export([to_map/1]).
-export([upgrade/2]).
-export([hash_length/1]).

-export([data/1]).
-export([params/1]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Creates a password object based on a plaintext password using the
%% default password protocol and params, returning `t()'.
%% @end
%% -----------------------------------------------------------------------------
-spec new(binary() | fun(() -> binary())) -> t() | no_return().

new(Password) ->
    Protocol = bondy_config:get([security, password, protocol]),
    KDF = bondy_config:get([security, password, Protocol, kdf]),
    KDFOpts = maps:from_list(bondy_config:get([security, password, KDF])),
    Params = maps:put(kdf, KDF, KDFOpts),
    Opts = #{protocol => Protocol, params => Params},
    new(Password, Opts).


%% -----------------------------------------------------------------------------
%% @doc Hash a plaintext password `Password' and the protocol and protocol
%% params defined in options `Opts', returning t().
%% @end
%% -----------------------------------------------------------------------------
-spec new(binary() | fun(() -> binary()), opts()) -> t() | no_return().

new(Fun, Opts0) when is_function(Fun, 1) ->
    new(Fun(), Opts0);

new(Password, Opts0) ->
    Opts = maps_utils:validate(Opts0, ?OPTS_VALIDATOR),
    Params = maps:get(params, Opts, #{}),

    case maps:get(protocol, Opts) of
        cra ->
            new_cra(Password, Params);
        scram ->
            new_scram(Password, Params)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec params(t()) -> params().

params(#{version := ?VERSION, params := Value}) ->
    Value.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec data(t()) -> data().

data(#{version := ?VERSION, data := Value}) ->
    Value.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec hash_length(t()) -> pos_integer().

hash_length(#{version := <<"1.0">>, hash_pass := Val}) ->
    %% hash_pass is hex formatted, so two chars per original char
    byte_size(Val) / 2;

hash_length(#{version := <<"1.1">>, hash_len := Val}) ->
    Val;

hash_length(#{version := ?VERSION, params := #{hash_length := Val}}) ->
    Val;

hash_length(#{} = PW) ->
    hash_length(maybe_add_version(PW)).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec to_map(Term :: proplist:proplist() | map()) -> t().

to_map(Term) when is_list(Term) ->
    maybe_add_version(maps:from_list(Term));

to_map(Term) when is_map(Term) ->
    maybe_add_version(Term).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec check_password(binary() | {hash, binary()}, t()) -> boolean().

check_password({hash, Hash}, #{version := <<"1.2">>, protocol := cra} = PW)
when is_binary(Hash) ->
    SPassword = maps_utils:get([data, salted_password], PW),
    pbkdf2:compare_secure(pbkdf2:to_hex(Hash), pbkdf2:to_hex(SPassword));

check_password(String, #{version := <<"1.2">>, protocol := cra} = PW)
when is_binary(String) ->
    #{
        data := #{
            salt := Salt,
            salted_password := SPassword
        },
        params := Params
    } = PW,

    Hash = bondy_password_cra:salted_password(String, Salt, Params),
    bondy_password_cra:compare(Hash, SPassword);

check_password({hash, Hash}, #{version := <<"1.1">>} = PW)
when is_binary(Hash) ->
    #{hash_pass := StoredHash} = PW,
    %% StoredHash is base64 encoded
    pbkdf2:compare_secure(pbkdf2:to_hex(Hash), pbkdf2:to_hex(StoredHash));

check_password(String, #{version := <<"1.1">>} = PW) when is_binary(String) ->
    #{
        hash_pass := StoredHash,
        hash_func := HashFun,
        iterations := HashIter,
        salt := Salt
    } = PW,
    HashLen = hash_length(PW),
    %% We use keylen in version > 1.0
    {ok, Hash0} = pbkdf2:pbkdf2(HashFun, String, Salt, HashIter, HashLen),

    %% StoredHash is base64 encoded
    Hash1 = base64:encode(Hash0),
    pbkdf2:compare_secure(pbkdf2:to_hex(Hash1), pbkdf2:to_hex(StoredHash));

check_password({hash, Hash}, #{version := <<"1.0">>} = PW)
when is_binary(Hash) ->
    #{hash_pass := StoredHash} = PW,
    %% StoredHash is hex value
    pbkdf2:compare_secure(pbkdf2:to_hex(Hash), StoredHash);

check_password(String, #{version := <<"1.0">>} = PW) when is_binary(String) ->
    #{
        hash_pass := StoredHash,
        hash_func := HashFun,
        iterations := HashIter,
        salt := Salt
    } = PW,
    {ok, Hash} = pbkdf2:pbkdf2(HashFun, String, Salt, HashIter),
    %% StoredHash is hex value
    pbkdf2:compare_secure(pbkdf2:to_hex(Hash), StoredHash);

check_password(Term, #{} = PW) ->
    %% No version number
    check_password(Term, add_version(PW)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec upgrade(
    String :: tuple() | binary(), T0 :: map() | proplists:proplist()) ->
    {true, T1 :: t()} | false.

upgrade(Term, BP) when is_list(BP) ->
    upgrade(Term, to_map(BP));

upgrade(_, #{version := ?VERSION}) ->
    false;

upgrade(Term, #{version := Version} = BP) ->
    case do_upgrade(Term, BP) of
        #{version := Version} ->
            false;
        NewBP ->
            {true, NewBP}
    end.





%% =============================================================================
%% PRIVATE: MIGRATIONS
%% =============================================================================


%% @private
maybe_add_version(#{version := _} = Pass) ->
    Pass;

maybe_add_version(#{} = Pass) ->
    add_version(Pass).

%% @private
add_version(#{} = Pass) ->
    %% Version 1.0 was implicit, we make it explicit so that we can upgrade
    maps:put(version, <<"1.0">>, Pass).




do_upgrade(_, #{version := ?VERSION} = Pass) ->
    %% We finished upgrading to latest version
    Pass;

do_upgrade({hash, _}, #{version := <<"1.0">>} = Pass) ->
    %% We need the original password to be able to upgrade to 1.1
    Pass;

do_upgrade({hash, SPassword}, #{version := <<"1.1">>} = Pass0) ->
    %% TODO check if we need to base64:decode
    #{
        hash_pass := SPassword,
        hash_len := HashLen,
        auth_name := pbkdf2,
        salt := Salt,
        iterations := Iterations
    } = Pass0,

    Pass1 = #{
        version => <<"1.2">>,
        protocol => cra,
        params => #{
            kdf => pbkdf2,
            salt_length => bondy_auth_wamp_cra:salt_length(),
            hash_length => HashLen,
            hash_function => bondy_password_cra:hash_function(),
            iterations => Iterations
        },
        data => #{
            salt => Salt,
            salted_password => SPassword
        }
    },
    do_upgrade({hash, SPassword}, Pass1);

do_upgrade(String, #{version := Version} = Pass0) when is_binary(String) ->
    UpgradeProtocol = bondy_config:get(
        [security, password, protocol_upgrade_enabled]
    ),
    case UpgradeProtocol of
        true ->
            do_upgrade(String, new(String));

        false when Version =:= <<"1.0">> ->
            do_upgrade(String, new(String, #{protocol => cra}));

        false when Version =:= <<"1.1">> ->
            SPassword = maps:get(hash_pass, Pass0),
            do_upgrade({hash, SPassword}, Pass0)
    end;

do_upgrade(String, #{} = Pass) when is_binary(String) ->
    %% In version 1.0, we had no 'version' property, so we add it
    %% and continue with upgrade recursively.
    do_upgrade(String, add_version(Pass));

do_upgrade(String, Pass) when is_binary(String) andalso is_list(Pass) ->
    %% Originally we stored passwords as proplists
    %% we convert to map regardless of version and
    %% continue with upgrade recursively.
    do_upgrade(String, maps:from_list(Pass)).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
-spec new_cra(binary(), bondy_password_cra:params()) -> t() | no_return().

new_cra(Password, Params0) ->
    Params = bondy_password_cra:validate_params(Params0),
    Salt = bondy_password_cra:salt(),
    SPassword = bondy_password_cra:salted_password(Password, Salt, Params),
    #{
        version => ?VERSION,
        protocol => cra,
        params => Params,
        data => #{
            salt => Salt,
            salted_password => SPassword
        }
    }.


%% @private
-spec new_scram(binary(), bondy_password_scram:params()) -> t() | no_return().

new_scram(Password, Params0) ->
    Params = bondy_password_scram:validate_params(Params0),
    Salt = bondy_password_scram:salt(),
    SPassword = bondy_password_scram:salted_password(Password, Salt, Params),
    ServerKey = bondy_password_scram:server_key(SPassword),
    ClientKey = bondy_password_scram:client_key(SPassword),
    StoredKey = bondy_password_scram:stored_key(ClientKey),

    #{
        version => ?VERSION,
        protocol => scram,
        params => Params,
        data => #{
            salt => Salt,
            stored_key => StoredKey,
            server_key => ServerKey
        }
    }.