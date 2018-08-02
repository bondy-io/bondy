%% =============================================================================
%%  bondy_SUITE.erl -
%%
%%  Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
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
            create_realm,
            enable_security,
            security_enabled,
            disable_security,
            security_disabled,
            create_groups,
            api_client_add,
            api_client_auth1,
            api_client_update,
            api_client_auth2,
            api_client_auth3,
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
            password_token_crud_2
        ]}
    ].

init_per_suite(Config) ->
    common:start_bondy(),
    [{realm_uri, <<"com.myrealm">>}|Config].

end_per_suite(Config) ->
    common:stop_bondy(),
    {save_config, Config}.


create_realm(Config) ->
    Realm = bondy_realm:add(?config(realm_uri, Config)),
    {save_config, [{realm, Realm} | Config]}.

enable_security(Config) ->
    {create_realm, Prev} = ?config(saved_config, Config),
    ok = bondy_realm:enable_security(?config(realm, Prev)),
    {save_config, Prev}.

security_enabled(Config) ->
    {enable_security, Prev} = ?config(saved_config, Config),
    R = ?config(realm, Prev),
    enabled = bondy_realm:security_status(R),
    true = bondy_realm:is_security_enabled(R),
    {save_config, Prev}.

disable_security(Config) ->
    {security_enabled, Prev} = ?config(saved_config, Config),
    ok = bondy_realm:disable_security(?config(realm, Prev)),
    {save_config, Prev}.

security_disabled(Config) ->
    {disable_security, Prev} = ?config(saved_config, Config),
    R = ?config(realm, Prev),
    disabled = bondy_realm:security_status(R),
    false = bondy_realm:is_security_enabled(R),
    {save_config, Prev}.






%% =============================================================================
%% API CLIENT
%% =============================================================================

create_groups(Config) ->
    {security_disabled, Prev} = ?config(saved_config, Config),
    Uri = ?config(realm_uri, Config),
    Name = <<"group_a">>,
    N = length(bondy_security_group:list(Uri)),
    ok = bondy_security_group:add(Uri, #{<<"name">> => Name}),
    #{
        <<"name">> := Name,
        <<"groups">> := [],
        <<"meta">> := #{}
    } = bondy_security_group:lookup(Uri, Name),
    true = length(bondy_security_group:list(Uri)) =:= N + 1,
    %% Create required groups for the tests
    ok = bondy_security_group:add(Uri, #{<<"name">> => <<"api_clients">>}),
    ok = bondy_security_group:add(Uri, #{<<"name">> => <<"resource_owners">>}),
    {save_config, Prev}.

api_client_add(Config) ->
    {create_groups, Prev} = ?config(saved_config, Config),
    {ok, #{
        <<"client_id">> := Id,
        <<"client_secret">> := Secret
    }} = bondy_api_client:add(?config(realm_uri, Prev), #{}),
    {save_config, [{client_id, Id}, {client_secret, Secret} | Prev]}.

api_client_auth1(Config) ->
    {api_client_add, Prev} = ?config(saved_config, Config),
    Uri = ?config(realm_uri, Prev),
    Id = ?config(client_id, Prev),
    Secret = ?config(client_secret, Prev),
    {ok, _} = bondy_security:authenticate(Uri, Id, Secret, [{ip, {127,0,0,1}}]),
    {save_config, Prev}.

api_client_update(Config) ->
    {api_client_auth1, Prev} = ?config(saved_config, Config),
    Secret = <<"New-Password">>,
    ok = bondy_api_client:update(
        ?config(realm_uri, Prev),
        ?config(client_id, Prev),
        #{
            <<"client_secret">> => Secret,
            <<"meta">> => #{<<"foo">> => <<"bar">>}
        }
    ),
    {save_config,
        lists:keyreplace(client_secret, 1, Prev, {client_secret, Secret})}.

api_client_auth2(Config) ->
    {api_client_update, Prev} = ?config(saved_config, Config),
    Uri = ?config(realm_uri, Prev),
    Id = ?config(client_id, Prev),
    Secret = ?config(client_secret, Prev),
    {ok, _} = bondy_security:authenticate(Uri, Id, Secret, [{ip, {127,0,0,1}}]),
    {save_config, Prev}.

api_client_auth3(Config) ->
    {api_client_auth2, Prev} = ?config(saved_config, Config),
    Uri = ?config(realm_uri, Prev),
    Id = string:uppercase(?config(client_id, Prev)),
    Secret = ?config(client_secret, Prev),
    {ok, _} = bondy_security:authenticate(Uri, Id, Secret, [{ip, {127,0,0,1}}]),
    {save_config, Prev}.

api_client_delete(Config) ->
    {api_client_auth3, Prev} = ?config(saved_config, Config),
    ok = bondy_api_client:remove(
        ?config(realm_uri, Config), ?config(client_id, Prev)),
    {save_config, Prev}.




%% =============================================================================
%% RESOURCE OWNER
%% =============================================================================



resource_owner_add(Config) ->
    R = #{
        username => <<"AlE">>,
        password => <<"ale">>,
        meta => #{<<"foo">> => <<"bar">>},
        groups => []
    },
    {ok, #{
        <<"username">> := Username
    }} = bondy_api_resource_owner:add(?config(realm_uri, Config), R),
    {save_config, [{username, Username}, {password, <<"ale">>} | Config]}.

