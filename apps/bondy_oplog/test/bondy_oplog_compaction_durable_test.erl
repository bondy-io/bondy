%% =============================================================================
%% Durable (pack-store) compaction runs IN the instance gen_server and bounds
%% the MST even when the oldest events are in sealed packs.
%%
%% Sealed packs are read via `prim_file:pread` on fds opened
%% `[read, raw, binary]` (`bondy_mst_pack_sealed_view`). A raw fd is bound to
%% the process that OPENED it — the instance gen_server, in `init/1`. Two
%% off-process sealed-read seams had to close for durable compaction:
%%   1. The frontier + `bondy_mst:truncate/2` (the truncate rewrites the left
%%      spine = the oldest = sealed pages) — fixed by running compaction
%%      synchronously in the gen_server instead of an async worker.
%%   2. The catalogue commit's catch-up replay. Folding the MST in the
%%      APPLIER process (a full fold from a stale `last_replayed_root`) is a
%%      sealed-pack read off-process — closed by computing the catch-up DIFF
%%      in the instance gen_server (the fd owner) and handing the pairs to the
%%      applier to apply (`apply_replayed_pairs/3`, which never reads the MST).
%%
%% Both tests force sealed packs (low `auto_seal_records`) and assert the MST
%% is truncated to empty in-process.
%% =============================================================================

-module(bondy_oplog_compaction_durable_test).

-include_lib("eunit/include/eunit.hrl").

-define(B, <<>>).
-define(SEAL_EVERY, 30).

durable_compaction_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Dir) ->
        [
            {timeout, 60, fun() -> durable_compaction_no_seal(Dir) end},
            {timeout, 60, fun() -> durable_compaction_with_seal(Dir) end},
            {timeout, 120, fun() -> durable_gc_reclaims_sealed_bytes(Dir) end},
            {timeout, 60, fun() ->
                compaction_advances_wal_watermark_and_sweeps(Dir)
            end},
            {timeout, 60, fun() ->
                wal_watermark_advances_only_after_the_checkpoint(Dir)
            end}
        ]
    end}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    Dir = filename:join(
        "/tmp/" ++ os:getpid(),
        "cdurable_" ++
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

%% Below the seal threshold: every page is still in the pending map (RAM,
%% process-independent), so the gen_server-side frontier + truncate AND the
%% applier-side replay all read cleanly. Durable compaction bounds the MST.
durable_compaction_no_seal(Dir) ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    {Cache, Proj} = register_shard(NS, primary, 0, lww_register),
    {ok, _} = open_pack_instance(InstId, NS, Dir),
    try
        Batch = 10,
        ?assert(Batch < ?SEAL_EVERY),
        append_batch(InstId, 1, Batch),
        _ = bondy_oplog_instance:await_apply(InstId),
        ?assertEqual(Batch, bondy_oplog:size(InstId)),
        ?assertEqual([], sealed_packs(Dir)),

        Root = bondy_oplog_instance:root_hash(InstId),
        ?assertMatch(
            {ok, {compacted, _, _}},
            bondy_oplog_instance:compact(InstId, [Root])
        ),
        ?assertEqual(0, bondy_oplog:size(InstId)),
        ?assertNotEqual(undefined, bondy_oplog:current_watermark(InstId))
    after
        ok = bondy_oplog:stop_instance(InstId),
        ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
        close_shard(Cache, Proj)
    end.

%% With the oldest events in sealed packs, durable compaction still bounds the
%% MST: the catch-up diff is computed in the fd-owning gen_server, then the
%% gen_server-side truncate rewrites the sealed left spine and drops the stable
%% prefix. A second sealing round + compaction also succeeds, proving the
%% instance is fully functional afterward.
durable_compaction_with_seal(Dir) ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    {Cache, Proj} = register_shard(NS, primary, 0, lww_register),
    {ok, _} = open_pack_instance(InstId, NS, Dir),
    try
        Batch = 120,
        append_batch(InstId, 1, Batch),
        _ = bondy_oplog_instance:await_apply(InstId),
        ?assertEqual(Batch, bondy_oplog:size(InstId)),
        %% The oldest events sealed to disk.
        ?assert(length(sealed_packs(Dir)) >= 1),

        %% Compaction truncates the sealed prefix in-process.
        Root = bondy_oplog_instance:root_hash(InstId),
        ?assertMatch(
            {ok, {compacted, _, _}},
            bondy_oplog_instance:compact(InstId, [Root])
        ),
        ?assertEqual(0, bondy_oplog:size(InstId)),
        ?assertNotEqual(undefined, bondy_oplog:current_watermark(InstId)),

        %% Still functional: a second sealing round + compaction succeeds.
        append_batch(InstId, 2, Batch),
        _ = bondy_oplog_instance:await_apply(InstId),
        ?assertEqual(Batch, bondy_oplog:size(InstId)),
        Root2 = bondy_oplog_instance:root_hash(InstId),
        ?assertMatch(
            {ok, {compacted, _, _}},
            bondy_oplog_instance:compact(InstId, [Root2])
        ),
        ?assertEqual(0, bondy_oplog:size(InstId))
    after
        ok = bondy_oplog:stop_instance(InstId),
        ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
        close_shard(Cache, Proj)
    end.

%% Compaction is the only producer of the WAL's snapshot watermark: the
%% retention sweep drops a segment only below the committed offset AND below
%% that watermark (`bondy_oplog_wal:compute_deletable/1`), and until
%% compaction fed it nothing ever advanced it, so no production WAL ever
%% dropped a segment — it grew to `max_total_wal_size` and then refused
%% appends with `wal_full`. Found 2026-09-03 while modelling the seq-counter
%% seed (`proofs/tla/SeqSeed.tla`); the model's RETAINED invariant is exactly
%% "a segment goes only below the DURABLE checkpoint watermark", which is why
%% the advance must follow the checkpoint write, never precede it.
%%
%% Tiny segments so a handful of writes span several; `commit_every => 1` so
%% the committed offset is past them; `min_live_segments => 1` so the floor
%% does not mask the sweep. After compaction the WAL's watermark is the
%% truncation key's HLC, at least one sealed segment is gone, the head
%% survives, and — the WAL having genuinely forgotten those writes — a
%% restart still mints past every acknowledged seq.
compaction_advances_wal_watermark_and_sweeps(Dir) ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    Origin = bondy_oplog_origin:new(),
    {Cache, Proj} = register_shard(NS, primary, 0, lww_register),
    Open = fun() ->
        bondy_oplog:start_instance(InstId, #{
            origin => Origin,
            fold_module => lww_register,
            backend => bondy_mst_pack_store,
            storage_path => unicode:characters_to_binary(Dir),
            backend_options => #{auto_seal_records => ?SEAL_EVERY},
            seed => true,
            max_segment_bytes => 512,
            min_live_segments => 1,
            applier => #{
                cell_apply_target => {NS, primary, 0}, commit_every => 1
            }
        })
    end,
    try
        {ok, _} = Open(),
        N = 20,
        append_batch(InstId, 1, N),
        _ = bondy_oplog_instance:await_apply(InstId),
        WalPid = bondy_oplog_registry:wal_pid(InstId),
        Info0 = bondy_oplog_wal:info(WalPid),
        ?assertEqual(undefined, maps:get(snapshot_watermark, Info0)),
        ?assert(length(maps:get(live_segments, Info0)) > 1),

        Root = bondy_oplog_instance:root_hash(InstId),
        ?assertMatch(
            {ok, {compacted, _, _}},
            bondy_oplog_instance:compact(InstId, [Root])
        ),
        Watermark = bondy_oplog:current_watermark(InstId),
        ?assertNotEqual(undefined, Watermark),

        Info1 = bondy_oplog_wal:info(WalPid),
        ?assertEqual(
            bondy_oplog_event:key_hlc(Watermark),
            maps:get(snapshot_watermark, Info1)
        ),
        ?assert(maps:get(deleted_through, Info1) > 0),
        ?assert(
            lists:member(
                maps:get(current_segment, Info1),
                maps:get(live_segments, Info1)
            )
        ),

        ok = bondy_oplog:stop_instance(InstId),
        {ok, _} = Open(),
        Key = bondy_oplog:append(
            InstId, {cell_apply, ?B, <<"after">>, {set, 99_000, <<"after">>}}
        ),
        ?assertEqual(N + 1, bondy_oplog_event:key_seq(Key))
    after
        ok = bondy_oplog:stop_instance(InstId),
        ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
        close_shard(Cache, Proj)
    end.

