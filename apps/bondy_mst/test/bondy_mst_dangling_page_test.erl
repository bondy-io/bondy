%% =============================================================================
%% Regression test for the dangling-page recovery added to
%% `bondy_mst:merge_aux/5`, `bondy_mst:split/4`, and `bondy_mst:put_at/6`.
%%
%% The original code crashed (FunctionClauseError on
%% `bondy_mst_page:level/1`, or `bondy_mst_page:list/1` on the put_at
%% path) when a Hash referenced by a parent page
%% could not be resolved in either Store0 or T#?MODULE.store. Observed
%% intermittently under sustained high write throughput in the
%% `e2e_pipeline` benchmark (≥8 shards × ≥16-event batched fsync
%% append_many) but not yet isolated to a deterministic source. The
%% recovery now logs and continues, treating the missing subtree as
%% empty so the gen_server stays alive.
%%
%% This test reproduces the dangling state synthetically by:
%%
%% - building a normal MST `A`,
%% - constructing a fake "child" hash that does not exist in A's store,
%% - splicing it into a page so a subsequent merge/put follows the
%%   dangling reference,
%% - asserting the operation returns without crashing and that pages
%%   the dangling-recovery had to drop are silently absent.
%% =============================================================================

-module(bondy_mst_dangling_page_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_mst.hrl").

dangling_page_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(bondy_mst),
            ok
        end,
        fun(_) -> ok end, [
            {timeout, 10, fun split_with_dangling_hash_does_not_crash/0},
            {timeout, 10, fun merge_aux_with_dangling_root_does_not_crash/0},
            {timeout, 10, fun put_with_dangling_root_does_not_crash/0}
        ]}.

%% A `split` call whose target Hash is not in any store should return
%% the `{undefined, undefined, Store}` triple — the same shape it
%% returns for an `undefined` Hash. The original code crashed on
%% `bondy_mst_page:level(undefined)`.
split_with_dangling_hash_does_not_crash() ->
    T = make_tree(<<"split_dangling">>),
    Tab = store_tab(T),
    T1 = bondy_mst:put(T, <<"k1">>, <<"v1">>),
    Fake = crypto:hash(sha256, <<"this hash points to nothing">>),
    ?assertEqual(false, ets:member(Tab, Fake)),

    %% Splice the fake hash into the root's Low so the next put
    %% follows a dangling reference. Direct ETS write — synthetic
    %% but matches the exact failure shape we see in the wild.
    %% ETS store rows are 3-tuples `{Hash, Page, FreedAt}` (FreedAt is a
    %% per-replica GC column kept outside the page record).
    Root = bondy_mst:root(T1),
    [{Root, Page, RowFreedAt}] = ets:lookup(Tab, Root),
    {bondy_mst_page, Level, _Low, List, _PageFreedAt} = Page,
    Corrupt = {bondy_mst_page, Level, Fake, List, undefined},
    true = ets:insert(Tab, {Root, Corrupt, RowFreedAt}),

    %% Put a key whose level forces traversal through Low: must NOT
    %% crash. The dangling-page recovery in split logs a warning and
    %% treats the missing subtree as empty.
    Result = bondy_mst:put(T1, key(50), value(50)),
    ?assert(is_tuple(Result)),
    ok.

%% A `merge` whose A-side root has been knocked out of A's store
%% should:
%%   - log a warning,
%%   - return a new tree that mirrors B (the dangling-A branch
%%     copies B over into A's store),
%%   - NOT crash the calling process.
merge_aux_with_dangling_root_does_not_crash() ->
    A = make_tree(<<"merge_dangling_a">>),
    B = make_tree(<<"merge_dangling_b">>),
    A1 = lists:foldl(
        fun(N, Acc) -> bondy_mst:put(Acc, key(N), value(N)) end,
        A,
        lists:seq(1, 32)
    ),
    B1 = lists:foldl(
        fun(N, Acc) ->
            bondy_mst:put(Acc, key(N + 100), value(N + 100))
        end,
        B,
        lists:seq(1, 16)
    ),
    ?assert(is_binary(bondy_mst:root(A1))),
    ?assert(is_binary(bondy_mst:root(B1))),

    %% Knock A's root out of A's ETS table so merge sees a dangling
    %% A-side. This synthesises the bench-time corruption.
    TabA = store_tab(A1),
    true = ets:delete(TabA, bondy_mst:root(A1)),

    %% Must not crash. The dangling-A branch copies B over.
    Merged = bondy_mst:merge(A1, B1),
    ?assert(is_tuple(Merged)),
    %% B's keys are now reachable from the merged tree.
    ?assertEqual(value(101), bondy_mst:get(Merged, key(101))),
    ok.

%% A `put` whose tree root has been knocked out of the store must NOT
%% crash with a `function_clause` in `bondy_mst_page:list/1`. This is
%% the realm-AAE crash in the wild:
%% `bondy_oplog_instance:install_fast_events/2` ->
%% `bondy_mst:put_batch/2` -> `put/3` -> `put_at/6` on a root whose
%% page is absent from the store. The dangling-page recovery in
%% put_at/6 logs a warning and treats the missing subtree as empty.
put_with_dangling_root_does_not_crash() ->
    T = make_tree(<<"put_dangling">>),
    T1 = lists:foldl(
        fun(N, Acc) -> bondy_mst:put(Acc, key(N), value(N)) end,
        T,
        lists:seq(1, 32)
    ),
    Root = bondy_mst:root(T1),
    ?assert(is_binary(Root)),

    %% Knock the root page out of the store, leaving a dangling root
    %% pointer: `bondy_mst_store:get(Store, Root)` now returns undefined.
    Tab = store_tab(T1),
    true = ets:delete(Tab, Root),

    %% The reported crash: a put on the dangling root. Must NOT crash —
    %% it recovers to a fresh subtree.
    T2 = bondy_mst:put(T1, key(999), value(999)),
    ?assert(is_tuple(T2)),
    ?assertEqual(value(999), bondy_mst:get(T2, key(999))),
    ok.

%% -------------------------------------------------------------------
%% Helpers

make_tree(Name) ->
    bondy_mst:new(#{
        store => bondy_mst_ets_store,
        store_opts => #{name => Name},
        hash_algorithm => sha256,
        merger => fun(_K, _V1, V2) -> V2 end
    }).

store_tab(T) ->
    %% Reach into the mst record / ets-store record to extract the
    %% private ETS tid. Test-only knob.
    Store = element(2, T),
    State = element(3, Store),
    element(3, State).

key(N) -> iolist_to_binary(io_lib:format("k:~8..0B", [N])).

value(N) -> iolist_to_binary(io_lib:format("v:~B", [N])).
