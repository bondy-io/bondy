%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% The per-origin sequence counter across a restart of a DURABLE instance.
%%
%% `proofs/tla/SeqSeed.tla` refutes the shipped seeding rule and
%% `proofs/isabelle/Seq_Seed.thy` proves the one built: at `init/1` the
%% counter is the maximum over the compaction checkpoint's own-origin
%% frontier entry, the live MST and the retained WAL — the last returned by
%% `bondy_oplog_wal:open/2` and handed to the instance by the supervisor
%% (`bondy_oplog_instance:wal_opened/3`) before minting opens. Each case here is one of
%% the model's counterexample traces run against the real instance on a
%% real directory: same instance id, same origin, same `storage_path`, a
%% stop, a start. Both were red against the code as shipped.
%%
%% The observable is the seq of the FIRST append after the restart: under
%% the proved rule it is `max acknowledged own seq + 1`; under a regressed
%% counter it collides with an acknowledged seq.
%%
%% What each case discriminates (mutation-checked):
%%   - `compact_to_empty_then_clean_restart` pins the Jepsen scenario. It
%%     goes red only when BOTH the frontier seed and the WAL seed are gone:
%%     under the shipped retention rule the WAL's head segment always holds
%%     the latest own append, so the WAL seed alone already covers this
%%     trace. The frontier seed is load-bearing for a WAL whose manifest
%%     predates `max_seq` (first restart after upgrade) and for the general
%%     retention rule the proof assumes; it has no falsifier of its own here.
%%   - `mint_before_the_wal_tail_is_replayed` is the clean-stop trace, not
%%     a WAL-seed falsifier: a clean stop writes the checkpoint, whose
%%     `minted` slot seeds the restart on its own. Mutation-checked on BOTH
%%     sides of the seed inversion — forcing the WAL-side seed to 0 and
%%     `wal_opened/3` delivering 0 each leave it green.
%%   - `mint_after_the_instance_is_killed` is the WAL-seed falsifier:
%%     the instance is killed, so no
%%     checkpoint is written and the retained WAL is the only durable
%%     seed. With `wal_opened/3` delivering 0 it is red.
%%
%% `failed_datasync_does_not_remint_its_seq` makes one WAL datasync fail. The
%% refused append's frame is already in the segment, so the seq the instance
%% hands back must not be minted again while that frame can survive: every
%% own-origin seq in the log must be distinct.
%% `append_to_a_stopping_writer_is_refused` stands a process that exits with
%% a stop reason in for the WAL writer: the append must be refused with
%% `{error, wal_unavailable}`, not raise, and its seq must be handed back.
%% =============================================================================
-module(bondy_oplog_seq_seed_restart_test).

-include_lib("eunit/include/eunit.hrl").

-define(B, <<>>).

seq_seed_restart_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Dir) ->
        [
            {timeout, 60, fun() ->
                compact_to_empty_then_clean_restart(Dir)
            end},
            {timeout, 60, fun() ->
                mint_before_the_wal_tail_is_replayed(Dir)
            end},
            {timeout, 60, fun() ->
                checkpoint_records_the_minted_seq(Dir)
            end},
            {timeout, 60, fun() ->
                mint_after_the_instance_is_killed(Dir)
            end},
            {timeout, 60, fun() ->
                failed_datasync_does_not_remint_its_seq(Dir)
            end},
            {timeout, 60, fun() ->
                append_to_a_stopping_writer_is_refused(Dir)
            end}
        ]
    end}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    Dir = filename:join(
        "/tmp/" ++ os:getpid(),
        "seqseed_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.

cleanup(Dir) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)]
    ],
    _ =
        try
            del_tree(Dir)
        catch
            _:_ -> ok
        end,
    ok.

