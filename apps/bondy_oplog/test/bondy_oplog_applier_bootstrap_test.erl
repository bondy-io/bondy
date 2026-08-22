%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% The catalogue-snapshot install path writes cell frames straight into the
%% projection and emits no per-cell merge event, so a table whose reactor
%% DERIVES state from that projection would never be told it arrived. It is
%% announced once per install group instead
%% (`bondy_oplog_core:publish_bootstrap/2`).
%%
%% These pin the two conditions guarding that announcement. Both are
%% load-bearing in opposite directions: announcing when nothing was installed
%% makes every skipped batch wake every subscriber, and failing to announce
%% when something WAS installed is the original defect.

-module(bondy_oplog_applier_bootstrap_test).

-include_lib("eunit/include/eunit.hrl").

-define(NS, main_security_groups).
-define(BUCKET, <<"announced_table">>).

%% The table opted in (`publish => true` gave it a `publish_ns`) and this
%% group installed cells: announce, under the table's own namespace.
announces_when_cells_were_installed_test() ->
    ?assertEqual(
        {publish, ?NS},
        bondy_oplog_applier:bootstrap_publish_decision(
            #{publish_ns => ?NS}, #{installed => 0}, #{installed => 3}
        )
    ).

%% The counts accumulate ACROSS groups in a batch, so the decision must be
%% made on this group's delta, not on the batch total — otherwise the second
%% group in a batch announces on the back of the first group's work.
announces_on_this_groups_delta_not_the_batch_total_test() ->
    ?assertEqual(
        {publish, ?NS},
        bondy_oplog_applier:bootstrap_publish_decision(
            #{publish_ns => ?NS}, #{installed => 10}, #{installed => 11}
        )
    ),
    ?assertEqual(
        skip,
        bondy_oplog_applier:bootstrap_publish_decision(
            #{publish_ns => ?NS}, #{installed => 10}, #{installed => 10}
        ),
        "a group that installed nothing must not ride a sibling's count"
    ).

%% Every cell skipped on the per-cell HLC guard: nothing was replaced, so
%% there is nothing to rebuild from.
skips_when_nothing_was_installed_test() ->
    ?assertEqual(
        skip,
        bondy_oplog_applier:bootstrap_publish_decision(
            #{publish_ns => ?NS}, #{installed => 0}, #{installed => 0}
        )
    ).

%% A table that did not declare `publish => true` has no subscribers to tell.
skips_when_the_table_did_not_opt_in_test() ->
    ?assertEqual(
        skip,
        bondy_oplog_applier:bootstrap_publish_decision(
            #{}, #{installed => 0}, #{installed => 5}
        )
    ),
    ?assertEqual(
        skip,
        bondy_oplog_applier:bootstrap_publish_decision(
            #{publish_ns => undefined}, #{installed => 0}, #{installed => 5}
        )
    ).

%% Totality: the accumulator is built by the install fold, but the decision
%% must not assume the key is present.
tolerates_absent_counters_test() ->
    ?assertEqual(
        skip,
        bondy_oplog_applier:bootstrap_publish_decision(
            #{publish_ns => ?NS}, #{}, #{}
        )
    ),
    ?assertEqual(
        {publish, ?NS},
        bondy_oplog_applier:bootstrap_publish_decision(
            #{publish_ns => ?NS}, #{}, #{installed => 1}
        )
    ).

%% =============================================================================
%% The wiring: a snapshot install actually reaches a subscriber
%% =============================================================================
%%
%% The decision tests above pin WHEN an install should announce itself. This
%% pins that it DOES — end to end, from `install_catalogue_batch/2` through
%% `maybe_publish_bootstrap/4` and the dispatcher to a live subscriber.
%%
%% WHY HERE RATHER THAN IN THE CLUSTER SUITE. `bondy_registry_rib_restart_SUITE`
%% asserts this for the EPHEMERAL registry tables, but its durable half is only
%% an obligation check: a wiped node acquires `main` through the pre-existing
%% op-based path, which published before any of this existed, so that assertion
%% would pass on unfixed code. Compacting the survivor to force the snapshot
%% path was tried and did not move it. Driving the install directly is
%% table-agnostic — it holds for durable and ephemeral alike by construction —
%% so the guard no longer depends on which recovery path a cluster happens to
%% take.

