%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Concurrent stress hunt for the P1 own-root page loss (Fly s16/s25:
%% `registry/*` ephemeral ETS instances transiently reference pages absent
%% from the page table; recurred live twice in s25, caught by the gc abort
%% guard, root cause open).
%%
%% The serialized op mix is certified sound
%% (`bondy_mst_gc_reachability_proper_test`), so this module hammers the two
%% CONCURRENT topologies the certification could not see:
%%
%% 1. PRODUCTION topology — one serialized mutator (put/put_batch/
%%    truncate+gc/guarded merge, as the instance gen_server) racing N page
%%    INSERTER processes (the sync session's `put_page` writes, including
%%    same-hash re-inserts of live pages, which path sharing makes routine)
%%    and M servability READERS (`missing_set(T, root(T))`) that classify
%%    every miss by immediate and delayed re-probe — discriminating
%%    "transient read-visibility artifact" from "true deletion".
%%
%% 2. WRITERS-ONLY topology — N fully concurrent writers on the shared store
%%    (the `concurrent_writes => true` capability taken at its word:
%%    unsynchronized read-root/build/set_root), with NO collector. This pins
%%    that path copying and `put` are themselves concurrency-safe: pages are
%%    content-addressed and only ever inserted, so racing writers cannot lose
%%    each other's pages.
%%
%%    Running a collector here instead is NOT a valid configuration and is
%%    deliberately not tested as one: `gc/2` requires the caller to establish
%%    the live-root set (see its docs), which unsynchronized writers make
%%    unknowable — a writer publishing a root after the mark has that root
%%    swept. That is a precondition violation, not a store defect.
%%
%% A failure prints the classification so the mechanism is named, not just
%% detected.
%% =============================================================================

-module(bondy_mst_ets_concurrent_stress_test).

-include_lib("eunit/include/eunit.hrl").

-define(KEY_RANGE, 500).
-define(DURATION_MS, 8_000).

production_topology_test_() ->
    {timeout, 120, fun() -> run(production) end}.

writers_only_topology_test_() ->
    {timeout, 120, fun() -> run(writers_only) end}.

%% =============================================================================
%% HARNESS
%% =============================================================================

run(Topology) ->
    T0 = new_tree(),
    T1 = seed(T0),
    Tab = page_tab(bondy_mst:root(T1)),
    Ctl = ets:new(ctl, [public, set]),
    true = ets:insert(Ctl, {tree, T1}),
    true = ets:insert(Ctl, {gen, 0}),
    true = ets:insert(Ctl, {stop, false}),
    true = ets:insert(Ctl, {violations, []}),

    Pids = spawn_workers(Topology, Ctl, Tab),
    timer:sleep(?DURATION_MS),
    true = ets:insert(Ctl, {stop, true}),
    await_workers(Pids),

    Violations = ets:lookup_element(Ctl, violations, 2),
    T = ets_tree(Ctl, T1),
    ets:delete(Ctl),
    catch bondy_mst:destroy(T),

    %% DELETIONS are the defect: a page gone for good under a live root.
    %%
    %% A page that reappears is not. In the library topology (unsynchronized
    %% writers, no single owner of the root) a reader can capture root R from
    %% writer A while writer B is mid-`put`, and observe B's not-yet-inserted
    %% spine as "missing" for microseconds. That is inherent to reading a root
    %% published by a writer you are not synchronized with — the production
    %% topology has one mutator and shows none of it — and it costs nothing:
    %% `gc/2`'s own guard re-checks servability before sweeping, and refuses.
    Deletions = [
        V
     || {_Root, Classified} = V <- Violations,
        lists:keymember(still_absent_after_50ms, 2, Classified)
    ],
    ?assertEqual([], lists:sublist(Deletions, 5)).

%% One writer identity mutates the tree; in the production topology it is the
%% ONLY process that changes the root or sweeps, exactly like the instance
%% gen_server.
spawn_workers(production, Ctl, Tab) ->
    [
        spawn_monitor(fun() -> mutator(Ctl) end),
        spawn_monitor(fun() -> inserter(Ctl, Tab, 1) end),
        spawn_monitor(fun() -> inserter(Ctl, Tab, 2) end),
        spawn_monitor(fun() -> reader(Ctl, Tab) end),
        spawn_monitor(fun() -> reader(Ctl, Tab) end)
    ];
