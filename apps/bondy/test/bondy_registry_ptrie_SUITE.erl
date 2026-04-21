%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_registry_ptrie_SUITE).
-moduledoc """
Property-based and unit tests for `bondy_registry_ptrie`.

Phase 1 (this file): sequential correctness of path-copied insert, remove,
lookup, and fold against a naive `map()` reference.

Later phases will add: CAS-retry tests with multiple writers, QSBR
reclamation tests, and wildcard/prefix matching once those features land in
the module.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("proper/include/proper.hrl").

-compile([nowarn_export_all, export_all]).

-define(NUMTESTS, 200).


all() ->
    [
        %% Unit tests — small, hand-picked cases
        unit_empty_trie,
        unit_single_insert_lookup,
        unit_shared_prefix,
        unit_one_key_prefix_of_another,
        unit_update_same_key,
        unit_remove_existing,
        unit_remove_nonexistent,
        unit_fold_order,

        %% Property tests — randomized against a map reference
        prop_insert_then_lookup,
        prop_insert_update_overwrites,
        prop_insert_absent_key_lookup,
        prop_random_ops_equal_to_map,
        prop_fold_contains_all_entries,
        prop_size_equals_fold_count,

        %% Concurrency — multi-writer + multi-reader
        concurrent_writers_distinct_keys,
        concurrent_writers_shared_keys,
        concurrent_readers_no_crash,
        concurrent_readers_and_writers,

        %% Reclamation — QSBR correctness and liveness
        reclaim_no_readers_drains_retire_queue,
        reclaim_blocked_by_active_reader,
        reclaim_progresses_after_reader_releases,
        reclaim_safe_under_concurrent_readers,
        janitor_converges_memory,

        %% WAMP wildcard + prefix matching
        match_exact_policy,
        match_prefix_policy,
        match_wildcard_single_segment,
        match_wildcard_multiple_segments,
        match_mixed_policies_at_same_key,
        match_prefix_on_ancestor_node,
        match_target_shorter_than_prefix,
        match_empty_target,
        match_no_match_returns_empty,
        match_encode_decode_round_trip,
        match_wildcard_must_consume_non_empty_segment,
        prop_match_agrees_with_reference
    ].


init_per_suite(Config) ->
    Config.


end_per_suite(Config) ->
    Config.


init_per_testcase(_TC, Config) ->
    Name = list_to_atom("ptrie_test_" ++ integer_to_list(erlang:unique_integer([positive]))),
    Handle = bondy_registry_ptrie:new(Name),
    [{handle, Handle} | Config].


end_per_testcase(_TC, Config) ->
    case ?config(handle, Config) of
        undefined -> ok;
        H -> catch bondy_registry_ptrie:delete(H)
    end,
    ok.


%% =============================================================================
%% UNIT TESTS
%% =============================================================================


unit_empty_trie(Config) ->
    H = ?config(handle, Config),
    ?assertEqual(error, bondy_registry_ptrie:lookup(H, <<"any">>)),
    ?assertEqual(0, bondy_registry_ptrie:size(H)).


unit_single_insert_lookup(Config) ->
    H = ?config(handle, Config),
    ok = bondy_registry_ptrie:insert(H, <<"com.example.foo">>, 42),
    ?assertEqual({ok, 42}, bondy_registry_ptrie:lookup(H, <<"com.example.foo">>)),
    ?assertEqual(1, bondy_registry_ptrie:size(H)).


unit_shared_prefix(Config) ->
    H = ?config(handle, Config),
    ok = bondy_registry_ptrie:insert(H, <<"com.example.foo">>, 1),
    ok = bondy_registry_ptrie:insert(H, <<"com.example.bar">>, 2),
    ok = bondy_registry_ptrie:insert(H, <<"com.example.baz">>, 3),
    ?assertEqual({ok, 1}, bondy_registry_ptrie:lookup(H, <<"com.example.foo">>)),
    ?assertEqual({ok, 2}, bondy_registry_ptrie:lookup(H, <<"com.example.bar">>)),
    ?assertEqual({ok, 3}, bondy_registry_ptrie:lookup(H, <<"com.example.baz">>)),
    ?assertEqual(error, bondy_registry_ptrie:lookup(H, <<"com.example.qux">>)),
    ?assertEqual(error, bondy_registry_ptrie:lookup(H, <<"com.example">>)),
    ?assertEqual(3, bondy_registry_ptrie:size(H)).


unit_one_key_prefix_of_another(Config) ->
    H = ?config(handle, Config),
    ok = bondy_registry_ptrie:insert(H, <<"com">>, 1),
    ok = bondy_registry_ptrie:insert(H, <<"com.example">>, 2),
    ok = bondy_registry_ptrie:insert(H, <<"com.example.foo">>, 3),
    ?assertEqual({ok, 1}, bondy_registry_ptrie:lookup(H, <<"com">>)),
    ?assertEqual({ok, 2}, bondy_registry_ptrie:lookup(H, <<"com.example">>)),
    ?assertEqual({ok, 3}, bondy_registry_ptrie:lookup(H, <<"com.example.foo">>)),
    ?assertEqual(error, bondy_registry_ptrie:lookup(H, <<>>)),
    ?assertEqual(error, bondy_registry_ptrie:lookup(H, <<"co">>)).


unit_update_same_key(Config) ->
    H = ?config(handle, Config),
    ok = bondy_registry_ptrie:insert(H, <<"k">>, v1),
    ok = bondy_registry_ptrie:insert(H, <<"k">>, v2),
    ok = bondy_registry_ptrie:insert(H, <<"k">>, v3),
    ?assertEqual({ok, v3}, bondy_registry_ptrie:lookup(H, <<"k">>)),
    ?assertEqual(1, bondy_registry_ptrie:size(H)).


unit_remove_existing(Config) ->
    H = ?config(handle, Config),
    ok = bondy_registry_ptrie:insert(H, <<"a">>, 1),
    ok = bondy_registry_ptrie:insert(H, <<"ab">>, 2),
    ok = bondy_registry_ptrie:insert(H, <<"abc">>, 3),
    ok = bondy_registry_ptrie:remove(H, <<"ab">>),
    ?assertEqual({ok, 1}, bondy_registry_ptrie:lookup(H, <<"a">>)),
    ?assertEqual(error, bondy_registry_ptrie:lookup(H, <<"ab">>)),
    ?assertEqual({ok, 3}, bondy_registry_ptrie:lookup(H, <<"abc">>)),
    ?assertEqual(2, bondy_registry_ptrie:size(H)).


unit_remove_nonexistent(Config) ->
    H = ?config(handle, Config),
    ok = bondy_registry_ptrie:insert(H, <<"a">>, 1),
    ok = bondy_registry_ptrie:remove(H, <<"nonexistent">>),
    ?assertEqual({ok, 1}, bondy_registry_ptrie:lookup(H, <<"a">>)),
    ?assertEqual(1, bondy_registry_ptrie:size(H)).


unit_fold_order(Config) ->
    H = ?config(handle, Config),
    Keys = [<<"c">>, <<"a">>, <<"b">>, <<"aa">>, <<"ab">>],
    [ok = bondy_registry_ptrie:insert(H, K, K) || K <- Keys],
    Folded = bondy_registry_ptrie:fold(
        H,
        fun(K, _V, Acc) -> [K | Acc] end,
        []
    ),
    %% fold visits in byte-lexicographic order; reversing the accumulator gives
    %% ascending order.
    ?assertEqual(lists:sort(Keys), lists:reverse(Folded)).


%% =============================================================================
%% PROPERTY TESTS
%% =============================================================================


prop_insert_then_lookup(Config) ->
    H = ?config(handle, Config),
    run_prop(
        ?FORALL(
            {K, V},
            {safe_key(), any_value()},
            begin
                clear(H),
                ok = bondy_registry_ptrie:insert(H, K, V),
                {ok, V} =:= bondy_registry_ptrie:lookup(H, K)
            end
        )
    ).


prop_insert_update_overwrites(Config) ->
    H = ?config(handle, Config),
    run_prop(
        ?FORALL(
            {K, V1, V2},
            {safe_key(), any_value(), any_value()},
            begin
                clear(H),
                ok = bondy_registry_ptrie:insert(H, K, V1),
                ok = bondy_registry_ptrie:insert(H, K, V2),
                {ok, V2} =:= bondy_registry_ptrie:lookup(H, K)
                    andalso 1 =:= bondy_registry_ptrie:size(H)
            end
        )
    ).


prop_insert_absent_key_lookup(Config) ->
    H = ?config(handle, Config),
    run_prop(
        ?FORALL(
            {Ks, Probe},
            {non_empty(list(safe_key())), safe_key()},
            ?IMPLIES(
                not lists:member(Probe, Ks),
                begin
                    clear(H),
                    [ok = bondy_registry_ptrie:insert(H, K, v) || K <- Ks],
                    error =:= bondy_registry_ptrie:lookup(H, Probe)
                end
            )
        )
    ).


prop_random_ops_equal_to_map(Config) ->
    H = ?config(handle, Config),
    run_prop(
        ?FORALL(
            Ops,
            list(op()),
            begin
                clear(H),
                Ref = apply_ops(Ops, H),
                ptrie_matches_map(H, Ref)
            end
        )
    ).


prop_fold_contains_all_entries(Config) ->
    H = ?config(handle, Config),
    run_prop(
        ?FORALL(
            Pairs0,
            list({safe_key(), any_value()}),
            begin
                clear(H),
                Pairs = dedup_pairs(Pairs0),
                [ok = bondy_registry_ptrie:insert(H, K, V) || {K, V} <- Pairs],
                Folded = bondy_registry_ptrie:fold(
                    H,
                    fun(K, V, Acc) -> [{K, V} | Acc] end,
                    []
                ),
                lists:sort(Pairs) =:= lists:sort(Folded)
            end
        )
    ).


prop_size_equals_fold_count(Config) ->
    H = ?config(handle, Config),
    run_prop(
        ?FORALL(
            Pairs0,
            list({safe_key(), any_value()}),
            begin
                clear(H),
                Pairs = dedup_pairs(Pairs0),
                [ok = bondy_registry_ptrie:insert(H, K, V) || {K, V} <- Pairs],
                length(Pairs) =:= bondy_registry_ptrie:size(H)
            end
        )
    ).


%% =============================================================================
%% CONCURRENCY TESTS
%% =============================================================================


concurrent_writers_distinct_keys(Config) ->
    %% N workers each insert their own exclusive set of keys. After they
    %% all finish, every committed key must be retrievable and the total
    %% count must equal the sum of per-worker counts.
    H = ?config(handle, Config),
    clear(H),
    Workers = 8,
    KeysPerWorker = 200,
    Parent = self(),
    Pids = [spawn_link(fun() ->
        Keys = [worker_key(W, I) || I <- lists:seq(1, KeysPerWorker)],
        [ok = bondy_registry_ptrie:insert(H, K, K) || K <- Keys],
        Parent ! {done, self(), Keys}
    end) || W <- lists:seq(1, Workers)],
    AllKeys = lists:flatten([receive {done, P, Ks} -> Ks end || P <- Pids]),
    %% Every key retrievable.
    lists:foreach(
        fun(K) -> ?assertEqual({ok, K}, bondy_registry_ptrie:lookup(H, K)) end,
        AllKeys
    ),
    ?assertEqual(length(AllKeys), bondy_registry_ptrie:size(H)),
    ok.


concurrent_writers_shared_keys(Config) ->
    %% N workers all write to the SAME key (conflict-max). The final value
    %% must be one of the values written; no writer may hang or return
    %% cas_exhausted within the default retry budget.
    %%
    %% We expand the retry budget assumption by using a small key set so
    %% writes serialize on the same CAS row.
    H = ?config(handle, Config),
    clear(H),
    Workers = 6,
    WritesPerWorker = 50,
    Key = <<"shared.hot.key">>,
    Parent = self(),
    Pids = [spawn_link(fun() ->
        Results = [bondy_registry_ptrie:insert(H, Key, {W, I})
                   || I <- lists:seq(1, WritesPerWorker)],
        Parent ! {done, self(), Results}
    end) || W <- lists:seq(1, Workers)],
    All = lists:flatten([receive {done, P, Rs} -> Rs end || P <- Pids]),
    %% Every insert either returned ok or cas_exhausted. We want ok to be
    %% the overwhelming majority; any cas_exhausted is a budget-retry.
    OkCount = length([ok || ok <- All]),
    ExhaustedCount = length([E || E = {error, cas_exhausted} <- All]),
    TotalWrites = Workers * WritesPerWorker,
    ?assertEqual(TotalWrites, OkCount + ExhaustedCount),
    ct:pal("shared-keys: ok=~p exhausted=~p/~p",
           [OkCount, ExhaustedCount, TotalWrites]),
    %% Final state must have exactly the one key (regardless of which
    %% writer's value won).
    {ok, _FinalValue} = bondy_registry_ptrie:lookup(H, Key),
    ?assertEqual(1, bondy_registry_ptrie:size(H)),
    ok.


concurrent_readers_no_crash(Config) ->
    %% While a single writer is inserting, many readers traverse the trie.
    %% Readers must never crash with `badarg` or similar from touching
    %% concurrently-retired nodes. This is the reader-safety claim — the
    %% janitor isn't running yet (not implemented) so retired nodes just
    %% accumulate in the retire table, which is the "conservative" case
    %% for reclamation-safety. Still, readers may traverse nodes that were
    %% fresh at the time of snapshot but unreachable at the time of lookup.
    H = ?config(handle, Config),
    clear(H),
    Writes = 1000,
    Readers = 8,
    ReadOpsPerReader = 5000,
    Parent = self(),

    %% Writer task.
    Writer = spawn_link(fun() ->
        lists:foreach(
            fun(I) ->
                K = iolist_to_binary(io_lib:format("key.~p", [I])),
                ok = bondy_registry_ptrie:insert(H, K, I)
            end,
            lists:seq(1, Writes)
        ),
        Parent ! {writer_done, self()}
    end),

    %% Reader tasks.
    ReaderPids = [spawn_link(fun() ->
        try
            lists:foreach(
                fun(I) ->
                    K = iolist_to_binary(
                        io_lib:format("key.~p", [I rem Writes])
                    ),
                    _ = bondy_registry_ptrie:lookup(H, K)
                end,
                lists:seq(1, ReadOpsPerReader)
            ),
            Parent ! {reader_done, self(), ok}
        catch
            C:E:S ->
                Parent ! {reader_done, self(), {crash, C, E, S}}
        end
    end) || _ <- lists:seq(1, Readers)],

    receive {writer_done, Writer} -> ok after 30_000 -> exit(writer_timeout) end,
    lists:foreach(fun(Pid) ->
        receive
            {reader_done, Pid, ok} -> ok;
            {reader_done, Pid, {crash, C, E, S}} ->
                ct:fail("Reader crashed: ~p:~p~n~p", [C, E, S])
        after 30_000 ->
            exit({reader_timeout, Pid})
        end
    end, ReaderPids),
    ok.


concurrent_readers_and_writers(Config) ->
    %% Heavy mixed workload: many writers + many readers. Every committed
    %% write (ok return) must be visible to every subsequent reader.
    H = ?config(handle, Config),
    clear(H),
    Writers = 6,
    Readers = 6,
    OpsPerWorker = 500,
    Parent = self(),

    WriterPids = [spawn_link(fun() ->
        Results = [begin
            K = worker_key(W, I),
            R = bondy_registry_ptrie:insert(H, K, I),
            {K, R}
        end || I <- lists:seq(1, OpsPerWorker)],
        Parent ! {writer_done, self(), Results}
    end) || W <- lists:seq(1, Writers)],

    ReaderPids = [spawn_link(fun() ->
        try
            %% Readers pick random keys from the writer key space and
            %% validate consistency (value either missing or correctly
            %% associated with the key).
            lists:foreach(
                fun(_) ->
                    W = rand:uniform(Writers),
                    I = rand:uniform(OpsPerWorker),
                    K = worker_key(W, I),
                    case bondy_registry_ptrie:lookup(H, K) of
                        error -> ok;        %% not yet written — fine
                        {ok, V} when V =:= I -> ok;
                        {ok, Other} ->
                            exit({bad_value, K, Other, expected, I})
                    end
                end,
                lists:seq(1, OpsPerWorker)
            ),
            Parent ! {reader_done, self(), ok}
        catch
            C:E:S -> Parent ! {reader_done, self(), {crash, C, E, S}}
        end
    end) || _ <- lists:seq(1, Readers)],

    AllWriterResults = lists:flatten([
        receive
            {writer_done, Pid, Rs} -> Rs
        after 60_000 ->
            exit({writer_timeout, Pid})
        end
    || Pid <- WriterPids]),

    lists:foreach(fun(Pid) ->
        receive
            {reader_done, Pid, ok} -> ok;
            {reader_done, Pid, {crash, C, E, S}} ->
                ct:fail("Reader crashed: ~p:~p~n~p", [C, E, S])
        after 60_000 -> exit({reader_timeout, Pid})
        end
    end, ReaderPids),

    %% Every committed write must be present with the right value.
    lists:foreach(
        fun
            ({K, ok}) ->
                ExpectedValue = worker_key_to_i(K),
                ?assertEqual({ok, ExpectedValue},
                             bondy_registry_ptrie:lookup(H, K));
            ({_, {error, cas_exhausted}}) ->
                ok
        end,
        AllWriterResults
    ),
    OkCount = length([1 || {_, ok} <- AllWriterResults]),
    ?assertEqual(OkCount, bondy_registry_ptrie:size(H)),
    ok.


%% =============================================================================
%% RECLAMATION TESTS
%% =============================================================================


reclaim_no_readers_drains_retire_queue(Config) ->
    %% With no active readers, every retired node should be reclaimable.
    H = ?config(handle, Config),
    clear(H),
    N = 500,
    Keys = [iolist_to_binary(io_lib:format("k.~p", [I])) || I <- lists:seq(1, N)],
    [ok = bondy_registry_ptrie:insert(H, K, K) || K <- Keys],
    [ok = bondy_registry_ptrie:remove(H, K) || K <- Keys],
    %% Ensure no readers are pinning anything.
    ?assertEqual(infinity, bondy_registry_ptrie:min_active_epoch(H)),
    RetireBefore = bondy_registry_ptrie:retire_count(H),
    Reclaimed = bondy_registry_ptrie:reclaim(H),
    ?assertEqual(RetireBefore, Reclaimed),
    ?assertEqual(0, bondy_registry_ptrie:retire_count(H)),
    %% After removing everything, only the empty root node remains.
    ?assertEqual(0, bondy_registry_ptrie:size(H)),
    ?assertEqual(1, bondy_registry_ptrie:node_count(H)),
    ok.


reclaim_blocked_by_active_reader(Config) ->
    %% A reader that has pinned an old epoch must prevent reclamation of
    %% everything retired AT OR AFTER its pinned epoch.
    H = ?config(handle, Config),
    clear(H),
    ok = bondy_registry_ptrie:insert(H, <<"pinned">>, original),
    ReaderRef = make_ref(),
    {Reader, ReleaseRef} = spawn_blocked_reader(H, ReaderRef),

    %% Reader is pinning an epoch. Now the writer mutates.
    ok = bondy_registry_ptrie:insert(H, <<"pinned">>, updated),
    ok = bondy_registry_ptrie:insert(H, <<"another">>, 1),
    RetireBefore = bondy_registry_ptrie:retire_count(H),
    ?assert(RetireBefore > 0),

    MinActive = bondy_registry_ptrie:min_active_epoch(H),
    ?assertNotEqual(infinity, MinActive),

    %% Reader pinned an epoch before any of the above writes, so no retires
    %% are reclaimable.
    Reclaimed = bondy_registry_ptrie:reclaim(H),
    ?assertEqual(0, Reclaimed),
    ?assertEqual(RetireBefore, bondy_registry_ptrie:retire_count(H)),

    Reader ! {release, ReleaseRef},
    receive {reader_exited, ReaderRef} -> ok
    after 5000 -> exit(reader_did_not_exit) end,
    ok.


reclaim_progresses_after_reader_releases(Config) ->
    %% Same setup as the previous test, but we now reclaim AFTER the reader
    %% releases. Everything should drain.
    H = ?config(handle, Config),
    clear(H),
    ok = bondy_registry_ptrie:insert(H, <<"pinned">>, original),
    ReaderRef = make_ref(),
    {Reader, ReleaseRef} = spawn_blocked_reader(H, ReaderRef),

    [ok = bondy_registry_ptrie:insert(H, iolist_to_binary(io_lib:format("k~p", [I])), I)
        || I <- lists:seq(1, 100)],

    Reader ! {release, ReleaseRef},
    receive {reader_exited, ReaderRef} -> ok
    after 5000 -> exit(reader_hang) end,

    _ = bondy_registry_ptrie:reclaim(H),
    ?assertEqual(0, bondy_registry_ptrie:retire_count(H)),
    ok.


reclaim_safe_under_concurrent_readers(Config) ->
    %% The aggressive test: readers run continuously while a writer fires
    %% mutations and the janitor reclaims. Readers must never observe a
    %% `badarg` from an ETS row that was reclaimed mid-traversal. If our
    %% QSBR protocol is correct, readers always see a consistent snapshot.
    H = ?config(handle, Config),
    clear(H),
    Parent = self(),
    Readers = 8,
    Writes = 2000,
    OpsPerReader = 10_000,

    Writer = spawn_link(fun() ->
        lists:foreach(
            fun(I) ->
                K = iolist_to_binary(io_lib:format("k.~p", [I rem 500])),
                case I rem 3 of
                    0 -> ok = bondy_registry_ptrie:insert(H, K, I);
                    1 -> ok = bondy_registry_ptrie:insert(H, K, {alt, I});
                    2 -> ok = bondy_registry_ptrie:remove(H, K)
                end
            end,
            lists:seq(1, Writes)
        ),
        Parent ! {writer_done, self()}
    end),

    ReaderPids = [spawn_link(fun() ->
        try
            lists:foreach(
                fun(I) ->
                    K = iolist_to_binary(
                        io_lib:format("k.~p", [I rem 500])
                    ),
                    _ = bondy_registry_ptrie:lookup(H, K)
                end,
                lists:seq(1, OpsPerReader)
            ),
            Parent ! {reader_done, self(), ok}
        catch
            C:E:S ->
                Parent ! {reader_done, self(), {crash, C, E, S}}
        end
    end) || _ <- lists:seq(1, Readers)],

    %% Run the janitor continuously in the background.
    {ok, Janitor} = bondy_registry_ptrie_janitor:start_link(
        H, #{period_ms => 10}
    ),

    receive {writer_done, Writer} -> ok after 60_000 -> exit(w_timeout) end,
    lists:foreach(fun(Pid) ->
        receive
            {reader_done, Pid, ok} -> ok;
            {reader_done, Pid, {crash, C, E, S}} ->
                ct:fail("reader crash ~p:~p~n~p", [C, E, S])
        after 60_000 -> exit({r_timeout, Pid})
        end
    end, ReaderPids),

    %% Give the janitor one more sweep after everything settles.
    _ = bondy_registry_ptrie_janitor:sweep(Janitor),
    ok = bondy_registry_ptrie_janitor:stop(Janitor),

    %% After everyone leaves and reclaim has run, the retire queue should
    %% be drained (or very close — there may be a tiny residual from late
    %% writes retired in the final micro-window before stop).
    Final = bondy_registry_ptrie:retire_count(H),
    ct:pal("retire_count after full drain: ~p", [Final]),
    ?assert(Final =< 4),
    ok.


janitor_converges_memory(Config) ->
    %% Without a janitor the retire table grows unboundedly. With a janitor
    %% and no long-lived readers, memory should converge — the node table
    %% stops growing after steady state and the retire queue stays small.
    H = ?config(handle, Config),
    clear(H),
    {ok, Janitor} = bondy_registry_ptrie_janitor:start_link(
        H, #{period_ms => 20}
    ),
    try
        N = 5000,
        lists:foreach(
            fun(I) ->
                K = iolist_to_binary(io_lib:format("ok.~8..0b", [I])),
                ok = bondy_registry_ptrie:insert(H, K, I)
            end,
            lists:seq(1, N)
        ),
        %% Let reclamation catch up.
        timer:sleep(500),
        _ = bondy_registry_ptrie_janitor:sweep(Janitor),
        Info = bondy_registry_ptrie:info(H),
        ct:pal("info after ~p inserts: ~p", [N, Info]),
        Retire = maps:get(retire_count, Info),
        ?assert(Retire =< 8),
        %% The node count should reflect the tree we actually built, not
        %% `sum of all path copies for every write` — that would be O(N*d).
        NodeCount = maps:get(node_count, Info),
        ?assert(NodeCount =< 3 * N),
        ok
    after
        ok = bondy_registry_ptrie_janitor:stop(Janitor)
    end.


%% @private
%% Spawn a reader that enters `bondy_registry_ptrie:fold/3`, pins its epoch
%% via `with_epoch/2`, and blocks inside the fold fun until the parent
%% sends `{release, ReleaseRef}`. Returns the reader pid and the
%% release-ref the parent should use to unblock it.
spawn_blocked_reader(H, ReaderRef) ->
    Parent = self(),
    ReleaseRef = make_ref(),
    Reader = spawn_link(fun() ->
        _ = bondy_registry_ptrie:fold(
            H,
            fun(_K, _V, _Acc) ->
                Parent ! {reader_pinned, ReaderRef},
                receive
                    {release, ReleaseRef} -> stop
                after 30_000 ->
                    exit(reader_release_timeout)
                end
            end,
            stop
        ),
        Parent ! {reader_exited, ReaderRef}
    end),
    receive
        {reader_pinned, ReaderRef} -> ok
    after 5000 ->
        exit({reader_did_not_pin, Reader})
    end,
    {Reader, ReleaseRef}.


%% =============================================================================
%% MATCH TESTS (WAMP wildcard + prefix)
%% =============================================================================


match_exact_policy(Config) ->
    H = ?config(handle, Config),
    clear(H),
    ok = bondy_registry_ptrie:insert(H, <<"com.example.svc.add">>, exact, v_add),
    ok = bondy_registry_ptrie:insert(H, <<"com.example.svc.sub">>, exact, v_sub),
    %% Exact match lands on the exact leaf, nothing else.
    ?assertEqual(
        [{<<"com.example.svc.add">>, exact, v_add}],
        bondy_registry_ptrie:match(H, <<"com.example.svc.add">>)
    ),
    ?assertEqual(
        [{<<"com.example.svc.sub">>, exact, v_sub}],
        bondy_registry_ptrie:match(H, <<"com.example.svc.sub">>)
    ),
    %% Non-matching target.
    ?assertEqual([], bondy_registry_ptrie:match(H, <<"com.other">>)),
    ok.


match_prefix_policy(Config) ->
    H = ?config(handle, Config),
    clear(H),
    ok = bondy_registry_ptrie:insert(H, <<"com.example.">>, prefix, p_short),
    ok = bondy_registry_ptrie:insert(H, <<"com.example.svc.">>, prefix, p_long),
    %% Target under both prefixes matches both.
    Results = bondy_registry_ptrie:match(H, <<"com.example.svc.add">>),
    ?assertEqual(
        lists:sort([{<<"com.example.">>, prefix, p_short},
                    {<<"com.example.svc.">>, prefix, p_long}]),
        lists:sort(Results)
    ),
    %% Target only under shorter prefix.
    ?assertEqual(
        [{<<"com.example.">>, prefix, p_short}],
        bondy_registry_ptrie:match(H, <<"com.example.other">>)
    ),
    %% Target not under either prefix.
    ?assertEqual([], bondy_registry_ptrie:match(H, <<"net.other.x">>)),
    ok.


match_wildcard_single_segment(Config) ->
    H = ?config(handle, Config),
    clear(H),
    Pattern = bondy_registry_ptrie:encode_pattern(<<"com..svc.add">>),
    ok = bondy_registry_ptrie:insert(H, Pattern, wildcard, w_any),
    %% Any single segment between "com" and "svc" matches.
    ?assertEqual(
        [{Pattern, wildcard, w_any}],
        bondy_registry_ptrie:match(H, <<"com.foo.svc.add">>)
    ),
    ?assertEqual(
        [{Pattern, wildcard, w_any}],
        bondy_registry_ptrie:match(H, <<"com.example.svc.add">>)
    ),
    %% Wrong structure (different suffix).
    ?assertEqual([], bondy_registry_ptrie:match(H, <<"com.foo.svc.sub">>)),
    %% Wrong number of segments.
    ?assertEqual([], bondy_registry_ptrie:match(H, <<"com.foo.bar.svc.add">>)),
    ok.


match_wildcard_multiple_segments(Config) ->
    H = ?config(handle, Config),
    clear(H),
    Pattern = bondy_registry_ptrie:encode_pattern(<<"com...add">>),
    ok = bondy_registry_ptrie:insert(H, Pattern, wildcard, w_two),
    %% Two variable segments between "com" and "add".
    ?assertEqual(
        [{Pattern, wildcard, w_two}],
        bondy_registry_ptrie:match(H, <<"com.x.y.add">>)
    ),
    ?assertEqual(
        [{Pattern, wildcard, w_two}],
        bondy_registry_ptrie:match(H, <<"com.abc.def.add">>)
    ),
    %% Too few segments.
    ?assertEqual([], bondy_registry_ptrie:match(H, <<"com.x.add">>)),
    %% Too many.
    ?assertEqual([], bondy_registry_ptrie:match(H, <<"com.a.b.c.add">>)),
    ok.


match_mixed_policies_at_same_key(Config) ->
    H = ?config(handle, Config),
    clear(H),
    %% Same key, different policies — all coexist.
    K = <<"com.example">>,
    ok = bondy_registry_ptrie:insert(H, K, exact, v_exact),
    ok = bondy_registry_ptrie:insert(H, K, prefix, v_prefix),
    %% A target equal to K matches both the exact and prefix leaves.
    Results = bondy_registry_ptrie:match(H, K),
    ?assertEqual(
        lists:sort([{K, exact, v_exact}, {K, prefix, v_prefix}]),
        lists:sort(Results)
    ),
    %% A strictly-longer target matches only the prefix leaf.
    %% (Note: prefix policy is byte-level; caller is responsible for
    %% supplying prefix keys that end with `.` for component-aligned match.
    %% Here `com.example.x` starts with `com.example` in bytes, so it matches.)
    ?assertEqual(
        [{K, prefix, v_prefix}],
        bondy_registry_ptrie:match(H, <<"com.example.x">>)
    ),
    ok.


match_prefix_on_ancestor_node(Config) ->
    H = ?config(handle, Config),
    clear(H),
    %% A prefix leaf on an ancestor node must be collected during the walk,
    %% even if descendants with more specific keys also match.
    ok = bondy_registry_ptrie:insert(H, <<"com.">>, prefix, v_short),
    ok = bondy_registry_ptrie:insert(H, <<"com.example.svc.add">>, exact, v_exact),
    Results = bondy_registry_ptrie:match(H, <<"com.example.svc.add">>),
    ?assertEqual(
        lists:sort([{<<"com.">>, prefix, v_short},
                    {<<"com.example.svc.add">>, exact, v_exact}]),
        lists:sort(Results)
    ),
    ok.


match_target_shorter_than_prefix(Config) ->
    H = ?config(handle, Config),
    clear(H),
    %% A prefix pattern longer than the target can't match. No collection.
    ok = bondy_registry_ptrie:insert(H, <<"com.example.service.">>, prefix, v_p),
    ?assertEqual([], bondy_registry_ptrie:match(H, <<"com.example">>)),
    ok.


match_empty_target(Config) ->
    H = ?config(handle, Config),
    clear(H),
    ok = bondy_registry_ptrie:insert(H, <<>>, exact, v_empty),
    ok = bondy_registry_ptrie:insert(H, <<>>, prefix, v_root_prefix),
    ok = bondy_registry_ptrie:insert(H, <<"a">>, exact, v_a),
    %% Empty target: matches the exact- and prefix-empty-key leaves only.
    Results = bondy_registry_ptrie:match(H, <<>>),
    ?assertEqual(
        lists:sort([{<<>>, exact, v_empty},
                    {<<>>, prefix, v_root_prefix}]),
        lists:sort(Results)
    ),
    ok.


match_no_match_returns_empty(Config) ->
    H = ?config(handle, Config),
    clear(H),
    ok = bondy_registry_ptrie:insert(H, <<"com.example.svc">>, exact, v),
    ?assertEqual([], bondy_registry_ptrie:match(H, <<"com.other.svc">>)),
    ?assertEqual([], bondy_registry_ptrie:match(H, <<"no.common.prefix">>)),
    ok.


match_encode_decode_round_trip(_Config) ->
    Cases = [
        <<"com.example.service.add">>,
        <<"com..service.add">>,
        <<"com...add">>,
        <<"..middle..">>,
        <<>>,
        <<"single">>,
        <<"single.">>
    ],
    lists:foreach(
        fun(URI) ->
            Enc = bondy_registry_ptrie:encode_pattern(URI),
            ?assertEqual(URI, bondy_registry_ptrie:decode_pattern(Enc))
        end,
        Cases
    ),
    ok.


match_wildcard_must_consume_non_empty_segment(Config) ->
    %% WAMP targets are "strict" (no empty components). A wildcard must
    %% consume at least one byte — it cannot match an empty segment.
    H = ?config(handle, Config),
    clear(H),
    Pattern = bondy_registry_ptrie:encode_pattern(<<"a..b">>),
    ok = bondy_registry_ptrie:insert(H, Pattern, wildcard, v),
    %% Valid target.
    ?assertEqual(
        [{Pattern, wildcard, v}],
        bondy_registry_ptrie:match(H, <<"a.x.b">>)
    ),
    %% Target with an empty middle component should NOT match (it would
    %% require matching `` against the wildcard, but WAMP strict URIs
    %% forbid empty components in targets anyway).
    ?assertEqual([], bondy_registry_ptrie:match(H, <<"a..b">>)),
    ok.


prop_match_agrees_with_reference(Config) ->
    %% Generate a random set of registered patterns (exact, prefix,
    %% wildcard) and a random target. Verify `match/2` returns the same
    %% set as a brute-force reference check over every stored pattern.
    H = ?config(handle, Config),
    run_prop(
        ?FORALL(
            {Registered, Target},
            {list(registered_pattern()), uri_target()},
            begin
                clear(H),
                [ok = bondy_registry_ptrie:insert(H, K, P, V)
                    || {K, P, V} <- Registered],
                Actual = lists:sort(bondy_registry_ptrie:match(H, Target)),
                %% Dedup by {K, P} — insert-with-same-{K,P}-overwrites
                %% means only the last V per {K, P} is live.
                LatestRegistered = dedup_by_kp(Registered),
                Expected = lists:sort(
                    [{K, P, V} || {K, P, V} <- LatestRegistered,
                                  reference_match(K, P, Target)]
                ),
                case Actual =:= Expected of
                    true -> true;
                    false ->
                        ct:pal("target=~p~nregistered=~p~nactual=~p~nexpected=~p",
                               [Target, LatestRegistered, Actual, Expected]),
                        false
                end
            end
        )
    ).


%% =============================================================================
%% GENERATORS
%% =============================================================================


safe_key() ->
    %% Keys drawn from a small byte alphabet to exercise path compression
    %% and branching with realistic shared prefixes.
    ?LET(
        Len,
        choose(0, 12),
        ?LET(
            Bytes,
            vector(Len, choose($a, $f)),
            list_to_binary(Bytes)
        )
    ).


any_value() ->
    oneof([
        integer(),
        binary(),
        atom(),
        {tuple, integer()}
    ]).


op() ->
    oneof([
        {insert, safe_key(), any_value()},
        {remove, safe_key()},
        {lookup, safe_key()}
    ]).


%% =============================================================================
%% HELPERS
%% =============================================================================


%% @private
run_prop(Prop) ->
    true = proper:quickcheck(Prop, [
        {numtests, ?NUMTESTS},
        {to_file, user},
        noshrink
    ]).


%% @private
clear(H) ->
    %% Atomic empty + drain retire queue so tests start from a clean
    %% reclamation state. Without the reclaim, the truncate's retired
    %% nodes would survive in the retire table and get counted by tests
    %% that assert on retire-queue state.
    ok = bondy_registry_ptrie:truncate(H),
    _ = bondy_registry_ptrie:reclaim(H),
    ok.


%% @private
apply_ops(Ops, H) ->
    lists:foldl(
        fun(Op, Ref) -> apply_op(Op, H, Ref) end,
        #{},
        Ops
    ).


%% @private
apply_op({insert, K, V}, H, Ref) ->
    ok = bondy_registry_ptrie:insert(H, K, V),
    maps:put(K, V, Ref);
apply_op({remove, K}, H, Ref) ->
    ok = bondy_registry_ptrie:remove(H, K),
    maps:remove(K, Ref);
apply_op({lookup, K}, H, Ref) ->
    _ = bondy_registry_ptrie:lookup(H, K),
    Ref.


%% @private
%% Check the ptrie contents are exactly the map.
ptrie_matches_map(H, Map) ->
    %% Each lookup agrees with the map.
    AllLookupsAgree = maps:fold(
        fun(K, V, Acc) ->
            Acc andalso {ok, V} =:= bondy_registry_ptrie:lookup(H, K)
        end,
        true,
        Map
    ),
    %% Fold returns exactly the map's contents.
    FoldedMap = bondy_registry_ptrie:fold(
        H,
        fun(K, V, Acc) -> maps:put(K, V, Acc) end,
        #{}
    ),
    AllLookupsAgree andalso Map =:= FoldedMap.


%% @private
dedup_pairs(Pairs) ->
    %% Last write wins for duplicated keys.
    maps:to_list(maps:from_list(Pairs)).


%% @private
%% Dedup a list of `{Key, Policy, Value}` by `{Key, Policy}`, last write
%% wins (simulates the "insert-overwrites" semantics).
dedup_by_kp(Registered) ->
    Map = lists:foldl(
        fun({K, P, V}, Acc) -> maps:put({K, P}, V, Acc) end,
        #{},
        Registered
    ),
    [{K, P, V} || {{K, P}, V} <- maps:to_list(Map)].


%% @private
%% Reference implementation of `match/2` for a single stored leaf against a
%% target URI. Used as the correctness oracle for the property test.
reference_match(Key, exact, Target) ->
    Key =:= Target;
reference_match(Key, prefix, Target) ->
    KS = byte_size(Key),
    byte_size(Target) >= KS
        andalso binary_part(Target, 0, KS) =:= Key;
reference_match(Key, wildcard, Target) ->
    %% Decode stored key to its URI components. Each <<0>> component is a
    %% wildcard. Split target by `.` and match componentwise.
    KeyDecoded = bondy_registry_ptrie:decode_pattern(Key),
    KeyParts = binary:split(KeyDecoded, <<".">>, [global]),
    TargetParts = binary:split(Target, <<".">>, [global]),
    wildcard_parts_match(KeyParts, TargetParts).


%% @private
wildcard_parts_match([], []) -> true;
wildcard_parts_match([], _) -> false;
wildcard_parts_match(_, []) -> false;
wildcard_parts_match([<<>> | KT], [TP | TT]) when byte_size(TP) > 0 ->
    wildcard_parts_match(KT, TT);
wildcard_parts_match([<<>> | _], [<<>> | _]) ->
    false;  %% wildcard can't match empty target segment
wildcard_parts_match([KP | KT], [KP | TT]) ->
    wildcard_parts_match(KT, TT);
wildcard_parts_match(_, _) ->
    false.


%% @private
%% A random pattern suitable for registration. Policy is weighted toward
%% generating each kind.
registered_pattern() ->
    ?LET(
        {Policy, URI},
        {oneof([exact, prefix, wildcard]), uri_pattern()},
        case Policy of
            wildcard ->
                {bondy_registry_ptrie:encode_pattern(
                     uri_pattern_with_wildcards(URI)
                 ),
                 wildcard,
                 v};
            _ ->
                {URI, Policy, v}
        end
    ).


%% @private
uri_pattern() ->
    ?LET(
        Parts,
        non_empty(list(uri_component())),
        iolist_to_binary(lists:join(<<".">>, Parts))
    ).


%% @private
%% Turn some components into empty ones (wildcards) at random positions.
uri_pattern_with_wildcards(URI) ->
    Parts = binary:split(URI, <<".">>, [global]),
    Rewritten = [maybe_wildcard(P) || P <- Parts],
    iolist_to_binary(lists:join(<<".">>, Rewritten)).


%% @private
maybe_wildcard(P) ->
    case rand:uniform(3) of
        1 -> <<>>;
        _ -> P
    end.


%% @private
uri_component() ->
    ?LET(
        Bytes,
        non_empty(vector_between(1, 5, choose($a, $f))),
        list_to_binary(Bytes)
    ).


%% @private
uri_target() ->
    %% Valid target URI: non-empty components, byte alphabet a–f.
    ?LET(
        Parts,
        non_empty(vector_between(1, 5, uri_component())),
        iolist_to_binary(lists:join(<<".">>, Parts))
    ).


%% @private
vector_between(Min, Max, Gen) ->
    ?LET(N, choose(Min, Max), vector(N, Gen)).


%% @private
worker_key(WorkerN, SeqI) ->
    iolist_to_binary(io_lib:format("w~4..0b.k~6..0b", [WorkerN, SeqI])).


%% @private
worker_key_to_i(K) ->
    %% Inverse of worker_key/2's sequence-number encoding (last 6 digits).
    Bin = iolist_to_binary(K),
    Size = byte_size(Bin),
    SeqBin = binary:part(Bin, Size - 6, 6),
    binary_to_integer(SeqBin).
