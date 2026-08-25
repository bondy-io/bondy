%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Tests for the two facade additions that back the API Gateway cut-over
%% (design §11.4): opt-in apply publishing (`publish => true` → a reactor can
%% `bondy_oplog_core:subscribe/2` to the table namespace) and the whole-table
%% scan `bondy_db:list/2`.

-module(bondy_db_publish_list_test).

-include_lib("eunit/include/eunit.hrl").

-define(CRDT, bondy_oplog_crdt_lww_register).

publish_list_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            {"publish => true delivers cell_apply events to a subscriber",
                fun publish_delivers/0},
            {"publish off by default — no events", fun publish_off/0},
            {
                "a shared (per_shard) instance publishes each table's local "
                "writes under ITS OWN namespace, not the founder's",
                fun publish_shared_instance_routes_per_table/0
            },
            {
                "a publish sibling on a non-publish founder still publishes; "
                "the founder still does not",
                fun publish_shared_instance_sibling_opt_in/0
            },
            {"list/2 enumerates all cells; clear removes from the scan",
                fun list_scans/0},
            {timeout, 120,
                {"list/2 pages past the substrate range cap (complete result)",
                    fun list_pages_to_completion/0}},
            {"short-form ops: term values, auto HLC, decoded reads",
                fun short_form_ops/0},
            {"a NUL-bearing realm is refused (G-1 injectivity)",
                fun nul_realm_refused/0},
            {"fold_all/4 spans every realm", fun fold_all_spans_realms/0},
            {"fold_all/4 pages past the substrate range cap",
                fun fold_all_pages_to_completion/0},
            {"fold_all/4 refuses a non-folding topology",
                fun fold_all_unsupported_topology/0}
        ]
    end}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

%% A `publish => true` table wires every shard's applier to publish each
%% verified apply to the table namespace. A subscriber receives `{Key, FoldOp}`.
publish_delivers() ->
    {Db, T} = open(pub_on, true),
    try
        NS = bondy_db:namespace(T),
        {ok, _Ref} = bondy_oplog_core:subscribe(NS, all),
        H = bondy_db:tick(T),
        ok = bondy_db:apply(T, <<"r">>, <<"k1">>, {set, H, <<"v1">>}),
        %% The event carries the cell-level key, which on the memory topology is
        %% realm-folded (`<<Realm,0,Key>>`) — the same shape `shared_shards`
        %% publishes, where a reactor un-folds it to recover the key.
        CellKey = <<"r", 0, "k1">>,
        receive
            {bondy_oplog_core_event, NS, CellKey, _Hlc, Op} ->
                ?assertEqual({set, H, <<"v1">>}, Op)
        after 5000 ->
            ?assert(false)
        end
    after
        ok = bondy_db:close(Db)
    end.

%% On a `per_shard` topology (memory; `shard_count => 1` so every table
%% shares ONE instance) the instance-level publish opts are the FOUNDING
%% table's. Local events must still be published under the WRITING table's
%% own namespace, resolved per bucket — the same resolution the merge path
%% uses — or a sibling's subscribers hear the founder's namespace (or
%% nothing). Falsifier for `bondy_oplog_applier:publish_batch_dir/2`.
publish_shared_instance_routes_per_table() ->
    {Db, Founder, Sibling} = open_shared(pub_shared, true, true),
    try
        FounderNS = bondy_db:namespace(Founder),
        SiblingNS = bondy_db:namespace(Sibling),
        {ok, _} = bondy_oplog_core:subscribe(FounderNS, all),
        {ok, _} = bondy_oplog_core:subscribe(SiblingNS, all),
        H = bondy_db:tick(Sibling),
        ok = bondy_db:apply(Sibling, <<"r">>, <<"k1">>, {set, H, <<"v1">>}),
        CellKey = <<"r", 0, "k1">>,
        receive
            {bondy_oplog_core_event, NS, CellKey, _Hlc, Op} ->
                ?assertEqual(SiblingNS, NS),
                ?assertEqual({set, H, <<"v1">>}, Op)
        after 5000 ->
            ?assert(false)
        end,
        %% And the founder's own writes still arrive under the founder's.
        H2 = bondy_db:tick(Founder),
        ok = bondy_db:apply(Founder, <<"r">>, <<"k2">>, {set, H2, <<"v2">>}),
        CellKey2 = <<"r", 0, "k2">>,
        receive
            {bondy_oplog_core_event, NS2, CellKey2, _Hlc2, Op2} ->
                ?assertEqual(FounderNS, NS2),
                ?assertEqual({set, H2, <<"v2">>}, Op2)
        after 5000 ->
            ?assert(false)
        end
    after
        ok = bondy_db:close(Db)
    end.

