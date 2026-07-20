%% =============================================================================
%% Adapter-level tests for `bondy_db_projection_leveled`.
%%
%% Each test starts its own leveled Bookie in a fresh temp directory,
%% exercises the adapter callbacks against it, and tears the Bookie
%% down. There is no `bondy_db` / shared-supervisor plumbing — the
%% adapter is verified in isolation against an inline-managed Bookie.
%%
%% Bucket is a first-class call-time parameter (`MST_DB_DESIGN.md` §18
%% item 14): every data callback (`get/3`, `put_batch/2`,
%% `range/5`, `delete/3`) takes it explicitly.
%%
%% Covers:
%%   - open/4 invalid-opts rejection (missing Bookie)
%%   - close/1 is a no-op against the underlying Bookie
%%   - get hit and miss
%%   - put_batch of varying sizes including empty
%%   - delete removes the (bucket, key) row
%%   - distinct buckets do not collide
%%   - range: empty, asc, desc, limit, half-open exclusion of High,
%%     limit smaller than range, limit larger than range
%%   - clear/2 is bucket-scoped: wipes only the buckets ending with the
%%     given index suffix, sparing co-located primary + sibling-index
%%     buckets in the same Bookie (the shared-backend correctness claim,
%%     PLUM_DB_TO_BONDY_DB_DESIGN.md §6.6.4)
%%   - info returns the expected map shape
%% =============================================================================

-module(bondy_db_projection_leveled_test).

-include_lib("eunit/include/eunit.hrl").

-define(BUCKET, <<"test">>).
-define(MOD, bondy_db_projection_leveled).

%% =============================================================================
%% Test list
%% =============================================================================

adapter_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun open_with_valid_opts/1,
        fun open_with_missing_bookie_is_rejected/1,
        fun close_is_a_noop/1,
        fun get_returns_not_found_for_missing_key/1,
        fun put_then_get_roundtrip/1,
        fun put_batch_with_multiple_entries/1,
        fun put_batch_with_empty_list/1,
        fun delete_removes_the_key/1,
        fun distinct_buckets_do_not_collide/1,
        fun range_returns_empty_for_no_data/1,
        fun range_excludes_the_high_bound/1,
        fun range_respects_limit/1,
        fun range_limit_larger_than_data_returns_all/1,
        fun range_asc_returns_ascending/1,
        fun clear_is_bucket_scoped/1,
        fun clear_is_entity_scoped/1,
        fun cell_keys_is_entity_scoped/1,
        fun info_reports_backend_and_bookie/1
    ]}.

%% =============================================================================
%% Setup / teardown
%% =============================================================================

setup() ->
    %% Per-test fresh Bookie in a fresh temp directory. The adapter uses
    %% head_only mode with the built-in ?HEAD_TAG; no custom leveled-tag
    %% extractor is involved.
    Dir = make_tempdir(),
    {ok, Pid} = leveled_bookie:book_start(
        [
            {root_path, Dir},
            {cache_size, 2000},
            {max_journalsize, 100_000_000},
            {sync_strategy, none},
            {head_only, with_lookup}
        ]
    ),
    {Pid, Dir}.

cleanup({Pid, Dir}) ->
    ok = leveled_bookie:book_close(Pid),
    rmrf(Dir),
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

