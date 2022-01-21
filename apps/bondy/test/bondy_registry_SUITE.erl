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

-module(bondy_registry_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include_lib("wamp/include/wamp.hrl").
-include("bondy_security.hrl").

-compile([nowarn_export_all, export_all]).

all() ->
    [
        {group, exact_matching},
        {group, rpc}
    ].

groups() ->
    [
        {rpc, [sequence], [
            register_invoke_single,
            register_shared,
            register_callback
        ]},
        {exact_matching, [sequence], [
            add_subscription,
            match_prefix
        ]}
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    plum_db_config:set(aae_enabled, false),
    Realm = bondy_realm:create(<<"com.foobar">>),
    RealmUri = bondy_realm:uri(Realm),
    ok = bondy_realm:disable_security(Realm),
    Peer = {{127, 0, 0, 1}, 10000},
    Session = bondy_session:new(RealmUri, #{
        peer => Peer,
        authid => <<"foo">>,
        authmethod => ?WAMP_ANON_AUTH,
        is_anonymous => true,
        security_enabled => true,
        authroles => [<<"anonymous">>],
        roles => #{
            caller => #{},
            subscriber => #{}
        }
    }),
    Ctxt0 = bondy_context:new(Peer, {ws, text, json}),
    Ctxt = bondy_context:set_session(Ctxt0, Session),


    [{context, Ctxt}, {realm, Realm}, {realm_uri, RealmUri} |Config].

end_per_suite(Config) ->
    meck:unload(),
    %% bondy_ct:stop_bondy(),
    {save_config, Config}.


%% =============================================================================
%% API CLIENT
%% =============================================================================



add_subscription(Config) ->
    Realm = ?config(realm_uri, Config),
    Ctxt = ?config(context, Config),
    Opts = #{match => <<"exact">>},

    Uri = <<"com.a.b.c">>,

    Ref = bondy_context:ref(Ctxt),
    {ok, Entry, true} = bondy_registry:add(
        subscription, Uri, Opts, Realm, Ref
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
        bondy_registry:add(subscription, Uri, Opts, Realm, Ref)
    ),

    ?assertEqual(
        Id1,
        bondy_registry_entry:id(bondy_registry:lookup(subscription, Id1, Realm))
    ),

    {ok, Entry2, true} = bondy_registry:add(
        subscription, <<"com.a">>, Opts, Realm, Ref
    ),

    Id2 = bondy_registry_entry:id(Entry2),

    ?assertEqual(
        Id2,
        bondy_registry_entry:id(bondy_registry:lookup(subscription, Id2, Realm))
    ),

    {ok, Entry3, true} = bondy_registry:add(
        subscription, <<"com.a.b">>, #{match => <<"prefix">>}, Realm, Ref
    ),

    Id3 = bondy_registry_entry:id(Entry3),

    ?assertEqual(
        Id3,
        bondy_registry_entry:id(bondy_registry:lookup(subscription, Id3, Realm))
    ).


match_prefix(Config) ->
    Realm = ?config(realm_uri, Config),
    Ctxt = ?config(context, Config),

    Ref = bondy_context:ref(Ctxt),

    {ok, Entry, false} = bondy_registry:add(
        subscription, <<"com.a">>, #{match => <<"prefix">>}, Realm, Ref
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


register_invoke_single(Config) ->
    Realm = ?config(realm_uri, Config),
    Uri = <<"com.example.", (bondy_utils:generate_fragment(12))/binary>>,
    Opts = #{invoke => ?INVOKE_SINGLE},

    Ref = bondy_ref:new(internal),

    ?assertMatch(
        {ok, _},
        bondy_dealer:register(Uri, Opts, Realm, Ref)
    ),

    ?assertMatch(
        {error, already_exists},
        bondy_dealer:register(Uri, Opts, Realm, Ref)
    ),

    ?assertMatch(
        {error, already_exists},
        bondy_dealer:register(Uri, #{invoke => ?INVOKE_ROUND_ROBIN}, Realm, Ref)
    ).


register_shared(Config) ->
    Realm = ?config(realm_uri, Config),
    Uri = <<"com.example.", (bondy_utils:generate_fragment(12))/binary>>,
    Opts = #{invoke => ?INVOKE_ROUND_ROBIN},

    Ref = bondy_ref:new(internal),

    ?assertMatch(
        {ok, _},
        bondy_dealer:register(Uri, Opts, Realm, Ref)
    ),

    ?assertMatch(
        {ok, _},
        bondy_dealer:register(Uri, Opts, Realm, Ref)
    ).


register_callback(Config) ->
    Realm = ?config(realm_uri, Config),

    Uri1 = <<"com.example.", (bondy_utils:generate_fragment(12))/binary>>,
    Uri2 = <<"com.example.", (bondy_utils:generate_fragment(12))/binary>>,


    Opts = #{invoke => ?INVOKE_ROUND_ROBIN},

    Ref1 = bondy_ref:new(internal, {bondy_wamp_api, handle_call}),

    ?assertMatch(
        {ok, _},
        bondy_dealer:register(Uri1, Opts, Realm, Ref1)
    ),
    ?assertMatch(
        {error, already_exists},
        bondy_dealer:register(Uri1, Opts, Realm, Ref1),
        "Callbacks cannot use shared registration"
    ),

    %% Not allowed currently
    %% Uri2 = <<"com.example.", (bondy_utils:generate_fragment(12))/binary>>,
    % ?assertMatch(
    %     {ok, _},
    %     bondy_dealer:register(Uri2, Opts, Realm, Ref1),
    %     "We can have multiple URIs associates with the same Ref"
    % ),

    Ref2 = bondy_ref:new(internal, {bondy_wamp_api, resolve}),

    ?assertMatch(
        {error, already_exists},
        bondy_dealer:register(Uri1, Opts, Realm, Ref2)
    ),

    ?assertMatch(
        {ok, _},
        bondy_dealer:register(Uri2, Opts, Realm, Ref2),
        "We can register another URI"
    ),
    ?assertMatch(
        {error, already_exists},
        bondy_dealer:register(Uri2, Opts, Realm, Ref2),
        "Callbacks cannot use shared registration"
    ),

    %% This should fail, for this we should be using static callbacks
    Ref3 = bondy_ref:new(
        internal, {bondy_wamp_api, handle_call}, undefined, 'bondy2@127.0.0.1'
    ),
    ?assertMatch(
        {error, already_exists},
        bondy_dealer:register(Uri1, Opts, Realm, Ref3)
    ).
