%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% The per-origin sequence counter across a restart of a DURABLE instance.
%%
%% `proofs/tla/SeqSeed.tla` refutes the shipped seeding rule and
%% `proofs/isabelle/Seq_Seed.thy` proves the one built: at `init/1` the
%% counter is the maximum over the compaction checkpoint's own-origin
%% frontier entry, the live MST and the retained WAL — the last handed over
%% by the WAL writer before it publishes its pid. Each case here is one of
%% the model's counterexample traces run against the real instance on a
%% real directory: same instance id, same origin, same `storage_path`, a
%% stop, a start. Both were red against the code as shipped.
%%
%% The observable is the seq of the FIRST append after the restart: under
%% the proved rule it is `max acknowledged own seq + 1`; under a regressed
%% counter it collides with an acknowledged seq.
%%
%% What each case discriminates (mutation-checked 2026-09-03):
%%   - `compact_to_empty_then_clean_restart` pins the Jepsen scenario. It
%%     goes red only when BOTH the frontier seed and the WAL seed are gone:
%%     under the shipped retention rule the WAL's head segment always holds
%%     the latest own append, so the WAL seed alone already covers this
%%     trace. The frontier seed is load-bearing for a WAL whose manifest
%%     predates `max_seq` (first restart after upgrade) and for the general
%%     retention rule the proof assumes; it has no falsifier of its own here.
%%   - `mint_before_the_wal_tail_is_replayed` discriminates the WAL seed:
%%     with `bondy_oplog_wal:init/1` seeding 0 it is red, the other stays
%%     green.
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

%% =============================================================================
%% Helpers
%% =============================================================================

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
        fold_module => lww_register,
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
            _ = bondy_oplog:projection(InstanceId),
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
