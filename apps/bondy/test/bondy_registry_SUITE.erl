%% =============================================================================
%%  bondy_SUITE.erl -
%%
%%  Copyright (c) 2016-2023 Leapsight. All rights reserved.
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
-include("bondy.hrl").
-include("bondy_security.hrl").
-include("bondy_registry.hrl").


-define(SORT(L), lists:sort(L)).

-compile([nowarn_export_all, export_all]).



all() ->
    [
        {group, rpc},
        {group, pubsub}
    ].


groups() ->
    [
        {rpc, [sequence], [
            register_invoke_single,
            register_shared,
            register_callback
        ]},
        {pubsub, [sequence], [
            sub_add_local_exact_1,
            sub_add_local_exact_2,
            sub_add_local_prefix_1,
            sub_add_local_prefix_2,
            sub_add_local_wildcard_1,
            sub_add_local_wildcard_,
            sub_del_local_exact_1,
            sub_del_local_exact_2
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


    [
        {context, Ctxt},
        {realm_uri, RealmUri}
        | Config
    ].


end_per_suite(Config) ->
    meck:unload(),
    %% bondy_ct:stop_bondy(),
    {save_config, Config}.


%% =============================================================================
%% PUBSUB
%% =============================================================================



sub_add_local_exact_1(Config) ->
    RealmUri = key_value:get(realm_uri, Config),
    Ctxt = key_value:get(context, Config),
    Type = subscription,
    Opts = #{match => ?EXACT_MATCH},
    Uri = <<"com.foo.bar">>,

    add_test(Type, RealmUri, Uri, Opts, Ctxt),

    Expected = {[{Uri, ?EXACT_MATCH}], []},

    ?assertEqual(
        Expected,
        project(bondy_registry:match(Type, RealmUri, Uri)),
        "The trie should have the added entries. Remote subs should be empty"
    ),

    ?assertEqual(
        {[], []},
        bondy_registry:match(Type, RealmUri, <<"com.foo.baz">>, #{}),
        "Should not match com.foo.baz"
    ).


sub_add_local_exact_2(Config) ->
    RealmUri = key_value:get(realm_uri, Config),
    Ctxt = key_value:get(context, Config),
    Type = subscription,
    Opts = #{match => ?EXACT_MATCH},
    Uri = <<"com.foo.baz">>,

    add_test(Type, RealmUri, Uri, Opts, Ctxt),

    Expected = {[{Uri, ?EXACT_MATCH}], []},

    ?assertEqual(
        Expected,
        project(bondy_registry:match(Type, RealmUri, Uri)),
        "The trie should have the added entries. Remote subs should be empty"
    ),

    Expected2 = {[{<<"com.foo.bar">>, ?EXACT_MATCH}], []},

    ?assertEqual(
        Expected2,
        project(
            bondy_registry:match(Type, RealmUri, <<"com.foo.bar">>, #{})
        ),
        "Should match com.foo.bar"
    ),

    ?assertEqual(
        {[], []},
        bondy_registry:match(Type, RealmUri, <<"com.foo.other">>, #{})
    ).


sub_add_local_prefix_1(Config) ->
    RealmUri = key_value:get(realm_uri, Config),
    Ctxt = key_value:get(context, Config),
    Type = subscription,
    Opts = #{match => ?PREFIX_MATCH},
    Uri = <<"com.foo">>,

    add_test(Type, RealmUri, Uri, Opts, Ctxt),

    Expected = {[{Uri, ?PREFIX_MATCH}], []},

    ?assertEqual(
        Expected,
        project(bondy_registry:match(Type, RealmUri, Uri)),
        "We should match the prefix"
    ),

    ?assertEqual(
        {
            ?SORT([
                {<<"com.foo.bar">>, ?EXACT_MATCH},
                {<<"com.foo">>, ?PREFIX_MATCH}
            ]),
            []
        },
        project(bondy_registry:match(Type, RealmUri, <<"com.foo.bar">>)),
        "The trie should have the added entries. Remote subs should be empty"
    ),

    ?assertEqual(
        {
            ?SORT([
                {<<"com.foo.baz">>, ?EXACT_MATCH},
                {<<"com.foo">>, ?PREFIX_MATCH}
            ]),
            []
        },
        project(bondy_registry:match(Type, RealmUri, <<"com.foo.baz">>)),
        "The trie should have the added entries. Remote subs should be empty"
    ),


    ?assertEqual(
        Expected,
        project(bondy_registry:match(Type, RealmUri, <<"com.foo.other">>)),
        "The trie match any subs starting with com.foo"
    ).



sub_add_local_prefix_2(Config) ->
    RealmUri = key_value:get(realm_uri, Config),
    Ctxt = key_value:get(context, Config),
    Type = subscription,

    add_test(Type, RealmUri, <<"com.a">>, #{match => ?PREFIX_MATCH}, Ctxt),

    ?assertEqual(
        {
            ?SORT([
                {<<"com.a">>, ?PREFIX_MATCH}
            ]),
            []
        },
        project(
            bondy_registry:match(subscription, RealmUri, <<"com.a">>)
        )
    ),

    add_test(Type, RealmUri, <<"com.a">>, #{match => ?EXACT_MATCH}, Ctxt),

    ?assertEqual(
        {
            ?SORT([
                {<<"com.a">>, ?EXACT_MATCH}, {<<"com.a">>, ?PREFIX_MATCH}
            ]),
            []
        },
        project(
            bondy_registry:match(subscription, RealmUri, <<"com.a">>)
        )
    ),

    add_test(Type, RealmUri, <<"com.a.b">>, #{match => ?PREFIX_MATCH}, Ctxt),

    ?assertEqual(
        {
            ?SORT([
                {<<"com.a">>, ?PREFIX_MATCH}, {<<"com.a.b">>, ?PREFIX_MATCH}
            ]),
            []
        },
        project(
            bondy_registry:match(subscription, RealmUri, <<"com.a.b">>)
        )
    ),

    ?assertEqual(
        {
            ?SORT([
                {<<"com.a">>, ?PREFIX_MATCH}, {<<"com.a.b">>, ?PREFIX_MATCH}
            ]),
            []
        },
        project(
            bondy_registry:match(subscription, RealmUri, <<"com.a.b.c.d">>)
        )
    ).



sub_add_local_wildcard_1(Config) ->
    RealmUri = key_value:get(realm_uri, Config),
    Ctxt = key_value:get(context, Config),
    Type = subscription,
    Opts = #{match => ?WILDCARD_MATCH},

    add_test(Type, RealmUri, <<"com.">>, Opts, Ctxt),


    ?assertEqual(
        {
            ?SORT([
                {<<"com.">>, ?WILDCARD_MATCH},
                {<<"com.a">>, ?EXACT_MATCH},
                {<<"com.a">>, ?PREFIX_MATCH}
            ]),
            []
        },
        project(
            bondy_registry:match(subscription, RealmUri, <<"com.a">>)
        )
    ),

    ?assertEqual(
        {?SORT([{<<"com.">>, ?WILDCARD_MATCH}]), []},
        project(
            bondy_registry:match(subscription, RealmUri, <<"com.b">>)
        )
    ),

    ?assertEqual(
        {?SORT([{<<"com.">>, ?WILDCARD_MATCH}]), []},
        project(
            bondy_registry:match(subscription, RealmUri, <<"com.bar">>)
        )
    ),

    ?assertEqual(
        {
            ?SORT([
                {<<"com.a">>,?PREFIX_MATCH},
                {<<"com.a.b">>,?PREFIX_MATCH}
            ]),
            []
        },
        project(
            bondy_registry:match(subscription, RealmUri, <<"com.a.b">>)
        )
    ),

    ?assertEqual(
        {
            ?SORT([{<<"com.a">>,?PREFIX_MATCH}, {<<"com.a.b">>,?PREFIX_MATCH}]),
            []
        },
        project(
            bondy_registry:match(subscription, RealmUri, <<"com.a.b.c.d">>)
        )
    ),

    add_test(Type, RealmUri, <<"....">>, Opts, Ctxt),

    add_test(Type, RealmUri, <<"com....">>, Opts, Ctxt),

    add_test(Type, RealmUri, <<".a...">>, Opts, Ctxt),

    add_test(Type, RealmUri, <<"..b..">>, Opts, Ctxt),

    add_test(Type, RealmUri, <<"...c.">>, Opts, Ctxt),

    add_test(Type, RealmUri, <<"....d">>, Opts, Ctxt),


    ?assertEqual(
        {
            ?SORT([
                {<<"....">>, ?WILDCARD_MATCH},
                {<<"com....">>, ?WILDCARD_MATCH},
                {<<"....d">>, ?WILDCARD_MATCH},
                {<<".a...">>, ?WILDCARD_MATCH},
                {<<"..b..">>, ?WILDCARD_MATCH},
                {<<"...c.">>, ?WILDCARD_MATCH},
                {<<"com.a">>, ?PREFIX_MATCH},
                {<<"com.a.b">>, ?PREFIX_MATCH}
            ]),
            []
        },
        project(
            bondy_registry:match(subscription, RealmUri, <<"com.a.b.c.d">>)
        )
    ).



sub_add_local_wildcard_(Config) ->
    Config.


sub_del_local_exact_1(Config) ->
    Config.


sub_del_local_exact_2(Config) ->
    Config.






register_invoke_single(Config) ->
    RealmUri = key_value:get(realm_uri, Config),
    Uri = <<"com.example.", (bondy_utils:generate_fragment(12))/binary>>,
    Opts = #{invoke => ?INVOKE_SINGLE},

    Ref = bondy_ref:new(internal),

    ?assertMatch(
        {ok, _},
        bondy_dealer:register(Uri, Opts, RealmUri, Ref)
    ),

    ?assertMatch(
        {error, already_exists},
        bondy_dealer:register(Uri, Opts, RealmUri, Ref)
    ),

    ?assertMatch(
        {error, already_exists},
        bondy_dealer:register(Uri, #{invoke => ?INVOKE_ROUND_ROBIN}, RealmUri, Ref)
    ).


register_shared(Config) ->
    RealmUri = key_value:get(realm_uri, Config),
    Uri = <<"com.example.", (bondy_utils:generate_fragment(12))/binary>>,
    Opts = #{invoke => ?INVOKE_ROUND_ROBIN},

    Ref = bondy_ref:new(internal),

    ?assertMatch(
        {ok, _},
        bondy_dealer:register(Uri, Opts, RealmUri, Ref)
    ),

    ?assertMatch(
        {ok, _},
        bondy_dealer:register(Uri, Opts, RealmUri, Ref)
    ).


register_callback(Config) ->
    RealmUri = key_value:get(realm_uri, Config),

    Uri1 = <<"com.example.", (bondy_utils:generate_fragment(12))/binary>>,
    Uri2 = <<"com.example.", (bondy_utils:generate_fragment(12))/binary>>,


    Opts = #{invoke => ?INVOKE_ROUND_ROBIN},

    Ref1 = bondy_ref:new(internal, {bondy_wamp_api, handle_call}),

    ?assertMatch(
        {ok, _},
        bondy_dealer:register(Uri1, Opts, RealmUri, Ref1)
    ),
    ?assertMatch(
        {error, already_exists},
        bondy_dealer:register(Uri1, Opts, RealmUri, Ref1),
        "Callbacks cannot use shared registration"
    ),

    %% Not allowed currently
    %% Uri2 = <<"com.example.", (bondy_utils:generate_fragment(12))/binary>>,
    % ?assertMatch(
    %     {ok, _},
    %     bondy_dealer:register(Uri2, Opts, RealmUri, Ref1),
    %     "We can have multiple URIs associates with the same Ref"
    % ),

    Ref2 = bondy_ref:new(internal, {bondy_wamp_api, resolve}),

    ?assertMatch(
        {error, already_exists},
        bondy_dealer:register(Uri1, Opts, RealmUri, Ref2)
    ),

    ?assertMatch(
        {ok, _},
        bondy_dealer:register(Uri2, Opts, RealmUri, Ref2),
        "We can register another URI"
    ),
    ?assertMatch(
        {error, already_exists},
        bondy_dealer:register(Uri2, Opts, RealmUri, Ref2),
        "Callbacks cannot use shared registration"
    ),

    %% This should fail, for this we should be using static callbacks
    Ref3 = bondy_ref:new(
        internal, {bondy_wamp_api, handle_call}, undefined, 'bondy2@127.0.0.1'
    ),
    ?assertMatch(
        {error, already_exists},
        bondy_dealer:register(Uri1, Opts, RealmUri, Ref3)
    ).


project(?EOT) ->
    [];

project(L) when is_list(L) ->
    project_aux(L);

project({L, R}) when is_list(L), is_list(R) ->
    {project_aux(L), R};

project({{L, R}, Cont}) ->
    {{project_aux(L), R}, Cont}.


project_aux(Entries) ->
    ?SORT([
        {
            bondy_registry_entry:uri(E),
            bondy_registry_entry:match_policy(E)
        } || E <- Entries
    ]).





%% =============================================================================
%% GENERIC
%% =============================================================================


add_test(Type, RealmUri, Uri, Opts, Ctxt) ->
    Ref = bondy_context:ref(Ctxt),
    SessionId = bondy_context:session_id(Ctxt),

    {ok, Entry, true} = bondy_registry:add(
        subscription, RealmUri, Uri, Opts, Ref
    ),

    Key = bondy_registry_entry:key(Entry),

    Id = bondy_registry_entry:id(Entry),

    ?assertEqual(
        {ok, Entry},
        bondy_registry:lookup(Type, Key),
        "The new entry should be returned by lookup/2"
    ),

    ?assertEqual(
        {ok, Entry},
        bondy_registry:lookup(Type, RealmUri, Id),
        "The new entry should be returned by lookup/3"
    ),

    ?assert(
        lists:member(Entry, bondy_registry:entries(Type, Ctxt)),
        "The new entry should be included in the list of stored entries"
    ),

    ?assert(
        lists:member(Entry, bondy_registry:entries(Type, RealmUri, SessionId)),
        "The new entry should be included in the list of stored entries "
        "for this session"
    ),

    ?assertEqual(
        {error, {already_exists, Entry}},
        bondy_registry:add(Type, RealmUri, Uri, Opts, Ref),
        "The registry should not allow duplicates"
    ).