%% The founder did not opt in, the sibling did: before the per-bucket
%% resolution the instance had NO publish wiring at all and the sibling's
%% subscribers stayed deaf; the sibling must publish and the founder must
%% stay silent.
publish_shared_instance_sibling_opt_in() ->
    {Db, Founder, Sibling} = open_shared(pub_shared_optin, false, true),
    try
        {ok, _} = bondy_oplog_core:subscribe(
            bondy_db:namespace(Founder), all
        ),
        SiblingNS = bondy_db:namespace(Sibling),
        {ok, _} = bondy_oplog_core:subscribe(SiblingNS, all),
        ok = bondy_db:apply(
            Founder, <<"r">>, <<"kf">>, {set, bondy_db:tick(Founder), <<"v">>}
        ),
        H = bondy_db:tick(Sibling),
        ok = bondy_db:apply(Sibling, <<"r">>, <<"ks">>, {set, H, <<"vs">>}),
        CellKey = <<"r", 0, "ks">>,
        receive
            {bondy_oplog_core_event, NS, Key, _Hlc, Op} ->
                ?assertEqual(SiblingNS, NS),
                ?assertEqual(CellKey, Key),
                ?assertEqual({set, H, <<"vs">>}, Op)
        after 5000 ->
            ?assert(false)
        end,
        %% Nothing further: the founder's write must not have published.
        receive
            {bondy_oplog_core_event, _, _, _, _} = Extra ->
                error({unexpected_event, Extra})
        after 300 ->
            ok
        end
    after
        ok = bondy_db:close(Db)
    end.

%% Default (no `publish` opt): the applier does not publish — a subscriber
%% receives nothing.
publish_off() ->
    {Db, T} = open(pub_off, false),
    try
        NS = bondy_db:namespace(T),
        {ok, _Ref} = bondy_oplog_core:subscribe(NS, all),
        ok = bondy_db:apply(
            T, <<"r">>, <<"k1">>, {set, bondy_db:tick(T), <<"v">>}
        ),
        receive
            {bondy_oplog_core_event, NS, _, _, _} -> ?assert(false)
        after 300 ->
            ok
        end
    after
        ok = bondy_db:close(Db)
    end.

%% list/2 scans every cell across shards; a cleared cell drops out (its lww
%% state interprets to the empty value, surfaced as a non-binary state).
list_scans() ->
    {Db, T} = open(list_scan, false),
    try
        ok = bondy_db:apply(
            T, <<"r">>, <<"a">>, {set, bondy_db:tick(T), <<"va">>}
        ),
        ok = bondy_db:apply(
            T, <<"r">>, <<"b">>, {set, bondy_db:tick(T), <<"vb">>}
        ),
        ok = bondy_db:apply(
            T, <<"r">>, <<"c">>, {set, bondy_db:tick(T), <<"vc">>}
        ),
        {ok, Live0} = bondy_db:list(T, <<"r">>),
        ?assertEqual(
            [{<<"a">>, <<"va">>}, {<<"b">>, <<"vb">>}, {<<"c">>, <<"vc">>}],
            live(Live0)
        ),
        %% Clear one key — it must drop out of the scan.
        ok = bondy_db:apply(T, <<"r">>, <<"b">>, {clear, bondy_db:tick(T)}),
        {ok, Live1} = bondy_db:list(T, <<"r">>),
        ?assertEqual(
            [{<<"a">>, <<"va">>}, {<<"c">>, <<"vc">>}], live(Live1)
        )
    after
        ok = bondy_db:close(Db)
    end.

