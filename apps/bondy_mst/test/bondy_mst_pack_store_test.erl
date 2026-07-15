%% =============================================================================
%% EUnit suite for `bondy_mst_pack_store`. Covers:
%%
%% 1. Lifecycle: open / close / reopen on the same directory; opts
%%    validation; instance_id mismatch rejection.
%% 2. put/get round-trip via the `bondy_mst_store` behaviour wrapper,
%%    in both pending and sealed states.
%% 3. set_root / get_root persistence across close + reopen.
%% 4. has / list / missing_set.
%% 5. seal extension: hash visibility before vs after sealing; pack
%%    fds rotate as expected.
%% 6. delete (tombstone): the `free_set` excludes a hash from `list/1`
%%    enumeration (and marks it for physical GC), but `get/2`/`has/2` still
%%    serve a physically-present page — the tombstone is a GC/enumeration
%%    hint, NOT a read mask (reachability from the root is the single source
%%    of truth for liveness). A page that was never written reads as absent.
%% 7. End-to-end MST workload: insert N pairs through the high-level
%%    `bondy_mst` interface using `bondy_mst_pack_store` as the
%%    backend; verify `to_list` matches.
%% =============================================================================

-module(bondy_mst_pack_store_test).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Fixture helpers
%% =============================================================================

mktemp_dir() ->
    Base = filename:join(
        [
            "/tmp",
            io_lib:format(
                "bondy_mst_pack_store_test_~p_~p",
                [
                    erlang:system_time(microsecond),
                    erlang:unique_integer([positive])
                ]
            )
        ]
    ),
    Dir = lists:flatten(Base),
    ok = filelib:ensure_path(Dir),
    Dir.

rmrf(Dir) ->
    _ = file:del_dir_r(Dir),
    ok.

with_tmp_dir(Fun) ->
    Dir = mktemp_dir(),
    try
        Fun(Dir)
    after
        rmrf(Dir)
    end.

opts(Dir) ->
    #{dir => Dir, instance_id => <<"pack-store-test">>}.

open_store(Dir) ->
    bondy_mst_store:open(bondy_mst_pack_store, sha256, opts(Dir)).

open_store_with(Dir, Extra) ->
    bondy_mst_store:open(
        bondy_mst_pack_store,
        sha256,
        maps:merge(opts(Dir), Extra)
    ).

mk_page(Level, Low, List) ->
    bondy_mst_page:new(Level, Low, List).

%% =============================================================================
%% Open / close
%% =============================================================================

open_close_empty_dir_test() ->
    with_tmp_dir(fun(Dir) ->
        S = open_store(Dir),
        ?assertEqual(undefined, bondy_mst_store:get_root(S)),
        ?assertEqual([], bondy_mst_store:list(S)),
        ?assertEqual(ok, bondy_mst_store:close(S)),
        %% Manifest exists on disk; no sealed packs.
        ?assert(filelib:is_regular(filename:join(Dir, "manifest")))
    end).

open_missing_dir_opt_test() ->
    ?assertError(
        {missing_opt, dir},
        bondy_mst_store:open(
            bondy_mst_pack_store,
            sha256,
            #{instance_id => <<"x">>}
        )
    ).

open_missing_instance_id_opt_test() ->
    with_tmp_dir(fun(Dir) ->
        ?assertError(
            {missing_opt, instance_id},
            bondy_mst_store:open(bondy_mst_pack_store, sha256, #{dir => Dir})
        )
    end).

open_unsupported_algo_test() ->
    with_tmp_dir(fun(Dir) ->
        ?assertError(
            {unsupported_hash_algorithm, sha512},
            bondy_mst_store:open(bondy_mst_pack_store, sha512, opts(Dir))
        )
    end).

reopen_with_different_instance_id_test() ->
    with_tmp_dir(fun(Dir) ->
        S = open_store(Dir),
        ok = bondy_mst_store:close(S),
        ?assertError(
            {pack_store_open, {instance_id_mismatch, _, _}},
            bondy_mst_store:open(
                bondy_mst_pack_store,
                sha256,
                #{dir => Dir, instance_id => <<"other">>}
            )
        )
    end).

%% =============================================================================
%% put / get / has
%% =============================================================================

put_get_returns_canonical_hash_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        try
            P = mk_page(0, undefined, [{k1, v1, undefined}]),
            {Hash, S1} = bondy_mst_store:put(S0, P),
            ?assertEqual(bondy_mst_page:hash(P, sha256), Hash),
            ?assertEqual(P, bondy_mst_store:get(S1, Hash)),
            ?assert(bondy_mst_store:has(S1, Hash))
        after
            _ = bondy_mst_store:close(S0)
        end
    end).

get_missing_hash_returns_undefined_test() ->
    with_tmp_dir(fun(Dir) ->
        S = open_store(Dir),
        try
            ?assertEqual(
                undefined,
                bondy_mst_store:get(S, crypto:hash(sha256, <<"x">>))
            ),
            ?assertNot(bondy_mst_store:has(S, crypto:hash(sha256, <<"x">>)))
        after
            _ = bondy_mst_store:close(S)
        end
    end).

put_is_idempotent_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        try
            P = mk_page(1, undefined, [{a, 1, undefined}]),
            {H1, S1} = bondy_mst_store:put(S0, P),
            {H2, S2} = bondy_mst_store:put(S1, P),
            ?assertEqual(H1, H2),
            ?assertEqual([P], bondy_mst_store:list(S2))
        after
            _ = bondy_mst_store:close(S0)
        end
    end).

list_returns_all_pages_pending_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        try
            Pages = [
                mk_page(0, undefined, [{k1, v1, undefined}]),
                mk_page(0, undefined, [{k2, v2, undefined}]),
                mk_page(1, undefined, [{k3, v3, undefined}])
            ],
            S = lists:foldl(
                fun(P, Acc) ->
                    {_, A} = bondy_mst_store:put(Acc, P),
                    A
                end,
                S0,
                Pages
            ),
            Got = lists:sort(bondy_mst_store:list(S)),
            ?assertEqual(lists:sort(Pages), Got)
        after
            _ = bondy_mst_store:close(S0)
        end
    end).

%% =============================================================================
%% set_root / get_root persistence
%% =============================================================================