%% The durability ORDER behind the sweep: the WAL's snapshot watermark
%% advances only after the compaction checkpoint is durable. A segment dropped
%% before its checkpoint is the crash window
%% `proofs/tla/SeqSeed_CkptCommitKeyedRetention.cfg` refutes. It has no
%% consequence a black-box test can reach — the WAL head always retains the
%% latest own append, so the counter seed survives either order — so it is
%% pinned by observation: at every checkpoint write the WAL still reports the
%% PREVIOUS watermark, and only afterwards the new one.
wal_watermark_advances_only_after_the_checkpoint(Dir) ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    Obs = ets:new(obs, [ordered_set, public]),
    {Cache, Proj} = register_shard(NS, primary, 0, lww_register),
    try
        {ok, _} = bondy_oplog:start_instance(InstId, #{
            origin => bondy_oplog_origin:new(),
            fold_module => lww_register,
            backend => bondy_mst_pack_store,
            storage_path => unicode:characters_to_binary(Dir),
            backend_options => #{auto_seal_records => ?SEAL_EVERY},
            seed => true,
            compaction_checkpoint => bondy_oplog_test_observing_checkpoint,
            compaction_checkpoint_opts => #{
                path => unicode:characters_to_binary(Dir),
                observations => Obs
            },
            applier => #{cell_apply_target => {NS, primary, 0}}
        }),
        Compact = fun(I) ->
            append_batch(InstId, I, 10),
            _ = bondy_oplog_instance:await_apply(InstId),
            Root = bondy_oplog_instance:root_hash(InstId),
            ?assertMatch(
                {ok, {compacted, _, _}},
                bondy_oplog_instance:compact(InstId, [Root])
            ),
            bondy_oplog:current_watermark(InstId)
        end,
        W1 = Compact(1),
        W2 = Compact(2),
        ?assert(W2 > W1),
        %% Each compaction wrote its checkpoint while the WAL still held the
        %% previous watermark; the WAL now holds the latest.
        ?assertEqual(
            [{W1, undefined}, {W2, bondy_oplog_event:key_hlc(W1)}],
            bondy_oplog_test_observing_checkpoint:observations(Obs)
        ),
        WalPid = bondy_oplog_registry:wal_pid(InstId),
        ?assertEqual(
            bondy_oplog_event:key_hlc(W2),
            maps:get(snapshot_watermark, bondy_oplog_wal:info(WalPid))
        )
    after
        ok = bondy_oplog:stop_instance(InstId),
        ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
        close_shard(Cache, Proj),
        ets:delete(Obs)
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

