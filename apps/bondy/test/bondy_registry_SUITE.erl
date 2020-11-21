%% =============================================================================
%%  bondy_SUITE.erl -
%%
%%  Copyright (c) 2016-2019 Ngineo Limited. All rights reserved.
%%  Copyright (c) 2020 Leapsight Holdings Limited. All rights reserved.
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

-module(bondy_registry_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([nowarn_export_all, export_all]).

all() ->
    [
        {group, exact_matching}
    ].

groups() ->
    [
        {exact_matching, [sequence], [
            add_subscription,
            match_prefix
        ]}
    ].

init_per_suite(Config) ->
    common:start_bondy(),
    plum_db_config:set(aae_enabled, false),
    Realm = bondy_realm:add(<<"com.foobar">>),
    RealmUri = bondy_realm:uri(Realm),
    ok = bondy_realm:disable_security(Realm),
    Ctxt = bondy_context:local_context(RealmUri),

    meck:expect(bondy_context, peer_id, fun(_Map)->
        {RealmUri, bondy_peer_service:mynode(), undefined, self()}
    end),

    [{context, Ctxt}, {realm, Realm}, {realm_uri, RealmUri} |Config].

end_per_suite(Config) ->
    meck:unload(),
    %% common:stop_bondy(),
    {save_config, Config}.


%% =============================================================================
%% API CLIENT
%% =============================================================================



add_subscription(Config) ->
    Realm = ?config(realm_uri, Config),
    Ctxt = ?config(context, Config),
    Opts = #{match => <<"exact">>},

    Uri = <<"com.a.b.c">>,

    {ok, Entry, true} = bondy_registry:add(
        subscription, Uri, Opts, Ctxt
    ),

    Id1 = bondy_registry_entry:id(Entry),
    Found = bondy_registry:lookup(subscription, Id1, Realm),

    ?assertEqual(
        Entry,
        Found
    ),
    ?assertEqual(
        [Entry],
        bondy_registry:entries(subscription, Ctxt)
    ),

    ?assertEqual(
        {error, {already_exists, Entry}},
        bondy_registry:add(subscription, <<"com.a.b.c">>, Opts, Ctxt)
    ),

    ?assertEqual(
        Id1,
        bondy_registry_entry:id(bondy_registry:lookup(subscription, Id1, Realm))
    ),

    {ok, Entry2, true} = bondy_registry:add(
        subscription, <<"com.a">>, Opts, Ctxt
    ),

    Id2 = bondy_registry_entry:id(Entry2),

    ?assertEqual(
        Id2,
        bondy_registry_entry:id(bondy_registry:lookup(subscription, Id2, Realm))
    ),

    {ok, Entry3, true} = bondy_registry:add(
        subscription, <<"com.a.b">>, #{match => <<"prefix">>}, Ctxt
    ),

    Id3 = bondy_registry_entry:id(Entry3),

    ?assertEqual(
        Id3,
        bondy_registry_entry:id(bondy_registry:lookup(subscription, Id3, Realm))
    ).


match_prefix(Config) ->
    Realm = ?config(realm_uri, Config),
    Ctxt = ?config(context, Config),

    {ok, Entry, false} = bondy_registry:add(
        subscription, <<"com.a">>, #{match => <<"prefix">>}, Ctxt
    ),

    Id = bondy_registry_entry:id(Entry),

    E = bondy_registry:lookup(subscription, Id, Realm),

    ?assertEqual(Id, bondy_registry_entry:id(E)),

    ?assertEqual(
        2,
        length(
            element(1, bondy_registry:match(subscription, <<"com.a">>, Realm))
        )
    ),
    ?assertEqual(
        2,
        length(
            element(1, bondy_registry:match(subscription, <<"com.a.b">>, Realm))
        )
    ),
    ?assertEqual(
        2,
        length(
            element(
                1, bondy_registry:match(subscription, <<"com.a.b.c.d">>, Realm)
            )
        )
    ).