set_root_round_trip_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        try
            P = mk_page(0, undefined, [{x, 1, undefined}]),
            {Hash, S1} = bondy_mst_store:put(S0, P),
            S2 = bondy_mst_store:set_root(S1, Hash),
            ?assertEqual(Hash, bondy_mst_store:get_root(S2))
        after
            _ = bondy_mst_store:close(S0)
        end
    end).

set_root_persists_across_close_reopen_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        P = mk_page(0, undefined, [{x, 1, undefined}]),
        {Hash, S1} = bondy_mst_store:put(S0, P),
        S2 = bondy_mst_store:set_root(S1, Hash),
        %% Seal so the page survives a reopen (incoming.pack is not
        %% replayed across a fresh open in this phase — pending pages
        %% require seal to be durable).
        {ok, S3} = bondy_mst_pack_store_seal(S2),
        ok = bondy_mst_store:close(S3),
        S4 = open_store(Dir),
        try
            ?assertEqual(Hash, bondy_mst_store:get_root(S4)),
            ?assertEqual(P, bondy_mst_store:get(S4, Hash))
        after
            _ = bondy_mst_store:close(S4)
        end
    end).

%% =============================================================================
%% Seal lifecycle
%% =============================================================================

seal_makes_pages_visible_via_sealed_view_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        try
            P = mk_page(0, undefined, [{k, v, undefined}]),
            {Hash, S1} = bondy_mst_store:put(S0, P),
            ?assertEqual([], pack_ids(S1)),
            {ok, S2} = bondy_mst_pack_store_seal(S1),
            ?assertEqual([1], pack_ids(S2)),
            ?assertEqual(P, bondy_mst_store:get(S2, Hash))
        after
            _ = bondy_mst_store:close(S0)
        end
    end).

seal_no_op_on_empty_pending_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        try
            {ok, S1} = bondy_mst_pack_store_seal(S0),
            ?assertEqual([], pack_ids(S1))
        after
            _ = bondy_mst_store:close(S0)
        end
    end).

multi_seal_keeps_all_pages_accessible_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        P1 = mk_page(0, undefined, [{a, 1, undefined}]),
        P2 = mk_page(0, undefined, [{b, 2, undefined}]),
        P3 = mk_page(0, undefined, [{c, 3, undefined}]),
        {H1, S1} = bondy_mst_store:put(S0, P1),
        {ok, S2} = bondy_mst_pack_store_seal(S1),
        {H2, S3} = bondy_mst_store:put(S2, P2),
        {ok, S4} = bondy_mst_pack_store_seal(S3),
        {H3, S5} = bondy_mst_store:put(S4, P3),
        try
            ?assertEqual([2, 1], pack_ids(S5)),
            ?assertEqual(P1, bondy_mst_store:get(S5, H1)),
            ?assertEqual(P2, bondy_mst_store:get(S5, H2)),
            %% H3 is still in pending (not sealed yet).
            ?assertEqual(P3, bondy_mst_store:get(S5, H3))
        after
            _ = bondy_mst_store:close(S5)
        end
    end).

%% =============================================================================
%% Auto-seal thresholds
%% =============================================================================

auto_seal_below_default_thresholds_does_not_seal_test() ->
    %% No opts → defaults apply (records=10_000, bytes=16_000_000);
    %% 10 puts is well below both → no seal yet.
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        S1 = lists:foldl(
            fun(I, Acc) ->
                P = mk_page(0, undefined, [{I, I, undefined}]),
                {_, A} = bondy_mst_store:put(Acc, P),
                A
            end,
            S0,
            lists:seq(1, 10)
        ),
        try
            ?assertEqual([], pack_ids(S1))
        after
            _ = bondy_mst_store:close(S1)
        end
    end).

