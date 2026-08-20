%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_registry_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_db_tables.hrl").
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
            register_callback,
            pattern_based_registration_is_not_optional,
            registry_rib_dual_write,
            rib_completion_selects_local,
            rib_completion_no_local_fails_fast,
            rib_self_heal_stale_cell,
            rib_retry_local_win,
            rib_retry_next_node,
            rib_retry_exhausted,
            rib_retry_requires_marker,
            rib_metrics_surface
        ]},
        {pubsub, [sequence], [
            sub_add_local_exact_1,
            sub_add_local_exact_2,
            sub_add_local_prefix_1,
            sub_add_local_prefix_2,
            sub_add_local_wildcard_1,
            sub_add_local_wildcard_,
            sub_del_local_exact_1,
            sub_del_local_exact_2,
            sub_session_death_cleans_registry,
            sub_same_uri_multiple_policies,
            sub_sessionless_refs,
            partition_pick_recovers_after_crash
        ]}
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
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
    Ctxt = bondy_context:new(Peer, {ws, text, json}, #{session => Session}),

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

    add_subscription_test(Type, RealmUri, Uri, Opts, Ctxt),

    Expected = {[{Uri, ?EXACT_MATCH}], []},

    ?assertEqual(
        Expected,
        project(bondy_registry:find_matches(Type, RealmUri, Uri)),
        "The trie should have the added entries. Remote subs should be empty"
    ),

    ?assertEqual(
        {[], []},
        bondy_registry:find_matches(Type, RealmUri, <<"com.foo.baz">>, #{}),
        "Should not match com.foo.baz"
    ).

sub_add_local_exact_2(Config) ->
    RealmUri = key_value:get(realm_uri, Config),
    Ctxt = key_value:get(context, Config),
    Type = subscription,
    Opts = #{match => ?EXACT_MATCH},
    Uri = <<"com.foo.baz">>,

    add_subscription_test(Type, RealmUri, Uri, Opts, Ctxt),

    Expected = {[{Uri, ?EXACT_MATCH}], []},

    ?assertEqual(
        Expected,
        project(bondy_registry:find_matches(Type, RealmUri, Uri)),
        "The trie should have the added entries. Remote subs should be empty"
    ),

    Expected2 = {[{<<"com.foo.bar">>, ?EXACT_MATCH}], []},

    ?assertEqual(
        Expected2,
        project(
            bondy_registry:find_matches(Type, RealmUri, <<"com.foo.bar">>, #{})
        ),
        "Should match com.foo.bar"
    ),

    ?assertEqual(
        {[], []},
        bondy_registry:find_matches(Type, RealmUri, <<"com.foo.other">>, #{})
    ).

sub_add_local_prefix_1(Config) ->
    RealmUri = key_value:get(realm_uri, Config),
    Ctxt = key_value:get(context, Config),
    Type = subscription,
    Opts = #{match => ?PREFIX_MATCH},
    Uri = <<"com.foo">>,

    add_subscription_test(Type, RealmUri, Uri, Opts, Ctxt),

    Expected = {[{Uri, ?PREFIX_MATCH}], []},

    ?assertEqual(
        Expected,
        project(bondy_registry:find_matches(Type, RealmUri, Uri)),
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
        project(bondy_registry:find_matches(Type, RealmUri, <<"com.foo.bar">>)),
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
        project(bondy_registry:find_matches(Type, RealmUri, <<"com.foo.baz">>)),
        "The trie should have the added entries. Remote subs should be empty"
    ),

    ?assertEqual(
        Expected,
        project(
            bondy_registry:find_matches(Type, RealmUri, <<"com.foo.other">>)
        ),
        "The trie match any subs starting with com.foo"
    ).

sub_add_local_prefix_2(Config) ->
    RealmUri = key_value:get(realm_uri, Config),
    Ctxt = key_value:get(context, Config),
    Type = subscription,

    add_subscription_test(
        Type, RealmUri, <<"com.a">>, #{match => ?PREFIX_MATCH}, Ctxt
    ),

    ?assertEqual(
        {
            ?SORT([
                {<<"com.a">>, ?PREFIX_MATCH}
            ]),
            []
        },
        project(
            bondy_registry:find_matches(subscription, RealmUri, <<"com.a">>)
        )
    ),

    add_subscription_test(
        Type, RealmUri, <<"com.a">>, #{match => ?EXACT_MATCH}, Ctxt
    ),

    ?assertEqual(
        {
            ?SORT([
                {<<"com.a">>, ?EXACT_MATCH}, {<<"com.a">>, ?PREFIX_MATCH}
            ]),
            []
        },
        project(
            bondy_registry:find_matches(subscription, RealmUri, <<"com.a">>)
        )
    ),

    add_subscription_test(
        Type, RealmUri, <<"com.a.b">>, #{match => ?PREFIX_MATCH}, Ctxt
    ),

    ?assertEqual(
        {
            ?SORT([
                {<<"com.a">>, ?PREFIX_MATCH}, {<<"com.a.b">>, ?PREFIX_MATCH}
            ]),
            []
        },
        project(
            bondy_registry:find_matches(subscription, RealmUri, <<"com.a.b">>)
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
            bondy_registry:find_matches(
                subscription, RealmUri, <<"com.a.b.c.d">>
            )
        )
    ).

sub_add_local_wildcard_1(Config) ->
    RealmUri = key_value:get(realm_uri, Config),
    Ctxt = key_value:get(context, Config),
    Type = subscription,
    Opts = #{match => ?WILDCARD_MATCH},

    add_subscription_test(Type, RealmUri, <<"com.">>, Opts, Ctxt),

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
            bondy_registry:find_matches(subscription, RealmUri, <<"com.a">>)
        )
    ),

    ?assertEqual(
        {?SORT([{<<"com.">>, ?WILDCARD_MATCH}]), []},
        project(
            bondy_registry:find_matches(subscription, RealmUri, <<"com.b">>)
        )
    ),

    ?assertEqual(
        {?SORT([{<<"com.">>, ?WILDCARD_MATCH}]), []},
        project(
            bondy_registry:find_matches(subscription, RealmUri, <<"com.bar">>)
        )
    ),

    ?assertEqual(
        {
            ?SORT([
                {<<"com.a">>, ?PREFIX_MATCH},
                {<<"com.a.b">>, ?PREFIX_MATCH}
            ]),
            []
        },
        project(
            bondy_registry:find_matches(subscription, RealmUri, <<"com.a.b">>)
        )
    ),

    ?assertEqual(
        {
            ?SORT([{<<"com.a">>, ?PREFIX_MATCH}, {<<"com.a.b">>, ?PREFIX_MATCH}]),
            []
        },
        project(
            bondy_registry:find_matches(
                subscription, RealmUri, <<"com.a.b.c.d">>
            )
        )
    ),

    add_subscription_test(Type, RealmUri, <<"....">>, Opts, Ctxt),

    add_subscription_test(Type, RealmUri, <<"com....">>, Opts, Ctxt),

    add_subscription_test(Type, RealmUri, <<".a...">>, Opts, Ctxt),

    add_subscription_test(Type, RealmUri, <<"..b..">>, Opts, Ctxt),

    add_subscription_test(Type, RealmUri, <<"...c.">>, Opts, Ctxt),

    add_subscription_test(Type, RealmUri, <<"....d">>, Opts, Ctxt),

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
            bondy_registry:find_matches(
                subscription, RealmUri, <<"com.a.b.c.d">>
            )
        )
    ).

