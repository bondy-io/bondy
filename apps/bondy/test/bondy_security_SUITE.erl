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
-compile(export_all).

all() ->
    common:all().

groups() ->
    [
        {main, [sequence], [
            create_realm,
            enable_security,
            security_enabled,
            disable_security,
            security_disabled,
            api_client_add,
            api_client_delete
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
    realm = element(1, Realm),
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

api_client_add(Config) ->
    {security_disabled, Prev} = ?config(saved_config, Config),
    {ok, #{
        <<"client_id">> := Id,
        <<"client_secret">> := Secret
    }} = bondy_api_client:add(?config(realm, Prev), #{}),
    {save_config, [{client_id, Id}, {client_secret, Secret} | Prev]}.


api_client_delete(Config) ->
    {api_client_add, Prev} = ?config(saved_config, Config),
    ok = bondy_api_client:remove(
        ?config(realm, Config), ?config(client_id, Prev)),
    {save_config, Prev}.
