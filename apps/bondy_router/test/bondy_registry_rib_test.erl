%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Whitebox eunit for `bondy_registry_rib:recompute/5` — the serialised
%% routing-summary derivation — driven with synthetic members rows against a
%% provisioned catalogue (the ephemeral `registry` DB with the RIB tables).
%% The hook-driven end-to-end path (register/unregister → cell) is covered
%% in `bondy_registry_SUITE`.
-module(bondy_registry_rib_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_db_tables.hrl").

-define(CAT, bondy_namespace_catalog).
-define(REALM, <<"com.example.rib">>).
-define(URI, <<"com.example.rib.proc">>).

recompute_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(bondy_db),
            ok
        end,
        fun(_) -> ok end, [
            {timeout, 60, {"registration summary lifecycle", fun regs/0}},
            {timeout, 60, {"subscription summary lifecycle", fun subs/0}},
            {timeout, 60, {"remote stub lifecycle", fun stubs/0}},
            {timeout, 60, {"subscriber node discovery", fun sub_nodes/0}},
            {timeout, 60, {"update damping", fun damping/0}}
        ]}.

regs() ->
    with_catalog(fun(Tab) ->
        Table = ?CAT:table(?BONDY_DB_REGISTRATION_RIB_TAB),
        ?assertMatch(#{db_name := registry}, Table),
        Key = cell_key(?EXACT_MATCH, ?URI),

        %% Two live local entries -> one cell, count 2, invoke carried,
        %% earliest/latest = the ends of the Created order.
        row(Tab, registration, ?EXACT_MATCH, 100, 1, ?INVOKE_ROUND_ROBIN),
        row(Tab, registration, ?EXACT_MATCH, 200, 2, ?INVOKE_ROUND_ROBIN),
        ok = recompute(Tab, registration),
        ?assertMatch(
            {ok, {
                #{
                    invoke := ?INVOKE_ROUND_ROBIN,
                    count := 2,
                    earliest := 100,
                    latest := 200
                },
                _Hlc
            }},
            bondy_db:read(Table, ?REALM, Key)
        ),

        %% Removing the latest entry shrinks the summary exactly.
        true = ets:delete(
            Tab, {registration, ?REALM, ?EXACT_MATCH, ?URI, 200, 2}
        ),
        ok = recompute(Tab, registration),
        ?assertMatch(
            {ok, {#{count := 1, earliest := 100, latest := 100}, _}},
            bondy_db:read(Table, ?REALM, Key)
        ),

        %% Last member gone -> the cell is cleared (presence `dead`).
        true = ets:delete(
            Tab, {registration, ?REALM, ?EXACT_MATCH, ?URI, 100, 1}
        ),
        ok = recompute(Tab, registration),
        ?assertEqual(
            {error, not_found}, bondy_db:read(Table, ?REALM, Key)
        ),

        %% A different policy for the same URI is a different cell —
        %% and prefix members do not leak into the exact summary.
        row(Tab, registration, ?PREFIX_MATCH, 300, 3, ?INVOKE_SINGLE),
        ok = recompute(Tab, registration, ?PREFIX_MATCH),
        ?assertEqual({error, not_found}, bondy_db:read(Table, ?REALM, Key)),
        ?assertMatch(
            {ok, {#{invoke := ?INVOKE_SINGLE, count := 1}, _}},
            bondy_db:read(Table, ?REALM, cell_key(?PREFIX_MATCH, ?URI))
        )
    end).

subs() ->
    with_catalog(fun(Tab) ->
        Table = ?CAT:table(?BONDY_DB_SUBSCRIPTION_RIB_TAB),
        Key = cell_key(?EXACT_MATCH, ?URI),

        %% Subscription cells are reachability-only: `#{count}`.
        row(Tab, subscription, ?EXACT_MATCH, 100, 1, undefined),
        row(Tab, subscription, ?EXACT_MATCH, 200, 2, undefined),
        ok = recompute(Tab, subscription),
        ?assertMatch(
            {ok, {#{count := 2} = V, _}} when map_size(V) == 1,
            bondy_db:read(Table, ?REALM, Key)
        ),

        true = ets:delete(
            Tab, {subscription, ?REALM, ?EXACT_MATCH, ?URI, 100, 1}
        ),
        true = ets:delete(
            Tab, {subscription, ?REALM, ?EXACT_MATCH, ?URI, 200, 2}
        ),
        ok = recompute(Tab, subscription),
        ?assertEqual({error, not_found}, bondy_db:read(Table, ?REALM, Key))
    end).

%% The remote-merge reactions maintain the stub store: `{set, Summary}`
%% upserts, `clear` drops, self-origin and garbage are ignored (totality).
stubs() ->
    ok = ensure_stubs_tab(),
    Peer = <<"peer@127.0.0.1">>,
    PeerKey = cell_key(?EXACT_MATCH, ?URI, Peer),
    Summary = #{
        invoke => ?INVOKE_ROUND_ROBIN,
        count => 2,
        earliest => 100,
        latest => 200
    },

    ok = bondy_registry_rib:on_remote_set(registration, PeerKey, Summary),
    ?assertEqual(
        [{Peer, Summary}],
        bondy_registry_rib:stub_nodes(
            registration, ?REALM, ?EXACT_MATCH, ?URI
        )
    ),
    ?assertEqual(
        [],
        bondy_registry_rib:stub_nodes(
            subscription, ?REALM, ?EXACT_MATCH, ?URI
        ),
        "Registration stubs must not leak into the subscription view"
    ),

    %% Self-origin cells are never stubbed (an owner is not its own peer).
    SelfKey = cell_key(?EXACT_MATCH, <<"com.example.rib.self">>),
    ok = bondy_registry_rib:on_remote_set(
        registration, SelfKey, Summary
    ),
    ?assertEqual(
        [],
        bondy_registry_rib:stub_nodes(
            registration, ?REALM, ?EXACT_MATCH, <<"com.example.rib.self">>
        )
    ),

    %% Garbage keys/values are ignored — the reaction is total.
    ok = bondy_registry_rib:on_remote_set(
        registration, <<"not a term">>, Summary
    ),
    ok = bondy_registry_rib:on_remote_set(
        registration, PeerKey, not_a_map
    ),
    ok = bondy_registry_rib:on_remote_clear(registration, <<"not a term">>),

    ok = bondy_registry_rib:on_remote_clear(registration, PeerKey),
    ?assertEqual(
        [],
        bondy_registry_rib:stub_nodes(
            registration, ?REALM, ?EXACT_MATCH, ?URI
        )
    ).

%% `subscription_nodes/3` — the broker's forwarding set: every remote node
%% with a subscription matching the topic, across policies, deduped, as
%% node atoms.
sub_nodes() ->
    ok = ensure_stubs_tab(),
    PeerA = <<"suba@127.0.0.1">>,
    PeerB = <<"subb@127.0.0.1">>,
    Realm = <<"com.example.ribsub">>,
    Topic = <<"com.example.ribsub.topic.a">>,

    SKey = fun(Policy, Uri, Node) ->
        term_to_binary({Realm, Policy, Uri, Node})
    end,

    %% PeerA subscribes the topic exactly; PeerB via a prefix pattern; PeerA
    %% again via a wildcard pattern (dedupe must collapse it).
    ok = bondy_registry_rib:on_remote_set(
        subscription, SKey(?EXACT_MATCH, Topic, PeerA), #{count => 1}
    ),
    ok = bondy_registry_rib:on_remote_set(
        subscription,
        SKey(?PREFIX_MATCH, <<"com.example.ribsub.topic.">>, PeerB),
        #{count => 3}
    ),
    ok = bondy_registry_rib:on_remote_set(
        subscription,
        SKey(?WILDCARD_MATCH, <<"com.example.ribsub..a">>, PeerA),
        #{count => 1}
    ),

    ?assertEqual(
        ['suba@127.0.0.1', 'subb@127.0.0.1'],
        bondy_registry_rib:subscription_nodes(Realm, Topic, #{})
    ),

    %% Pinning `match` to exact drops the pattern subscribers.
    ?assertEqual(
        ['suba@127.0.0.1'],
        bondy_registry_rib:subscription_nodes(
            Realm, Topic, #{match => ?EXACT_MATCH}
        )
    ),

    %% A topic matched by the prefix pattern only.
    ?assertEqual(
        ['subb@127.0.0.1'],
        bondy_registry_rib:subscription_nodes(
            Realm, <<"com.example.ribsub.topic.zz">>, #{}
        )
    ),

    %% Registration stubs never leak into the subscription view.
    ok = bondy_registry_rib:on_remote_set(
        registration,
        SKey(?EXACT_MATCH, <<"com.example.ribsub.proc">>, PeerB),
        #{invoke => ?INVOKE_SINGLE, count => 1, earliest => 1, latest => 1}
    ),
    ?assertEqual(
        [],
        bondy_registry_rib:subscription_nodes(
            Realm, <<"com.example.ribsub.proc">>, #{}
        )
    ),

    %% Cleanup so other tests sharing the named table see none of this.
    _ = [
        bondy_registry_rib:on_remote_clear(subscription, K)
     || K <- [
            SKey(?EXACT_MATCH, Topic, PeerA),
            SKey(?PREFIX_MATCH, <<"com.example.ribsub.topic.">>, PeerB),
            SKey(?WILDCARD_MATCH, <<"com.example.ribsub..a">>, PeerA)
        ]
    ],
    ok = bondy_registry_rib:on_remote_clear(
        registration, SKey(?EXACT_MATCH, <<"com.example.ribsub.proc">>, PeerB)
    ).

%% Update damping: cell creation and selection-relevant changes (earliest)
%% write through; count/latest-only changes on a live cell are suppressed
%% within the window and written once it closes (here: by switching the
%% window off, standing in for the trailing recompute the partition server
%% runs in production).
damping() ->
    %% In production the damp table is claimed via bondy_table_manager (a
    %% bondy_router process) on first use; here a bare named table
    %% suffices — `ensure_damp_table` reuses any existing one.
    ok = ensure_named_tab(bondy_registry_rib_damp, set),
    with_catalog(fun(Tab) ->
        Table = ?CAT:table(?BONDY_DB_REGISTRATION_RIB_TAB),
        Key = cell_key(?EXACT_MATCH, ?URI),
        ok = application:set_env(bondy_router, registry_rib_damping, 60000),
        try
            %% 0→1 (creation) is never damped.
            row(Tab, registration, ?EXACT_MATCH, 100, 1, ?INVOKE_SINGLE),
            ok = recompute(Tab, registration),
            ?assertMatch(
                {ok, {#{count := 1}, _}}, bondy_db:read(Table, ?REALM, Key)
            ),

            %% A count/latest-only change within the window is suppressed.
            row(Tab, registration, ?EXACT_MATCH, 200, 2, ?INVOKE_SINGLE),
            ok = recompute(Tab, registration),
            ?assertMatch(
                {ok, {#{count := 1, latest := 100}, _}},
                bondy_db:read(Table, ?REALM, Key)
            ),

            %% An `earliest` change is selection-relevant — writes through.
            true = ets:delete(
                Tab, {registration, ?REALM, ?EXACT_MATCH, ?URI, 100, 1}
            ),
            ok = recompute(Tab, registration),
            ?assertMatch(
                {ok, {#{count := 1, earliest := 200}, _}},
                bondy_db:read(Table, ?REALM, Key)
            ),

            %% Another count-only change: suppressed again...
            row(Tab, registration, ?EXACT_MATCH, 300, 3, ?INVOKE_SINGLE),
            ok = recompute(Tab, registration),
            ?assertMatch(
                {ok, {#{count := 1}, _}}, bondy_db:read(Table, ?REALM, Key)
            ),

            %% ...and lands once the window no longer applies.
            ok = application:set_env(bondy_router, registry_rib_damping, 0),
            ok = recompute(Tab, registration),
            ?assertMatch(
                {ok, {#{count := 2, latest := 300}, _}},
                bondy_db:read(Table, ?REALM, Key)
            ),

            %% 1→0 (last member gone) is never damped.
            application:set_env(bondy_router, registry_rib_damping, 60000),
            true = ets:delete(
                Tab, {registration, ?REALM, ?EXACT_MATCH, ?URI, 200, 2}
            ),
            true = ets:delete(
                Tab, {registration, ?REALM, ?EXACT_MATCH, ?URI, 300, 3}
            ),
            ok = recompute(Tab, registration),
            ?assertEqual(
                {error, not_found}, bondy_db:read(Table, ?REALM, Key)
            )
        after
            application:unset_env(bondy_router, registry_rib_damping)
        end
    end).

%% =============================================================================
%% Helpers
%% =============================================================================

with_catalog(Fun) ->
    Tmp = make_tmpdir(),
    ok = bondy_db_config:set([databases, main, oplog, shard_count], 1),
    application:set_env(bondy_router, platform_data_dir, Tmp),
    {ok, Pid} = ?CAT:start_link(),
    Tab = ets:new(rib_members, [ordered_set, public]),
    try
        Fun(Tab)
    after
        ets:delete(Tab),
        _ = catch gen_server:stop(Pid, normal, 30000),
        ok = bondy_db_config:set([databases, main, oplog, shard_count], 16),
        application:unset_env(bondy_router, platform_data_dir),
        _ = file:del_dir_r(Tmp),
        ok
    end.

row(Tab, Type, Policy, Created, EntryId, Invoke) ->
    true = ets:insert(
        Tab, {{Type, ?REALM, Policy, ?URI, Created, EntryId}, Invoke}
    ).

recompute(Tab, Type) ->
    recompute(Tab, Type, ?EXACT_MATCH).

recompute(Tab, Type, Policy) ->
    bondy_registry_rib:recompute(Tab, Type, ?REALM, Policy, ?URI).

cell_key(Policy, Uri) ->
    cell_key(Policy, Uri, bondy_config:nodestring()).

cell_key(Policy, Uri, Node) ->
    term_to_binary({?REALM, Policy, Uri, Node}).

make_tmpdir() ->
    Base = filename:join(
        "/tmp",
        "bondy_rib_test_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = filelib:ensure_path(Base),
    Base.

%% The real store is claimed via bondy_table_manager (a bondy app process) by
%% the reactor; here a bare named table suffices — the rib functions resolve
%% it by name. Another test (or an app boot sharing this BEAM) may have
%% created it already; reuse it — this test's realm/URIs are unique to it.
ensure_stubs_tab() ->
    ensure_named_tab(bondy_registry_rib_stubs, ordered_set).

ensure_named_tab(Name, Type) ->
    case ets:whereis(Name) of
        undefined ->
            _ = ets:new(
                Name, [Type, named_table, public, {keypos, 1}]
            ),
            ok;
        _ ->
            ok
    end.