auto_seal_records_triggers_on_threshold_test() ->
    %% Record-count threshold: seal fires when the Nth put pushes
    %% pending_count to >= threshold. State after the triggering put
    %% must reflect the rolled-over pack: empty pending, sealed pack
    %% present, all priors still resolvable.
    with_tmp_dir(fun(Dir) ->
        S0 = open_store_with(Dir, #{auto_seal_records => 3}),
        P1 = mk_page(0, undefined, [{a, 1, undefined}]),
        P2 = mk_page(0, undefined, [{b, 2, undefined}]),
        P3 = mk_page(0, undefined, [{c, 3, undefined}]),
        {H1, S1} = bondy_mst_store:put(S0, P1),
        ?assertEqual([], pack_ids(S1)),
        {H2, S2} = bondy_mst_store:put(S1, P2),
        ?assertEqual([], pack_ids(S2)),
        {H3, S3} = bondy_mst_store:put(S2, P3),
        try
            ?assertEqual([1], pack_ids(S3)),
            ?assertEqual(P1, bondy_mst_store:get(S3, H1)),
            ?assertEqual(P2, bondy_mst_store:get(S3, H2)),
            ?assertEqual(P3, bondy_mst_store:get(S3, H3))
        after
            _ = bondy_mst_store:close(S3)
        end
    end).

auto_seal_records_below_threshold_does_not_seal_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store_with(Dir, #{auto_seal_records => 5}),
        S1 = lists:foldl(
            fun(I, Acc) ->
                P = mk_page(0, undefined, [{I, I, undefined}]),
                {_, A} = bondy_mst_store:put(Acc, P),
                A
            end,
            S0,
            lists:seq(1, 4)
        ),
        try
            ?assertEqual([], pack_ids(S1))
        after
            _ = bondy_mst_store:close(S1)
        end
    end).

auto_seal_records_resets_after_seal_test() ->
    %% After auto-seal fires, the counter restarts from zero — a second
    %% batch fills incoming.pack again and triggers a second seal.
    with_tmp_dir(fun(Dir) ->
        S0 = open_store_with(Dir, #{auto_seal_records => 2}),
        Pages = [
            mk_page(0, undefined, [{I, I, undefined}])
         || I <- lists:seq(1, 4)
        ],
        S1 = lists:foldl(
            fun(P, Acc) ->
                {_, A} = bondy_mst_store:put(Acc, P),
                A
            end,
            S0,
            Pages
        ),
        try
            %% 4 puts at threshold=2 → two seals → pack ids [2, 1].
            ?assertEqual([2, 1], pack_ids(S1))
        after
            _ = bondy_mst_store:close(S1)
        end
    end).

auto_seal_bytes_triggers_on_threshold_test() ->
    %% Byte threshold low enough that the first put crosses it
    %% (incoming.pack header 48B + record header 40B + body 43B = 131B
    %% after one put; threshold 100 → triggers on first put).
    with_tmp_dir(fun(Dir) ->
        S0 = open_store_with(Dir, #{auto_seal_bytes => 100}),
        P = mk_page(0, undefined, [{k, v, undefined}]),
        {H, S1} = bondy_mst_store:put(S0, P),
        try
            ?assertEqual([1], pack_ids(S1)),
            ?assertEqual(P, bondy_mst_store:get(S1, H))
        after
            _ = bondy_mst_store:close(S1)
        end
    end).

auto_seal_bytes_below_threshold_does_not_seal_test() ->
    with_tmp_dir(fun(Dir) ->
        %% Threshold above one-put offset (131) → no seal yet.
        S0 = open_store_with(Dir, #{auto_seal_bytes => 1000}),
        P = mk_page(0, undefined, [{k, v, undefined}]),
        {_, S1} = bondy_mst_store:put(S0, P),
        try
            ?assertEqual([], pack_ids(S1))
        after
            _ = bondy_mst_store:close(S1)
        end
    end).

auto_seal_first_threshold_to_cross_wins_test() ->
    %% Records threshold trips first when both are configured but the
    %% byte threshold is far above one-put offsets.
    with_tmp_dir(fun(Dir) ->
        S0 = open_store_with(Dir, #{
            auto_seal_records => 2,
            auto_seal_bytes => 10_000_000
        }),
        P1 = mk_page(0, undefined, [{a, 1, undefined}]),
        P2 = mk_page(0, undefined, [{b, 2, undefined}]),
        {_, S1} = bondy_mst_store:put(S0, P1),
        {_, S2} = bondy_mst_store:put(S1, P2),
        try
            ?assertEqual([1], pack_ids(S2))
        after
            _ = bondy_mst_store:close(S2)
        end
    end).

auto_seal_idempotent_put_does_not_advance_threshold_test() ->
    %% Re-putting the same hash is a no-op on pending_count and
    %% incoming_offset, so it must not trip the threshold.
    with_tmp_dir(fun(Dir) ->
        S0 = open_store_with(Dir, #{auto_seal_records => 2}),
        P = mk_page(0, undefined, [{k, v, undefined}]),
        {_, S1} = bondy_mst_store:put(S0, P),
        {_, S2} = bondy_mst_store:put(S1, P),
        {_, S3} = bondy_mst_store:put(S2, P),
        try
            %% Still one pending entry; no seal.
            ?assertEqual([], pack_ids(S3))
        after
            _ = bondy_mst_store:close(S3)
        end
    end).

auto_seal_explicit_infinity_disables_test() ->
    %% Caller-supplied `infinity` must behave identically to the
    %% default.
    with_tmp_dir(fun(Dir) ->
        S0 = open_store_with(Dir, #{
            auto_seal_records => infinity,
            auto_seal_bytes => infinity
        }),
        S1 = lists:foldl(
            fun(I, Acc) ->
                P = mk_page(0, undefined, [{I, I, undefined}]),
                {_, A} = bondy_mst_store:put(Acc, P),
                A
            end,
            S0,
            lists:seq(1, 20)
        ),
        try
            ?assertEqual([], pack_ids(S1))
        after
            _ = bondy_mst_store:close(S1)
        end
    end).

auto_seal_bad_records_opt_test() ->
    with_tmp_dir(fun(Dir) ->
        ?assertError(
            {invalid_opt, auto_seal_records, 0},
            bondy_mst_store:open(
                bondy_mst_pack_store,
                sha256,
                (opts(Dir))#{auto_seal_records => 0}
            )
        ),
        ?assertError(
            {invalid_opt, auto_seal_records, -1},
            bondy_mst_store:open(
                bondy_mst_pack_store,
                sha256,
                (opts(Dir))#{auto_seal_records => -1}
            )
        ),
        ?assertError(
            {invalid_opt, auto_seal_records, not_a_number},
            bondy_mst_store:open(
                bondy_mst_pack_store,
                sha256,
                (opts(Dir))#{auto_seal_records => not_a_number}
            )
        )
    end).

auto_seal_bad_bytes_opt_test() ->
    with_tmp_dir(fun(Dir) ->
        ?assertError(
            {invalid_opt, auto_seal_bytes, 0},
            bondy_mst_store:open(
                bondy_mst_pack_store,
                sha256,
                (opts(Dir))#{auto_seal_bytes => 0}
            )
        )
    end).

auto_seal_survives_close_reopen_with_same_opts_test() ->
    %% Opts are not persisted in the manifest; the caller passes them
    %% on each open. Verify that auto-seal still fires after reopen
    %% when the same opts are supplied, and that pages sealed on the
    %% first open are still readable.
    with_tmp_dir(fun(Dir) ->
        Opts = (opts(Dir))#{auto_seal_records => 2},
        S0 = bondy_mst_store:open(bondy_mst_pack_store, sha256, Opts),
        P1 = mk_page(0, undefined, [{a, 1, undefined}]),
        P2 = mk_page(0, undefined, [{b, 2, undefined}]),
        {H1, S1} = bondy_mst_store:put(S0, P1),
        {H2, S2} = bondy_mst_store:put(S1, P2),
        ?assertEqual([1], pack_ids(S2)),
        ok = bondy_mst_store:close(S2),
        S3 = bondy_mst_store:open(bondy_mst_pack_store, sha256, Opts),
        try
            ?assertEqual([1], pack_ids(S3)),
            ?assertEqual(P1, bondy_mst_store:get(S3, H1)),
            ?assertEqual(P2, bondy_mst_store:get(S3, H2)),
            %% Two more puts on the reopened store trigger another seal.
            P3 = mk_page(0, undefined, [{c, 3, undefined}]),
            P4 = mk_page(0, undefined, [{d, 4, undefined}]),
            {_, S4} = bondy_mst_store:put(S3, P3),
            {_, S5} = bondy_mst_store:put(S4, P4),
            ?assertEqual([2, 1], pack_ids(S5))
        after
            _ = bondy_mst_store:close(S3)
        end
    end).

%% =============================================================================
%% delete / free tombstones
%% =============================================================================

delete_excludes_hash_from_list_but_content_addressable_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        try
            P = mk_page(0, undefined, [{k, v, undefined}]),
            {Hash, S1} = bondy_mst_store:put(S0, P),
            S2 = bondy_mst_store:delete(S1, Hash),
            %% Excluded from enumeration (and marked for GC)...
            ?assertEqual([], bondy_mst_store:list(S2)),
            %% ...but the page is physically present, so it is still served:
            %% the `free_set` is a GC/enumeration hint, not a read mask.
            ?assertEqual(P, bondy_mst_store:get(S2, Hash)),
            ?assert(bondy_mst_store:has(S2, Hash))
        after
            _ = bondy_mst_store:close(S0)
        end
    end).

re_put_after_delete_relists_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        try
            P = mk_page(0, undefined, [{k, v, undefined}]),
            {Hash, S1} = bondy_mst_store:put(S0, P),
            S2 = bondy_mst_store:delete(S1, Hash),
            ?assertEqual([], bondy_mst_store:list(S2)),
            %% Re-put clears the tombstone, so it re-appears in enumeration.
            {Hash, S3} = bondy_mst_store:put(S2, P),
            ?assertEqual(P, bondy_mst_store:get(S3, Hash)),
            ?assert(bondy_mst_store:has(S3, Hash)),
            ?assertEqual([P], bondy_mst_store:list(S3))
        after
            _ = bondy_mst_store:close(S0)
        end
    end).

%% =============================================================================
%% Tombstone persistence across reopen
%% =============================================================================

tombstone_persists_across_reopen_test() ->
    %% After delete + close, the tombstone file must keep the hash EXCLUDED
    %% FROM list/1 on the next open. The page content stays addressable — it
    %% is physically present in the sealed pack (the tombstone is a GC /
    %% enumeration hint, not a read mask).
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        P = mk_page(0, undefined, [{persist, me, undefined}]),
        {Hash, S1} = bondy_mst_store:put(S0, P),
        {ok, S2} = bondy_mst_pack_store_seal(S1),
        S3 = bondy_mst_store:delete(S2, Hash),
        ?assertEqual([], bondy_mst_store:list(S3)),
        ?assertEqual(P, bondy_mst_store:get(S3, Hash)),
        ?assertEqual(ok, bondy_mst_store:close(S3)),
        %% The file is there.
        ?assert(
            filelib:is_regular(
                bondy_mst_pack_tombstones:path(Dir)
            )
        ),
        S4 = open_store(Dir),
        try
            ?assertEqual([], bondy_mst_store:list(S4)),
            ?assertEqual(P, bondy_mst_store:get(S4, Hash)),
            ?assert(bondy_mst_store:has(S4, Hash))
        after
            _ = bondy_mst_store:close(S4)
        end
    end).

