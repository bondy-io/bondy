%% =============================================================================
%%  bondy_SUITE.erl -
%%
%%  Copyright (c) 2016-2022 Leapsight. All rights reserved.
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

-module(bondy_security_SUITE).
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
        {group, api_client},
        {group, resource_owner},
        {group, user},
        {group, oauth}
    ].

groups() ->
    [
        {api_client, [sequence], [
            security_toggle,
            create_groups,
            api_client_add,
            api_client_auth1,
            api_client_update,
            api_client_auth2,
            api_client_delete
        ]},
        {resource_owner, [sequence], [
            resource_owner_add,
            resource_owner_auth1,
            resource_owner_update,
            resource_owner_change_password,
            resource_owner_auth2,
            resource_owner_auth3,
            resource_owner_delete
        ]},
        {user, [sequence], [
            user_add,
            user_auth1,
            user_update,
            user_auth2,
            user_auth3,
            user_delete
        ]},
        {oauth, [sequence], [
            password_token_crud_1,
            issue_revoke_by_device_id,
            issue_refresh_revoke_by_device_id
        ]}
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    RealmUri = <<"com.example.test.security">>,
    Realm = add_realm(RealmUri),
    [{realm_uri, RealmUri}, {realm, Realm} |Config].

end_per_suite(Config) ->
    bondy_ct:stop_bondy(),
    {save_config, Config}.


add_realm(RealmUri) ->
    Config = #{
        uri => RealmUri,
        description => <<"A test realm">>,
        authmethods => [
            ?PASSWORD_AUTH, ?OAUTH2_AUTH
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
                usernames => <<"all">>,
                authmethod => ?PASSWORD_AUTH,
                cidr => <<"0.0.0.0/0">>
            },
            #{
                usernames => [?U2],
                authmethod => ?PASSWORD_AUTH,
                cidr => <<"198.162.0.0/16">>
            }
        ]
    },
    bondy_realm:create(Config).


security_toggle(Config) ->
    R = ?config(realm, Config),
    Uri = bondy_realm:uri(R),
    ok = bondy_realm:enable_security(R),

    ?assertEqual(true, bondy_realm:is_security_enabled(R)),
    ?assertEqual(enabled, bondy_realm:security_status(R)),

    ok = bondy_realm:disable_security(R),

    ?assertEqual(false, bondy_realm:is_security_enabled(Uri)),
    ?assertEqual(disabled, bondy_realm:security_status(Uri)),

    ok = bondy_realm:enable_security(R),

    {save_config, Config}.



%% =============================================================================
%% API CLIENT
%% =============================================================================

