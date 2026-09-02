%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Unit tests for the durable-DB topology manifest: the on-disk freeze
%% of the keying configuration and the boot-time reconciliation that protects
%% an existing data dir from a silently-changed (re-key-on-change) topology.
%%
%% Pure file/term logic — no bondy_db stack, no Partisan, no disterl. Each test
%% gets its own temp data dir.
%% =============================================================================

-module(bondy_db_manifest_test).

-include_lib("eunit/include/eunit.hrl").

%% A representative configured frozen topology (the catalogue assembles the
%% real one). Omits hash_algo / key_encoding_version on purpose — those are
%% stamped by the module itself.
configured() ->
    #{
        db => main,
        topology_module => bondy_db_topology_shared_shards,
        partition_strategy => aggregate,
        shard_count => 16,
        realm_prefix_depth => 1,
        tables => #{
            security_users => #{aggregate_root => identity},
            security_user_grants => #{aggregate_root => leading_col},
            bondy_realm => #{aggregate_root => identity}
        }
    }.

%% =============================================================================
%% Fixtures
%% =============================================================================

manifest_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun genesis_writes_and_freezes/1,
        fun match_on_identical_config/1,
        fun stamps_substrate_invariants/1,
        fun warn_mismatch_returns_on_disk_effective/1,
        fun stop_mismatch_errors/1,
        fun corrupt_manifest_is_rejected/1,
        fun checksum_tamper_is_rejected/1,
        fun read_absent_is_not_found/1,
        fun diff_identical/1,
        fun diff_scalar_change/1,
        fun diff_table_attr_change/1,
        fun diff_table_added_removed/1,
        fun hash_probe_skipped_when_absent_on_disk/1,
        fun hash_probe_divergence_detected/1
    ]}.

setup() ->
    Dir = filename:join(
        [
            "/tmp/" ++ os:getpid(),
            "bondy_db_manifest_test",
            integer_to_list(erlang:unique_integer([positive]))
        ]
    ),
    ok = filelib:ensure_path(Dir),
    Dir.

cleanup(Dir) ->
    _ = file_delete_recursive(Dir),
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