re_put_after_reopen_clears_persisted_tombstone_test() ->
    %% Once the page is re-put, the tombstone file must reflect the
    %% removed entry; a third reopen must keep it visible.
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        P = mk_page(0, undefined, [{repaved, ok, undefined}]),
        {Hash, S1} = bondy_mst_store:put(S0, P),
        {ok, S2} = bondy_mst_pack_store_seal(S1),
        S3 = bondy_mst_store:delete(S2, Hash),
        bondy_mst_store:close(S3),
        S4 = open_store(Dir),
        {Hash, S5} = bondy_mst_store:put(S4, P),
        ?assertEqual(P, bondy_mst_store:get(S5, Hash)),
        bondy_mst_store:close(S5),
        S6 = open_store(Dir),
        try
            ?assertEqual(P, bondy_mst_store:get(S6, Hash))
        after
            _ = bondy_mst_store:close(S6)
        end
    end).

tombstone_file_absent_for_fresh_store_test() ->
    %% A pristine instance writes nothing until the first delete /
    %% free that actually adds a hash to the set.
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        try
            ?assertNot(
                filelib:is_regular(
                    bondy_mst_pack_tombstones:path(Dir)
                )
            )
        after
            _ = bondy_mst_store:close(S0)
        end
    end).

delete_of_unknown_hash_still_persists_test() ->
    %% Deleting a hash that was never put still records the
    %% tombstone — get/has must return undefined/false across reopen.
    with_tmp_dir(fun(Dir) ->
        Ghost = crypto:hash(sha256, <<"never seen">>),
        S0 = open_store(Dir),
        S1 = bondy_mst_store:delete(S0, Ghost),
        ?assertEqual(undefined, bondy_mst_store:get(S1, Ghost)),
        bondy_mst_store:close(S1),
        ?assert(
            filelib:is_regular(
                bondy_mst_pack_tombstones:path(Dir)
            )
        ),
        S2 = open_store(Dir),
        try
            ?assertEqual(undefined, bondy_mst_store:get(S2, Ghost)),
            ?assertNot(bondy_mst_store:has(S2, Ghost))
        after
            _ = bondy_mst_store:close(S2)
        end
    end).

re_tombstoning_same_hash_does_not_rewrite_test() ->
    %% Same hash deleted twice — second delete must skip the write.
    %% Disables the tombstones-flush debounce so every change is
    %% persisted immediately (so we can compare on-disk bytes
    %% between the two calls).
    with_tmp_dir(fun(Dir) ->
        H = crypto:hash(sha256, <<"once">>),
        S0 = open_store_with(Dir, #{tombstones_flush_every_records => 1}),
        S1 = bondy_mst_store:delete(S0, H),
        Path = bondy_mst_pack_tombstones:path(Dir),
        {ok, Bin1} = file:read_file(Path),
        S2 = bondy_mst_store:delete(S1, H),
        {ok, Bin2} = file:read_file(Path),
        ?assertEqual(Bin1, Bin2),
        _ = S2,
        bondy_mst_store:close(S2)
    end).

corrupt_tombstones_file_falls_back_to_empty_set_test() ->
    %% A garbled tombstones file must not stop the store from
    %% opening — load logs WARNING and produces an empty set so
    %% reads recover (with the divergence noted in the impl).
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        H = crypto:hash(sha256, <<"ghost">>),
        S1 = bondy_mst_store:delete(S0, H),
        bondy_mst_store:close(S1),
        Path = bondy_mst_pack_tombstones:path(Dir),
        ok = file:write_file(Path, <<"garbage bytes that do not parse">>),
        S2 = open_store(Dir),
        try
            %% Tombstone forgotten — get returns undefined only
            %% because the page was never put, not because of the
            %% tombstone.
            ?assertEqual(undefined, bondy_mst_store:get(S2, H))
        after
            _ = bondy_mst_store:close(S2)
        end
    end).

