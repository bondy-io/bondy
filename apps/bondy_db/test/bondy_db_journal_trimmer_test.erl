%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Proves the head_only journal actually shrinks. Without
%% `bondy_db_journal_trimmer` nothing reclaims it: leveled refuses
%% `compact_journal` under `head_only` and never self-schedules the `trim`
%% counterpart, so rolled journal files accumulate for the life of the store.
%%
%% The assertion is deliberately the falsifying one — that the file count
%% DROPS — rather than that a call returned `ok`, which it would even if the
%% trim were a no-op (it silently was, in an earlier iteration of this work,
%% because the delete is deferred past a 10s poll).
-module(bondy_db_journal_trimmer_test).

-include_lib("eunit/include/eunit.hrl").

%% Leveled defers the unlink until its `delete_pending` poll fires
%% (?DELETE_TIMEOUT = 10s) and no snapshot can still be reading the file.
-define(RECLAIM_WAIT_MS, 25_000).
-define(CELLS, 4000).
-define(VAL_BYTES, 300).
-define(ROUNDS, 12).

trim_reclaims_journal_files_test_() ->
    {timeout, 120, fun trim_reclaims_journal_files/0}.

trim_reclaims_journal_files() ->
    Dir = test_dir(),
    ok = filelib:ensure_dir(filename:join(Dir, ".keep")),
    {ok, Sup} = bondy_db_leveled_sup:start_link(),

    try
        {ok, Bookie} = bondy_db_leveled_sup:start_bookie(Sup, book_opts(Dir)),
        ?assert(is_pid(Bookie)),

        %% The trimmer is this supervisor's own child.
        ?assertEqual(1, bondy_db_leveled_sup:bookie_count(Sup)),
        Trimmer = trimmer_pid(Sup),
        ?assert(is_pid(Trimmer)),

        ok = write_rounds(Bookie),

        Before = cdb_count(Dir),
        ?assert(
            Before > 1,
            lists:flatten(
                io_lib:format(
                    "test needs several rolled journal files, got ~p", [Before]
                )
            )
        ),

        {ok, 1} = bondy_db_journal_trimmer:trim_now(Trimmer),
        ok = await_fewer(Dir, Before, ?RECLAIM_WAIT_MS),

        After = cdb_count(Dir),
        ?assert(
            After < Before,
            lists:flatten(
                io_lib:format(
                    "journal not reclaimed: ~p files before, ~p after",
                    [Before, After]
                )
            )
        ),
        ok
    after
        try
            bondy_db_leveled_sup:stop(Sup)
        catch
            _:_ -> ok
        end,
        os:cmd("rm -rf " ++ Dir)
    end.

%% =============================================================================
%% HELPERS
%% =============================================================================

test_dir() ->
    %% Per-pid so concurrent runs cannot share a store.
    filename:join(
        "/tmp",
        "bondy_db_jtrim_" ++ os:getpid() ++ "_" ++
            integer_to_list(
                erlang:unique_integer([positive])
            )
    ).

book_opts(Dir) ->
    [
        {root_path, Dir},
        %% The mode under test. Everything here follows from it.
        {head_only, with_lookup},
        {cache_size, 500},
        %% Small enough that this many writes roll several journal files.
        {max_journalsize, 3_000_000},
        {compression_method, lz4},
        {log_level, error}
    ].

write_rounds(Bookie) ->
    lists:foreach(
        fun(Round) ->
            lists:foreach(
                fun(Lo) ->
                    Hi = min(Lo + 249, ?CELLS),
                    %% `pause` is backpressure, not failure — the projection
                    %% adapter treats it as ok, so this does too.
                    _ = leveled_bookie:book_mput(
                        Bookie, specs(Lo, Hi, Round)
                    )
                end,
                lists:seq(1, ?CELLS, 250)
            )
        end,
        lists:seq(1, ?ROUNDS)
    ).

%% Mirrors `bondy_db_projection_leveled:build_object_specs/2`: two subkeys per
%% cell, each carrying <<HlcLen:16, Hlc:64, Bytes/binary>>. Payloads are random
%% so the journal cannot compress away the very growth under test.
specs(Lo, Hi, Round) ->
    Hlc = 1_700_000_000_000_000 + Round,
    lists:flatmap(
        fun(I) ->
            K = key(I),
            Bytes = crypto:strong_rand_bytes(?VAL_BYTES),
            P = <<8:16/big-unsigned, Hlc:64/big-unsigned, Bytes/binary>>,
            [
                {add, <<"b">>, K, <<"s">>, P},
                {add, <<"b">>, K, <<"v">>, P}
            ]
        end,
        lists:seq(Lo, Hi)
    ).

key(I) ->
    list_to_binary(io_lib:format("cell~8..0b", [I])).

trimmer_pid(Sup) ->
    case
        [
            P
         || {_Id, P, _T, Mods} <- supervisor:which_children(Sup),
            is_pid(P),
            Mods =:= [bondy_db_journal_trimmer]
        ]
    of
        [Pid] -> Pid;
        Other -> Other
    end.

cdb_count(Dir) ->
    length(filelib:wildcard(filename:join([Dir, "journal", "*", "*.cdb"]))).

await_fewer(_Dir, _Before, Remaining) when Remaining =< 0 ->
    ok;
await_fewer(Dir, Before, Remaining) ->
    case cdb_count(Dir) < Before of
        true ->
            ok;
        false ->
            timer:sleep(1000),
            await_fewer(Dir, Before, Remaining - 1000)
    end.

%% Leveled archives rather than deletes on open: the inker renames journal
%% files missing from its manifest, and the penciller renames unused SSTs,
%% both to `.bak`, which it calls "removable waste not of backup". Nothing in
%% leveled removes them. `bondy_db_leveled_sup:book_start/1` does.
sweep_removes_archived_files_test_() ->
    {timeout, 60, fun sweep_removes_archived_files/0}.

sweep_removes_archived_files() ->
    Dir = test_dir(),
    JournalFiles = filename:join([Dir, "journal", "journal_files"]),
    LedgerFiles = filename:join([Dir, "ledger", "ledger_files"]),
    ok = filelib:ensure_dir(filename:join(JournalFiles, ".keep")),
    ok = filelib:ensure_dir(filename:join(LedgerFiles, ".keep")),

    %% Stand in for what a previous open left behind.
    Stale = [
        filename:join(JournalFiles, "0_deadbeef.bak"),
        filename:join(JournalFiles, "33_deadbeef.bak"),
        filename:join(LedgerFiles, "0_1.bak")
    ],
    [ok = file:write_file(F, <<"waste">>) || F <- Stale],
    ?assertEqual(3, length(bak_files(Dir))),

    {ok, Sup} = bondy_db_leveled_sup:start_link(),
    try
        {ok, Bookie} = bondy_db_leveled_sup:start_bookie(Sup, book_opts(Dir)),
        ?assert(is_pid(Bookie)),

        ?assertEqual(
            [],
            bak_files(Dir),
            "archived files should not survive a Bookie start"
        ),

        %% The sweep must not have touched anything live: the store still
        %% works, and a written cell reads back.
        _ = leveled_bookie:book_mput(Bookie, specs(1, 1, 1)),
        ?assertMatch(
            {ok, _},
            leveled_bookie:book_headonly(Bookie, <<"b">>, key(1), <<"s">>)
        ),
        ok
    after
        try
            bondy_db_leveled_sup:stop(Sup)
        catch
            _:_ -> ok
        end,
        os:cmd("rm -rf " ++ Dir)
    end.

bak_files(Dir) ->
    filelib:wildcard(filename:join([Dir, "*", "*", "*.bak"])).