mk_id() ->
    list_to_binary(
        "cdur_" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))
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

open_pack_instance(InstanceId, NS, Dir) ->
    bondy_oplog:start_instance(InstanceId, #{
        origin => bondy_oplog_origin:new(),
        fold_module => lww_register,
        backend => bondy_mst_pack_store,
        storage_path => unicode:characters_to_binary(Dir),
        backend_options => #{auto_seal_records => ?SEAL_EVERY},
        %% A `storage_path` instance starts in `pre_bootstrap`; `seed` makes
        %% this genesis instance `live` so its applier drains (no peer to
        %% bootstrap from).
        seed => true,
        applier => #{cell_apply_target => {NS, primary, 0}}
    }).

append_batch(InstanceId, I, Batch) ->
    lists:foreach(
        fun(J) ->
            Key = key(I, J),
            Hlc = I * 1000 + J,
            _ = bondy_oplog:append(
                InstanceId, {cell_apply, ?B, Key, {set, Hlc, Key}}
            ),
            _ = bondy_oplog:projection(InstanceId)
        end,
        lists:seq(1, Batch)
    ).

key(I, J) ->
    <<"k_", (integer_to_binary(I))/binary, "_", (integer_to_binary(J))/binary>>.

sealed_packs(Dir) ->
    filelib:fold_files(
        Dir, "pack-.*\\.pack$", true, fun(F, Acc) -> [F | Acc] end, []
    ).

del_tree(Dir) ->
    case filelib:is_dir(Dir) of
        true ->
            {ok, Names} = file:list_dir(Dir),
            [del_tree(filename:join(Dir, N)) || N <- Names],
            file:del_dir(Dir);
        false ->
            file:delete(Dir)
    end.

%% Durable page RECLAMATION, as opposed to truncation.
%%
%% Truncation on the pack backend only unlinks the dropped subtrees;
%% `truncate_below_or_equal/4` collects on ETS alone. So until
%% `maybe_collect_durable/1` existed, every durable compaction left its whole
%% dropped prefix in the sealed packs and nothing ever reclaimed it — bytes on
%% disk grew monotonically for the lifetime of the shard.
%%
%% Asserts the bytes actually come back, because the code path is otherwise
%% invisible: it is gated behind a one-hour interval and a seal-in-flight
%% check, so a shard could run for months without it ever being exercised.
durable_gc_reclaims_sealed_bytes(Dir) ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    {Cache, Proj} = register_shard(NS, primary, 0, lww_register),
    {ok, _} = open_pack_instance(InstId, NS, Dir),
    %% The interval exists to stop a full sealed-pack rewrite running every
    %% cycle; here we want it on every tick.
    ok = application:set_env(bondy_oplog, durable_gc_interval_ms, 0),
    try
        append_batch(InstId, 1, 400),
        _ = bondy_oplog_instance:await_apply(InstId),
        ?assert(length(sealed_packs(Dir)) >= 1),
        Before = sealed_bytes(Dir),
        ?assert(Before > 0),

        %% Drop essentially everything, then let the tick collect. Two rounds:
        %% the first truncates and the second is the tick that reclaims.
        Root = bondy_oplog_instance:root_hash(InstId),
        _ = bondy_oplog_instance:compact(InstId, [Root]),
        _ = bondy_oplog_instance:compact(InstId, []),

        After = sealed_bytes(Dir),
        ?assert(
            After < Before,
            lists:flatten(
                io_lib:format(
                    "sealed bytes did not shrink: before=~p after=~p", [
                        Before, After
                    ]
                )
            )
        ),
        %% ...and the shard is still fully servable afterwards, which is the
        %% part that matters: a collection that drops a reachable page would
        %% also "reclaim" bytes.
        D = bondy_oplog_instance:diagnose_root(InstId),
        ?assertEqual(true, maps:get(servable, D))
    after
        ok = application:unset_env(bondy_oplog, durable_gc_interval_ms),
        ok = bondy_oplog:stop_instance(InstId),
        ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
        close_shard(Cache, Proj)
    end.

%% @private
sealed_bytes(Dir) ->
    lists:sum([filelib:file_size(F) || F <- sealed_packs(Dir)]).