gc_prunes_and_persists_tombstones_test() ->
    %% After GC the tombstone for an applied hash is dropped from
    %% the in-memory set AND the on-disk file.
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        P1 = mk_page(0, undefined, [{k1, v1, undefined}]),
        P2 = mk_page(0, undefined, [{k2, v2, undefined}]),
        {H1, S1} = bondy_mst_store:put(S0, P1),
        {H2, S2} = bondy_mst_store:put(S1, P2),
        {ok, S3} = bondy_mst_pack_store_seal(S2),
        %% Tombstone H1, then GC against KeepRoots=[H2] so H1 is
        %% applied (its pack entry is dropped).
        S4 = bondy_mst_store:delete(S3, H1),
        {S5, Meta} = bondy_mst_store:gc(S4, [H2]),
        ?assertMatch(#{compacted := true}, Meta),
        ?assertEqual(undefined, bondy_mst_store:get(S5, H1)),
        bondy_mst_store:close(S5),
        %% Tombstone file is either absent or carries an empty set
        %% (the applied tombstone was pruned).
        case bondy_mst_pack_tombstones:read(Dir) of
            {error, enoent} ->
                ok;
            {ok, S} ->
                ?assertEqual(0, sets:size(S))
        end,
        %% Reopen and verify H1 is still gone, H2 still present.
        S6 = open_store(Dir),
        try
            ?assertEqual(undefined, bondy_mst_store:get(S6, H1)),
            ?assertEqual(P2, bondy_mst_store:get(S6, H2))
        after
            _ = bondy_mst_store:close(S6)
        end
    end).

%% =============================================================================
%% missing_set
%% =============================================================================

missing_set_returns_unknown_root_test() ->
    with_tmp_dir(fun(Dir) ->
        S = open_store(Dir),
        try
            FakeRoot = crypto:hash(sha256, <<"nope">>),
            Got = bondy_mst_store:missing_set(S, FakeRoot),
            ?assertEqual([FakeRoot], lists:sort(sets:to_list(Got)))
        after
            _ = bondy_mst_store:close(S)
        end
    end).

missing_set_empty_when_full_tree_present_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        try
            %% Build a tiny tree: leaf page, then internal page that
            %% refers to it.
            Leaf = mk_page(0, undefined, [{k, v, undefined}]),
            {LH, S1} = bondy_mst_store:put(S0, Leaf),
            Top = mk_page(1, undefined, [{k, v, LH}]),
            {TH, S2} = bondy_mst_store:put(S1, Top),
            Got = bondy_mst_store:missing_set(S2, TH),
            ?assertEqual([], lists:sort(sets:to_list(Got)))
        after
            _ = bondy_mst_store:close(S0)
        end
    end).

%% =============================================================================
%% End-to-end through bondy_mst
%% =============================================================================

mst_end_to_end_pack_backend_test() ->
    with_tmp_dir(fun(Dir) ->
        M0 = bondy_mst:new(#{
            store => bondy_mst_pack_store,
            store_opts => opts(Dir)
        }),
        Pairs = [{N, N * 2} || N <- lists:seq(1, 20)],
        M1 = lists:foldl(
            fun({K, V}, Acc) -> bondy_mst:put(Acc, K, V) end,
            M0,
            Pairs
        ),
        List = bondy_mst:to_list(M1),
        ?assertEqual(lists:sort(Pairs), lists:sort(List)),
        _ = bondy_mst_store:close(bondy_mst:store(M1))
    end).

%% =============================================================================
%% Helpers
%% =============================================================================

%% @private
%% `bondy_mst_pack_store:seal/1` is a backend-specific extension —
%% reach through the behaviour wrapper to call it.
bondy_mst_pack_store_seal(S) ->
    {bondy_mst_store, _, Backend, _} = S,
    case bondy_mst_pack_store:seal(Backend) of
        {ok, B1} ->
            {ok, setelement(3, S, B1)};
        {error, _} = E ->
            E
    end.

%% @private
pack_ids(S) ->
    {bondy_mst_store, _, Backend, _} = S,
    bondy_mst_pack_store:sealed_pack_ids(Backend).

%% @private
store_dir(S) ->
    {bondy_mst_store, _, Backend, _} = S,
    bondy_mst_pack_store:dir(Backend).

%% @private
read_manifest(Dir) ->
    {ok, M} = bondy_mst_pack_manifest:read(Dir),
    M.

%% =============================================================================
%% gc / compaction
%% =============================================================================

gc_no_op_when_no_sealed_packs_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        try
            {S1, Meta} = bondy_mst_store:gc(S0, []),
            ?assertMatch(#{compacted := false}, Meta),
            ?assertEqual([], pack_ids(S1))
        after
            _ = bondy_mst_store:close(S0)
        end
    end).

gc_epoch_rejected_with_typed_meta_test() ->
    with_tmp_dir(fun(Dir) ->
        S = open_store(Dir),
        try
            {S1, Meta} = bondy_mst_store:gc(S, 12345),
            ?assertMatch(
                #{
                    compacted := false,
                    reason := epoch_unsupported
                },
                Meta
            ),
            %% State must be unchanged.
            ?assertEqual([], pack_ids(S1))
        after
            _ = bondy_mst_store:close(S)
        end
    end).

gc_no_op_when_single_pack_and_no_drops_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        P = mk_page(0, undefined, [{a, 1, undefined}]),
        {H, S1} = bondy_mst_store:put(S0, P),
        {ok, S2} = bondy_mst_pack_store_seal(S1),
        ?assertEqual([1], pack_ids(S2)),
        {S3, Meta} = bondy_mst_store:gc(S2, [H]),
        try
            ?assertMatch(#{compacted := false}, Meta),
            ?assertEqual([1], pack_ids(S3)),
            ?assertEqual(P, bondy_mst_store:get(S3, H))
        after
            _ = bondy_mst_store:close(S3)
        end
    end).

