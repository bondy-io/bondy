%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Whitebox eunit for `bondy_registry_rib`'s entry-add/remove write path — the
%% per-field CRDT deltas `on_entry_added/3`/`on_entry_removed/3` apply
%% directly from the caller, with no partition dispatch or recompute step.
%% Driven with real `bondy_registry_entry:t()` records against a provisioned
%% catalogue. The hook-driven end-to-end path (register/unregister → cell) is
%% covered in `bondy_registry_SUITE`.
-module(bondy_registry_rib_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_db_tables.hrl").

-define(CAT, bondy_namespace_catalog).
-define(REALM, <<"com.example.rib">>).
-define(URI, <<"com.example.rib.proc">>).

%% One catalogue is booted for the whole suite (not one per test function):
%% each fresh boot of the registry DB's (ephemeral, mem-backed, fused) oplog
%% instance races its own cold-start drain scheduling, and churning through
%% that repeatedly — once per test, as this suite used to — reliably
%% surfaces it. A single shared boot is also the more faithful model: a real
%% node provisions its registry DB once, not once per test case.
write_path_test_() ->
    {setup, fun setup_catalog/0, fun teardown_catalog/1, fun({_Pid, _Tmp, Tab}) ->
        [
            {timeout, 60,
                {"registration summary lifecycle", fun() -> regs(Tab) end}},
            {timeout, 60,
                {"subscription summary lifecycle", fun() -> subs(Tab) end}},
            {timeout, 60, {"remote stub lifecycle", fun stubs/0}},
            {timeout, 60, {"subscriber node discovery", fun sub_nodes/0}},
            {timeout, 60, {"reshape_summary/2", fun reshape_summary/0}}
        ]
    end}.

%% `bondy_db:read/3` on a RIB table returns the RAW `bondy_oplog_crdt_
%% struct`/`bondy_oplog_crdt_pn_counter` projection — the generic CRDT
%% toolkit modules are registered directly (no per-use-case wrapper), so
%% schema fields are already top-level: `count`, `invoke` and the
%% `earliest`/`latest` min/max ratchet registers over the group's
%% entry-creation times (removals never shrink them — they are lifetime
%% watermarks, which is what bounds the cell to a scalar per field).
%% `reshape_summary/2` only normalises shape for consumers, exercised on
%% its own in the `reshape_summary/0` test below.
%% The RIB hooks write async (`bondy_db:apply_async/4` — no
%% read-your-writes barrier), so tests reading the cell right after a
%% hook must flush the shard first.
flush(Table, Key) ->
    ok = bondy_db:await(Table, ?REALM, Key).

regs(Tab) ->
    Table = ?CAT:table(?BONDY_DB_REGISTRATION_RIB_TAB),
    ?assertMatch(#{db_name := registry}, Table),
    Key = cell_key(?EXACT_MATCH, ?URI),

    %% Two live local entries -> one cell, count 2, invoke carried,
    %% earliest/latest ratcheted to the min/max creation times.
    E1 = entry(registration, ?EXACT_MATCH, ?INVOKE_ROUND_ROBIN),
    timer:sleep(2),
    E2 = entry(registration, ?EXACT_MATCH, ?INVOKE_ROUND_ROBIN),
    Created1 = bondy_registry_entry:created(E1),
    Created2 = bondy_registry_entry:created(E2),

    ok = bondy_registry_rib:on_entry_added(self(), Tab, E1),
    ok = bondy_registry_rib:on_entry_added(self(), Tab, E2),
    ok = flush(Table, Key),
    {ok, {
        #{
            invoke := Invoke0,
            count := Count0,
            earliest := Earliest0,
            latest := Latest0
        },
        _
    }} =
        bondy_db:read(Table, ?REALM, Key),
    ?assertEqual(?INVOKE_ROUND_ROBIN, Invoke0),
    ?assertEqual(2, Count0),
    ?assertEqual(min(Created1, Created2), Earliest0),
    ?assertEqual(max(Created1, Created2), Latest0),

    %% Removing an entry shrinks the count but NOT the ratchets — they
    %% are lifetime watermarks by design (the former two_p_set shrank
    %% here, at the cost of one tombstone per removal, forever).
    ok = bondy_registry_rib:on_entry_removed(self(), Tab, E2),
    ok = flush(Table, Key),
    {ok, {#{count := Count1, earliest := Earliest1, latest := Latest1}, _}} =
        bondy_db:read(Table, ?REALM, Key),
    ?assertEqual(1, Count1),
    ?assertEqual(Earliest0, Earliest1),
    ?assertEqual(Latest0, Latest1),

    %% Last member gone -> no explicit clear, count settles to 0 while
    %% the watermarks remain.
    ok = bondy_registry_rib:on_entry_removed(self(), Tab, E1),
    ok = flush(Table, Key),
    ?assertMatch(
        {ok, {#{count := 0, earliest := Earliest0, latest := Latest0}, _}},
        bondy_db:read(Table, ?REALM, Key)
    ),

    %% A different policy for the same URI is a different cell — and does
    %% not resurrect the emptied exact-match one.
    E3 = entry(registration, ?PREFIX_MATCH, ?INVOKE_SINGLE),
    ok = bondy_registry_rib:on_entry_added(self(), Tab, E3),
    ok = flush(Table, cell_key(?PREFIX_MATCH, ?URI)),
    ?assertMatch(
        {ok, {#{count := 0}, _}}, bondy_db:read(Table, ?REALM, Key)
    ),
    ?assertMatch(
        {ok, {#{invoke := ?INVOKE_SINGLE, count := 1}, _}},
        bondy_db:read(Table, ?REALM, cell_key(?PREFIX_MATCH, ?URI))
    ),

    %% Leave the prefix cell empty too, so it does not leak into `subs/1`'s
    %% shared members table.
    ok = bondy_registry_rib:on_entry_removed(self(), Tab, E3).

subs(Tab) ->
    Table = ?CAT:table(?BONDY_DB_SUBSCRIPTION_RIB_TAB),
    Key = cell_key(?EXACT_MATCH, ?URI),

    %% Subscription cells are reachability-only: a bare pn_counter, so the
    %% raw read is a plain integer (`reshape_summary/2` wraps it as
    %% `#{count => N}` for consumers — see the `reshape_summary/0` test).
    E1 = entry(subscription, ?EXACT_MATCH, undefined),
    E2 = entry(subscription, ?EXACT_MATCH, undefined),

    ok = bondy_registry_rib:on_entry_added(self(), Tab, E1),
    ok = bondy_registry_rib:on_entry_added(self(), Tab, E2),
    ok = flush(Table, Key),
    ?assertMatch({ok, {2, _}}, bondy_db:read(Table, ?REALM, Key)),

    ok = bondy_registry_rib:on_entry_removed(self(), Tab, E1),
    ok = bondy_registry_rib:on_entry_removed(self(), Tab, E2),
    ok = flush(Table, Key),
    ?assertMatch({ok, {0, _}}, bondy_db:read(Table, ?REALM, Key)).

%% Unit-tests the read-path reshape in isolation: registration passes
%% the ratchet registers through (normalising never-written fields to
%% `undefined`); subscription wraps the bare counter.
reshape_summary() ->
    ?assertEqual(
        #{
            invoke => ?INVOKE_ROUND_ROBIN,
            count => 3,
            earliest => 100,
            latest => 200
        },
        bondy_registry_rib:reshape_summary(registration, #{
            count => 3,
            invoke => ?INVOKE_ROUND_ROBIN,
            earliest => 100,
            latest => 200
        })
    ),
    %% A cell whose ratchets were never written (or a raw value where an
    %% unwritten register is omitted) reshapes to `undefined` watermarks.
    ?assertEqual(
        #{
            invoke => ?INVOKE_SINGLE,
            count => 0,
            earliest => undefined,
            latest => undefined
        },
        bondy_registry_rib:reshape_summary(registration, #{
            count => 0,
            invoke => ?INVOKE_SINGLE
        })
    ),
    ?assertEqual(
        #{count => 7},
        bondy_registry_rib:reshape_summary(subscription, 7)
    ).

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

%% =============================================================================
%% Helpers
%% =============================================================================

setup_catalog() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    Tmp = make_tmpdir(),
    ok = bondy_db_config:set([databases, main, oplog, shard_count], 1),
    application:set_env(bondy_router, platform_data_dir, Tmp),
    {ok, Pid} = ?CAT:start_link(),
    Tab = ets:new(rib_members, [ordered_set, public]),
    timer:sleep(500),
    {Pid, Tmp, Tab}.

teardown_catalog({Pid, Tmp, Tab}) ->
    ets:delete(Tab),
    _ = catch gen_server:stop(Pid, normal, 30000),
    ok = bondy_db_config:set([databases, main, oplog, shard_count], 16),
    application:unset_env(bondy_router, platform_data_dir),
    _ = file:del_dir_r(Tmp),
    ok.

%% The registry DB's oplog instance(s) start asynchronously after
%% `?CAT:start_link/0` returns — a write issued immediately can race a
%% not-yet-registered instance (`{error, {instance_unavailable, _}}`).
%% Probed on `regs/1`'s own exact-match cell key, so it exercises the exact
%% shard those writes will use, via the registration table (tier_2 — its
%% write goes through `apply_with_context/4`'s extra applier-context
%% round-trip, which registers slightly after the plain WAL/instance front
%% the tier_0 subscription table would exercise) with a genuine, harmless
%% op (`{apply, count, {inc, 0}}`).
await_ready(Table, RealmUri) ->
    Key = cell_key(?EXACT_MATCH, ?URI),
    await_ready(Table, RealmUri, Key, 250).

await_ready(_Table, _RealmUri, _Key, 0) ->
    error(rib_test_db_not_ready);
await_ready(Table, RealmUri, Key, N) ->
    case bondy_db:apply(Table, RealmUri, Key, {apply, count, {inc, 0}}) of
        ok ->
            ok;
        {error, {instance_unavailable, _}} ->
            timer:sleep(20),
            await_ready(Table, RealmUri, Key, N - 1)
    end.

%% A synthetic local entry for `?REALM`/`?URI`. `Invoke` is ignored for
%% subscriptions (the type carries no invocation policy).
entry(Type, Policy, Invoke) ->
    Ref = bondy_ref:new(internal),
    Opts = #{match => Policy, invoke => Invoke},
    bondy_registry_entry:new(Type, ?REALM, Ref, ?URI, Opts).

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
