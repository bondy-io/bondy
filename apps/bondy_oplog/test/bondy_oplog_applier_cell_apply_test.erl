%% =============================================================================
%% End-to-end tests for the applier's per-cell projection-write path
%% (`MST_DB_DESIGN.md` §6.3).
%%
%% Verifies:
%%   - `{cell_apply, Bucket, Key, FoldEvent}` events drive a read-modify-write
%%     against the projection adapter registered in
%%     `bondy_oplog_core_registry`.
%%   - The cell frame written by the applier round-trips through
%%     `bondy_oplog_core:read/3` (substrate read merges projection + cache
%%     + overlay + fold).
%%   - Later-HLC events win over earlier ones (LWW semantics inherited
%%     from the fold module).
%%   - Earlier-HLC events are absorbed without rewriting the cell —
%%     proving the applier does a true read-modify-write, not a blind
%%     overwrite.
%%   - `clear` then a higher-HLC `set` resurrects the register.
%%   - Per-instance fold remains unaffected — cell_apply ops do NOT
%%     leak into the per-instance fold state.
%%   - `cell_apply_target` pointing at an unregistered shard fails the
%%     applier's `init/1` cleanly (the supervisor surfaces the error).
%%   - Defaults (no `cell_apply_target`) leave the path as a strict
%%     no-op.
%% =============================================================================

-module(bondy_oplog_applier_cell_apply_test).

-include_lib("eunit/include/eunit.hrl").

%% Default bucket — substrate `read/3` alias and per-entity tests both
%% land on `<<>>` for now.
-define(B, <<>>).

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)]
    ],
    ok.

cell_apply_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun apply_writes_projection/0,
        fun apply_round_trips_through_db_core_read/0,
        fun later_hlc_wins/0,
        fun earlier_hlc_is_absorbed/0,
        fun clear_then_resurrect/0,
        fun cell_apply_does_not_feed_per_instance_fold/0,
        fun missing_target_means_strict_noop/0,
        fun unregistered_target_fails_init/0,
        fun invalid_target_shape_rejected/0
    ]}.

%% =============================================================================
%% Tests
%% =============================================================================

apply_writes_projection() ->
    %% Single cell_apply event must produce a frame in the projection
    %% adapter whose HLC and decoded state match the LWW fold's contract.
    {Id, NS, Cache, Proj} = setup_instance(),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?B, <<"alice">>, {set, 1, <<"v1">>}}
    ),
    _ = barrier(Id),
    {ok, Frame} = bondy_oplog_projection_ets:get(Proj, ?B, <<"alice">>),
    {Hlc, Body, _} = bondy_oplog_cell_frame:decode_full(Frame),
    State = bondy_oplog_crdt_lww_register:decode_state(Body),
    ?assertEqual({set, <<"v1">>, 1}, State),
    ?assertEqual(1, Hlc),
    teardown_instance(Id, NS, Cache, Proj).

apply_round_trips_through_db_core_read() ->
    %% Substrate read must see the frame the applier just wrote and
    %% return the user-facing value (post-§3.6 the read API returns
    %% `to_value/1`).
    {Id, NS, Cache, Proj} = setup_instance(),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"bob">>, {set, 42, <<"v">>}}),
    _ = barrier(Id),
    Result = bondy_oplog_core:read(NS, primary, <<"bob">>),
    ?assertEqual({<<"v">>, 42}, Result),
    teardown_instance(Id, NS, Cache, Proj).

later_hlc_wins() ->
    {Id, NS, Cache, Proj} = setup_instance(),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?B, <<"k">>, {set, 1, <<"first">>}}
    ),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?B, <<"k">>, {set, 2, <<"second">>}}
    ),
    _ = barrier(Id),
    {<<"second">>, 2} =
        bondy_oplog_core:read(NS, primary, <<"k">>),
    teardown_instance(Id, NS, Cache, Proj).

earlier_hlc_is_absorbed() ->
    %% Applying an HLC-older event after a newer one must leave the
    %% cell unchanged — the LWW fold's `apply_event/3` is responsible
    %% for the absorption. The applier just hands the event to the
    %% fold; this proves the read-modify-write loop reads the current
    %% state instead of blindly overwriting.
    {Id, NS, Cache, Proj} = setup_instance(),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?B, <<"k">>, {set, 5, <<"newer">>}}
    ),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?B, <<"k">>, {set, 3, <<"older">>}}
    ),
    _ = barrier(Id),
    {<<"newer">>, 5} =
        bondy_oplog_core:read(NS, primary, <<"k">>),
    teardown_instance(Id, NS, Cache, Proj).