gc_drops_unreachable_pages_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        P1 = mk_page(0, undefined, [{a, 1, undefined}]),
        P2 = mk_page(0, undefined, [{b, 2, undefined}]),
        P3 = mk_page(0, undefined, [{c, 3, undefined}]),
        {H1, S1} = bondy_mst_store:put(S0, P1),
        {_H2, S2} = bondy_mst_store:put(S1, P2),
        {_H3, S3} = bondy_mst_store:put(S2, P3),
        {ok, S4} = bondy_mst_pack_store_seal(S3),
        ?assertEqual([1], pack_ids(S4)),
        {S5, Meta} = bondy_mst_store:gc(S4, [H1]),
        try
            ?assertMatch(
                #{
                    compacted := true,
                    retired := [1],
                    new_pack := 2,
                    kept := 1,
                    dropped := 2
                },
                Meta
            ),
            ?assertEqual([2], pack_ids(S5)),
            ?assertEqual(P1, bondy_mst_store:get(S5, H1)),
            %% Unreachable pages are gone from the store.
            ?assertEqual([P1], bondy_mst_store:list(S5))
        after
            _ = bondy_mst_store:close(S5)
        end
    end).

gc_drops_tombstoned_pages_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        P1 = mk_page(0, undefined, [{a, 1, undefined}]),
        P2 = mk_page(0, undefined, [{b, 2, undefined}]),
        {H1, S1} = bondy_mst_store:put(S0, P1),
        {H2, S2} = bondy_mst_store:put(S1, P2),
        {ok, S3} = bondy_mst_pack_store_seal(S2),
        %% Tombstone H2 while it lives in the sealed pack. KeepRoots is [H1]
        %% only: H2 is tombstoned AND unreachable, so GC physically drops it.
        %% (Listing H2 in KeepRoots would make it reachable — GC correctly
        %% keeps reachable pages, and a reachable page must NOT be hidden by
        %% the tombstone: a present page is served. See get/2.)
        S4 = bondy_mst_store:delete(S3, H2),
        {S5, Meta} = bondy_mst_store:gc(S4, [H1]),
        try
            ?assertMatch(
                #{
                    compacted := true,
                    dropped := 1,
                    kept := 1
                },
                Meta
            ),
            %% H1 retained, H2 physically dropped (genuinely absent now).
            ?assertEqual(P1, bondy_mst_store:get(S5, H1)),
            ?assertEqual(undefined, bondy_mst_store:get(S5, H2))
        after
            _ = bondy_mst_store:close(S5)
        end
    end).

gc_coalesces_multiple_sealed_packs_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        P1 = mk_page(0, undefined, [{a, 1, undefined}]),
        P2 = mk_page(0, undefined, [{b, 2, undefined}]),
        {H1, S1} = bondy_mst_store:put(S0, P1),
        {ok, S2} = bondy_mst_pack_store_seal(S1),
        {H2, S3} = bondy_mst_store:put(S2, P2),
        {ok, S4} = bondy_mst_pack_store_seal(S3),
        ?assertEqual([2, 1], pack_ids(S4)),
        {S5, Meta} = bondy_mst_store:gc(S4, [H1, H2]),
        try
            ?assertMatch(
                #{
                    compacted := true,
                    retired := [1, 2],
                    new_pack := 3,
                    kept := 2,
                    dropped := 0
                },
                Meta
            ),
            ?assertEqual([3], pack_ids(S5)),
            ?assertEqual(P1, bondy_mst_store:get(S5, H1)),
            ?assertEqual(P2, bondy_mst_store:get(S5, H2))
        after
            _ = bondy_mst_store:close(S5)
        end
    end).

gc_empty_keep_roots_retires_all_packs_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        P = mk_page(0, undefined, [{k, v, undefined}]),
        {_H, S1} = bondy_mst_store:put(S0, P),
        {ok, S2} = bondy_mst_pack_store_seal(S1),
        ?assertEqual([1], pack_ids(S2)),
        {S3, Meta} = bondy_mst_store:gc(S2, []),
        try
            ?assertMatch(
                #{
                    compacted := true,
                    retired := [1],
                    new_pack := undefined,
                    kept := 0,
                    dropped := 1
                },
                Meta
            ),
            ?assertEqual([], pack_ids(S3)),
            ?assertEqual([], bondy_mst_store:list(S3))
        after
            _ = bondy_mst_store:close(S3)
        end
    end).

gc_advances_deleted_through_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        P = mk_page(0, undefined, [{k, v, undefined}]),
        {_, S1} = bondy_mst_store:put(S0, P),
        {ok, S2} = bondy_mst_pack_store_seal(S1),
        {S3, _} = bondy_mst_store:gc(S2, []),
        try
            M = read_manifest(store_dir(S3)),
            ?assertEqual([], bondy_mst_pack_manifest:sealed_packs(M)),
            ?assertEqual(1, bondy_mst_pack_manifest:deleted_through(M))
        after
            _ = bondy_mst_store:close(S3)
        end
    end).

gc_deletes_old_pack_files_from_disk_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        P = mk_page(0, undefined, [{k, v, undefined}]),
        {_, S1} = bondy_mst_store:put(S0, P),
        {ok, S2} = bondy_mst_pack_store_seal(S1),
        OldPack = bondy_mst_pack_paths:sealed_pack_path(Dir, 1),
        OldIdx = bondy_mst_pack_paths:sealed_idx_path(Dir, 1),
        ?assert(filelib:is_regular(OldPack)),
        ?assert(filelib:is_regular(OldIdx)),
        {S3, _} = bondy_mst_store:gc(S2, []),
        try
            ?assertNot(filelib:is_regular(OldPack)),
            ?assertNot(filelib:is_regular(OldIdx))
        after
            _ = bondy_mst_store:close(S3)
        end
    end).

gc_new_pack_id_is_max_plus_one_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        P1 = mk_page(0, undefined, [{a, 1, undefined}]),
        P2 = mk_page(0, undefined, [{b, 2, undefined}]),
        {H1, S1} = bondy_mst_store:put(S0, P1),
        {ok, S2} = bondy_mst_pack_store_seal(S1),
        {H2, S3} = bondy_mst_store:put(S2, P2),
        {ok, S4} = bondy_mst_pack_store_seal(S3),
        ?assertEqual([2, 1], pack_ids(S4)),
        {S5, Meta} = bondy_mst_store:gc(S4, [H1, H2]),
        try
            ?assertEqual(3, maps:get(new_pack, Meta)),
            ?assertEqual([3], pack_ids(S5))
        after
            _ = bondy_mst_store:close(S5)
        end
    end).