%% `write/2` produces a `file:consult/1` file, which `read/1` decodes as
%% UTF-8. The frozen map's `db`, `topology_module` and `partition_strategy`
%% are caller-supplied atoms, and a table name is any atom, so a non-ASCII
%% character can reach the rendering; a byte-per-character conversion of that
%% rendering (`iolist_to_binary/1`) writes bytes that are not valid UTF-8 and
%% `read/1` fails with `{unreadable_manifest, {_, file_io_server,
%% invalid_unicode}}`. Through the real write/read pair, byte-for-byte.
write_read_survives_non_ascii_atoms_test_() ->
    Cases = [
        {"latin-1 db name", #{db => 'café'}},
        {"wide db name", #{db => '日本'}},
        {"latin-1 partition strategy", #{partition_strategy => 'agrégat'}},
        {"latin-1 table name", #{
            tables => #{'usuários' => #{aggregate_root => identity}}
        }}
    ],
    [
        {Label, fun() ->
            Dir = setup(),
            try
                Manifest = bondy_db_manifest:build(
                    maps:merge(configured(), Override)
                ),
                ?assertEqual(ok, bondy_db_manifest:write(Dir, Manifest)),
                ?assertEqual({ok, Manifest}, bondy_db_manifest:read(Dir))
            after
                cleanup(Dir)
            end
        end}
     || {Label, Override} <- Cases
    ].

genesis_writes_and_freezes(Dir) ->
    fun() ->
        Cfg = configured(),
        ?assertEqual({error, not_found}, bondy_db_manifest:read(Dir)),
        Res = bondy_db_manifest:reconcile(Dir, Cfg, warn),
        ?assertMatch({ok, genesis, _}, Res),
        {ok, genesis, Effective} = Res,
        %% The effective topology is the configured one (+ stamped invariants).
        ?assertEqual(aggregate, maps:get(partition_strategy, Effective)),
        %% The manifest file now exists and round-trips.
        ?assert(filelib:is_regular(bondy_db_manifest:path(Dir))),
        ?assertMatch({ok, #{frozen := _}}, bondy_db_manifest:read(Dir))
    end.

match_on_identical_config(Dir) ->
    fun() ->
        Cfg = configured(),
        {ok, genesis, _} = bondy_db_manifest:reconcile(Dir, Cfg, warn),
        %% Re-reconciling with the same config (warn or stop) matches.
        ?assertMatch(
            {ok, match, _}, bondy_db_manifest:reconcile(Dir, Cfg, warn)
        ),
        ?assertMatch(
            {ok, match, _}, bondy_db_manifest:reconcile(Dir, Cfg, stop)
        )
    end.

stamps_substrate_invariants(Dir) ->
    fun() ->
        {ok, genesis, _} = bondy_db_manifest:reconcile(Dir, configured(), warn),
        {ok, #{frozen := Frozen}} = bondy_db_manifest:read(Dir),
        %% hash_algo, key_encoding_version, and instances_strategy are added by
        %% the module even though the caller never supplied them.
        ?assert(maps:is_key(hash_algo, Frozen)),
        ?assert(maps:is_key(key_encoding_version, Frozen)),
        ?assertEqual(phash2, maps:get(hash_algo, Frozen)),
        %% instances_strategy is derived from the topology module
        %% (shared_shards ⇒ per_shard, the one-log-per-shard collapse).
        ?assertEqual(per_shard, maps:get(instances_strategy, Frozen)),
        %% hash_probe records what phash2 actually computes over a fixed
        %% sentinel, so an OTP change to phash2 shows up as a divergence.
        ?assertEqual(
            erlang:phash2({bondy_db_hash_probe, 42}, 1 bsl 27),
            maps:get(hash_probe, Frozen)
        )
    end.

warn_mismatch_returns_on_disk_effective(Dir) ->
    fun() ->
        %% Genesis with shard_count = 16.
        {ok, genesis, _} = bondy_db_manifest:reconcile(Dir, configured(), warn),
        %% Boot with a DIFFERENT shard_count and a changed per-table key.
        Changed = (configured())#{
            shard_count => 32,
            tables => maps:put(
                bondy_realm,
                #{aggregate_root => leading_col},
                maps:get(tables, configured())
            )
        },
        Res = bondy_db_manifest:reconcile(Dir, Changed, warn),
        ?assertMatch({ok, {mismatch, _}, _}, Res),
        {ok, {mismatch, Divs}, Effective} = Res,
        %% Effective is the ON-DISK topology (16), not the new config (32).
        ?assertEqual(16, maps:get(shard_count, Effective)),
        %% Both diverging keys are named.
        Keys = [K || {K, _, _} <- Divs],
        ?assert(lists:member(shard_count, Keys)),
        ?assert(lists:member({table, bondy_realm, aggregate_root}, Keys)),
        %% The manifest on disk is unchanged (still the genesis one).
        {ok, #{frozen := Frozen}} = bondy_db_manifest:read(Dir),
        ?assertEqual(16, maps:get(shard_count, Frozen))
    end.

stop_mismatch_errors(Dir) ->
    fun() ->
        {ok, genesis, _} = bondy_db_manifest:reconcile(Dir, configured(), warn),
        Changed = (configured())#{partition_strategy => entity},
        ?assertEqual(
            {error, topology_mismatch},
            bondy_db_manifest:reconcile(Dir, Changed, stop)
        )
    end.

corrupt_manifest_is_rejected(Dir) ->
    fun() ->
        ok = file:write_file(
            bondy_db_manifest:path(Dir), <<"not an erlang term">>
        ),
        ?assertMatch({error, _}, bondy_db_manifest:read(Dir)),
        %% reconcile surfaces the read error (does not silently genesis-write).
        ?assertMatch(
            {error, _}, bondy_db_manifest:reconcile(Dir, configured(), warn)
        )
    end.

checksum_tamper_is_rejected(Dir) ->
    fun() ->
        {ok, genesis, _} = bondy_db_manifest:reconcile(Dir, configured(), warn),
        {ok, Manifest} = bondy_db_manifest:read(Dir),
        %% Tamper the frozen map WITHOUT updating the checksum.
        Tampered = Manifest#{
            frozen := maps:put(shard_count, 999, maps:get(frozen, Manifest))
        },
        ok = file:write_file(
            bondy_db_manifest:path(Dir),
            io_lib:format("~p.~n", [Tampered])
        ),
        ?assertMatch(
            {error, {corrupt_manifest, {checksum, _, _}}},
            bondy_db_manifest:read(Dir)
        )
    end.

read_absent_is_not_found(Dir) ->
    fun() ->
        ?assertEqual({error, not_found}, bondy_db_manifest:read(Dir))
    end.

%% =============================================================================
%% diff/2
%%
%% `diff/2` finalizes only its first (configured) arg; the second is the
%% on-disk frozen, which already carries the stamped substrate invariants. So
%% the baseline is taken from a real written + read-back manifest, exactly as
%% reconcile/3 does it.
%% =============================================================================

diff_identical(Dir) ->
    fun() ->
        OnDisk = baseline(Dir),
        ?assertEqual([], bondy_db_manifest:diff(configured(), OnDisk))
    end.

diff_scalar_change(Dir) ->
    fun() ->
        OnDisk = baseline(Dir),
        Changed = (configured())#{shard_count => 8},
        ?assertEqual(
            [{shard_count, 8, 16}], bondy_db_manifest:diff(Changed, OnDisk)
        )
    end.

diff_table_attr_change(Dir) ->
    fun() ->
        OnDisk = baseline(Dir),
        Changed = (configured())#{
            tables => maps:put(
                security_users,
                #{aggregate_root => leading_col},
                maps:get(tables, configured())
            )
        },
        ?assertEqual(
            [{{table, security_users, aggregate_root}, leading_col, identity}],
            bondy_db_manifest:diff(Changed, OnDisk)
        )
    end.

diff_table_added_removed(Dir) ->
    fun() ->
        OnDisk = baseline(Dir),
        Changed = (configured())#{
            tables => maps:remove(bondy_realm, maps:get(tables, configured()))
        },
        ?assertMatch(
            [{{table, bondy_realm}, '$absent', _}],
            bondy_db_manifest:diff(Changed, OnDisk)
        )
    end.

hash_probe_skipped_when_absent_on_disk(Dir) ->
    fun() ->
        %% A manifest written before the probe existed has no baseline to
        %% compare against — it must reconcile as a match, not a mismatch.
        OnDisk = maps:remove(hash_probe, baseline(Dir)),
        ?assertEqual([], bondy_db_manifest:diff(configured(), OnDisk))
    end.

hash_probe_divergence_detected(Dir) ->
    fun() ->
        %% Simulate a phash2 behaviour change: the on-disk manifest recorded a
        %% different probe value than the running VM computes.
        OnDisk0 = baseline(Dir),
        Recorded = maps:get(hash_probe, OnDisk0),
        OnDisk = OnDisk0#{hash_probe => Recorded + 1},
        ?assertEqual(
            [{hash_probe, Recorded, Recorded + 1}],
            bondy_db_manifest:diff(configured(), OnDisk)
        )
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

%% Genesis-write the baseline config and read back its (finalized) frozen map.
baseline(Dir) ->
    {ok, genesis, _} = bondy_db_manifest:reconcile(Dir, configured(), warn),
    {ok, #{frozen := Frozen}} = bondy_db_manifest:read(Dir),
    Frozen.

file_delete_recursive(Path) ->
    case filelib:is_dir(Path) of
        true ->
            {ok, Names} = file:list_dir(Path),
            _ = [file_delete_recursive(filename:join(Path, N)) || N <- Names],
            file:del_dir(Path);
        false ->
            file:delete(Path)
    end.
