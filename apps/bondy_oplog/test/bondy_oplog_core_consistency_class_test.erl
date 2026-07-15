%% =============================================================================
%% Tests for the per-namespace `consistency_class` policy
%% (`MST_DB_DESIGN.md` §15, §18 item 13).
%%
%% Verifies:
%%   - default class is `ap` when not specified at register time
%%   - an explicit `cp` or `ap` is stored and retrievable
%%   - an invalid class is rejected at register
%%   - `eventual` reads on a `cp` namespace return a violation
%%   - `causal` and `snapshot` reads on a `cp` namespace pass
%%   - `eventual` reads on an `ap` namespace pass
%%   - a batch spanning ap+cp namespaces with `eventual` consistency is
%%     rejected because at least one namespace is `cp`
%% =============================================================================

-module(bondy_oplog_core_consistency_class_test).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    ok.

class_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun default_class_is_ap/0,
        fun explicit_cp_is_stored/0,
        fun explicit_ap_is_stored/0,
        fun invalid_class_is_rejected/0,
        fun unknown_namespace_returns_ap/0,
        fun eventual_on_cp_is_rejected/0,
        fun causal_on_cp_passes/0,
        fun snapshot_on_cp_passes/0,
        fun eventual_on_ap_passes/0,
        fun mixed_batch_with_cp_member_is_rejected/0
    ]}.

%% =============================================================================
%% Registry behaviour
%% =============================================================================

default_class_is_ap() ->
    NS = mk_ns(),
    {Setup, _} = setup_shard(NS, primary, 0, #{}),
    ?assertEqual(ap, bondy_oplog_core_registry:consistency_class(NS)),
    {ok, Entry} = bondy_oplog_core_registry:lookup(NS, primary, 0),
    ?assertEqual(ap, bondy_oplog_core_registry:entry_consistency_class(Entry)),
    teardown_shard(Setup).

explicit_cp_is_stored() ->
    NS = mk_ns(),
    {Setup, _} = setup_shard(NS, primary, 0, #{consistency_class => cp}),
    ?assertEqual(cp, bondy_oplog_core_registry:consistency_class(NS)),
    teardown_shard(Setup).

explicit_ap_is_stored() ->
    NS = mk_ns(),
    {Setup, _} = setup_shard(NS, primary, 0, #{consistency_class => ap}),
    ?assertEqual(ap, bondy_oplog_core_registry:consistency_class(NS)),
    teardown_shard(Setup).

invalid_class_is_rejected() ->
    NS = mk_ns(),
    Result = bondy_oplog_core_registry:register(
        NS, primary, 0, (base_config())#{
            consistency_class => not_a_real_class
        }
    ),
    ?assertEqual(
        {error, {invalid_consistency_class, not_a_real_class}},
        Result
    ).

unknown_namespace_returns_ap() ->
    ?assertEqual(ap, bondy_oplog_core_registry:consistency_class(no_such_ns_x)).

%% =============================================================================
%% Read enforcement
%% =============================================================================

eventual_on_cp_is_rejected() ->
    NS = mk_ns(),
    {Setup, _} = setup_shard(NS, primary, 0, #{consistency_class => cp}),
    Reads = [{NS, primary, <<>>, <<"k">>}],
    Result = bondy_oplog_core:read_batch(Reads, #{consistency => eventual}),
    ?assertMatch(
        {error, {consistency_class_violation, NS, cp, eventual}},
        Result
    ),
    teardown_shard(Setup).

causal_on_cp_passes() ->
    NS = mk_ns(),
    {Setup, _} = setup_shard(NS, primary, 0, #{consistency_class => cp}),
    Reads = [{NS, primary, <<>>, <<"k">>}],
    %% causal + infinity max_lag = always passes the freshness check.
    Result = bondy_oplog_core:read_batch(Reads, #{
        consistency => causal, max_lag => infinity
    }),
    ?assertMatch({ok, _, _}, Result),
    teardown_shard(Setup).

snapshot_on_cp_passes() ->
    NS = mk_ns(),
    {Setup, _} = setup_shard(NS, primary, 0, #{consistency_class => cp}),
    Reads = [{NS, primary, <<>>, <<"k">>}],
    Result = bondy_oplog_core:read_batch(Reads, #{
        consistency => snapshot, max_lag => infinity
    }),
    ?assertMatch({ok, _, _}, Result),
    teardown_shard(Setup).

eventual_on_ap_passes() ->
    NS = mk_ns(),
    {Setup, _} = setup_shard(NS, primary, 0, #{consistency_class => ap}),
    Reads = [{NS, primary, <<>>, <<"k">>}],
    Result = bondy_oplog_core:read_batch(Reads, #{consistency => eventual}),
    ?assertMatch({ok, _, _}, Result),
    teardown_shard(Setup).

mixed_batch_with_cp_member_is_rejected() ->
    NSA = mk_ns(),
    NSB = mk_ns(),
    {SetupA, _} = setup_shard(NSA, primary, 0, #{consistency_class => ap}),
    {SetupB, _} = setup_shard(NSB, primary, 0, #{consistency_class => cp}),
    Reads = [{NSA, primary, <<>>, <<"a">>}, {NSB, primary, <<>>, <<"b">>}],
    Result = bondy_oplog_core:read_batch(Reads, #{consistency => eventual}),
    ?assertMatch(
        {error, {consistency_class_violation, NSB, cp, eventual}},
        Result
    ),
    teardown_shard(SetupA),
    teardown_shard(SetupB).

%% =============================================================================
%% Helpers
%% =============================================================================

mk_ns() ->
    list_to_atom(
        "mst_class_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

base_config() ->
    %% Minimum config that passes validation.
    {ok, CH} = bondy_oplog_cache_ets:init(no_ns, primary, 0, #{}),
    {ok, PH} = bondy_oplog_projection_ets:open(no_ns, primary, 0, #{}),
    OV = bondy_oplog_db_overlay:new(),
    #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => CH,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => PH,
        overlay => OV,
        fold_module => lww_register
    }.

setup_shard(NS, Index, Shard, ExtraConfig) ->
    {ok, CH} = bondy_oplog_cache_ets:init(NS, Index, Shard, #{}),
    {ok, PH} = bondy_oplog_projection_ets:open(NS, Index, Shard, #{}),
    OV = bondy_oplog_db_overlay:new(),
    Config = maps:merge(
        #{
            shard_count => 1,
            cache_adapter => bondy_oplog_cache_ets,
            cache_handle => CH,
            projection_adapter => bondy_oplog_projection_ets,
            projection_handle => PH,
            overlay => OV,
            fold_module => lww_register
        },
        ExtraConfig
    ),
    ok = bondy_oplog_core_registry:register(NS, Index, Shard, Config),
    Setup = #{
        ns => NS,
        index => Index,
        shard => Shard,
        cache_handle => CH,
        projection => PH,
        overlay => OV
    },
    {Setup, Setup}.

teardown_shard(#{
    ns := NS,
    index := Index,
    shard := Shard,
    cache_handle := CH,
    projection := PH,
    overlay := OV
}) ->
    ok = bondy_oplog_core_registry:unregister(NS, Index, Shard),
    ok = bondy_oplog_cache_ets:close(CH),
    ok = bondy_oplog_projection_ets:close(PH),
    ok = bondy_oplog_db_overlay:delete(OV).