gc_persists_across_reopen_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        P1 = mk_page(0, undefined, [{a, 1, undefined}]),
        P2 = mk_page(0, undefined, [{b, 2, undefined}]),
        {H1, S1} = bondy_mst_store:put(S0, P1),
        {H2, S2} = bondy_mst_store:put(S1, P2),
        {ok, S3} = bondy_mst_pack_store_seal(S2),
        {S4, _} = bondy_mst_store:gc(S3, [H1]),
        ok = bondy_mst_store:close(S4),
        %% Reopen and confirm only H1 survives.
        S5 = open_store(Dir),
        try
            ?assertEqual([2], pack_ids(S5)),
            ?assertEqual(P1, bondy_mst_store:get(S5, H1)),
            ?assertEqual(undefined, bondy_mst_store:get(S5, H2)),
            M = read_manifest(Dir),
            ?assertEqual([2], bondy_mst_pack_manifest:sealed_packs(M)),
            ?assertEqual(1, bondy_mst_pack_manifest:deleted_through(M))
        after
            _ = bondy_mst_store:close(S5)
        end
    end).

gc_tombstones_for_pending_preserved_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        %% Sealed page (will be retained by gc).
        P1 = mk_page(0, undefined, [{a, 1, undefined}]),
        {H1, S1} = bondy_mst_store:put(S0, P1),
        {ok, S2} = bondy_mst_pack_store_seal(S1),
        %% Pending page tombstoned BEFORE gc.
        P2 = mk_page(0, undefined, [{b, 2, undefined}]),
        {H2, S3} = bondy_mst_store:put(S2, P2),
        S4 = bondy_mst_store:delete(S3, H2),
        {S5, _} = bondy_mst_store:gc(S4, [H1]),
        try
            %% Pending tombstone survives gc — the entry is still in
            %% incoming.pack and remains physically addressable (the
            %% tombstone is a GC/enumeration hint, not a read mask), but it
            %% is excluded from list/1, which proves the tombstone was
            %% preserved (not pruned) for the still-pending page.
            ?assertEqual(P2, bondy_mst_store:get(S5, H2)),
            ?assert(bondy_mst_store:has(S5, H2)),
            ?assertEqual([P1], bondy_mst_store:list(S5)),
            %% Sealed page still resolvable.
            ?assertEqual(P1, bondy_mst_store:get(S5, H1))
        after
            _ = bondy_mst_store:close(S5)
        end
    end).

gc_through_bondy_mst_test() ->
    with_tmp_dir(fun(Dir) ->
        M0 = bondy_mst:new(#{
            store => bondy_mst_pack_store,
            store_opts => opts(Dir)
        }),
        Pairs = [{N, N * 2} || N <- lists:seq(1, 10)],
        M1 = lists:foldl(
            fun({K, V}, Acc) -> bondy_mst:put(Acc, K, V) end,
            M0,
            Pairs
        ),
        %% Seal so all pages are sealed before gc.
        {ok, S1} = bondy_mst_pack_store_seal(bondy_mst:store(M1)),
        M2 = bondy_mst:set_store(M1, S1),
        %% gc/1 keeps current root only — every reachable page survives.
        M3 = bondy_mst:gc(M2),
        try
            ?assertEqual(
                lists:sort(Pairs),
                lists:sort(bondy_mst:to_list(M3))
            )
        after
            _ = bondy_mst_store:close(bondy_mst:store(M3))
        end
    end).

%% =============================================================================
%% gc — retry on transient open_sealed_view failure (#16)
%% =============================================================================

gc_open_view_succeeds_after_transient_failure_test() ->
    %% The first `bondy_mst_pack_index:open/1` call inside
    %% finalise_compaction returns `{error, eio}`; the retry passes
    %% through. The store ends up with the new sealed pack and is
    %% functional.
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        P1 = mk_page(0, undefined, [{a, 1, undefined}]),
        P2 = mk_page(0, undefined, [{b, 2, undefined}]),
        {H1, S1} = bondy_mst_store:put(S0, P1),
        {_H2, S2} = bondy_mst_store:put(S1, P2),
        {ok, S3} = bondy_mst_pack_store_seal(S2),
        with_index_open_fault(1, eio, fun() ->
            {S4, Meta} = bondy_mst_store:gc(S3, [H1]),
            try
                ?assertMatch(
                    #{
                        compacted := true,
                        retired := [1],
                        new_pack := 2,
                        kept := 1,
                        dropped := 1
                    },
                    Meta
                ),
                ?assertEqual([2], pack_ids(S4)),
                ?assertEqual(P1, bondy_mst_store:get(S4, H1))
            after
                _ = bondy_mst_store:close(S4)
            end
        end)
    end).

gc_open_view_raises_after_persistent_failure_test() ->
    %% Both attempts fail → `error({gc_open_view, _, _})` raises.
    %% Use two pages and keep only one so compaction actually runs
    %% (a single-pack no-drop GC is a no-op that doesn't touch the
    %% view-open path).
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        P1 = mk_page(0, undefined, [{a, 1, undefined}]),
        P2 = mk_page(0, undefined, [{b, 2, undefined}]),
        {H1, S1} = bondy_mst_store:put(S0, P1),
        {_H2, S2} = bondy_mst_store:put(S1, P2),
        {ok, S3} = bondy_mst_pack_store_seal(S2),
        with_index_open_fault(always, eio, fun() ->
            ?assertError(
                {gc_open_view, 2, {sealed_idx, 2, eio}},
                bondy_mst_store:gc(S3, [H1])
            )
        end),
        _ = bondy_mst_store:close(S3)
    end).