%% `SeqSeed_Shipped.cfg`, 7 steps: Reserve, Append, Apply, TruncateFlush,
%% TruncateCheckpoint, Stop, Restart. After compaction the live MST holds no
%% own-origin event and the checkpoint carries the frontier; a clean stop
%% writes it again. The shipped `init/1` read only the MST and came back at
%% 0, so the first append after the restart re-minted seq 1 — a dot every
%% peer had already applied, invisible to the frontier-gap oracle.
compact_to_empty_then_clean_restart(Dir) ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    Origin = bondy_oplog_origin:new(),
    {Cache, Proj} = register_shard(NS, primary, 0, lww_register),
    try
        {ok, _} = open_pack_instance(InstId, NS, Dir, Origin),
        N = 10,
        Keys = append_batch(InstId, 1, N),
        _ = bondy_oplog_instance:await_apply(InstId),
        MaxSeq = lists:max([bondy_oplog_event:key_seq(K) || K <- Keys]),
        ?assertEqual(N, MaxSeq),
        ?assertEqual(N, bondy_oplog:size(InstId)),

        %% Compact to empty: the peer confirms our own root.
        Root = bondy_oplog_instance:root_hash(InstId),
        ?assertMatch(
            {ok, {compacted, _, _}},
            bondy_oplog_instance:compact(InstId, [Root])
        ),
        ?assertEqual(0, bondy_oplog:size(InstId)),
        %% The premise of the trace: nothing own-origin is left in the MST
        %% and the restored frontier will say `MaxSeq`.
        ?assertEqual(
            #{Origin => MaxSeq},
            maps:with([Origin], bondy_oplog_registry:frontier(InstId))
        ),

        ok = bondy_oplog:stop_instance(InstId),
        {ok, _} = open_pack_instance(InstId, NS, Dir, Origin),
        ?assertEqual(
            #{Origin => MaxSeq},
            maps:with([Origin], bondy_oplog_registry:frontier(InstId))
        ),

        Key = bondy_oplog:append(
            InstId, {cell_apply, ?B, <<"after">>, {set, 99_000, <<"after">>}}
        ),
        ?assertEqual(Origin, bondy_oplog_event:key_origin(Key)),
        ?assertEqual(MaxSeq + 1, bondy_oplog_event:key_seq(Key))
    after
        ok = bondy_oplog:stop_instance(InstId),
        ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
        close_shard(Cache, Proj)
    end.

%% `SeqSeed_CkptEarlyMint.cfg`, 4 steps: Reserve, Append, Stop, Restart. The
%% writes are durable in the WAL but were never applied, so neither the MST
%% nor the checkpoint knows them; only the WAL does. After the restart the
%% applier is still gated (`drain_gated`), standing in for the window between
%% `init/1` publishing the write path and the boot replay's first install
%% bump — nothing in the code closes that window. The counter must already be
%% past the WAL's own maximum when the first write arrives.
mint_before_the_wal_tail_is_replayed(Dir) ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    Origin = bondy_oplog_origin:new(),
    {Cache, Proj} = register_shard(NS, primary, 0, lww_register),
    try
        %% Gated from the start: the appends land in the WAL and nowhere
        %% else.
        {ok, _} = open_pack_instance(InstId, NS, Dir, Origin, #{
            drain_gated => true
        }),
        N = 10,
        Keys = [
            bondy_oplog:append(
                InstId, {cell_apply, ?B, key(1, J), {set, 1000 + J, key(1, J)}}
            )
         || J <- lists:seq(1, N)
        ],
        MaxSeq = lists:max([bondy_oplog_event:key_seq(K) || K <- Keys]),
        ?assertEqual(N, MaxSeq),
        ?assertEqual(undefined, mst_last_key(InstId)),

        ok = bondy_oplog:stop_instance(InstId),
        {ok, _} = open_pack_instance(InstId, NS, Dir, Origin, #{
            drain_gated => true
        }),
        %% Still nothing applied: the frontier and the MST know no own seq.
        ?assertEqual(
            #{}, maps:with([Origin], bondy_oplog_registry:frontier(InstId))
        ),
        ?assertEqual(undefined, mst_last_key(InstId)),

        Key = bondy_oplog:append(
            InstId, {cell_apply, ?B, <<"after">>, {set, 99_000, <<"after">>}}
        ),
        ?assertEqual(Origin, bondy_oplog_event:key_origin(Key)),
        ?assertEqual(MaxSeq + 1, bondy_oplog_event:key_seq(Key))
    after
        ok = bondy_oplog:stop_instance(InstId),
        ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
        close_shard(Cache, Proj)
    end.