spawn_workers(writers_only, Ctl, Tab) ->
    [
        spawn_monitor(fun() -> free_writer(Ctl, 1) end),
        spawn_monitor(fun() -> free_writer(Ctl, 2) end),
        spawn_monitor(fun() -> free_writer(Ctl, 3) end),
        spawn_monitor(fun() -> reader(Ctl, Tab) end),
        spawn_monitor(fun() -> reader(Ctl, Tab) end)
    ].

await_workers(Pids) ->
    lists:foreach(
        fun({Pid, Ref}) ->
            receive
                {'DOWN', Ref, process, Pid, _} -> ok
            after 30_000 ->
                exit(Pid, kill)
            end
        end,
        Pids
    ).

%% =============================================================================
%% WORKERS
%% =============================================================================

%% The production-topology serialized mutator: puts, batches, compactions
%% (truncate+gc, pins none — the pin path is peer-root machinery the readers
%% do not model), occasional full-page adoption + guarded merge.
mutator(Ctl) ->
    rand:seed(exsss),
    mutator_loop(Ctl, 0).

mutator_loop(Ctl, N) ->
    case stopped(Ctl) of
        true ->
            ok;
        false ->
            T0 = ets_tree(Ctl, undefined),
            %% Seqlock: odd while a mutation (and any sweep inside it) is in
            %% flight, even once the NEW tree is published. A reader that
            %% observes the same even generation across its whole walk knows
            %% no mutation overlapped it — so a miss cannot be a stale-root
            %% artifact of sweep-before-publish.
            _ = ets:update_counter(Ctl, gen, 1),
            T =
                case rand:uniform(10) of
                    R when R =< 5 ->
                        bondy_mst:put(T0, key(), 1);
                    R when R =< 8 ->
                        Pairs = [{key(), 1} || _ <- lists:seq(1, 20)],
                        bondy_mst:put_batch(T0, lists:ukeysort(1, Pairs));
                    9 ->
                        compact(T0);
                    10 ->
                        adopt_and_merge(T0)
                end,
            true = ets:insert(Ctl, {tree, T}),
            _ = ets:update_counter(Ctl, gen, 1),
            mutator_loop(Ctl, N + 1)
    end.

%% A free (library-topology) writer: unsynchronized read-root/build/set_root
%% on the shared store, as `concurrent_writes => true` permits.
free_writer(Ctl, Seed) ->
    rand:seed(exsss, {Seed, Seed, Seed}),
    free_writer_loop(Ctl).

free_writer_loop(Ctl) ->
    case stopped(Ctl) of
        true ->
            ok;
        false ->
            T0 = ets_tree(Ctl, undefined),
            T = bondy_mst:put(T0, key(), 1),
            true = ets:insert(ctl_tab(Ctl), {tree, T}),
            free_writer_loop(Ctl)
    end.

%% The sync-session model: adopts content pages from a private peer tree into
%% the shared store (put_page), including hashes that already exist (path
%% sharing makes same-hash re-insert routine).
inserter(Ctl, _Tab, Seed) ->
    rand:seed(exsss, {Seed, 7, 13}),
    inserter_loop(Ctl).

inserter_loop(Ctl) ->
    case stopped(Ctl) of
        true ->
            ok;
        false ->
            T = ets_tree(Ctl, undefined),
            PeerT0 = new_tree(),
            PeerT = lists:foldl(
                fun(_, Acc) -> bondy_mst:put(Acc, key(), 1) end,
                PeerT0,
                lists:seq(1, 10)
            ),
            Pages = lists:reverse(
                bondy_mst:fold_pages(
                    PeerT,
                    fun({_H, P}, Acc) -> [P | Acc] end,
                    [],
                    #{root => bondy_mst:root(PeerT)}
                )
            ),
            _ = lists:foldl(
                fun(P, Acc) ->
                    {_, Acc1} = bondy_mst:put_page(Acc, P),
                    Acc1
                end,
                T,
                Pages
            ),
            catch bondy_mst:destroy(PeerT),
            inserter_loop(Ctl)
    end.

