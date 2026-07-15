%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% The load-bearing correctness property of the lock-free mem WAL append
%% (`bondy_oplog_wal_mem:append_local/2`) + the gap-tolerant fused drain reader
%% (`bondy_oplog_wal_mem_reader`): under many concurrent writers reserving Seqs
%% and inserting out of order, the drain must deliver EVERY event EXACTLY ONCE —
%% no event is lost to a skipped in-flight gap. We drive high write concurrency
%% into one fused ephemeral shard and assert every distinct key installs into the
%% MST and reads back. A skip (the dangerous failure the "read to first gap"
%% invariant exists to prevent) would drop a key; a duplicate is harmless
%% (CRDT-idempotent).
-module(bondy_db_fused_concurrency_test).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)]
    ],
    ok.

concurrency_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 60, fun concurrent_lockfree_writes_no_loss/0}
    ]}.

%% 16 concurrent writers × 500 distinct keys each = 8000 lock-free appends into
%% one shard's mem WAL, racing the drain. Every key must install and read back.
concurrent_lockfree_writes_no_loss() ->
    {Db, T, Id} = open_fused_mem(fmc),
    W = 16,
    K = 500,
    Total = W * K,

    Parent = self(),
    Pids = [
        spawn_link(fun() ->
            lists:foreach(
                fun(I) ->
                    Key = key(Wi, I),
                    ok = bondy_db:apply(T, <<"r">>, Key, {set, val(Wi, I)})
                end,
                lists:seq(1, K)
            ),
            Parent ! {done, self()}
        end)
     || Wi <- lists:seq(1, W)
    ],
    [
        receive
            {done, P} -> ok
        after 30000 -> error({writer_timeout, P})
        end
     || P <- Pids
    ],

    %% The drain must install every appended event (exactly-once through the
    %% lock-free WAL + gap-tolerant reader). Gate on live_size reaching Total —
    %% if any in-flight gap were skipped, this never completes.
    ok = wait_until(fun() -> live_size(Id) >= Total end, 30000),

    %% Every distinct key reads back its value — no event lost.
    lists:foreach(
        fun({Wi, I}) ->
            ?assertEqual(val(Wi, I), read(T, key(Wi, I)))
        end,
        [{Wi, I} || Wi <- lists:seq(1, W), I <- lists:seq(1, K)]
    ),
    %% Exactly `Total` distinct cells live in the MST — no key dropped.
    ?assertEqual(Total, live_size(Id)),
    ok = bondy_db:close(Db).

%% =============================================================================
%% Helpers
%% =============================================================================

open_fused_mem(Name) ->
    Origin = bondy_oplog_origin:new(),
    {ok, Db} = bondy_db:open(mk_name(Name), #{
        topology => bondy_db_topology_memory,
        shard_count => 1,
        fold_module => lww_register,
        oplog_instance_opts => #{origin => Origin, wal_backend => mem}
    }),
    {ok, T} = bondy_db:open_table(Db, items, #{fused => true}),
    #{0 := Id} = maps:get(instance_ids, T),
    {Db, T, Id}.

key(W, I) ->
    <<"k-", (integer_to_binary(W))/binary, $-, (integer_to_binary(I))/binary>>.

val(W, I) ->
    <<"v-", (integer_to_binary(W))/binary, $-, (integer_to_binary(I))/binary>>.

read(T, Key) ->
    case bondy_db:read(T, <<"r">>, Key) of
        {ok, {V, _Hlc}} -> V;
        Other -> Other
    end.

live_size(Id) ->
    case bondy_oplog_registry:live_size(Id) of
        undefined -> 0;
        N -> N
    end.

wait_until(_Pred, Remaining) when Remaining =< 0 ->
    error(timeout);
wait_until(Pred, Remaining) ->
    case Pred() of
        true -> ok;
        false ->
            timer:sleep(50),
            wait_until(Pred, Remaining - 50)
    end.

mk_name(Prefix) ->
    list_to_atom(
        atom_to_list(Prefix) ++
            "_" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).