%% The retained WAL as the ONLY seed. The instance is killed — `terminate/2`
%% never runs, so no checkpoint (and no minted slot) is written and the
%% frontier is empty; the one_for_all sibling restart reopens the WAL and
%% hands its maximum to the new instance (`wal_opened/3`). The first mint
%% after the restart must land above that maximum. The registry row of the
%% killed incarnation outlives it, fast-path bundle included: the new
%% incarnation must not let a caller mint from that stale bundle before it
%% has seeded (`init/1` clears it).
mint_after_the_instance_is_killed(Dir) ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    Origin = bondy_oplog_origin:new(),
    {Cache, Proj} = register_shard(NS, primary, 0, lww_register),
    try
        {ok, _} = open_pack_instance(InstId, NS, Dir, Origin, #{
            drain_gated => true
        }),
        N = 10,
        Keys = [
            bondy_oplog:append(
                InstId, {cell_apply, ?B, key(1, J), {set, 1000 + J, key(1, J)}}
            )
         || J <- lists:seq(1, N)
        ],
        MaxSeq = lists:max([bondy_oplog_event:key_seq(K) || K <- Keys]),
        ?assertEqual(N, MaxSeq),
        %% Premise: no checkpoint exists, nothing was applied.
        ?assertEqual([], checkpoint_files_lenient(Dir, InstId)),
        ?assertEqual(undefined, mst_last_key(InstId)),

        OldInst = bondy_oplog_instance:whereis(InstId),
        OldWal = bondy_oplog_registry:wal_pid(InstId),
        true = is_pid(OldInst) andalso is_pid(OldWal),
        true = exit(OldInst, kill),
        ok = await_subtree_restart(InstId, OldInst, OldWal, 5000),
        ?assertEqual([], checkpoint_files_lenient(Dir, InstId)),
        ?assertEqual(
            #{}, maps:with([Origin], bondy_oplog_registry:frontier(InstId))
        ),

        Key = append_when_open(
            InstId,
            {cell_apply, ?B, <<"after">>, {set, 99_000, <<"after">>}},
            5000
        ),
        ?assertEqual(Origin, bondy_oplog_event:key_origin(Key)),
        ?assertEqual(MaxSeq + 1, bondy_oplog_event:key_seq(Key))
    after
        ok = bondy_oplog:stop_instance(InstId),
        ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
        close_shard(Cache, Proj)
    end.