resource_owner_auth1(Config) ->
    {resource_owner_add, Prev} = ?config(saved_config, Config),
    Uri = ?config(realm_uri, Prev),
    Username = ?config(username, Prev),
    Pass = ?config(password, Prev),
    {ok, _} = bondy_security:authenticate(
        Uri, Username, Pass, [{ip, {127,0,0,1}}]),
    {save_config, Prev}.

resource_owner_update(Config) ->
    {resource_owner_auth1, Prev} = ?config(saved_config, Config),
    RealmUri = ?config(realm_uri, Prev),
    Username = ?config(username, Prev),
    Pass = <<"New-Password">>,
    #{<<"groups">> := Gs} = bondy_security_user:lookup(RealmUri, Username),
    {ok, _} = bondy_api_resource_owner:update(
        RealmUri,
        Username,
        #{
            <<"password">> => Pass,
            <<"meta">> => #{<<"foo">> => <<"bar">>}
        }
    ),
    #{<<"groups">> := Gs} = bondy_security_user:lookup(RealmUri, Username),
    {save_config,
        lists:keyreplace(password, 1, Prev, {password, Pass})}.

resource_owner_change_password(Config) ->
    {resource_owner_update, Prev} = ?config(saved_config, Config),
    RealmUri = ?config(realm_uri, Prev),
    Username = ?config(username, Prev),
    OldPass = ?config(password, Prev),
    User1 = bondy_security_user:lookup(RealmUri, Username),
    NewPass = <<"New-Password2">>,
    ok = bondy_security_user:change_password(
        RealmUri, Username, NewPass, OldPass),
    %% Validate that we have only changed the password
    User2 = bondy_security_user:lookup(RealmUri, Username),
    %% error([User1, User2]),
    true = User1 =:= User2,
    {save_config,
        lists:keyreplace(password, 1, Prev, {password, NewPass})}.

resource_owner_auth2(Config) ->
    {resource_owner_change_password, Prev} = ?config(saved_config, Config),
    Uri = ?config(realm_uri, Prev),
    Username = ?config(username, Prev),
    Pass = ?config(password, Prev),
    {ok, _} = bondy_security:authenticate(
        Uri, Username, Pass, [{ip, {127,0,0,1}}]),
    {save_config, Prev}.

resource_owner_auth3(Config) ->
    {resource_owner_auth2, Prev} = ?config(saved_config, Config),
    Uri = ?config(realm_uri, Prev),
    Username = string:uppercase(?config(username, Prev)),
    Pass = ?config(password, Prev),
    {ok, _} = bondy_security:authenticate(
        Uri, Username, Pass, [{ip, {127,0,0,1}}]),
    {save_config, Prev}.

resource_owner_delete(Config) ->
    {resource_owner_auth3, Prev} = ?config(saved_config, Config),
    ok = bondy_api_resource_owner:remove(
        ?config(realm_uri, Config), ?config(username, Prev)),
    {save_config, Prev}.