create_groups(Config) ->
    {security_toggle, Prev} = ?config(saved_config, Config),
    Uri = ?config(realm_uri, Config),
    Name = <<"group_a">>,
    N = length(bondy_rbac_group:list(Uri)),

    ?assertMatch(
        {ok, _},
        bondy_rbac_group:add(Uri, bondy_rbac_group:new(#{<<"name">> => Name}))
    ),

    ?assertMatch(
        #{type := group, name := Name, groups := [], meta := #{}}, bondy_rbac_group:lookup(Uri, Name)
    ),
    ?assertEqual(N + 1, length(bondy_rbac_group:list(Uri))),

    %% Create required groups for the tests
    ?assertMatch(
        {ok, _},
        bondy_rbac_group:add(
            Uri, bondy_rbac_group:new(#{<<"name">> => <<"api_clients">>})
        )
    ),

    ?assertMatch(
        {ok, _},
        bondy_rbac_group:add(
            Uri, bondy_rbac_group:new(#{<<"name">> => <<"resource_owners">>})
        )
    ),

    {save_config, Prev}.

api_client_add(Config) ->
    {create_groups, Prev} = ?config(saved_config, Config),
    ClientId = bondy_utils:generate_fragment(48),
    Secret = bondy_utils:generate_fragment(48),
    Uri = ?config(realm_uri, Prev),
    In = #{
        <<"client_id">> => ClientId,
        <<"client_secret">> => Secret
    },
    ?assertMatch(
        {ok, #{type := user}},
        bondy_oauth2_client:add(Uri, In)
    ),

    ?assertMatch(
        #{type := user},
        bondy_rbac_user:lookup(Uri, ClientId)
    ),

    {save_config, [{client_id, ClientId}, {client_secret, Secret} | Prev]}.


api_client_auth1(Config) ->
    {api_client_add, Prev} = ?config(saved_config, Config),
    Uri = ?config(realm_uri, Prev),
    Id = ?config(client_id, Prev),
    Secret = ?config(client_secret, Prev),
    ok = authenticate(Uri, Id, Secret),

    {save_config, Prev}.

api_client_update(Config) ->
    {api_client_auth1, Prev} = ?config(saved_config, Config),

    RealmUri = ?config(realm_uri, Prev),
    ClientId = ?config(client_id, Prev),

    ?assertMatch(
        {ok, #{
            groups := [<<"api_clients">>],
            username := _,
            type := user
        }},
        bondy_oauth2_client:update(
            RealmUri,
            ClientId,
            #{
                <<"client_secret">> => <<"New-Password">>,
                <<"meta">> => #{<<"foo">> => <<"bar">>}
            }
        )
    ),

    %% Updating password has no effect, we need to use the change password API
    ?assertMatch(
        {error, bad_signature},
        do_authenticate(RealmUri, ClientId, <<"New-Password">>)
    ),

    {save_config, Prev}.

api_client_auth2(Config) ->
    {api_client_update, Prev} = ?config(saved_config, Config),
    RealmUri = ?config(realm_uri, Prev),
    ClientId = ?config(client_id, Prev),
    NewSecret = <<"New-Password">>,

    ok = bondy_rbac_user:change_password(RealmUri, ClientId, NewSecret),

    ok = authenticate(RealmUri, ClientId, NewSecret),

    {save_config, Prev}.



api_client_delete(Config) ->
    {api_client_auth2, Prev} = ?config(saved_config, Config),
    ok = bondy_oauth2_client:remove(
        ?config(realm_uri, Config), ?config(client_id, Prev)),
    {save_config, Prev}.




%% =============================================================================
%% RESOURCE OWNER
%% =============================================================================



resource_owner_add(Config) ->
    Username = <<"AlE">>,
    R0 = #{
        <<"username">> => Username,
        <<"password">> => <<"ale">>,
        <<"meta">> => #{<<"foo">> => <<"bar">>},
        <<"groups">> => []
    },

    ?assertError(
        #{code := invalid_value, key := <<"password">>},
        bondy_oauth2_resource_owner:add(?config(realm_uri, Config), R0),
        "password is too small"
    ),
    Password = <<"ale123456">>,
    R1 = maps:put(<<"password">>, Password, R0),

    ?assertMatch(
        {ok, #{username := <<"ale">>}},
        bondy_oauth2_resource_owner:add(?config(realm_uri, Config), R1)
    ),

    {save_config, [{username, Username}, {password, Password} | Config]}.

resource_owner_auth1(Config) ->
    {resource_owner_add, Prev} = ?config(saved_config, Config),
    Uri = ?config(realm_uri, Prev),
    Username = ?config(username, Prev),
    Pass = ?config(password, Prev),

    ok = authenticate(Uri, Username, Pass),
    {save_config, Prev}.

resource_owner_update(Config) ->
    {resource_owner_auth1, Prev} = ?config(saved_config, Config),
    RealmUri = ?config(realm_uri, Prev),
    Username = ?config(username, Prev),
    Pass = <<"New-Password">>,
    #{groups := Gs} = bondy_rbac_user:lookup(RealmUri, Username),
    {ok, _} = bondy_oauth2_resource_owner:update(
        RealmUri,
        Username,
        #{
            <<"password">> => Pass,
            <<"meta">> => #{<<"foo">> => <<"bar">>}
        }
    ),
    #{groups := Gs} = bondy_rbac_user:lookup(RealmUri, Username),
    {save_config, Prev}.

resource_owner_change_password(Config) ->
    {resource_owner_update, Prev} = ?config(saved_config, Config),
    RealmUri = ?config(realm_uri, Prev),
    Username = ?config(username, Prev),
    OldPass = ?config(password, Prev),
    User1 = bondy_rbac_user:lookup(RealmUri, Username),
    NewPass = <<"New-Password2">>,
    ok = bondy_rbac_user:change_password(
        RealmUri, Username, NewPass, OldPass),
    %% Validate that we have only changed the password
    User2 = bondy_rbac_user:lookup(RealmUri, Username),
    %% error([User1, User2]),
    true = User1 =/= User2,
    {save_config,
        lists:keyreplace(password, 1, Prev, {password, NewPass})}.

resource_owner_auth2(Config) ->
    {resource_owner_change_password, Prev} = ?config(saved_config, Config),
    Uri = ?config(realm_uri, Prev),
    Username = ?config(username, Prev),
    Pass = ?config(password, Prev),
    ok = authenticate(Uri, Username, Pass),
    {save_config, Prev}.

resource_owner_auth3(Config) ->
    {resource_owner_auth2, Prev} = ?config(saved_config, Config),
    Uri = ?config(realm_uri, Prev),
    Username = string:uppercase(?config(username, Prev)),
    Pass = ?config(password, Prev),

    ok = authenticate(Uri, Username, Pass),
    {save_config, Prev}.

resource_owner_delete(Config) ->
    {resource_owner_auth3, Prev} = ?config(saved_config, Config),
    ok = bondy_oauth2_resource_owner:remove(
        ?config(realm_uri, Config), ?config(username, Prev)),
    {save_config, Prev}.




%% =============================================================================
%% USER
%% =============================================================================



user_add(Config) ->
    In = #{
        <<"username">> => <<"AlE2">>,
        <<"password">> => <<"ale123456">>,
        <<"meta">> => #{<<"foo">> => <<"bar">>},
        <<"groups">> => []
    },

    User = bondy_rbac_user:new(In),

    ?assertEqual(
        false,
        bondy_password:is_type(bondy_rbac_user:password(User))
    ),

    ?assertEqual(
        true,
        is_function(bondy_rbac_user:password(User), 1)
    ),

    {ok, NewUser} = bondy_rbac_user:add(?config(realm_uri, Config), User),

    ?assertEqual(
        true,
        bondy_password:is_type(bondy_rbac_user:password(NewUser))
    ),

    ?assertEqual(
        #{
            enabled => true,
            sso_realm_uri => undefined,
            groups => [],
            has_authorized_keys => false,
            has_password => true,
            meta => #{<<"foo">> => <<"bar">>},
            type => user,
            username => <<"ale2">>,
            version => <<"1.1">>
        },
        bondy_rbac_user:to_external(User)
    ),

    {save_config, [
        {username, <<"AlE2">>}, {password, <<"ale123456">>}
        | Config
    ]}.

