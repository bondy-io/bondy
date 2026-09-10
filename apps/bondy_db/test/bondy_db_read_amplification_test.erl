%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% The read-amplification ratchet for `bondy_db`'s complete-enumeration entry
%% points (`list/2`, `fold_all/4`), plus the failure mode the walk they share
%% deliberately made loud.
%%
%% ## What is being pinned, and why a test rather than a benchmark
%%
%% Both used to page with `bondy_oplog_core:range_all/5`, which scatters each
%% page to EVERY shard and k-way merges the results. Per-shard calls take the
%% caller's `limit` verbatim, so a page of `limit` rows costs
%% `shard_count x limit` row decodes and throws the rest away. Draining a band
%% is then `O(N x shards)` — with the shipped default of 16 shards, sixteen
%% reads per row returned.
%%
%% That is invisible to every correctness test: the results were complete,
%% ordered and deduplicated the whole time. It is also invisible to a wall
%% clock in CI. So the oracle here is neither — it is the substrate's own
%% `[bondy_oplog_core, range]` telemetry, whose `entries_returned` counts rows
%% the substrate actually handed back. Summed across one call and divided by
%% the rows returned, that IS the amplification factor, exactly and
%% deterministically.
%%
%% Measured on this fixture (4000 rows, 4 shards) before the walk landed:
%% 9,939 rows scanned for 4,000 returned, 2.48x. The factor climbs toward
%% `shard_count` as the band grows past `shard_count x limit`, which is why
%% the bound is stated as a small multiple rather than an absolute count.
%%
%% Note the fixture uses 4 shards, not the shipped 16, purely to keep the
%% write phase short; the defect is not shard-count-specific.

-module(bondy_db_read_amplification_test).

-include_lib("eunit/include/eunit.hrl").

-define(CRDT, bondy_oplog_crdt_lww_register).
-define(R, <<"realm">>).
-define(N, 4000).
-define(SHARDS, 4).
%% One read per row is the target; the slack absorbs the per-shard chunk
%% overshoot at band boundaries. A scatter-merge cannot get under it.
-define(MAX_FACTOR, 1.5).

amplification_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Table) ->
        [
            {timeout, 300,
                {"list/2 reads each row about once", fun() ->
                    list_reads_each_row_once(Table)
                end}},
            {timeout, 300,
                {"fold_all/4 reads each row about once", fun() ->
                    fold_all_reads_each_row_once(Table)
                end}}
        ]
    end}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    {ok, Db} = bondy_db:open(bondy_db_read_amp, #{
        topology => bondy_db_topology_memory,
        shard_count => ?SHARDS,
        fold_module => lww_register
    }),
    {ok, T} = bondy_db:open_table(Db, items, #{
        fold_module => lww_register,
        crdt_module => ?CRDT
    }),
    _ = [
        bondy_db:apply(T, ?R, key(I), {set, bondy_db:tick(T), <<"v">>})
     || I <- lists:seq(1, ?N)
    ],
    {Db, T}.

cleanup({Db, _T}) ->
    try
        bondy_db:close(Db)
    catch
        _:_ -> ok
    end,
    ok.

list_reads_each_row_once({_Db, T}) ->
    {Rows, Scanned} = measure(fun() -> bondy_db:list(T, ?R) end),
    ?assertEqual(?N, length(Rows)),
    assert_factor(list, Scanned, length(Rows)).

fold_all_reads_each_row_once({_Db, T}) ->
    Count = fun(_Row, Acc) -> Acc + 1 end,
    {N, Scanned} = measure(fun() -> bondy_db:fold_all(T, Count, 0, #{}) end),
    ?assertEqual(?N, N),
    assert_factor(fold_all, Scanned, N).

%% =============================================================================
%% HELPERS
%% =============================================================================

assert_factor(What, Scanned, Returned) ->
    Factor = Scanned / Returned,
    ?assert(
        Factor =< ?MAX_FACTOR orelse
            error(
                {read_amplification, What, #{
                    scanned => Scanned,
                    returned => Returned,
                    factor => Factor,
                    max => ?MAX_FACTOR
                }}
            )
    ).

%% Sum `entries_returned` over every per-shard range the call performs.
%%
%% The counter has to be shared rather than process-local: a scatter-merge
%% emits from processes spawned by `bondy_oplog_core:scatter_range/7`, and
%% missing those would make the amplification it causes invisible here —
%% i.e. the oracle would silently stop measuring the very thing it exists
%% for.
measure(Fun) ->
    Ctr = counters:new(1, []),
    Id = {?MODULE, erlang:unique_integer()},
    ok = telemetry:attach(
        Id,
        [bondy_oplog_core, range],
        fun(_Event, #{entries_returned := N}, _Meta, C) ->
            counters:add(C, 1, N)
        end,
        Ctr
    ),
    try
        {ok, Result} = Fun(),
        {Result, counters:get(Ctr, 1)}
    after
        telemetry:detach(Id)
    end.

key(I) ->
    iolist_to_binary(io_lib:format("k~8..0b", [I])).