%% The ergonomic API: the short-form ops carry no caller HLC and arbitrary term
%% values; the substrate stamps the write HLC and serialises the term. A read
%% returns the decoded value paired with its HLC; `clear` is non-terminal.
short_form_ops() ->
    {Db, T} = open(short_form, false),
    try
        ok = bondy_db:apply(T, <<"r">>, <<"k">>, {set, #{name => <<"alice">>}}),
        ?assertMatch(
            {ok, {#{name := <<"alice">>}, _Hlc}},
            bondy_db:read(T, <<"r">>, <<"k">>)
        ),
        %% clear (short form) removes the cell.
        ok = bondy_db:apply(T, <<"r">>, <<"k">>, clear),
        ?assertEqual({error, not_found}, bondy_db:read(T, <<"r">>, <<"k">>)),
        %% A later set reanimates it — with a different term type.
        ok = bondy_db:apply(T, <<"r">>, <<"k">>, {set, 42}),
        ?assertMatch({ok, {42, _Hlc}}, bondy_db:read(T, <<"r">>, <<"k">>))
    after
        ok = bondy_db:close(Db)
    end.

%% list/2 must page internally past `range_all/5`'s merged-page cap (1000):
%% a realm with more rows than the cap gets the COMPLETE enumeration, not a
%% silently truncated first page.
list_pages_to_completion() ->
    {Db, T} = open(list_page, false),
    N = 1203,
    try
        ok = lists:foreach(
            fun(I) ->
                Key = iolist_to_binary(io_lib:format("k~4..0b", [I])),
                ok = bondy_db:apply(
                    T, <<"r">>, Key, {set, bondy_db:tick(T), <<"v">>}
                )
            end,
            lists:seq(1, N)
        ),
        {ok, Rows} = bondy_db:list(T, <<"r">>),
        ?assertEqual(N, length(Rows)),
        %% Complete AND ascending — the page seams neither drop nor reorder.
        Keys = [K || {K, _, _} <- Rows],
        ?assertEqual(lists:sort(Keys), Keys)
    after
        ok = bondy_db:close(Db)
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

open(Name, Publish) ->
    {ok, Db} = bondy_db:open(Name, #{
        topology => bondy_db_topology_memory,
        shard_count => 4,
        fold_module => lww_register
    }),
    {ok, T} = bondy_db:open_table(Db, items, #{
        fold_module => lww_register,
        crdt_module => ?CRDT,
        publish => Publish
    }),
    {Db, T}.

%% One DB with `shard_count => 1`, so the memory topology's `per_shard`
%% collapse puts BOTH tables on one shared oplog instance: `items` founds
%% it, `widgets` joins as a sibling.
open_shared(Name, FounderPublish, SiblingPublish) ->
    {ok, Db} = bondy_db:open(Name, #{
        topology => bondy_db_topology_memory,
        shard_count => 1,
        fold_module => lww_register
    }),
    {ok, Founder} = bondy_db:open_table(Db, items, #{
        fold_module => lww_register,
        crdt_module => ?CRDT,
        publish => FounderPublish
    }),
    {ok, Sibling} = bondy_db:open_table(Db, widgets, #{
        fold_module => lww_register,
        crdt_module => ?CRDT,
        publish => SiblingPublish
    }),
    {Db, Founder, Sibling}.

%% Keep only live (binary-valued) cells as {Key, Value}, sorted by key.
live(Cells) ->
    lists:sort([{K, V} || {K, V, _Hlc} <- Cells, is_binary(V)]).