user_auth1(Config) ->
    {user_add, Prev} = ?config(saved_config, Config),
    Uri = ?config(realm_uri, Prev),
    Username = ?config(username, Prev),
    Pass = ?config(password, Prev),
    ok = authenticate(Uri, Username, Pass),
    {save_config, Prev}.

user_update(Config) ->
    {user_auth1, Prev} = ?config(saved_config, Config),
    Pass = <<"New-Password">>,
    % Out = #{
    %     <<"groups">> => [],
    %     <<"has_password">> => true,
    %     <<"meta">> => #{<<"foo">> => <<"bar2">>},
    %     <<"sources">> => [],
    %     <<"username">> => <<"AlE2">>
    % },
    {ok, #{type := user}} = bondy_rbac_user:update(
        ?config(realm_uri, Prev),
        ?config(username, Prev),
        #{
            <<"password">> => Pass,
            <<"meta">> => #{<<"foo">> => <<"bar2">>}
        },
        #{
            update_credentials => true,
            forward_credentials => true
        }
    ),
    {save_config,
        lists:keyreplace(password, 1, Prev, {password, Pass})}.

user_auth2(Config) ->
    {user_update, Prev} = ?config(saved_config, Config),
    Uri = ?config(realm_uri, Prev),
    Username = ?config(username, Prev),
    Pass = ?config(password, Prev),
    ok = authenticate(Uri, Username, Pass),
    {save_config, Prev}.

user_auth3(Config) ->
    {user_auth2, Prev} = ?config(saved_config, Config),
    Uri = ?config(realm_uri, Prev),
    Username = string:uppercase(?config(username, Prev)),
    Pass = ?config(password, Prev),

    ok = authenticate(Uri, Username, Pass),
    {save_config, Prev}.

user_delete(Config) ->
    {user_auth3, Prev} = ?config(saved_config, Config),
    ok = bondy_rbac_user:remove(
        ?config(realm_uri, Config), ?config(username, Prev)),
    {save_config, Prev}.



