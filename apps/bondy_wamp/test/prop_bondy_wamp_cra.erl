%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% @doc Property-based tests for bondy_wamp_cra (WAMP-CRA derivation and
%% response). The headline property is the client/server agreement: the
%% response a client computes from the raw password and CHALLENGE.Extra equals
%% the one a server derives from the stored salted password.
%% @end
-module(prop_bondy_wamp_cra).

-include_lib("proper/include/proper.hrl").

-export([
    prop_client_response_matches_server/0,
    prop_wrong_password_response_differs/0,
    prop_salted_password_deterministic/0
]).

%% =============================================================================
%% GENERATORS
%% =============================================================================

%% Keep PBKDF2 cost low so the property suite stays fast.
iterations() ->
    range(4096, 4196).

secret() ->
    non_empty(binary()).

%% =============================================================================
%% PROPERTIES
%% =============================================================================

%% The client response/3 (raw password + CHALLENGE.Extra) equals the server
%% response/2 (pre-salted password) for the same inputs.
prop_client_response_matches_server() ->
    ?FORALL(
        {Password, Salt, Iter, Challenge},
        {secret(), binary(16), iterations(), binary()},
        begin
            KeyLen = bondy_wamp_cra:hash_length(),
            Params = #{
                kdf => pbkdf2,
                iterations => Iter,
                hash_function => bondy_wamp_cra:hash_function(),
                hash_length => KeyLen
            },
            SPass = bondy_wamp_cra:salted_password(Password, Salt, Params),
            Server = bondy_wamp_cra:response(Challenge, SPass),
            Client = bondy_wamp_cra:response(Challenge, Password, #{
                salt => Salt, iterations => Iter, keylen => KeyLen
            }),
            Server =:= Client andalso bondy_wamp_cra:compare(Server, Client)
        end
    ).

%% A response computed with the wrong password differs from the expected one.
prop_wrong_password_response_differs() ->
    ?FORALL(
        {P1, P2, Salt, Iter, Challenge},
        {secret(), secret(), binary(16), iterations(), binary()},
        ?IMPLIES(
            P1 =/= P2,
            begin
                KeyLen = bondy_wamp_cra:hash_length(),
                Extra = #{salt => Salt, iterations => Iter, keylen => KeyLen},
                R1 = bondy_wamp_cra:response(Challenge, P1, Extra),
                R2 = bondy_wamp_cra:response(Challenge, P2, Extra),
                R1 =/= R2
            end
        )
    ).

%% salted_password is a pure function of (password, salt, params).
prop_salted_password_deterministic() ->
    ?FORALL(
        {Password, Salt, Iter},
        {secret(), binary(16), iterations()},
        begin
            Params = #{
                kdf => pbkdf2,
                iterations => Iter,
                hash_function => bondy_wamp_cra:hash_function(),
                hash_length => bondy_wamp_cra:hash_length()
            },
            A = bondy_wamp_cra:salted_password(Password, Salt, Params),
            B = bondy_wamp_cra:salted_password(Password, Salt, Params),
            A =:= B
        end
    ).