%% `list/2` narrows to one realm; `fold_all/4` is the same scan without that
%% narrowing, for callers that cannot name the realms up front. It yields the
%% STORAGE key (`<<Realm, 0, Key>>`) because it does not know the realm to
%% strip — the caller splits on the first NUL, which is exact under G-1.
fold_all_spans_realms() ->
    {Db, T} = open(fold_all_realms, false),
    try
        Cells = [
            {<<"r1">>, <<"a">>, <<"v1a">>},
            {<<"r1">>, <<"b">>, <<"v1b">>},
            {<<"r2">>, <<"a">>, <<"v2a">>},
            {<<"r3">>, <<"z">>, <<"v3z">>}
        ],
        _ = [
            bondy_db:apply(T, R, K, {set, bondy_db:tick(T), V})
         || {R, K, V} <- Cells
        ],

        %% `list/2` sees one realm...
        {ok, R1} = bondy_db:list(T, <<"r1">>),
        ?assertEqual([{<<"a">>, <<"v1a">>}, {<<"b">>, <<"v1b">>}], live(R1)),

        %% ...`fold_all/4` sees them all, and the realm is recoverable.
        {ok, Got} = bondy_db:fold_all(
            T,
            fun
                ({StorageKey, V, _Hlc}, Acc) when is_binary(V) ->
                    [Realm, Key] = binary:split(StorageKey, <<0>>),
                    [{Realm, Key, V} | Acc];
                (_, Acc) ->
                    Acc
            end,
            [],
            #{}
        ),
        ?assertEqual(lists:sort(Cells), lists:sort(Got))
    after
        try
            bondy_db:close(Db)
        catch
            _:_ -> ok
        end
    end.

%% The substrate caps a single merged page, so the fold must page to
%% exhaustion exactly as `list/2` does — a truncated rebuild would silently
%% skip cells, which is the failure mode this whole primitive exists to remove.
fold_all_pages_to_completion() ->
    {Db, T} = open(fold_all_paging, false),
    try
        N = 2500,
        _ = [
            bondy_db:apply(
                T,
                <<"r", (integer_to_binary(I rem 3))/binary>>,
                integer_to_binary(I),
                {set, bondy_db:tick(T), <<"v">>}
            )
         || I <- lists:seq(1, N)
        ],
        {ok, Count} = bondy_db:fold_all(
            T,
            fun
                ({_K, V, _Hlc}, Acc) when is_binary(V) -> Acc + 1;
                (_, Acc) -> Acc
            end,
            0,
            #{}
        ),
        ?assertEqual(N, Count)
    after
        try
            bondy_db:close(Db)
        catch
            _:_ -> ok
        end
    end.

%% Only realm-FOLDING topologies can be scanned this way; the others keep the
%% realm in the bucket and nothing enumerates buckets. It must RAISE rather
%% than return an empty fold, which would be indistinguishable from an empty
%% table — the silent-skip failure this primitive exists to remove.
%%
%% A synthetic table map is deliberate, and is the stronger assertion: the
%% refusal has to happen on the topology alone, BEFORE any bucket resolution
%% or substrate call, so a map carrying nothing but the namespace and the
%% topology is sufficient to reach it. Standing up a real `per_entity` DB
%% would also drag in its `sup` requirement, testing the fixture rather than
%% the guard.
fold_all_unsupported_topology() ->
    _ = [
        ?assertError(
            {unsupported_topology, T},
            bondy_db:fold_all(
                #{namespace => fold_all_ns, db_topology => T},
                fun(_, Acc) -> Acc end,
                ok,
                #{}
            )
        )
     || T <- [bondy_db_topology_per_entity, bondy_db_topology_single_bookie]
    ],
    ok.

%% G-1's injectivity precondition, enforced at the facade: a NUL inside a
%% realm would fold realms `<<"a">>` and `<<"a",0,"b">>` onto colliding
%% storage cells, and the shorter realm's scan band would CONTAIN the longer
%% realm's rows — a cross-tenant leak. Writes AND scans must refuse.
nul_realm_refused() ->
    {Db, T} = open(nul_realm, false),
    try
        Evil = <<"a", 0, "b">>,
        ?assertError(
            {badarg, {realm_contains_nul, Evil}},
            bondy_db:apply(T, Evil, <<"k">>, {set, <<"v">>})
        ),
        ?assertError(
            {badarg, {realm_contains_nul, Evil}},
            bondy_db:list(T, Evil)
        ),
        ?assertError(
            {badarg, {realm_contains_nul, Evil}},
            bondy_db:read(T, Evil, <<"k">>)
        ),
        %% The victim realm is untouched and fully functional.
        ok = bondy_db:apply(T, <<"a">>, <<"k">>, {set, <<"safe">>}),
        ?assertMatch({ok, {<<"safe">>, _}}, bondy_db:read(T, <<"a">>, <<"k">>))
    after
        ok = bondy_db:close(Db)
    end.