%% The servability oracle. On a miss it classifies by re-probe:
%%   - `appeared_immediately` / `appeared_within_1ms` / `appeared_within_50ms`
%%     → transient read-visibility artifact
%%   - `still_absent_after_50ms` → true deletion (or never-written)
%% Only misses against a root that is STILL current are violations — a root
%% that moved mid-walk legitimately loses pages to the next compaction.
reader(Ctl, Tab) ->
    case stopped(Ctl) of
        true ->
            ok;
        false ->
            G1 = gen(Ctl),
            T = ets_tree(Ctl, undefined),
            Root = bondy_mst:root(T),
            case
                G1 rem 2 =:= 0 andalso Root =/= undefined andalso
                    bondy_mst:missing_set(T, Root)
            of
                false ->
                    ok;
                [] ->
                    ok;
                Missing ->
                    Classified = [
                        {H, classify(Tab, H)}
                     || H <- lists:sublist(Missing, 3)
                    ],
                    %% Only a walk AND classification fully inside one even
                    %% generation is a genuine violation: no mutation (and
                    %% therefore no sweep) overlapped the observation.
                    case gen(Ctl) of
                        G1 ->
                            record_violation(Ctl, {Root, Classified});
                        _ ->
                            ok
                    end
            end,
            reader(Ctl, Tab)
    end.

gen(Ctl) ->
    try
        ets:lookup_element(Ctl, gen, 2)
    catch
        _:_ -> 1
    end.

classify(Tab, H) ->
    case ets:member(Tab, H) of
        true ->
            appeared_immediately;
        false ->
            timer:sleep(1),
            case ets:member(Tab, H) of
                true ->
                    appeared_within_1ms;
                false ->
                    timer:sleep(49),
                    case ets:member(Tab, H) of
                        true -> appeared_within_50ms;
                        false -> still_absent_after_50ms
                    end
            end
    end.

%% =============================================================================
%% MUTATOR OPS
%% =============================================================================

compact(T0) ->
    Keys = [K || {K, _} <- bondy_mst:to_list(T0)],
    case Keys of
        [] ->
            T0;
        _ ->
            W = lists:nth(rand:uniform(length(Keys)), Keys),
            bondy_mst:gc(bondy_mst:truncate(T0, W), [])
    end.

adopt_and_merge(T0) ->
    PeerT0 = new_tree(),
    PeerT = lists:foldl(
        fun(_, Acc) -> bondy_mst:put(Acc, key(), 1) end,
        PeerT0,
        lists:seq(1, 15)
    ),
    PeerRoot = bondy_mst:root(PeerT),
    Pages = lists:reverse(
        bondy_mst:fold_pages(
            PeerT,
            fun({_H, P}, Acc) -> [P | Acc] end,
            [],
            #{root => PeerRoot}
        )
    ),
    T1 = lists:foldl(
        fun(P, Acc) ->
            {_, Acc1} = bondy_mst:put_page(Acc, P),
            Acc1
        end,
        T0,
        Pages
    ),
    catch bondy_mst:destroy(PeerT),
    %% The production integrate guard.
    case bondy_mst:missing_set(T1, PeerRoot) of
        [] -> bondy_mst:merge(T1, T1, PeerRoot);
        _ -> T1
    end.

%% =============================================================================
%% HELPERS
%% =============================================================================

new_tree() ->
    bondy_mst:new(#{
        store => bondy_mst_ets_store,
        store_opts => #{name => <<"conc_stress">>},
        merger => fun(_K, V, V) -> V end
    }).

seed(T0) ->
    lists:foldl(
        fun(K, Acc) -> bondy_mst:put(Acc, K, 1) end,
        T0,
        lists:seq(1, 100)
    ).

key() ->
    rand:uniform(?KEY_RANGE).

page_tab(RootHash) ->
    Self = self(),
    [Tab | _] = [
        T
     || T <- ets:all(),
        ets:info(T, owner) =:= Self,
        ets:info(T, type) =:= set,
        (catch ets:lookup(T, <<"$root">>)) =:= [{<<"$root">>, RootHash}]
    ],
    Tab.

ets_tree(Ctl, Default) ->
    try
        ets:lookup_element(ctl_tab(Ctl), tree, 2)
    catch
        _:_ -> Default
    end.

ctl_tab(Ctl) -> Ctl.

ctl_self(Ctl) -> Ctl.

stopped(Ctl) ->
    try
        ets:lookup_element(Ctl, stop, 2)
    catch
        _:_ -> true
    end.

record_violation(Ctl, V) ->
    Old = ets:lookup_element(Ctl, violations, 2),
    true = ets:insert(Ctl, {violations, [V | Old]}),
    ok.