%% =============================================================================
%% USER
%% =============================================================================



user_add(Config) ->
    R = #{
        username => <<"AlE2">>,
        password => <<"ale">>,
        meta => #{<<"foo">> => <<"bar">>},
        groups => []
    },
    ok = bondy_security_user:add(?config(realm_uri, Config), R),
    {save_config, [{username, <<"AlE2">>}, {password, <<"ale">>} | Config]}.

user_auth1(Config) ->
    {user_add, Prev} = ?config(saved_config, Config),
    Uri = ?config(realm_uri, Prev),
    Username = ?config(username, Prev),
    Pass = ?config(password, Prev),
    {ok, _} = bondy_security:authenticate(
        Uri, Username, Pass, [{ip, {127,0,0,1}}]),
    {save_config, Prev}.

user_update(Config) ->
    {user_auth1, Prev} = ?config(saved_config, Config),
    Pass = <<"New-Password">>,
    ok = bondy_security_user:update(
        ?config(realm_uri, Prev),
        ?config(username, Prev),
        #{
            <<"password">> => Pass,
            <<"meta">> => #{<<"foo">> => <<"bar">>}
        }
    ),
    {save_config,
        lists:keyreplace(password, 1, Prev, {password, Pass})}.

user_auth2(Config) ->
    {user_update, Prev} = ?config(saved_config, Config),
    Uri = ?config(realm_uri, Prev),
    Username = ?config(username, Prev),
    Pass = ?config(password, Prev),
    {ok, _} = bondy_security:authenticate(
        Uri, Username, Pass, [{ip, {127,0,0,1}}]),
    {save_config, Prev}.

user_auth3(Config) ->
    {user_auth2, Prev} = ?config(saved_config, Config),
    Uri = ?config(realm_uri, Prev),
    Username = string:uppercase(?config(username, Prev)),
    Pass = ?config(password, Prev),
    {ok, _} = bondy_security:authenticate(
        Uri, Username, Pass, [{ip, {127,0,0,1}}]),
    {save_config, Prev}.

user_delete(Config) ->
    {user_auth3, Prev} = ?config(saved_config, Config),
    ok = bondy_security_user:remove(
        ?config(realm_uri, Config), ?config(username, Prev)),
    {save_config, Prev}.





%% =============================================================================
%% OAUTH
%% =============================================================================


password_token_crud_1(Config) ->
    Uri = ?config(realm_uri, Config),
    {ok, #{
        <<"client_id">> := C
    }} = bondy_api_client:add(Uri, #{}),
    R = #{
        username => <<"ale">>,
        password => <<"1234">>,
        meta => #{},
        groups => []
    },
    {ok, #{
        <<"username">> := U
    }} = bondy_api_resource_owner:add(Uri, R),

    {ok, _JWT0, RToken0, _Claims0} = bondy_oauth2:issue_token(
        password, Uri, C, U, [], #{}
    ),
    {ok, _JWT1, RToken1, _Claims1} = bondy_oauth2:refresh_token(
        Uri, C, RToken0),
    {error, oauth2_invalid_grant} = bondy_oauth2:revoke_token(refresh_token, Uri, C, RToken0),
    ok = bondy_oauth2:revoke_token(refresh_token, Uri, C, RToken1),
    {error, oauth2_invalid_grant} = bondy_oauth2:revoke_token(
        refresh_token, Uri, C, RToken1),

    {save_config, [{client_id, C}, {username, U} | Config]}.


    password_token_crud_2(Config) ->
        {password_token_crud_1, Prev} = ?config(saved_config, Config),
        Uri = ?config(realm_uri, Prev),
        C = ?config(client_id, Prev),
        U = ?config(username, Prev),
        D = <<"1">>,

        {ok, _JWT0, RToken0, _Claims0} = bondy_oauth2:issue_token(
            password, Uri, C, U, [], #{<<"client_device_id">> => D}
        ),
        ok = bondy_oauth2:revoke_user_token(refresh_token, Uri, C, U, D),
        {error, oauth2_invalid_grant} = bondy_oauth2:revoke_token(
            refresh_token, Uri, C, RToken0).