%% =============================================================================
%% OAUTH
%% =============================================================================


password_token_crud_1(Config) ->
    Uri = ?config(realm_uri, Config),
    ClientId = bondy_utils:generate_fragment(48),
    Client = #{
        <<"client_id">> => ClientId,
        <<"client_secret">> => bondy_utils:generate_fragment(48)
    },
    {ok, _} = bondy_oauth2_client:add(Uri, Client),
    U = <<"ale">>,
    R = #{
        <<"username">> => U,
        <<"password">> => <<"123456">>,
        <<"meta">> => #{},
        <<"groups">> => []
    },
    {ok, _} = bondy_oauth2_resource_owner:add(Uri, R),

    {ok, _JWT0, RToken0, _Claims0} = bondy_oauth2:issue_token(
        password, Uri, ClientId, U, [], #{}
    ),
    Data0 = bondy_oauth2:lookup_token(Uri, ClientId, RToken0),
    Ts0 = bondy_oauth2:issued_at(Data0),
    timer:sleep(2000), % issued_at is seconds
    {ok, _JWT1, RToken1, _Claims1} = bondy_oauth2:refresh_token(
        Uri, ClientId, RToken0
    ),
    Data1 = bondy_oauth2:lookup_token(Uri, ClientId, RToken1),
    {error, not_found} = bondy_oauth2:lookup_token(Uri, ClientId, RToken0),
    %% Revoke token should never fail, even if the token was already revoked
    ok = bondy_oauth2:revoke_token(refresh_token, Uri, ClientId, RToken0),
    Ts1 = bondy_oauth2:issued_at(Data1),
    true = Ts0 < Ts1,

    ok = bondy_oauth2:revoke_tokens(refresh_token, Uri, U),
    {error, not_found} = bondy_oauth2:lookup_token(Uri, ClientId, RToken1),
    %% Revoke token should never fail, even if the token was already revoked
    ok = bondy_oauth2:revoke_token(refresh_token, Uri, ClientId, RToken1),

    {save_config, [{client_id, ClientId}, {username, U} | Config]}.


    issue_revoke_by_device_id(Config) ->
        {password_token_crud_1, Prev} = ?config(saved_config, Config),
        Uri = ?config(realm_uri, Prev),
        C = ?config(client_id, Prev),
        U = ?config(username, Prev),
        D = <<"1">>,

        {ok, _JWT0, RToken0, _Claims0} = bondy_oauth2:issue_token(
            password, Uri, C, U, [], #{<<"client_device_id">> => D}
        ),
        ok = bondy_oauth2:revoke_token(refresh_token, Uri, C, U, D),
        {error, not_found} = bondy_oauth2:lookup_token(Uri, C, RToken0),
        {save_config, [{client_id, C}, {username, U} | Config]}.


    issue_refresh_revoke_by_device_id(Config) ->
        {issue_revoke_by_device_id, Prev} = ?config(saved_config, Config),
        Uri = ?config(realm_uri, Prev),
        C = ?config(client_id, Prev),
        U = ?config(username, Prev),
        D = <<"1">>,

        {ok, _, RToken0, _} = bondy_oauth2:issue_token(
            password, Uri, C, U, [], #{<<"client_device_id">> => D}
        ),
        timer:sleep(2000),
        {ok, _, RToken1, _} = bondy_oauth2:refresh_token(Uri, C, RToken0),
        {error, not_found} = bondy_oauth2:lookup_token(Uri, C, RToken0),
        ok = bondy_oauth2:revoke_token(refresh_token, Uri, C, U, D),
        {error, not_found} = bondy_oauth2:lookup_token(Uri, C, RToken1).



authenticate(Uri, Username, Secret) ->
    Result = do_authenticate(Uri, Username, Secret),
    ?assertMatch({ok, _, _}, Result),
    ok.


do_authenticate(Uri, Username, Secret) ->
    SessionId = bondy_session_id:new(),
    Roles = [],
    Peer = {{127,0,0,1}, 1111},
    {ok, Ctxt} = bondy_auth:init(SessionId, Uri, Username, Roles, Peer),
    ?assertEqual(
        true,
        lists:member(?PASSWORD_AUTH, bondy_auth:available_methods(Ctxt))
    ),
    bondy_auth:authenticate(?PASSWORD_AUTH, Secret, #{}, Ctxt).