gc_open_view_persistent_failure_recoverable_on_reopen_test() ->
    %% The raise leaves the on-disk state correct: the manifest names
    %% the new pack id, and the new pack + idx files exist. A reopen
    %% rebuilds the sealed-view list and the kept hash is retrievable.
    with_tmp_dir(fun(Dir) ->
        S0 = open_store(Dir),
        P1 = mk_page(0, undefined, [{a, 1, undefined}]),
        P2 = mk_page(0, undefined, [{b, 2, undefined}]),
        {H1, S1} = bondy_mst_store:put(S0, P1),
        {_H2, S2} = bondy_mst_store:put(S1, P2),
        {ok, S3} = bondy_mst_pack_store_seal(S2),
        with_index_open_fault(always, eio, fun() ->
            ?assertError(
                {gc_open_view, _, _},
                bondy_mst_store:gc(S3, [H1])
            )
        end),
        %% The in-memory S3 is now stale relative to disk — the
        %% manifest on disk reflects the compaction even though the
        %% raise prevented the in-memory view from updating.  Close
        %% it (the writer's incoming fd is still valid) and reopen.
        _ = bondy_mst_store:close(S3),
        S4 = open_store(Dir),
        try
            ?assertEqual([2], pack_ids(S4)),
            ?assertEqual(P1, bondy_mst_store:get(S4, H1)),
            M = read_manifest(Dir),
            ?assertEqual([2], bondy_mst_pack_manifest:sealed_packs(M)),
            ?assertEqual(1, bondy_mst_pack_manifest:deleted_through(M))
        after
            _ = bondy_mst_store:close(S4)
        end
    end).

%% @private
%% Install a fault on `bondy_mst_pack_index:open/1`: the first `FailN`
%% calls return `{error, Reason}`; subsequent calls pass through. Pass
%% `always` to fail indefinitely. Holds a node-scoped global lock so two
%% suites mecking the same module cannot collide.
with_index_open_fault(FailN, Reason, Body) ->
    Lock = {bondy_mst_pack_index_fault, ?MODULE},
    global:trans(
        {Lock, self()},
        fun() ->
            ok = meck:new(bondy_mst_pack_index, [passthrough]),
            try
                install_index_open_expectation(FailN, Reason),
                Body()
            after
                _ = meck:unload(bondy_mst_pack_index)
            end
        end,
        [node()],
        infinity
    ).

%% @private
install_index_open_expectation(always, Reason) ->
    meck:expect(
        bondy_mst_pack_index,
        open,
        fun(_Bin) -> {error, Reason} end
    );
install_index_open_expectation(N, Reason) when is_integer(N), N >= 1 ->
    Counter = atomics:new(1, []),
    ok = atomics:put(Counter, 1, N),
    meck:expect(
        bondy_mst_pack_index,
        open,
        fun(Bin) ->
            case atomics:sub_get(Counter, 1, 1) of
                Remaining when Remaining >= 0 ->
                    {error, Reason};
                _ ->
                    meck:passthrough([Bin])
            end
        end
    ).

%% =============================================================================
%% Tombstones-flush debounce
%% =============================================================================
%%
%% `delete/2` (and the MST's spine-revision `free/3` via `put/2`) used
%% to fsync the `tombstones` file on every call — ~5 such writes per
%% MST put under steady-state churn. The store now keeps the free_set
%% in memory and flushes under the same debounce shape as `set_root/2`:
%% threshold-on-records OR wall-clock, with seal / GC / close as
%% forced-flush boundaries.

ts_disk_set(Dir) ->
    Path = bondy_mst_pack_tombstones:path(Dir),
    case file:read_file(Path) of
        {ok, Bin} ->
            case bondy_mst_pack_tombstones:decode(Bin) of
                {ok, Set} -> Set;
                {error, _} = E -> E
            end;
        {error, enoent} ->
            sets:new();
        {error, _} = E ->
            E
    end.

tombstones_below_threshold_skips_disk_write_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store_with(Dir, #{
            tombstones_flush_every_records => 4,
            tombstones_flush_every_ms => infinity
        }),
        H1 = crypto:hash(sha256, <<"h1">>),
        H2 = crypto:hash(sha256, <<"h2">>),
        H3 = crypto:hash(sha256, <<"h3">>),
        S1 = bondy_mst_store:delete(S0, H1),
        S2 = bondy_mst_store:delete(S1, H2),
        S3 = bondy_mst_store:delete(S2, H3),
        %% Three changes, threshold is 4 — file should NOT have these.
        ?assert(sets:is_empty(ts_disk_set(Dir))),
        _ = S3,
        bondy_mst_store:close(S3)
    end).

tombstones_threshold_flushes_to_disk_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store_with(Dir, #{
            tombstones_flush_every_records => 3,
            tombstones_flush_every_ms => infinity
        }),
        H1 = crypto:hash(sha256, <<"a">>),
        H2 = crypto:hash(sha256, <<"b">>),
        H3 = crypto:hash(sha256, <<"c">>),
        S1 = bondy_mst_store:delete(S0, H1),
        S2 = bondy_mst_store:delete(S1, H2),
        ?assert(sets:is_empty(ts_disk_set(Dir))),
        %% Third call crosses the threshold.
        S3 = bondy_mst_store:delete(S2, H3),
        DiskSet = ts_disk_set(Dir),
        ?assert(sets:is_element(H1, DiskSet)),
        ?assert(sets:is_element(H2, DiskSet)),
        ?assert(sets:is_element(H3, DiskSet)),
        _ = S3,
        bondy_mst_store:close(S3)
    end).

tombstones_close_flushes_pending_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store_with(Dir, #{
            tombstones_flush_every_records => infinity,
            tombstones_flush_every_ms => infinity
        }),
        H = crypto:hash(sha256, <<"close-flush">>),
        S1 = bondy_mst_store:delete(S0, H),
        %% Thresholds are infinity, so no in-flight flush yet.
        ?assert(sets:is_empty(ts_disk_set(Dir))),
        bondy_mst_store:close(S1),
        %% close/1 must have force-flushed.
        ?assert(sets:is_element(H, ts_disk_set(Dir)))
    end).

tombstones_seal_flushes_pending_test() ->
    with_tmp_dir(fun(Dir) ->
        S0 = open_store_with(Dir, #{
            tombstones_flush_every_records => infinity,
            tombstones_flush_every_ms => infinity
        }),
        H = crypto:hash(sha256, <<"seal-flush">>),
        S1 = bondy_mst_store:delete(S0, H),
        ?assert(sets:is_empty(ts_disk_set(Dir))),
        %% seal/1 forces a tombstones flush even though no incoming pack.
        {ok, S2} = bondy_mst_pack_store_seal(S1),
        ?assert(sets:is_element(H, ts_disk_set(Dir))),
        _ = S2,
        bondy_mst_store:close(S2)
    end).