%% The compaction checkpoint carries the own-origin MINTED maximum in a slot
%% of its own, separate from the applied frontier.
%%
%% The two are different quantities: the frontier's per-origin entry asserts an
%% applied PREFIX and its readers treat an over-claim as licence to discard,
%% while the allocator needs "highest seq ever handed out" and treats an
%% under-claim as licence to re-mint a dot a peer already applied. They ride
%% one map today, so capping the frontier for soundness would regress the
%% allocator.
%%
%% The discriminating assertion is the one on the PERSISTED PAYLOAD: the
%% own-origin frontier entry is reaped before the checkpoint is written, so a
%% minted slot that read the frontier instead of the live allocator records 0.
%% The post-restart seq assertion is a consequence, not a falsifier — the
%% retained WAL's head segment holds the latest own append and seeds the
%% counter on its own (see `compact_to_empty_then_clean_restart/1`); it becomes
%% load-bearing once the frontier is capped.
checkpoint_records_the_minted_seq(Dir) ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    Origin = bondy_oplog_origin:new(),
    {Cache, Proj} = register_shard(NS, primary, 0, lww_register),
    try
        {ok, _} = open_pack_instance(InstId, NS, Dir, Origin),
        N = 10,
        _ = append_batch(InstId, 1, N),
        _ = bondy_oplog_instance:await_apply(InstId),

        %% Compact to empty so neither the live MST nor the WAL below the
        %% watermark holds an own-origin event.
        Root = bondy_oplog_instance:root_hash(InstId),
        ?assertMatch(
            {ok, {compacted, _, _}},
            bondy_oplog_instance:compact(InstId, [Root])
        ),
        ?assertEqual(0, bondy_oplog:size(InstId)),

        %% Remove the own-origin entry from the applied frontier. Everything
        %% below now distinguishes the minted slot from the frontier.
        ?assertEqual(
            [Origin],
            bondy_oplog_registry:reap_frontier(InstId, [
                Origin
            ])
        ),
        ?assertEqual(
            #{}, maps:with([Origin], bondy_oplog_registry:frontier(InstId))
        ),
        ok = bondy_oplog_instance:persist_frontier(InstId),

        %% The persisted payload: an empty own-origin frontier entry next to a
        %% minted slot at the allocator's true position.
        lists:foreach(
            fun(F) ->
                {ok, Bin} = file:read_file(F),
                case erlang:binary_to_term(Bin) of
                    {checkpoint_v1, _W,
                        {projection_managed, frontier, VV, Minted, _Prov}} ->
                        ?assertEqual(0, maps:get(Origin, VV, 0)),
                        ?assertEqual(N, Minted);
                    Other ->
                        erlang:error({unexpected_checkpoint, F, Other})
                end
            end,
            checkpoint_files(Dir, InstId)
        ),

        ok = bondy_oplog:stop_instance(InstId),
        {ok, _} = open_pack_instance(InstId, NS, Dir, Origin),
        %% The frontier stays reaped across the restart — nothing resurrects
        %% the own entry — so the counter came back from the minted slot and
        %% the retained WAL, not from the frontier.
        ?assertEqual(
            #{}, maps:with([Origin], bondy_oplog_registry:frontier(InstId))
        ),
        Key = bondy_oplog:append(
            InstId, {cell_apply, ?B, <<"after">>, {set, 99_000, <<"after">>}}
        ),
        ?assertEqual(N + 1, bondy_oplog_event:key_seq(Key))
    after
        ok = bondy_oplog:stop_instance(InstId),
        ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
        close_shard(Cache, Proj)
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

%% This instance's checkpoint files. The tree is shared by every instance the
%% case set opens under `Dir`, so filter by instance id — asserting over a
%% sibling's checkpoint would fail on its unrelated origin.
failed_datasync_does_not_remint_its_seq(Dir) ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    Origin = bondy_oplog_origin:new(),
    {Cache, Proj} = register_shard(NS, primary, 0, lww_register),
    try
        {ok, _} = open_pack_instance(InstId, NS, Dir, Origin),
        _ = append_batch(InstId, 1, 1),
        Wal = bondy_oplog_registry:wal_pid(InstId),
        Fired = atomics:new(1, []),
        Refused = with_io_fault_lock(fun() ->
            ok = meck:expect(bondy_mst_io, datasync, fun(Fd) ->
                case
                    self() =:= Wal andalso atomics:add_get(Fired, 1, 1) =:= 1
                of
                    true -> {error, eio};
                    false -> meck:passthrough([Fd])
                end
            end),
            try_append(InstId, <<"refused">>)
        end),
        ?assertMatch({error, _}, Refused),
        _ = append_until_accepted(InstId, <<"accepted">>, 100),
        {ok, It} = bondy_log_reader:open(
            bondy_oplog_registry:wal_pid(InstId), beginning, [{follow, false}]
        ),
        Seqs = [
            bondy_oplog_event:key_seq(bondy_oplog_event:key(E))
         || E <- read_all(It, []),
            bondy_oplog_event:key_origin(bondy_oplog_event:key(E)) =:= Origin
        ],
        ?assertEqual(lists:usort(Seqs), lists:sort(Seqs))
    after
        ok = bondy_oplog:stop_instance(InstId),
        ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
        close_shard(Cache, Proj)
    end.