sub_add_local_wildcard_(Config) ->
    Config.

sub_del_local_exact_1(Config) ->
    Config.

sub_del_local_exact_2(Config) ->
    Config.

%% The subscription-side counterpart of
%% `bondy_http_connector_callee_lifecycle_SUITE:callee_death_cleans_registry/1`
%% (registration side). A subscriber's session dying (a killed connection
%% process) must trigger the SAME `bondy_session_manager` DOWN handler ->
%% `bondy_router:flush/2` -> `bondy_broker:flush/2` -> registry `remove_all`
%% chain that the registration side already proves — orphaned subscriptions
%% left behind after every client of a load test disconnects is exactly the
%% shape of the memory growth observed under a real subscribe-heavy load
%% (Fly fleet-scale run, 2026-08-01/02): zero active connections, but the
%% fused registry projection never shrank back down.
sub_session_death_cleans_registry(Config) ->
    RealmUri = key_value:get(realm_uri, Config),
    Uri = <<"com.example.", (bondy_utils:generate_fragment(12))/binary>>,

    Pid = start_subscriber(RealmUri, Uri, #{match => ?EXACT_MATCH}),

    {Matches, _} = bondy_registry:find_matches(subscription, RealmUri, Uri),
    ?assertMatch([_ | _], Matches, "The subscriber must have a live entry"),

    ok = kill_and_wait(Pid),

    ?assert(
        await(
            fun() ->
                {M, _} =
                    bondy_registry:find_matches(subscription, RealmUri, Uri),
                M =:= []
            end,
            500
        ),
        "subscription was not cleaned after session death"
    ).

%% A killed partition must not leave pick/1 serving its dead pid: once
%% the supervisor restarts the partition and its init reconnects the
%% pool worker, pick must return the restarted partition's live pid.
partition_pick_recovers_after_crash(Config) ->
    RealmUri = key_value:get(realm_uri, Config),

    Pid0 = bondy_registry_partition:pick(RealmUri),
    ?assert(is_pid(Pid0) andalso is_process_alive(Pid0)),

    true = exit(Pid0, kill),

    ?assert(
        await(
            fun() ->
                case bondy_registry_partition:pick(RealmUri) of
                    Pid when is_pid(Pid), Pid =/= Pid0 ->
                        is_process_alive(Pid);
                    _ ->
                        %% restart window: the pool may briefly have no
                        %% connected worker for this slot
                        false
                end
            end,
            500
        ),
        "pick/1 must serve the restarted partition's live pid"
    ).

%% It is valid for one session to subscribe to the same URI under two
%% match policies — the duplicate check is keyed on (session, uri, POLICY),
%% so the second policy must create its own entry, not hit already_exists.
sub_same_uri_multiple_policies(Config) ->
    RealmUri = key_value:get(realm_uri, Config),
    Ctxt = key_value:get(context, Config),
    Ref = bondy_context:ref(Ctxt),
    Type = subscription,
    Uri = <<"com.multi.policy">>,

    {ok, {E1, _}} = bondy_registry:add(
        Type, RealmUri, Uri, #{match => ?EXACT_MATCH}, Ref
    ),
    {ok, {E2, _}} = bondy_registry:add(
        Type, RealmUri, Uri, #{match => ?PREFIX_MATCH}, Ref
    ),

    ?assertNotEqual(
        bondy_registry_entry:id(E1),
        bondy_registry_entry:id(E2),
        "Each match policy must get its own entry"
    ),

    ?assertMatch(
        {error, {already_exists, _}},
        bondy_registry:add(Type, RealmUri, Uri, #{match => ?EXACT_MATCH}, Ref),
        "Re-subscribing under an already-held policy is idempotent"
    ),
    ?assertMatch(
        {error, {already_exists, _}},
        bondy_registry:add(Type, RealmUri, Uri, #{match => ?PREFIX_MATCH}, Ref),
        "Re-subscribing under an already-held policy is idempotent"
    ).

%% Session-less (internal) subscribers: the SAME process reference
%% re-subscribing to a topic is idempotent (already_exists with its own
%% entry), while a DIFFERENT process subscribing to the same topic gets its
%% own entry — each internal subscriber needs its own delivery.
sub_sessionless_refs(Config) ->
    RealmUri = key_value:get(realm_uri, Config),
    Type = subscription,
    Uri = <<"com.sessionless.topic">>,
    Opts = #{match => ?EXACT_MATCH},

    PidA = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    PidB = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    RefA = bondy_ref:new(internal, PidA),
    RefB = bondy_ref:new(internal, PidB),

    {ok, {EntryA, _}} = bondy_registry:add(Type, RealmUri, Uri, Opts, RefA),

    ?assertMatch(
        {error, {already_exists, EntryA}},
        bondy_registry:add(Type, RealmUri, Uri, Opts, RefA),
        "Same internal ref re-subscribing is idempotent"
    ),

    {ok, {EntryB, _}} = bondy_registry:add(Type, RealmUri, Uri, Opts, RefB),

    ?assertNotEqual(
        bondy_registry_entry:id(EntryA),
        bondy_registry_entry:id(EntryB),
        "A different internal process gets its own subscription"
    ),

    ok = bondy_registry:remove(EntryA),
    ok = bondy_registry:remove(EntryB),
    PidA ! stop,
    PidB ! stop,
    ok.

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
        bondy_dealer:register(
            Uri, #{invoke => ?INVOKE_ROUND_ROBIN}, RealmUri, Ref
        )
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

pattern_based_registration_is_not_optional(Config) ->
    %% `wamp.dealer.pattern_based_registration` and
    %% `wamp.broker.pattern_based_subscription` used to be operator flags.
    %% Turning the first off refused the wildcard that
    %% `bondy_session_manager:register_node_session_get/1` registers to serve
    %% `wamp.session.get`, and the refusal came back as
    %% `{error, pattern_based_registration_disabled}` where a `case` had no
    %% clause for it — so setting the flag did not disable a feature, it stopped
    %% the node opening sessions at all. There is no longer anything to set:
    %% `bondy_config:setup_wamp/0` seats both, with no mapping to override them.
    %%
    %% Two halves, because a re-introduced flag and a dropped `set` break
    %% different ones.
    RealmUri = key_value:get(realm_uri, Config),

    %% One: the registration the router makes of itself. The same shape as the
    %% session manager's — an internal callback reference, wildcard policy, the
    %% empty component standing in for the session's id segment.
    Frag = bondy_utils:generate_fragment(12),
    Uri = <<"com.example.", Frag/binary, "..get">>,
    Ref = bondy_ref:new(internal, {bondy_session_api, get}),
    Opts = #{match => ?WILDCARD_MATCH, callback_args => [RealmUri]},
    ?assertMatch(
        {ok, _},
        bondy_dealer:register(Uri, Opts, RealmUri, Ref),
        "A wildcard registration is not refusable"
    ),

    %% Two: what WELCOME tells a client. Advertising these as absent is the
    %% quieter half of the same fault — a client that reads the roles before it
    %% registers a pattern would conclude the router cannot route one.
    #{dealer := #{features := DF}, broker := #{features := BF}} =
        bondy_router:roles(),
    ?assertEqual(true, maps:get(pattern_based_registration, DF, false)),
    ?assertEqual(true, maps:get(pattern_based_subscription, BF, false)).

%% Proves the RIB dual-write path end-to-end: local register/unregister
%% drives this node's replicated summary cell via the partition hooks + the
%% serialised recompute. The recompute is async (a cast to the partition
%% server), so cell assertions poll.
registry_rib_dual_write(Config) ->
    RealmUri = key_value:get(realm_uri, Config),
    Uri = <<"com.example.", (bondy_utils:generate_fragment(12))/binary>>,
    Opts = #{invoke => ?INVOKE_ROUND_ROBIN},
    Ref = bondy_ref:new(internal),
    Table = bondy_namespace_catalog:table(?BONDY_DB_REGISTRATION_RIB_TAB),
    Key = term_to_binary(
        {RealmUri, ?EXACT_MATCH, Uri, bondy_config:nodestring()}
    ),

    %% Two shared registrations -> one summary cell, count 2.
    ?assertMatch({ok, _}, bondy_dealer:register(Uri, Opts, RealmUri, Ref)),
    ?assertMatch({ok, _}, bondy_dealer:register(Uri, Opts, RealmUri, Ref)),

    %% `bondy_db:read/3` returns the RAW `bondy_oplog_crdt_struct`
    %% projection (registered directly, no per-use-case wrapper) —
    %% schema fields are top-level, with `earliest`/`latest` as the
    %% min/max ratchet registers over the group's creation times.
    ?assert(
        await_cell(Table, RealmUri, Key, fun
            (
                {ok, {
                    #{
                        invoke := I,
                        count := 2,
                        earliest := E,
                        latest := L
                    },
                    _
                }}
            ) when
                I == ?INVOKE_ROUND_ROBIN,
                is_integer(E),
                is_integer(L),
                E =< L
            ->
                true;
            (_) ->
                false
        end),
        "Two shared registrations must summarise to one cell with count 2"
    ),

    %% Removing one registration shrinks the cell to count 1.
    Entries = bondy_registry:find_matches(registration, RealmUri, Uri),
    ?assertEqual(2, length(Entries)),
    [E1, E2] = Entries,
    ok = bondy_registry:remove(E1),

    ?assert(
        await_cell(Table, RealmUri, Key, fun
            ({ok, {#{count := 1}, _}}) -> true;
            (_) -> false
        end),
        "Removing one of two registrations must leave count 1"
    ),

    %% Removing the last registration settles the cell to count=0 — no
    %% explicit clear; a count=0 cell is "not routable" (see
    %% `bondy_registry_rib`'s moduledoc "Concurrency model"), physically
    %% reclaimed later via `stabilize/2` once causally stable.
    ok = bondy_registry:remove(E2),

    ?assert(
        await_cell(Table, RealmUri, Key, fun
            ({ok, {#{count := 0}, _}}) -> true;
            (_) -> false
        end),
        "Removing the last registration must settle the cell to count=0"
    ),

    %% Subscriptions: reachability-only cells (`#{count}`).
    Ctxt = key_value:get(context, Config),
    SubUri = <<"com.example.", (bondy_utils:generate_fragment(12))/binary>>,
    add_subscription_test(
        subscription, RealmUri, SubUri, #{match => ?EXACT_MATCH}, Ctxt
    ),
    SubTable = bondy_namespace_catalog:table(?BONDY_DB_SUBSCRIPTION_RIB_TAB),
    SubKey = term_to_binary(
        {RealmUri, ?EXACT_MATCH, SubUri, bondy_config:nodestring()}
    ),

    %% Subscription is a bare `bondy_oplog_crdt_pn_counter`, registered
    %% directly — its raw projection is a plain integer, not a map
    %% (`bondy_registry_rib:reshape_summary/2` wraps it as `#{count => N}`
    %% for consumers, unit-tested on its own).
    ?assert(
        await_cell(SubTable, RealmUri, SubKey, fun
            ({ok, {1, _}}) -> true;
            (_) -> false
        end),
        "A local subscription must produce a count-only cell"
    ),

    {[SubEntry], []} =
        bondy_registry:find_matches(subscription, RealmUri, SubUri),
    ok = bondy_registry:remove(SubEntry),

    ?assert(
        await_cell(SubTable, RealmUri, SubKey, fun
            ({ok, {0, _}}) -> true;
            (_) -> false
        end),
        "Removing the subscription must settle the cell to count=0"
    ),

    %% The consistency gate over the whole realm — including every entry the
    %% earlier cases in this suite left registered: the node set derivable
    %% from summaries must equal the node set derivable from full entries.
    %% Recomputes are async, so poll to a fixpoint.
    ?assert(
        await(fun() -> bondy_registry_rib:check(RealmUri) =:= [] end, 500),
        lists:flatten(
            io_lib:format(
                "RIB summaries must agree with the full-entry view, got: ~p",
                [bondy_registry_rib:check(RealmUri)]
            )
        )
    ).

%% Owner-side completion: a node-addressed forwarded CALL (`rib_completion`
%% tag) must IGNORE the sender's entry hint and re-select among this node's
%% live local registrations — here a callback procedure, so the selected
%% callee is applied and the RESULT is sent back to the caller ref.
rib_completion_selects_local(Config) ->
    RealmUri = key_value:get(realm_uri, Config),
    Uri = <<"com.example.", (bondy_utils:generate_fragment(12))/binary>>,
    Ref = bondy_ref:new(internal, {?MODULE, rib_echo}),
    ?assertMatch(
        {ok, _},
        bondy_dealer:register(Uri, #{invoke => ?INVOKE_SINGLE}, RealmUri, Ref)
    ),

    Caller = bondy_ref:new(internal),
    %% A deliberately bogus hint: completion must not trust it.
    Hint = bondy_ref:new(internal),
    Call = bondy_wamp_message:call(1, #{}, Uri),

    ok = bondy_dealer:forward(Call, Hint, #{
        realm_uri => RealmUri,
        from => Caller,
        rib_completion => true
    }),

    receive
        {?BONDY_REQ, _, RealmUri, #result{args = [<<"pong">>]}} ->
            ok;
        {?BONDY_REQ, _, RealmUri, Other} ->
            error({unexpected_response, Other})
    after 5000 ->
        error(no_response)
    end.

%% Owner-side completion with NO live local registration (a stale route)
%% must fail fast back to the caller with wamp.error.no_eligible_callee —
%% never hang, never re-forward.
rib_completion_no_local_fails_fast(Config) ->
    RealmUri = key_value:get(realm_uri, Config),
    Uri = <<"com.example.", (bondy_utils:generate_fragment(12))/binary>>,

    Caller = bondy_ref:new(internal),
    Call = bondy_wamp_message:call(1, #{}, Uri),

    ok = bondy_dealer:forward(Call, bondy_ref:new(internal), #{
        realm_uri => RealmUri,
        from => Caller,
        rib_completion => true
    }),

    receive
        {?BONDY_REQ, _, RealmUri, #error{
            request_type = ?CALL,
            request_id = 1,
            error_uri = ?WAMP_NO_ELIGIBLE_CALLE
        }} ->
            ok;
        {?BONDY_REQ, _, RealmUri, Other} ->
            error({unexpected_response, Other})
    after 5000 ->
        error(no_response)
    end.

%% A merged RIB cell naming THIS node is an echo of our own writes; when it
%% does not match local truth — e.g. peers merging back a pre-restart cell —
%% self_heal corrects `count` via a corrective delta (`LocalCount -
%% ReplicatedCount`): a stale cell with no local members settles to
%% count=0 (no explicit clear — see `bondy_registry_rib`'s moduledoc), a
%% clobbered one is brought back down to the true local count. This closes
%% the resurrection hole for a rebooted node whose peers still hold its old
%% summaries.
rib_self_heal_stale_cell(Config) ->
    RealmUri = key_value:get(realm_uri, Config),
    Uri = <<"com.example.", (bondy_utils:generate_fragment(12))/binary>>,
    Table = bondy_namespace_catalog:table(?BONDY_DB_REGISTRATION_RIB_TAB),
    Key = term_to_binary(
        {RealmUri, ?EXACT_MATCH, Uri, bondy_config:nodestring()}
    ),

    %% Plant a stale self cell via real per-field CRDT ops (the write shape
    %% `bondy_registry_rib:apply_added/1` itself uses), as an AAE merge-back
    %% would leave one, and simulate its merge event reaching the reactor.
    %% There is no local registration for the URI, so self_heal's corrective
    %% delta (0 - 1) must settle it to count=0.
    ok = bondy_db:apply_batch(Table, RealmUri, Key, [
        {apply, count, {inc, 1}},
        {apply, invoke, {set, ?INVOKE_SINGLE}},
        {apply, earliest, {set, 1}},
        {apply, latest, {set, 1}}
    ]),
    ok = bondy_registry_rib:on_remote_set(registration, Key, #{}),
    ?assert(
        await_cell(Table, RealmUri, Key, fun
            ({ok, {#{count := 0}, _}}) -> true;
            (_) -> false
        end),
        "A stale self cell with no local members must settle to count=0"
    ),

    %% With a live local registration the same echo re-asserts the truth.
    Ref = bondy_ref:new(internal),
    {ok, _} = bondy_dealer:register(
        Uri, #{invoke => ?INVOKE_SINGLE}, RealmUri, Ref
    ),
    ?assert(
        await_cell(Table, RealmUri, Key, fun
            ({ok, {#{count := 1}, _}}) -> true;
            (_) -> false
        end)
    ),
    %% Clobber the replicated count to 7 with no matching local entries.
    ok = bondy_db:apply_batch(Table, RealmUri, Key, [{apply, count, {inc, 6}}]),
    ok = bondy_registry_rib:on_remote_set(registration, Key, #{}),
    ?assert(
        await_cell(Table, RealmUri, Key, fun
            ({ok, {#{count := 1}, _}}) -> true;
            (_) -> false
        end),
        "A clobbered self cell must be re-asserted from local truth"
    ),

    %% Cleanup: leave the realm as we found it.
    Entries = bondy_registry:find_matches(registration, RealmUri, Uri),
    _ = [ok = bondy_registry:remove(E) || E <- Entries],
    ok.

%% Bounded pre-invocation retry, local absorption: a node-addressed CALL
%% came back with the owner's completion-miss ERROR; with budget left and a
%% live LOCAL registration, the retry must re-select — `self` competes
%% again — and complete the call locally instead of relaying the error.
rib_retry_local_win(Config) ->
    RealmUri = key_value:get(realm_uri, Config),
    Uri = <<"com.example.", (bondy_utils:generate_fragment(12))/binary>>,
    Ref = bondy_ref:new(internal, {?MODULE, rib_echo}),
    ?assertMatch(
        {ok, _},
        bondy_dealer:register(Uri, #{invoke => ?INVOKE_SINGLE}, RealmUri, Ref)
    ),

    Caller = bondy_ref:new(internal),
    CallId = 71,
    ok = add_rib_retry_promise(
        RealmUri, Caller, CallId, Uri, [<<"deadnode@nohost">>], 1
    ),
    ok = bondy_dealer:forward(
        completion_miss_error(CallId, #{rib_completion_miss => true}),
        Caller,
        #{realm_uri => RealmUri}
    ),

    receive
        {?BONDY_REQ, _, RealmUri, #result{args = [<<"pong">>]}} ->
            ok;
        {?BONDY_REQ, _, RealmUri, Other} ->
            error({unexpected_response, Other})
    after 5000 ->
        error(no_response)
    end.

%% Retry, next-node leg: no local registration, one UNTRIED stub node
%% remains. The retry must re-forward node-addressed to it — no error to
%% the caller — under a NEW call promise carrying the shrunk budget and
%% the failed node in the tried set.
rib_retry_next_node(Config) ->
    RealmUri = key_value:get(realm_uri, Config),
    Uri = <<"com.example.", (bondy_utils:generate_fragment(12))/binary>>,
    Dead = <<"deadnode@nohost">>,
    Next = <<"nextnode@nohost">>,
    StubKey = term_to_binary({RealmUri, ?EXACT_MATCH, Uri, Next}),
    Summary = #{
        invoke => ?INVOKE_SINGLE, count => 1, earliest => 1, latest => 1
    },
    ok = bondy_registry_rib:on_remote_set(registration, StubKey, Summary),

    Caller = bondy_ref:new(internal),
    CallId = 72,
    ok = add_rib_retry_promise(RealmUri, Caller, CallId, Uri, [Dead], 1),
    ok = bondy_dealer:forward(
        completion_miss_error(CallId, #{rib_completion_miss => true}),
        Caller,
        #{realm_uri => RealmUri}
    ),

    %% No response reaches the caller — the call is in flight again.
    receive
        {?BONDY_REQ, _, RealmUri, Unexpected} ->
            error({unexpected_response, Unexpected})
    after 1000 ->
        ok
    end,

    %% The re-routed leg holds a fresh promise: budget spent, both nodes
    %% recorded as tried.
    Key = bondy_rpc_promise:call_key_pattern(RealmUri, Caller, CallId),
    {ok, Promise} = bondy_rpc_promise:find(Key),
    ?assertMatch(
        #{rib_retry := #{remaining := 0, tried := [Next, Dead]}},
        bondy_rpc_promise:info(Promise)
    ),
    %% Cleanup: the in-flight leg targets a fictional node.
    _ = bondy_rpc_promise:take(Key),
    ok = bondy_registry_rib:on_remote_clear(registration, StubKey).

%% Retry with an exhausted budget: the completion-miss ERROR is final and
%% must reach the caller with the routing-internal marker stripped.
rib_retry_exhausted(Config) ->
    RealmUri = key_value:get(realm_uri, Config),
    Uri = <<"com.example.", (bondy_utils:generate_fragment(12))/binary>>,
    Ref = bondy_ref:new(internal, {?MODULE, rib_echo}),
    ?assertMatch(
        {ok, _},
        bondy_dealer:register(Uri, #{invoke => ?INVOKE_SINGLE}, RealmUri, Ref)
    ),

    Caller = bondy_ref:new(internal),
    CallId = 73,
    ok = add_rib_retry_promise(
        RealmUri, Caller, CallId, Uri, [<<"deadnode@nohost">>], 0
    ),
    ok = bondy_dealer:forward(
        completion_miss_error(CallId, #{rib_completion_miss => true}),
        Caller,
        #{realm_uri => RealmUri}
    ),

    receive
        {?BONDY_REQ, _, RealmUri, #error{
            request_type = ?CALL,
            request_id = CallId,
            error_uri = ?WAMP_NO_ELIGIBLE_CALLE,
            details = Details
        }} ->
            ?assertNot(maps:is_key(rib_completion_miss, Details));
        {?BONDY_REQ, _, RealmUri, Other} ->
            error({unexpected_response, Other})
    after 5000 ->
        error(no_response)
    end.

%% A no_eligible_callee WITHOUT the completion-miss marker — e.g. produced
%% by a callee-death flush, where an invocation WAS in flight — must never
%% be retried, even with budget and a live local alternative: at-most-once
%% invocation would otherwise break.
rib_retry_requires_marker(Config) ->
    RealmUri = key_value:get(realm_uri, Config),
    Uri = <<"com.example.", (bondy_utils:generate_fragment(12))/binary>>,
    Ref = bondy_ref:new(internal, {?MODULE, rib_echo}),
    ?assertMatch(
        {ok, _},
        bondy_dealer:register(Uri, #{invoke => ?INVOKE_SINGLE}, RealmUri, Ref)
    ),

    Caller = bondy_ref:new(internal),
    CallId = 74,
    ok = add_rib_retry_promise(
        RealmUri, Caller, CallId, Uri, [<<"deadnode@nohost">>], 1
    ),
    ok = bondy_dealer:forward(
        completion_miss_error(CallId, #{}),
        Caller,
        #{realm_uri => RealmUri}
    ),

    receive
        {?BONDY_REQ, _, RealmUri, #error{
            request_type = ?CALL,
            request_id = CallId,
            error_uri = ?WAMP_NO_ELIGIBLE_CALLE
        }} ->
            ok;
        {?BONDY_REQ, _, RealmUri, Other} ->
            error({unexpected_response, Other})
    after 5000 ->
        error(no_response)
    end.

%% The RIB observability surface: every family moves at its capture site.
%% Values are read as deltas — the suite's earlier cases already moved
%% most of these counters.
rib_metrics_surface(Config) ->
    RealmUri = key_value:get(realm_uri, Config),
    Uri = <<"com.example.", (bondy_utils:generate_fragment(12))/binary>>,
    V = fun(Name, Label) ->
        case bondy_metrics:value(#{name => Name, label => Label}) of
            undefined -> 0;
            N -> N
        end
    end,

    %% Occupancy: the members gauge follows local entry lifecycle.
    Members0 = V(bondy_registry_rib_members, #{}),
    Ref = bondy_ref:new(internal, {?MODULE, rib_echo}),
    {ok, _} = bondy_dealer:register(
        Uri, #{invoke => ?INVOKE_SINGLE}, RealmUri, Ref
    ),
    ?assertEqual(Members0 + 1, V(bondy_registry_rib_members, #{})),

    %% Stub occupancy follows remote cell lifecycle, by type.
    Stubs0 = V(bondy_registry_rib_stub_cells, #{type => registration}),
    PeerKey = term_to_binary(
        {RealmUri, ?EXACT_MATCH, Uri, <<"metrics_peer@nohost">>}
    ),
    Summary = #{
        invoke => ?INVOKE_SINGLE, count => 1, earliest => 1, latest => 1
    },
    ok = bondy_registry_rib:on_remote_set(registration, PeerKey, Summary),
    ?assertEqual(
        Stubs0 + 1, V(bondy_registry_rib_stub_cells, #{type => registration})
    ),
    %% Upserting the same stub must not drift the gauge.
    ok = bondy_registry_rib:on_remote_set(registration, PeerKey, Summary),
    ?assertEqual(
        Stubs0 + 1, V(bondy_registry_rib_stub_cells, #{type => registration})
    ),
    ok = bondy_registry_rib:on_remote_clear(registration, PeerKey),
    ?assertEqual(
        Stubs0, V(bondy_registry_rib_stub_cells, #{type => registration})
    ),

    %% Retry outcomes: a completion miss absorbed by the local
    %% registration counts as a `local` retry.
    Local0 = V(bondy_rpc_rib_retries_total, #{outcome => local}),
    Caller = bondy_ref:new(internal),
    ok = add_rib_retry_promise(
        RealmUri, Caller, 91, Uri, [<<"deadnode@nohost">>], 1
    ),
    ok = bondy_dealer:forward(
        completion_miss_error(91, #{rib_completion_miss => true}),
        Caller,
        #{realm_uri => RealmUri}
    ),
    receive
        {?BONDY_REQ, _, RealmUri, #result{}} -> ok
    after 5000 ->
        error(no_response)
    end,
    ?assertEqual(
        Local0 + 1, V(bondy_rpc_rib_retries_total, #{outcome => local})
    ),

    %% Owner-side completion outcomes.
    Ok0 = V(bondy_rpc_rib_completions_total, #{outcome => ok}),
    Miss0 = V(bondy_rpc_rib_completions_total, #{outcome => miss}),
    ok = bondy_dealer:forward(
        bondy_wamp_message:call(92, #{}, Uri),
        bondy_ref:new(internal),
        #{realm_uri => RealmUri, from => Caller, rib_completion => true}
    ),
    receive
        {?BONDY_REQ, _, RealmUri, #result{}} -> ok
    after 5000 ->
        error(no_response)
    end,
    NoProc = <<"com.example.", (bondy_utils:generate_fragment(12))/binary>>,
    ok = bondy_dealer:forward(
        bondy_wamp_message:call(93, #{}, NoProc),
        bondy_ref:new(internal),
        #{realm_uri => RealmUri, from => Caller, rib_completion => true}
    ),
    receive
        {?BONDY_REQ, _, RealmUri, #error{request_id = 93}} -> ok
    after 5000 ->
        error(no_response)
    end,
    ?assertEqual(Ok0 + 1, V(bondy_rpc_rib_completions_total, #{outcome => ok})),
    ?assertEqual(
        Miss0 + 1, V(bondy_rpc_rib_completions_total, #{outcome => miss})
    ),

    %% The divergence sweep gauges the node-wide total. The raw read
    %% distinguishes "sweep ran, converged" (0) from "never gauged"
    %% (undefined).
    bondy_registry ! rib_check,
    ?assert(
        await(
            fun() ->
                0 =:=
                    bondy_metrics:value(#{
                        name => bondy_registry_rib_divergences
                    })
            end,
            500
        ),
        "the sweep must gauge zero divergences on a converged node"
    ),

    %% Cleanup.
    Entries = bondy_registry:find_matches(registration, RealmUri, Uri),
    _ = [ok = bondy_registry:remove(E) || E <- Entries],
    ok.

%% @private
%% A caller-side call promise as `rib_forward_call` leaves it: the prepared
%% entry-less CALL plus the retry state.
add_rib_retry_promise(RealmUri, Caller, CallId, Uri, Tried, Remaining) ->
    Call0 = bondy_wamp_message:call(CallId, #{}, Uri),
    Call = Call0#call{
        options = (Call0#call.options)#{
            '$private' => #{
                call_id => CallId,
                registration_id => undefined,
                invocation_details => #{procedure => Uri, trust_level => 0}
            }
        }
    },
    Promise = bondy_rpc_promise:new_call(RealmUri, Caller, CallId, #{
        procedure_uri => Uri,
        timeout => 10000,
        rib_retry => #{
            call => Call,
            opts => #{call_opts => #{}},
            tried => Tried,
            remaining => Remaining
        }
    }),
    bondy_rpc_promise:add(Promise).

%% @private
%% The completion-miss ERROR as the owner node sends it (the marker is
%% stamped on the record, mirroring `reply_no_eligible_callee`).
completion_miss_error(CallId, Details) ->
    Error = bondy_wamp_message:error(
        ?CALL,
        CallId,
        #{},
        ?WAMP_NO_ELIGIBLE_CALLE,
        [<<"There are no eligible callees for the procedure.">>]
    ),
    Error#error{details = maps:merge(Error#error.details, Details)}.

%% The callback target for rib_completion_selects_local. The dynamic
%% callback convention: return {ok, Details, Args, KWArgs} -> RESULT.
rib_echo() ->
    {ok, #{}, [<<"pong">>], #{}}.

rib_echo(_) ->
    rib_echo().

rib_echo(_, _) ->
    rib_echo().

%% @private
await(_Pred, 0) ->
    false;
await(Pred, N) ->
    case Pred() of
        true ->
            true;
        false ->
            timer:sleep(10),
            await(Pred, N - 1)
    end.

%% @private
%% Opens a real, `bondy_session_manager`-monitored session in a dedicated
%% process (so killing it is a genuine process-monitor DOWN, exercising the
%% same cleanup trigger a real WAMP connection dying would), subscribes to
%% `Uri` through it, then blocks until killed by the caller.
start_subscriber(RealmUri, Uri, Opts) ->
    Parent = self(),
    Pid = spawn(fun() ->
        SessionId = bondy_session_id:new(),
        SessionOpts = #{
            type => internal,
            roles => #{subscriber => #{}},
            agent => <<"bondy_registry_SUITE">>,
            is_anonymous => true
        },
        {ok, Session} = bondy_session_manager:open(
            SessionId, RealmUri, SessionOpts
        ),
        Ctxt = bondy_context:new(
            {{127, 0, 0, 1}, 0}, {ws, text, json}, #{session => Session}
        ),
        Ref = bondy_context:ref(Ctxt),
        {ok, {_Entry, true}} =
            bondy_registry:add(subscription, RealmUri, Uri, Opts, Ref),
        Parent ! {self(), ready},
        receive
            stop -> ok
        end
    end),
    receive
        {Pid, ready} -> Pid
    after 5000 ->
        ct:fail({timeout_waiting_for_subscriber_ready, Pid})
    end.

%% @private
kill_and_wait(Pid) ->
    MonRef = monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', MonRef, process, _, _} -> ok
    after 5000 ->
        ct:fail({timeout_waiting_for_exit, Pid})
    end.

%% @private
%% Polls the RIB cell until `Pred(ReadResult)` or ~5s.
await_cell(Table, RealmUri, Key, Pred) ->
    await_cell(Table, RealmUri, Key, Pred, 500).

await_cell(_, _, _, _, 0) ->
    false;
await_cell(Table, RealmUri, Key, Pred, N) ->
    case Pred(bondy_db:read(Table, RealmUri, Key)) of
        true ->
            true;
        false ->
            timer:sleep(10),
            await_cell(Table, RealmUri, Key, Pred, N - 1)
    end.

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
        }
     || E <- Entries
    ]).

%% =============================================================================
%% GENERIC
%% =============================================================================

add_subscription_test(Type, RealmUri, Uri, Opts, Ctxt) ->
    Ref = bondy_context:ref(Ctxt),
    RealmUri = bondy_context:realm_uri(Ctxt),
    SessionId = bondy_context:session_id(Ctxt),

    {ok, {Entry, true}} = bondy_registry:add(Type, RealmUri, Uri, Opts, Ref),

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
        lists:member(Entry, bondy_registry:entries(Type, RealmUri, SessionId)),
        "The new entry should be included in the list of stored entries "
        "for this session"
    ),

    %% {Matches, _} = bondy_registry:match(Type, RealmUri, Uri),

    %% ?assert(
    %%     lists:member(Entry, Matches),
    %%     {Entry, Matches}
    %% ),

    ?assertEqual(
        {error, {already_exists, Entry}},
        bondy_registry:add(Type, RealmUri, Uri, Opts, Ref),
        "The registry should not allow duplicates"
    ).