install_wiring_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 60, fun install_announces_to_subscribers/0},
        {timeout, 60, fun install_without_publish_ns_is_silent/0}
    ]}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup(_) ->
    _ = [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

install_announces_to_subscribers() ->
    {_SrcId, Cells} = seeded_snapshot(),
    {TgtNs, TgtApplier} = target(#{publish_ns_opt => true}),

    {ok, _Ref} = bondy_oplog_core:subscribe(TgtNs, all),
    {ok, Counts} =
        bondy_oplog_applier:install_catalogue_batch(TgtApplier, Cells),
    ?assert(maps:get(installed, Counts) > 0),

    receive
        {bondy_oplog_core_bootstrap_event, TgtNs, ?BUCKET} ->
            ok
    after 5000 ->
        error(
            {no_bootstrap_event,
                "a snapshot install of a publish => true table must announce "
                "itself; nothing else on that path emits an event"}
        )
    end.

%% A table that did not opt in has no subscribers to tell, and must not
%% manufacture traffic for them.
install_without_publish_ns_is_silent() ->
    {_SrcId, Cells} = seeded_snapshot(),
    {TgtNs, TgtApplier} = target(#{publish_ns_opt => false}),

    {ok, _Ref} = bondy_oplog_core:subscribe(TgtNs, all),
    {ok, Counts} =
        bondy_oplog_applier:install_catalogue_batch(TgtApplier, Cells),
    ?assert(maps:get(installed, Counts) > 0),

    receive
        {bondy_oplog_core_bootstrap_event, _, _} = M ->
            error({unexpected_bootstrap_event, M})
    after 500 ->
        ok
    end.

%% @private
%% A source instance holding two cells, and the whole-shard snapshot of it —
%% the same shape a peer ships during a bootstrap.
seeded_snapshot() ->
    Id = mk_id(<<"src">>),
    Ns = binary_to_atom(<<"bootsrc_", Id/binary>>, utf8),
    _ = register_shard(Ns, Id, #{}),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        applier => #{
            cell_apply_target => {Ns, primary, 0},
            cell_apply_bucket => ?BUCKET
        }
    }),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET, <<"k1">>, {set, 5, <<"v1">>}}
    ),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET, <<"k2">>, {set, 6, <<"v2">>}}
    ),
    _ = bondy_oplog:projection(Id),
    {Id, pull_snapshot(Id)}.

%% @private
%% A fresh instance to install onto, with or without the `publish => true`
%% opt-in expressed as the shard entry's `publish_ns`.
target(#{publish_ns_opt := WantPublish}) ->
    Id = mk_id(<<"tgt">>),
    Ns = binary_to_atom(<<"boottgt_", Id/binary>>, utf8),
    Extra =
        case WantPublish of
            true -> #{publish_ns => Ns};
            false -> #{}
        end,
    _ = register_shard(Ns, Id, Extra),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        applier => #{
            cell_apply_target => {Ns, primary, 0},
            cell_apply_bucket => ?BUCKET
        }
    }),
    {Ns, bondy_oplog_registry:applier_pid(Id)}.

%% @private
register_shard(NS, Id, Extra) ->
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, primary, 0, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, primary, 0, #{}),
    Config = maps:merge(
        #{
            shard_count => 1,
            cache_adapter => bondy_oplog_cache_ets,
            cache_handle => Cache,
            projection_adapter => bondy_oplog_projection_ets,
            projection_handle => Proj,
            fold_module => lww_register,
            overlay => disabled,
            instance_id => Id,
            cell_apply_bucket => ?BUCKET
        },
        Extra
    ),
    ok = bondy_oplog_core_registry:register(NS, primary, 0, Config),
    {Cache, Proj}.

%% @private
pull_snapshot(Id) ->
    {ok, {_W, Cursor}} = bondy_oplog_catalogue_snapshot:init(Id),
    pull_snapshot_loop(Id, Cursor, []).

%% @private
pull_snapshot_loop(Id, Cursor, Acc) ->
    case bondy_oplog_catalogue_snapshot:next(Id, Cursor) of
        {ok, {batch, {NextCursor, Cells}}} ->
            pull_snapshot_loop(Id, NextCursor, Acc ++ Cells);
        {ok, {done, Cells}} ->
            Acc ++ Cells
    end.

%% @private
mk_id(Prefix) ->
    N = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    <<Prefix/binary, "_", N/binary>>.