append_to_a_stopping_writer_is_refused(Dir) ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    Origin = bondy_oplog_origin:new(),
    {Cache, Proj} = register_shard(NS, primary, 0, lww_register),
    try
        {ok, _} = open_pack_instance(InstId, NS, Dir, Origin),
        [First] = append_batch(InstId, 1, 1),
        Wal = bondy_oplog_registry:wal_pid(InstId),
        Stopping = spawn(fun() ->
            receive
                {'$gen_call', _, _} -> exit({datasync_failed, eio})
            end
        end),
        ok = bondy_oplog_registry:set_wal_pid(InstId, Stopping),
        Refused =
            try
                bondy_oplog:append(
                    InstId, {cell_apply, ?B, <<"r">>, {set, 99_000, <<"r">>}}
                )
            after
                ok = bondy_oplog_registry:set_wal_pid(InstId, Wal)
            end,
        ?assertEqual({error, wal_unavailable}, Refused),
        Next = bondy_oplog:append(
            InstId, {cell_apply, ?B, <<"n">>, {set, 99_001, <<"n">>}}
        ),
        ?assertEqual(
            bondy_oplog_event:key_seq(First) + 1,
            bondy_oplog_event:key_seq(Next)
        )
    after
        ok = bondy_oplog:stop_instance(InstId),
        ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
        close_shard(Cache, Proj)
    end.

try_append(InstId, K) ->
    try bondy_oplog:append(InstId, {cell_apply, ?B, K, {set, 99_000, K}}) of
        Result -> Result
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

%% The shard's subtree restarts after the refused datasync; appends made
%% while it does are refused too.
append_until_accepted(_InstId, _K, 0) ->
    error(append_never_accepted);
append_until_accepted(InstId, K, N) ->
    case try_append(InstId, K) of
        {error, _} ->
            timer:sleep(50),
            append_until_accepted(InstId, K, N - 1);
        Key ->
            Key
    end.

read_all(It0, Acc) ->
    case bondy_log_reader:next(It0) of
        {ok, Events, _, _, It} -> read_all(It, Acc ++ Events);
        end_of_log -> Acc
    end.

%% Serialises every test that mocks `bondy_mst_io` in this VM (the lock key
%% is shared with the WAL suites).
with_io_fault_lock(Body) ->
    global:trans(
        {{meck_vm_lock, bondy_mst_io}, self()},
        fun() ->
            ok = meck:new(bondy_mst_io, [passthrough]),
            try
                Body()
            after
                _ = meck:unload(bondy_mst_io)
            end
        end,
        [node()],
        infinity
    ).

checkpoint_files(Dir, InstId) ->
    Files = [
        F
     || F <- filelib:wildcard(filename:join(Dir, "**/checkpoint.etf")),
        string:find(F, binary_to_list(InstId)) =/= nomatch
    ],
    ?assert(length(Files) >= 1),
    Files.

checkpoint_files_lenient(Dir, InstId) ->
    [
        F
     || F <- filelib:wildcard(filename:join(Dir, "**/checkpoint.etf")),
        string:find(F, binary_to_list(InstId)) =/= nomatch
    ].

