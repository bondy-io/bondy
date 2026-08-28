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
%% that repeatedly — once per test — reliably surfaces it. A single shared
%% boot is also the more faithful model: a real
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
            {timeout, 60, {"reshape_summary/2", fun reshape_summary/0}},
            {timeout, 60,
                {"self_heal skips when local truth is unreadable", fun() ->
                    self_heal_unreadable(Tab)
                end}},
            {timeout, 60,
                {"rebuild/1 restores peer stubs from the projection",
                    fun rebuild_restores_stubs/0}},
            {timeout, 60,
                {"rebuild/1 is idempotent", fun rebuild_idempotent/0}},
            {timeout, 60,
                {"rebuild/1 ignores count = 0 cells",
                    fun rebuild_skips_emptied/0}}
        ]
    end}.

%% `rebuild/1` reconstructs the stub view from the projection alone — the
%% catalogue-snapshot install path emits no per-cell merge event, so this is
%% the only thing that rebuilds it after a bootstrap.
%%
%% Seeds a PEER cell directly in the projection, wipes the stub table to
%% simulate the post-restart state (in-memory ETS, gone with the VM) and
%% asserts `rebuild/1` puts the stub back. Wiping the table rather than
%% relying on a fresh one is deliberate: the cell must be recovered from the
%% PROJECTION, not left over from the write that seeded it.
rebuild_restores_stubs() ->
    ok = ensure_stubs_tab(),
    Table = ?CAT:table(?BONDY_DB_REGISTRATION_RIB_TAB),
    Peer = <<"peer_rebuild@127.0.0.1">>,
    Uri = <<"com.example.rib.rebuild.restore">>,
    Key = cell_key(?EXACT_MATCH, Uri, Peer),

    ok = bondy_db:apply(Table, ?REALM, Key, {apply, count, {inc, 3}}),
    ok = flush(Table, Key),
    true = ets:delete_all_objects(bondy_registry_rib_stubs),
    ?assertEqual(
        [],
        bondy_registry_rib:stub_nodes(
            registration, ?REALM, ?EXACT_MATCH, Uri
        ),
        "precondition: the stub view must start empty"
    ),

    ok = bondy_registry_rib:rebuild(?BONDY_DB_REGISTRATION_RIB_TAB),
    ?assertMatch(
        [{Peer, #{count := 3}}],
        bondy_registry_rib:stub_nodes(
            registration, ?REALM, ?EXACT_MATCH, Uri
        ),
        "rebuild/1 must recover the peer stub from the projection"
    ).

%% A streamed snapshot notifies a table once PER BATCH, so `rebuild/1` runs
%% several times per bootstrap. Its doc claims idempotence; this is the
%% evidence for that claim rather than a restatement of it.
rebuild_idempotent() ->
    ok = ensure_stubs_tab(),
    Table = ?CAT:table(?BONDY_DB_REGISTRATION_RIB_TAB),
    Peer = <<"peer_idem@127.0.0.1">>,
    Uri = <<"com.example.rib.rebuild.idem">>,
    Key = cell_key(?EXACT_MATCH, Uri, Peer),

    ok = bondy_db:apply(Table, ?REALM, Key, {apply, count, {inc, 2}}),
    ok = flush(Table, Key),

    ok = bondy_registry_rib:rebuild(?BONDY_DB_REGISTRATION_RIB_TAB),
    First = bondy_registry_rib:stub_nodes(
        registration, ?REALM, ?EXACT_MATCH, Uri
    ),
    ok = bondy_registry_rib:rebuild(?BONDY_DB_REGISTRATION_RIB_TAB),
    ok = bondy_registry_rib:rebuild(?BONDY_DB_REGISTRATION_RIB_TAB),
    Third = bondy_registry_rib:stub_nodes(
        registration, ?REALM, ?EXACT_MATCH, Uri
    ),

    ?assertMatch([{Peer, #{count := 2}}], First),
    ?assertEqual(
        First,
        Third,
        "three rebuilds must leave the same stub view as one"
    ).

%% `count = 0` is the only signal an emptied group ever sends, and the stub
%% store has to read it as removal. A rebuild walks cells that a live merge
%% would have dropped, so it must apply the same rule rather than
%% resurrecting a dead group as a routable stub.
rebuild_skips_emptied() ->
    ok = ensure_stubs_tab(),
    Table = ?CAT:table(?BONDY_DB_REGISTRATION_RIB_TAB),
    Peer = <<"peer_empty@127.0.0.1">>,
    Uri = <<"com.example.rib.rebuild.emptied">>,
    Key = cell_key(?EXACT_MATCH, Uri, Peer),

    ok = bondy_db:apply(Table, ?REALM, Key, {apply, count, {inc, 1}}),
    ok = flush(Table, Key),
    ok = bondy_db:apply(Table, ?REALM, Key, {apply, count, {inc, -1}}),
    ok = flush(Table, Key),

    ok = bondy_registry_rib:rebuild(?BONDY_DB_REGISTRATION_RIB_TAB),
    ?assertEqual(
        [],
        bondy_registry_rib:stub_nodes(
            registration, ?REALM, ?EXACT_MATCH, Uri
        ),
        "a count = 0 cell is not routable and must not become a stub"
    ).

%% An own-node cell merged back in while the local truth is UNREADABLE must
%% leave the cell alone.
%%
%% `self_heal/4` turns `local_count/4` into a corrective delta and writes it
%% through `bondy_db:apply/4` — a REPLICATED write. `local_count/4` used to
%% report an unreadable partition store (unprovisioned, or the registry gproc
%% pool not up) as `0`, which is indistinguishable from "this node genuinely
%% owns nothing". The two demand opposite actions, and guessing wrong is not
%% a missed repair: it broadcasts `-ReplicatedCount` for every cell it walks,
%% erasing this node's own live registrations cluster-wide.
%%
%% FALSIFICATION: this asserts the cell is UNCHANGED. On the pre-fix code the
%% count is driven to 0 by a corrective delta, so this test fails there — it
%% is not a happy-path restatement.
%%
%% The eunit fixture has no registry partition pool, which is exactly the
%% unreadable case, so no mocking is needed to reach it.
self_heal_unreadable(_Tab) ->
    ok = ensure_stubs_tab(),
    Table = ?CAT:table(?BONDY_DB_REGISTRATION_RIB_TAB),
    Uri = <<"com.example.rib.self_heal_unreadable">>,
    Key = cell_key(?EXACT_MATCH, Uri),

    %% Seed an own-node cell with a non-zero count, as a bootstrap or a peer
    %% merge would restore it after a restart.
    ok = bondy_db:apply(
        Table, ?REALM, Key, {apply, count, {inc, 2}}
    ),
    ok = flush(Table, Key),
    ?assertMatch(
        #{count := 2},
        summary(Table, Key),
        "precondition: the seeded own-cell must read back as count = 2"
    ),

    %% The local truth is unreadable here, so the reaction must not write.
    ok = bondy_registry_rib:on_remote_set(registration, Key, #{count => 2}),
    ok = flush(Table, Key),

    ?assertMatch(
        #{count := 2},
        summary(Table, Key),
        "self_heal must SKIP when the local count is unknown; treating "
        "unknown as 0 writes a replicated erasure of this node's own cells"
    ).

%% @private
summary(Table, Key) ->
    {ok, {Value, _Hlc}} = bondy_db:read(Table, ?REALM, Key),
    bondy_registry_rib:reshape_summary(registration, Value).

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
    _ =
        try
            gen_server:stop(Pid, normal, 30000)
        catch
            _:_ -> ok
        end,
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
        "/tmp/" ++ os:getpid(),
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

%% A cell key is `term_to_binary`'d on the WRITING node (`cell_key/1`) and
%% the bytes travel verbatim, so a merge event hands this node PEER-encoded
%% bytes — `[safe]`-decode per the C-2 peer-bytes rule. Legitimate keys are
%% all-binary 4-tuples, so `[safe]` refuses nothing legitimate; a
%% non-conforming key carrying an unknown atom must be rejected WITHOUT
%% interning it. The atom below exists only as bytes (a hand-built ETF
%% 4-tuple with a SMALL_ATOM_UTF8_EXT seat) unless the decode interns it.
peer_key_with_unknown_atom_rejected_without_interning_test() ->
    Name = <<"bondy_c2_stub_key_atom_qz4">>,
    ?assertError(badarg, binary_to_existing_atom(Name, utf8)),
    Key = <<
        131,
        104,
        4,
        109,
        1:32/big-unsigned,
        "r",
        109,
        1:32/big-unsigned,
        "p",
        109,
        1:32/big-unsigned,
        "u",
        119,
        (byte_size(Name)):8,
        Name/binary
    >>,
    ?assertEqual(error, bondy_registry_rib:decode_cell_key(Key)),
    ?assertError(badarg, binary_to_existing_atom(Name, utf8)),
    Legit = term_to_binary({<<"r">>, <<"p">>, <<"u">>, <<"n">>}),
    ?assertEqual(
        {ok, {<<"r">>, <<"p">>, <<"u">>, <<"n">>}},
        bondy_registry_rib:decode_cell_key(Legit)
    ).