clear_then_resurrect() ->
    {Id, NS, Cache, Proj} = setup_instance(),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"k">>, {set, 1, <<"v1">>}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"k">>, {clear, 2}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"k">>, {set, 3, <<"v2">>}}),
    _ = barrier(Id),
    {<<"v2">>, 3} =
        bondy_oplog_core:read(NS, primary, <<"k">>),
    teardown_instance(Id, NS, Cache, Proj).

cell_apply_does_not_feed_per_instance_fold() ->
    %% The applier filters cell_apply events out of `apply_fold_batch/2`
    %% so the per-instance fold (configured here as lww_register) stays
    %% at `initial_value` regardless of how many cell_apply events
    %% have been appended.
    {Id, NS, Cache, Proj} = setup_instance(),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"k1">>, {set, 1, <<"v1">>}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"k2">>, {set, 2, <<"v2">>}}),
    _ = barrier(Id),
    %% lww_register's `initial_value/0` is `undefined`.
    ?assertEqual({ok, undefined}, bondy_oplog:projection(Id)),
    teardown_instance(Id, NS, Cache, Proj).

missing_target_means_strict_noop() ->
    %% Without `cell_apply_target` the cell_apply events do not crash
    %% the applier — they just don't drive a projection write. The
    %% per-instance fold also leaves them alone (filtered by
    %% `partition_by_op/1`).
    Id = mk_id(),
    NS = ns_of(Id),
    %% Register the shard so a subsequent `bondy_oplog_core:read` does
    %% not error on "namespace not configured" — projection stays
    %% empty.
    {Cache, Proj} = register_shard(NS, primary, 0),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register
    }),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"k">>, {set, 1, <<"v">>}}),
    _ = barrier(Id),
    ?assertEqual(
        undefined,
        bondy_oplog_core:read(NS, primary, <<"k">>)
    ),
    teardown_instance(Id, NS, Cache, Proj).

unregistered_target_fails_init() ->
    %% Pointing `cell_apply_target` at a triple that is not registered
    %% must surface as a clean startup error — silently disabling the
    %% path on a typo would be a debugging trap.
    Id = mk_id(),
    NS = ns_of(Id),
    ?assertMatch(
        {error, _},
        bondy_oplog:start_instance(Id, #{
            fold_module => lww_register,
            applier => #{
                cell_apply_target => {NS, primary, 0}
            }
        })
    ).

invalid_target_shape_rejected() ->
    %% `cell_apply_target` must be a `{atom(), atom(), non_neg_integer()}`
    %% triple. Anything else fails validation before the applier is
    %% even resolved.
    Id = mk_id(),
    ?assertMatch(
        {error, _},
        bondy_oplog:start_instance(Id, #{
            fold_module => lww_register,
            applier => #{
                cell_apply_target => not_a_triple
            }
        })
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

mk_id() ->
    list_to_binary(
        "cellapply_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

ns_of(Id) when is_binary(Id) ->
    binary_to_atom(<<"ns_", Id/binary>>, utf8).

%% Provision + register an `(NS, primary, 0)` shard backed by an ETS
%% cache + ETS projection adapter, both opened fresh for this call.
%% Returns the handles so the caller can `close/1` them at teardown.
register_shard(NS, Index, Shard) ->
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, Index, Shard, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, Index, Shard, #{}),
    ok = bondy_oplog_core_registry:register(NS, Index, Shard, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        fold_module => lww_register,
        overlay => disabled
    }),
    {Cache, Proj}.

%% Common setup: fresh instance id, fresh namespace, fresh shard with
%% ETS cache + projection, instance started with cell_apply_target
%% pointing at the freshly registered shard.
setup_instance() ->
    Id = mk_id(),
    NS = ns_of(Id),
    {Cache, Proj} = register_shard(NS, primary, 0),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        applier => #{
            cell_apply_target => {NS, primary, 0}
        }
    }),
    {Id, NS, Cache, Proj}.

teardown_instance(Id, NS, Cache, Proj) ->
    ok = bondy_oplog:stop_instance(Id),
    ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
    ok = bondy_oplog_projection_ets:close(Proj),
    ok = bondy_oplog_cache_ets:close(Cache),
    ok.

%% Synchronous barrier through the applier mailbox. The
%% `gen_server:call` to `projection/1` queues after every prior
%% `install_local_batch` cast and after any in-flight `apply_batch/2`
%% pass, so when the call returns every appended event has been
%% folded AND its projection (if cell_apply) has been written.
barrier(Id) ->
    bondy_oplog:projection(Id).