%% Polls until the one_for_all restart has produced a new instance AND a
%% new WAL pid, both alive.
await_subtree_restart(InstId, OldInst, OldWal, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    await_subtree_restart_loop(InstId, OldInst, OldWal, Deadline).

await_subtree_restart_loop(InstId, OldInst, OldWal, Deadline) ->
    Inst = bondy_oplog_instance:whereis(InstId),
    Wal = bondy_oplog_registry:wal_pid(InstId),
    Fresh =
        is_pid(Inst) andalso Inst =/= OldInst andalso
            is_process_alive(Inst) andalso
            is_pid(Wal) andalso Wal =/= OldWal andalso
            is_process_alive(Wal),
    case Fresh of
        true ->
            ok;
        false ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> error({subtree_restart_timeout, Inst, Wal});
                false -> timer:sleep(20)
            end,
            await_subtree_restart_loop(InstId, OldInst, OldWal, Deadline)
    end.

%% `bondy_oplog:append/2` answers `{error, wal_unavailable}` (or `noproc`
%% while the instance is mid-restart) until `wal_opened/3` has landed;
%% retry until it mints.
append_when_open(InstId, Op, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    append_when_open_loop(InstId, Op, Deadline).

append_when_open_loop(InstId, Op, Deadline) ->
    Res =
        try bondy_oplog:append(InstId, Op) of
            R -> R
        catch
            error:{noproc, _} -> {error, noproc}
        end,
    case Res of
        {error, Reason} when
            Reason =:= wal_unavailable; Reason =:= noproc
        ->
            erlang:monotonic_time(millisecond) > Deadline andalso
                error({append_timeout, Reason}),
            timer:sleep(20),
            append_when_open_loop(InstId, Op, Deadline);
        Key ->
            Key
    end.

mk_id() ->
    list_to_binary(
        "seqseed_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

ns_of(Id) when is_binary(Id) ->
    binary_to_atom(<<"ns_", Id/binary>>, utf8).

register_shard(NS, Index, Shard, FoldModule) ->
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, Index, Shard, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, Index, Shard, #{}),
    ok = bondy_oplog_core_registry:register(NS, Index, Shard, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        fold_module => FoldModule,
        overlay => disabled
    }),
    {Cache, Proj}.

close_shard(Cache, Proj) ->
    ok = bondy_oplog_projection_ets:close(Proj),
    ok = bondy_oplog_cache_ets:close(Cache),
    ok.

open_pack_instance(InstanceId, NS, Dir, Origin) ->
    open_pack_instance(InstanceId, NS, Dir, Origin, #{}).

open_pack_instance(InstanceId, NS, Dir, Origin, ApplierOpts) ->
    bondy_oplog:start_instance(InstanceId, #{
        origin => Origin,
        backend => bondy_mst_pack_store,
        storage_path => unicode:characters_to_binary(Dir),
        %% A `storage_path` instance starts in `pre_bootstrap`; `seed` makes
        %% this genesis instance `live` so its applier drains (no peer to
        %% bootstrap from).
        seed => true,
        applier => ApplierOpts#{cell_apply_target => {NS, primary, 0}}
    }).

append_batch(InstanceId, I, Batch) ->
    lists:map(
        fun(J) ->
            Key = key(I, J),
            Hlc = I * 1000 + J,
            EvKey = bondy_oplog:append(
                InstanceId, {cell_apply, ?B, Key, {set, Hlc, Key}}
            ),
            ok = bondy_oplog_test_projection:drain(InstanceId),
            EvKey
        end,
        lists:seq(1, Batch)
    ).

key(I, J) ->
    <<"k_", (integer_to_binary(I))/binary, "_", (integer_to_binary(J))/binary>>.

%% The MST's last event key; `undefined` when nothing was ever promoted.
mst_last_key(InstId) ->
    maps:get(last_event_key, bondy_oplog_instance:info(InstId)).

del_tree(Dir) ->
    case filelib:is_dir(Dir) of
        true ->
            {ok, Names} = file:list_dir(Dir),
            lists:foreach(
                fun(N) -> del_tree(filename:join(Dir, N)) end, Names
            ),
            file:del_dir(Dir);
        false ->
            file:delete(Dir)
    end.