open_with_valid_opts({Pid, _Dir}) ->
    fun() ->
        {ok, Handle} = ?MOD:open(ns, idx, 0, #{bookie => Pid}),
        ?assertMatch(#{bookie := Pid}, Handle)
    end.

open_with_missing_bookie_is_rejected({_Pid, _Dir}) ->
    fun() ->
        ?assertMatch(
            {error, {invalid_opts, _}},
            ?MOD:open(ns, idx, 0, #{})
        )
    end.

close_is_a_noop({Pid, _Dir}) ->
    fun() ->
        H = handle(Pid),
        ?assertEqual(ok, ?MOD:close(H)),
        %% Bookie is still alive — close/1 did not touch it.
        ?assert(is_process_alive(Pid))
    end.

get_returns_not_found_for_missing_key({Pid, _Dir}) ->
    fun() ->
        H = handle(Pid),
        ?assertEqual(not_found, ?MOD:get(H, ?BUCKET, <<"nope">>))
    end.

put_then_get_roundtrip({Pid, _Dir}) ->
    fun() ->
        H = handle(Pid),
        F = mk_frame(<<"v1">>),
        ok = ?MOD:put_batch(H, [{?BUCKET, <<"k1">>, F}]),
        ?assertEqual({ok, F}, ?MOD:get(H, ?BUCKET, <<"k1">>))
    end.

put_batch_with_multiple_entries({Pid, _Dir}) ->
    fun() ->
        H = handle(Pid),
        Entries = [
            {?BUCKET, key_n(I), mk_frame(value_n(I))}
         || I <- lists:seq(1, 10)
        ],
        ok = ?MOD:put_batch(H, Entries),
        [
            ?assertEqual(
                {ok, mk_frame(value_n(I))},
                ?MOD:get(H, ?BUCKET, key_n(I))
            )
         || I <- lists:seq(1, 10)
        ],
        ok
    end.

put_batch_with_empty_list({Pid, _Dir}) ->
    fun() ->
        H = handle(Pid),
        ?assertEqual(ok, ?MOD:put_batch(H, []))
    end.

delete_removes_the_key({Pid, _Dir}) ->
    fun() ->
        H = handle(Pid),
        F = mk_frame(<<"v">>),
        ok = ?MOD:put_batch(H, [{?BUCKET, <<"k">>, F}]),
        ?assertEqual({ok, F}, ?MOD:get(H, ?BUCKET, <<"k">>)),
        ok = ?MOD:delete(H, ?BUCKET, <<"k">>),
        ?assertEqual(not_found, ?MOD:get(H, ?BUCKET, <<"k">>))
    end.

distinct_buckets_do_not_collide({Pid, _Dir}) ->
    fun() ->
        H = handle(Pid),
        F1 = mk_frame(<<"v1">>),
        F2 = mk_frame(<<"v2">>),
        ok = ?MOD:put_batch(H, [
            {<<"b1">>, <<"k">>, F1},
            {<<"b2">>, <<"k">>, F2}
        ]),
        ?assertEqual({ok, F1}, ?MOD:get(H, <<"b1">>, <<"k">>)),
        ?assertEqual({ok, F2}, ?MOD:get(H, <<"b2">>, <<"k">>))
    end.

range_returns_empty_for_no_data({Pid, _Dir}) ->
    fun() ->
        H = handle(Pid),
        ?assertEqual(
            {ok, []},
            ?MOD:range(H, ?BUCKET, <<"a">>, <<"z">>, #{})
        )
    end.

range_excludes_the_high_bound({Pid, _Dir}) ->
    fun() ->
        H = handle(Pid),
        ok = ?MOD:put_batch(H, [
            {?BUCKET, <<"k01">>, mk_frame(<<"v01">>)},
            {?BUCKET, <<"k02">>, mk_frame(<<"v02">>)},
            {?BUCKET, <<"k03">>, mk_frame(<<"v03">>)}
        ]),
        %% [k01, k03) — must include k01 and k02, exclude k03.
        {ok, Rows} = ?MOD:range(
            H,
            ?BUCKET,
            <<"k01">>,
            <<"k03">>,
            #{limit => 100}
        ),
        Keys = [K || {K, _} <- Rows],
        ?assertEqual([<<"k01">>, <<"k02">>], Keys)
    end.

range_respects_limit({Pid, _Dir}) ->
    fun() ->
        H = handle(Pid),
        Entries = [
            {?BUCKET, key_n(I), mk_frame(value_n(I))}
         || I <- lists:seq(1, 10)
        ],
        ok = ?MOD:put_batch(H, Entries),
        {ok, Rows} = ?MOD:range(
            H,
            ?BUCKET,
            key_n(1),
            key_n(11),
            #{limit => 3}
        ),
        ?assertEqual(3, length(Rows)),
        %% First three in ascending order.
        ?assertEqual([key_n(1), key_n(2), key_n(3)], [K || {K, _} <- Rows])
    end.

range_limit_larger_than_data_returns_all({Pid, _Dir}) ->
    fun() ->
        H = handle(Pid),
        Entries = [
            {?BUCKET, key_n(I), mk_frame(value_n(I))}
         || I <- lists:seq(1, 5)
        ],
        ok = ?MOD:put_batch(H, Entries),
        {ok, Rows} = ?MOD:range(
            H,
            ?BUCKET,
            key_n(1),
            key_n(99),
            #{limit => 100}
        ),
        ?assertEqual(5, length(Rows))
    end.

range_asc_returns_ascending({Pid, _Dir}) ->
    fun() ->
        H = handle(Pid),
        ok = ?MOD:put_batch(H, [
            {?BUCKET, <<"k01">>, mk_frame(<<"v01">>)},
            {?BUCKET, <<"k02">>, mk_frame(<<"v02">>)},
            {?BUCKET, <<"k03">>, mk_frame(<<"v03">>)}
        ]),
        {ok, Rows} = ?MOD:range(
            H,
            ?BUCKET,
            <<"k01">>,
            <<"k99">>,
            #{}
        ),
        ?assertEqual([<<"k01">>, <<"k02">>, <<"k03">>], [K || {K, _} <- Rows])
    end.

clear_is_bucket_scoped({Pid, _Dir}) ->
    fun() ->
        H = handle(Pid),
        %% Three buckets co-located in ONE Bookie, mirroring a shared
        %% backend (shared_shards / single_bookie):
        %%  - Target  index  "users/$idx/by_name"  (to be wiped)
        %%  - Sibling index  "users/$idx/by_email" (different suffix)
        %%  - Primary table   "users"              (no /$idx/ infix)
        Target = <<"users/$idx/by_name">>,
        Sibling = <<"users/$idx/by_email">>,
        Primary = <<"users">>,
        F = mk_frame(<<"v">>),
        ok = ?MOD:put_batch(H, [
            {Target, <<"t1">>, F},
            {Target, <<"t2">>, F},
            %% A value_equals_state cell (only the ?SK_STATE subkey is
            %% written) — what real index entries look like. The clear
            %% folds off ?SK_STATE, so it must catch these too.
            {Target, <<"t3">>, mk_state_frame(<<"sv">>)},
            {Sibling, <<"s1">>, F},
            {Primary, <<"p1">>, F}
        ]),
        %% `{suffix, IndexName}` scope — the single-table-handle path
        %% (per_entity / memory). Documents the codec it resolves to.
        ?assertEqual(
            <<"/$idx/by_name">>, bondy_oplog_index_key:bucket_suffix(by_name)
        ),
        ok = ?MOD:clear(H, {suffix, by_name}),
        %% Target index fully wiped (including the state-only cell)...
        ?assertEqual(not_found, ?MOD:get(H, Target, <<"t1">>)),
        ?assertEqual(not_found, ?MOD:get(H, Target, <<"t2">>)),
        ?assertEqual(not_found, ?MOD:get(H, Target, <<"t3">>)),
        %% ...sibling index and primary table spared.
        ?assertEqual({ok, F}, ?MOD:get(H, Sibling, <<"s1">>)),
        ?assertEqual({ok, F}, ?MOD:get(H, Primary, <<"p1">>))
    end.

%% The `{entity, ET, IndexName}` scope is the shared-backend wipe
%% (`shared_shards` / `single_bookie`): it must drop ONLY the target entity
%% type's index cells, sparing a co-located sibling table that declared the
%% SAME `IndexName` — the over-wipe this fix closes.
clear_is_entity_scoped({Pid, _Dir}) ->
    fun() ->
        H = handle(Pid),
        F = mk_frame(<<"v">>),
        S = mk_state_frame(<<"sv">>),
        ok = ?MOD:put_batch(H, [
            %% TARGET — `users`/`by_name`, both shared-backend layouts:

            %% shared_shards
            {<<"users/$idx/by_name">>, <<"t1">>, F},
            %% state-only cell
            {<<"users/$idx/by_name">>, <<"t2">>, S},
            %% single_bookie, r1
            {<<"r1/users/$idx/by_name">>, <<"t3">>, F},
            %% single_bookie, r2
            {<<"r2/users/$idx/by_name">>, <<"t4">>, F},
            %% SIBLING table sharing the SAME index name — must survive:

            %% shared_shards
            {<<"items/$idx/by_name">>, <<"s1">>, F},
            %% single_bookie
            {<<"r1/items/$idx/by_name">>, <<"s2">>, F},
            %% Same ET, DIFFERENT index name — must survive:
            {<<"users/$idx/by_email">>, <<"e1">>, F},
            %% substring traps: `power_users` is NOT `users` (ends `_users`,
            %% not `/users`) — must survive:
            {<<"power_users/$idx/by_name">>, <<"x1">>, F},
            {<<"r1/power_users/$idx/by_name">>, <<"x2">>, F},
            %% primary tables (no `/$idx/`) — must survive:
            {<<"users">>, <<"p1">>, F},
            {<<"r1/users">>, <<"p2">>, F},
            {<<"items">>, <<"p3">>, F}
        ]),
        ok = ?MOD:clear(H, {entity, <<"users">>, by_name}),
        %% TARGET wiped across both layouts and all realms (incl. state-only):
        [
            ?assertEqual(not_found, ?MOD:get(H, B, K))
         || {B, K} <- [
                {<<"users/$idx/by_name">>, <<"t1">>},
                {<<"users/$idx/by_name">>, <<"t2">>},
                {<<"r1/users/$idx/by_name">>, <<"t3">>},
                {<<"r2/users/$idx/by_name">>, <<"t4">>}
            ]
        ],
        %% Everything else spared — the sibling same-named index above all:
        [
            ?assertMatch({ok, _}, ?MOD:get(H, B, K))
         || {B, K} <- [
                {<<"items/$idx/by_name">>, <<"s1">>},
                {<<"r1/items/$idx/by_name">>, <<"s2">>},
                {<<"users/$idx/by_email">>, <<"e1">>},
                {<<"power_users/$idx/by_name">>, <<"x1">>},
                {<<"r1/power_users/$idx/by_name">>, <<"x2">>},
                {<<"users">>, <<"p1">>},
                {<<"r1/users">>, <<"p2">>},
                {<<"items">>, <<"p3">>}
            ]
        ]
    end.

%% `cell_keys/2` is the rebuild's cell directory (D-9). It must return EXACTLY
%% the primary cells of the given entity type, across both shared-backend bucket
%% layouts, while excluding index buckets, the reserved marker/flag buckets, and
%% every other table's cells co-located in the same Bookie.
cell_keys_is_entity_scoped({Pid, _Dir}) ->
    fun() ->
        H = handle(Pid),
        F = mk_frame(<<"v">>),
        ok = ?MOD:put_batch(H, [
            %% `users` PRIMARY cells we expect back:

            %% shared_shards (bucket = ET)
            {<<"users">>, <<"u_ss">>, F},
            %% single_bookie (Realm/ET), r1
            {<<"r1/users">>, <<"u_r1">>, F},
            %% single_bookie, r2
            {<<"r2/users">>, <<"u_r2">>, F},
            %% `users` INDEX cells — excluded (the `/$idx/` infix):
            {<<"users/$idx/by_name">>, <<"active">>, F},
            {<<"r1/users/$idx/by_name">>, <<"active">>, F},
            %% reserved marker/flag buckets — excluded:
            {<<"$idx_trusted">>, <<"m">>, F},
            {<<"$idx_clean">>, <<"m">>, F},
            %% OTHER tables co-located in the Bookie — excluded (not `users`):

            %% shared_shards other table
            {<<"items">>, <<"i1">>, F},
            %% single_bookie other table
            {<<"r1/items">>, <<"i2">>, F},
            %% substring traps: `power_users` must NOT match ET `users`
            %% (equals it? no; ends with `/users`? no — ends with `_users`):
            {<<"power_users">>, <<"pu1">>, F},
            {<<"r1/power_users">>, <<"pu2">>, F}
        ]),
        Got = lists:sort(?MOD:cell_keys(H, {entity, <<"users">>})),
        Expected = lists:sort([
            {<<"users">>, <<"u_ss">>},
            {<<"r1/users">>, <<"u_r1">>},
            {<<"r2/users">>, <<"u_r2">>}
        ]),
        ?assertEqual(Expected, Got),
        %% A different entity type sees only ITS cells (cross-table isolation
        %% holds symmetrically).
        ?assertEqual(
            lists:sort([{<<"items">>, <<"i1">>}, {<<"r1/items">>, <<"i2">>}]),
            lists:sort(?MOD:cell_keys(H, {entity, <<"items">>}))
        ),
        %% The `all_primary` scope (the `per_entity` path) enumerates EVERY
        %% non-index, non-reserved bucket's cells — every primary above, across
        %% all entity types — while still excluding the `/$idx/` index buckets
        %% and the reserved `$idx_*` marker/flag buckets. (A dedicated per_entity
        %% Bookie holds only one table's realm-keyed primaries; this co-located
        %% fixture proves the bucket filter, not co-location.)
        ?assertEqual(
            lists:sort([
                {<<"users">>, <<"u_ss">>},
                {<<"r1/users">>, <<"u_r1">>},
                {<<"r2/users">>, <<"u_r2">>},
                {<<"items">>, <<"i1">>},
                {<<"r1/items">>, <<"i2">>},
                {<<"power_users">>, <<"pu1">>},
                {<<"r1/power_users">>, <<"pu2">>}
            ]),
            lists:sort(?MOD:cell_keys(H, all_primary))
        )
    end.

info_reports_backend_and_bookie({Pid, _Dir}) ->
    fun() ->
        H = handle(Pid),
        Info = ?MOD:info(H),
        ?assertMatch(#{backend := leveled, bookie := Pid}, Info)
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

handle(Pid) ->
    {ok, H} = ?MOD:open(ns, idx, 0, #{bookie => Pid}),
    H.

key_n(I) ->
    list_to_binary(io_lib:format("k~3..0B", [I])).

value_n(I) ->
    list_to_binary(io_lib:format("v~3..0B", [I])).

%% Adapter-level tests want to verify get/put/range/delete with opaque
%% byte payloads but the leveled tag extractor now expects a V2 frame
%% (`bondy_oplog_cell_frame:encode/4`). Wrap arbitrary bytes in a
%% minimal V2 frame so the extractor succeeds; the adapter just stores
%% and returns the bytes round-trip.
mk_frame(Bytes) when is_binary(Bytes) ->
    bondy_oplog_cell_frame:encode(0, Bytes, Bytes, false).

%% A value_equals_state frame: HasValueColumn=true means the value subkey
%% is omitted on write (only ?SK_STATE is stored) — the shape every real
%% secondary-index cell has. See bondy_db_projection_leveled:build_object_specs/2.
mk_state_frame(Bytes) when is_binary(Bytes) ->
    bondy_oplog_cell_frame:encode(0, Bytes, undefined, true).

make_tempdir() ->
    Base = filename:join([
        "/tmp",
        "bondy_mst_leveled_test",
        integer_to_list(erlang:unique_integer([positive, monotonic]))
    ]),
    ok = filelib:ensure_dir(filename:join(Base, ".keep")),
    Base.

rmrf(Dir) ->
    %% Best-effort cleanup; leveled lays out files under Dir/journal and
    %% Dir/ledger.
    case file:del_dir_r(Dir) of
        ok ->
            ok;
        {error, enoent} ->
            ok;
        {error, Reason} ->
            io:format(user, "cleanup of ~p failed: ~p~n", [Dir, Reason]),
            ok
    end.
