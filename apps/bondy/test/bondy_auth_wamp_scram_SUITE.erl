%% =============================================================================
%%  bondy_auth_wamp_scram_SUITE.erl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
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

-module(bondy_auth_wamp_scram_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("bondy_security.hrl").

-define(U1, <<"user_1">>).
-define(U2, <<"user_2">>).
-define(P1, <<"aWe11KeptSecret">>).
-define(P2, <<"An0therWe11KeptSecret">>).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        missing_client_nonce
        % ,
        % test_1
    ].


init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    RealmUri = <<"com.example.test.auth_wamp_scram">>,
    ok = add_realm(RealmUri),

    [{realm_uri, RealmUri} | Config].

end_per_suite(Config) ->
    % bondy_ct:stop_bondy(),
    {save_config, Config}.


add_realm(RealmUri) ->
    %% We use the same keys for both users (not to be done in real life)
    Config = #{
        uri => RealmUri,
        description => <<"A test realm">>,
        authmethods => [
            ?WAMP_SCRAM_AUTH
        ],
        security_enabled => true,
        grants => [
            #{
                permissions => [
                    <<"wamp.register">>,
                    <<"wamp.unregister">>,
                    <<"wamp.subscribe">>,
                    <<"wamp.unsubscribe">>,
                    <<"wamp.call">>,
                    <<"wamp.cancel">>,
                    <<"wamp.publish">>
                ],
                uri => <<"">>,
                match => <<"prefix">>,
                roles => <<"all">>
            }
        ],
        users => [
            #{
                username => ?U1,
                password => ?P1,
                groups => [],
                meta => #{}
            },
            #{
                username => ?U2,
                password => ?P1,
                groups => [],
                meta => #{}
            }
        ],
        sources => [
            #{
                usernames => [?U1],
                authmethod => ?WAMP_SCRAM_AUTH,
                cidr => <<"0.0.0.0/0">>
            },
            #{
                usernames => [?U2],
                authmethod => ?WAMP_SCRAM_AUTH,
                cidr => <<"198.162.0.0/16">>
            }
        ]
    },

    _ = bondy_realm:create(Config),

    ?assertEqual(
        scram,
        bondy_password:protocol(
            bondy_rbac_user:password(
                bondy_rbac_user:fetch(RealmUri, ?U1)

            )
        )
    ),

    dbg:stop(),
    ok.


missing_client_nonce(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),
    Roles = [],
    SourceIP = {127, 0, 0, 1},

    {ok, Ctxt1} = bondy_auth:init(SessionId, RealmUri, ?U1, Roles, SourceIP),
    ?assertEqual(
        true,
        lists:member(?WAMP_SCRAM_AUTH, bondy_auth:available_methods(Ctxt1))
    ),

    ?assertMatch(
        {error, missing_nonce},
        bondy_auth:challenge(?WAMP_SCRAM_AUTH, #{}, Ctxt1)
    ).


test_1(Config) ->

    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),
    Roles = [],
    SourceIP = {127, 0, 0, 1},

    {ok, Ctxt1} = bondy_auth:init(SessionId, RealmUri, ?U1, Roles, SourceIP),

    {ok, User} = bondy_rbac_user:lookup(RealmUri, ?U1),

    ?assertEqual(
        scram,
        bondy_password:protocol(bondy_rbac_user:password(User))
    ),
    ?assertEqual(
        true,
        lists:member(?WAMP_SCRAM_AUTH, bondy_auth:available_methods(Ctxt1))
    ),

    ClientNonce = crypto:strong_rand_bytes(16),
    HelloDetails = #{authextra => #{
        <<"nonce">> => base64:encode(ClientNonce)
    }},
    {true, ChallengeExtra, NewCtxt1} = bondy_auth:challenge(
        ?WAMP_SCRAM_AUTH, HelloDetails, Ctxt1
    ),

    % dbg:tracer(), dbg:p(all,c),
% dbg:tpl(bondy_auth_wamp_scram, '_', x),
    % dbg:tpl(bondy_password_scram, '_', x),

    Signature = client_signature(?U1, ClientNonce, ChallengeExtra),

    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(
            ?WAMP_SCRAM_AUTH, Signature, undefined, NewCtxt1
        )
    ),
    ?assertMatch(
        {error, invalid_signature},
        bondy_auth:authenticate(
            ?WAMP_SCRAM_AUTH, <<"foo">>, undefined, NewCtxt1
        )
    ),

    ?assertMatch(
        {error, method_not_allowed},
        bondy_auth:authenticate(?PASSWORD_AUTH, <<"foo">>, undefined, Ctxt1)
    ),

    ?assertMatch(
        {error, invalid_method},
        bondy_auth:authenticate(<<"foo">>, <<"foo">>, undefined, Ctxt1)
    ),

    %% user 2 is not granted access from SourceIP (see test_2)
    {ok, Ctxt2} = bondy_auth:init(SessionId, RealmUri, ?U2, Roles, SourceIP),

    ?assertEqual(
        false,
        lists:member(?PASSWORD_AUTH, bondy_auth:available_methods(Ctxt2))
    ),

    ?assertMatch(
        {error, method_not_allowed},
        bondy_auth:authenticate(?PASSWORD_AUTH, <<"foo">>, undefined, Ctxt2)
    ).


client_signature(UserId, ClientNonce, ChallengeExtra) ->
    #{
        nonce := ServerNonce, %% base64
        salt := Salt,  %% base64
        iterations := Iterations
    } = ChallengeExtra,

    AuthMessage = bondy_password_scram:auth_message(
        UserId, ClientNonce, ServerNonce, Salt, Iterations
    ),

    %% A hack to comply with bondy_password_scram API
    Params0 = maps:with([kdf, iterations, memory], ChallengeExtra),
    Params = Params0#{
        hash_function => bondy_password_scram:hash_function(),
        hash_length => bondy_password_scram:hash_length()
    },

    SPassword = bondy_password_scram:salted_password(?P1, Salt, Params),

    ClientKey = bondy_password_scram:client_key(SPassword),
    StoredKey =  bondy_password_scram:stored_key(ClientKey),
    ClientSignature = bondy_password_scram:client_signature(
        StoredKey, AuthMessage
    ),
    ClientProof = bondy_password_scram:client_proof(ClientKey, ClientSignature),

    base64:encode(ClientProof).


    % %% Server side
    % SClientSignature = bondy_password_scram:client_signature(
    %     ServerKey, AuthMessage
    % ),
    % RecClientKey = bondy_password_scram:recovered_client_key(
    %     ClientSignature, ClientProof
    % ),

    % StoredKey =:= bondy_password_scram:recovered_stored_key(RecClientKey);




    %   %% We simulate a client performing the challenge-response here as we have
    % %% been provided with the Password string via the Password authentication
    % %% message.
    % ServerNonce = bondy_password_scram:server_nonce(ClientNonce),

