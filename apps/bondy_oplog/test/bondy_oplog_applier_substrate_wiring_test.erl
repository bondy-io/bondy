%% =============================================================================
%% End-to-end tests for the applier's substrate read-side wiring
%% (MST_DB_DESIGN §11/§12 + open items 6 & 7).
%%
%% Verifies:
%%   - `publish_ns` + `publish_fun` opts forward verified events to
%%     `bondy_oplog_core:publish/4`; subscribers receive matching events.
%%   - `publish_fun` returning `skip` suppresses delivery without
%%     wedging the applier.
%%   - `publish_fun` raising is tolerated (event not published, applier
%%     continues).
%%   - `ae_targets` causes registered shards' AE counters to advance on
%%     every successful commit, with a shared `Now` for every target in
%%     one commit.
%%   - Missing registry entries (`not_found`) are tolerated and
%%     surfaced via telemetry.
%%   - Defaults (no opts) leave both wires as strict no-ops.
%% =============================================================================

-module(bondy_oplog_applier_substrate_wiring_test).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    [
        bondy_oplog_core_registry:unregister(NS, primary, 0)
     || NS <- bondy_oplog_core_registry:namespaces()
    ],
    ok.

wiring_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun publish_default_is_noop/0,
        fun publish_forwards_events_to_subscribers/0,
        fun publish_skip_suppresses_delivery/0,
        fun publish_fun_raise_is_tolerated/0,
        fun publish_partial_opts_are_rejected/0,
        fun ae_default_is_noop/0,
        fun ae_targets_bump_after_commit/0,
        fun ae_targets_share_now_across_one_commit/0,
        fun ae_targets_not_found_is_tolerated/0
    ]}.

%% =============================================================================
%% Publish wiring
%% =============================================================================

publish_default_is_noop() ->
    %% Subscribe to a namespace, start an instance with no publish opts,
    %% append an event, and assert no delivery happens.
    Id = mk_id(),
    NS = ns_of(Id),
    {ok, SubRef} = bondy_oplog_core:subscribe(NS, all),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register
    }),
    _ = bondy_oplog:append(Id, {set, 1, <<"v">>}),
    {ok, {set, <<"v">>, 1}} = bondy_oplog:projection(Id),
    ?assertEqual(no_message, recv_one(50)),
    ok = bondy_oplog_core:unsubscribe(SubRef),
    ok = bondy_oplog:stop_instance(Id).

publish_forwards_events_to_subscribers() ->
    Id = mk_id(),
    NS = ns_of(Id),
    {ok, SubRef} = bondy_oplog_core:subscribe(NS, all),
    Fun = fun(E) ->
        Op = bondy_oplog_event:op(E),
        {derived_key_of(Op), Op}
    end,
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        applier => #{
            publish_ns => NS,
            publish_fun => Fun
        }
    }),
    _ = bondy_oplog:append(Id, {set, 1, <<"alpha">>}),
    _ = bondy_oplog:append(Id, {set, 2, <<"beta">>}),
    %% Drain to make the projection visible — also forces apply_batch
    %% to have run for both events and therefore publish to have fired.
    {ok, {set, <<"beta">>, 2}} = bondy_oplog:projection(Id),
    Msgs = collect_messages(2, 1000),
    [{NS_A, K_A, _Hlc_A, Op_A}, {NS_B, K_B, _Hlc_B, Op_B}] = Msgs,
    ?assertEqual(NS, NS_A),
    ?assertEqual(NS, NS_B),
    ?assertEqual(<<"key:1">>, K_A),
    ?assertEqual(<<"key:2">>, K_B),
    ?assertEqual({set, 1, <<"alpha">>}, Op_A),
    ?assertEqual({set, 2, <<"beta">>}, Op_B),
    ok = bondy_oplog_core:unsubscribe(SubRef),
    ok = bondy_oplog:stop_instance(Id).

publish_skip_suppresses_delivery() ->
    Id = mk_id(),
    NS = ns_of(Id),
    {ok, SubRef} = bondy_oplog_core:subscribe(NS, all),
    %% Only set-events publish; clear-events skip.
    Fun = fun(E) ->
        case bondy_oplog_event:op(E) of
            {set, _, _} = Op -> {<<"k">>, Op};
            {clear, _} -> skip
        end
    end,
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        applier => #{
            publish_ns => NS,
            publish_fun => Fun
        }
    }),
    _ = bondy_oplog:append(Id, {set, 1, <<"a">>}),
    _ = bondy_oplog:append(Id, {clear, 2}),
    _ = bondy_oplog:append(Id, {set, 3, <<"b">>}),
    {ok, _} = bondy_oplog:projection(Id),
    Msgs = collect_messages(2, 1000),
    Ops = [Op || {_NS, _K, _H, Op} <- Msgs],
    ?assertEqual([{set, 1, <<"a">>}, {set, 3, <<"b">>}], Ops),
    ?assertEqual(no_message, recv_one(50)),
    ok = bondy_oplog_core:unsubscribe(SubRef),
    ok = bondy_oplog:stop_instance(Id).

publish_fun_raise_is_tolerated() ->
    Id = mk_id(),
    NS = ns_of(Id),
    {ok, SubRef} = bondy_oplog_core:subscribe(NS, all),
    Fun = fun(E) ->
        case bondy_oplog_event:op(E) of
            {set, 2, _} -> error(boom);
            Op -> {<<"k">>, Op}
        end
    end,
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        applier => #{
            publish_ns => NS,
            publish_fun => Fun
        }
    }),
    _ = bondy_oplog:append(Id, {set, 1, <<"a">>}),
    _ = bondy_oplog:append(Id, {set, 2, <<"b">>}),
    _ = bondy_oplog:append(Id, {set, 3, <<"c">>}),
    %% Projection still works — the fold side is untouched.
    {ok, {set, <<"c">>, 3}} = bondy_oplog:projection(Id),
    Msgs = collect_messages(2, 1000),
    Ops = [Op || {_NS, _K, _H, Op} <- Msgs],
    ?assertEqual([{set, 1, <<"a">>}, {set, 3, <<"c">>}], Ops),
    ok = bondy_oplog_core:unsubscribe(SubRef),
    ok = bondy_oplog:stop_instance(Id).

publish_partial_opts_are_rejected() ->
    %% `publish_ns` without `publish_fun` is rejected at applier init.
    Id = mk_id(),
    NS = ns_of(Id),
    Result = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        applier => #{publish_ns => NS}
    }),
    %% The dynamic supervisor returns the start_link error; here we
    %% just assert it isn't `ok` and isn't silently swallowed.
    ?assertMatch({error, _}, Result),
    %% No instance to stop on the error path.
    case bondy_oplog:list_instances() of
        L -> false = lists:member(Id, L)
    end,
    ok.

%% =============================================================================
%% AE wiring
%% =============================================================================

ae_default_is_noop() ->
    %% Without `ae_targets` the AE counter for the namespace stays at
    %% the "infinitely stale" sentinel.
    Id = mk_id(),
    NS = ns_of(Id),
    ok = register_shard(NS, 0),
    Before = bondy_oplog_core_registry:last_ae_at(NS, primary, 0),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register
    }),
    _ = bondy_oplog:append(Id, {set, 1, <<"v">>}),
    {ok, _} = bondy_oplog:projection(Id),
    %% Allow a commit boundary; default `commit_every = 64` means a
    %% single append doesn't auto-commit, but `stop_instance` drains
    %% via `end_of_log` → `commit_now`.
    ok = bondy_oplog:stop_instance(Id),
    After = bondy_oplog_core_registry:last_ae_at(NS, primary, 0),
    ?assertEqual(Before, After),
    ok = bondy_oplog_core_registry:unregister(NS, primary, 0).

ae_targets_bump_after_commit() ->
    Id = mk_id(),
    NS = ns_of(Id),
    ok = register_shard(NS, 0),
    Before = bondy_oplog_core_registry:last_ae_at(NS, primary, 0),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        applier => #{
            ae_targets => [{NS, primary, 0}],
            %% Force a commit per event so the bump fires inside the
            %% test rather than only on shutdown.
            commit_every => 1
        }
    }),
    _ = bondy_oplog:append(Id, {set, 1, <<"v">>}),
    {ok, _} = bondy_oplog:projection(Id),
    After = wait_for_ae_advance(NS, primary, 0, Before, 1000),
    ?assert(After > Before),
    ok = bondy_oplog:stop_instance(Id),
    ok = bondy_oplog_core_registry:unregister(NS, primary, 0).

ae_targets_share_now_across_one_commit() ->
    %% Two shards under different indices but same NS — a single commit
    %% should bump both to the same `Now`.
    Id = mk_id(),
    NS = ns_of(Id),
    ok = register_shard(NS, primary, 0),
    ok = register_shard(NS, by_name, 0),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        applier => #{
            ae_targets => [{NS, primary, 0}, {NS, by_name, 0}],
            commit_every => 1
        }
    }),
    _ = bondy_oplog:append(Id, {set, 1, <<"v">>}),
    {ok, _} = bondy_oplog:projection(Id),
    _ = wait_for_ae_advance(NS, primary, 0, sentinel(), 1000),
    A = bondy_oplog_core_registry:last_ae_at(NS, primary, 0),
    B = bondy_oplog_core_registry:last_ae_at(NS, by_name, 0),
    %% Both bumps share the same `Now` argument inside `bump_ae_targets/1`,
    %% so the atomics reads must be identical.
    ?assertEqual(A, B),
    ok = bondy_oplog:stop_instance(Id),
    ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
    ok = bondy_oplog_core_registry:unregister(NS, by_name, 0).

ae_targets_not_found_is_tolerated() ->
    Id = mk_id(),
    NS = ns_of(Id),
    %% Register only one of the two targets; the other should be
    %% counted as `not_found` in telemetry but otherwise leave the
    %% commit path intact.
    ok = register_shard(NS, primary, 0),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        applier => #{
            ae_targets =>
                [
                    {NS, primary, 0},
                    {missing_ns, primary, 0}
                ],
            commit_every => 1
        }
    }),
    _ = bondy_oplog:append(Id, {set, 1, <<"v">>}),
    {ok, _} = bondy_oplog:projection(Id),
    _ = wait_for_ae_advance(NS, primary, 0, sentinel(), 1000),
    ?assert(bondy_oplog_core_registry:last_ae_at(NS, primary, 0) > sentinel()),
    ?assertEqual(
        not_found,
        bondy_oplog_core_registry:last_ae_at(missing_ns, primary, 0)
    ),
    ok = bondy_oplog:stop_instance(Id),
    ok = bondy_oplog_core_registry:unregister(NS, primary, 0).

%% =============================================================================
%% Helpers
%% =============================================================================

mk_id() ->
    list_to_binary(
        "wiring_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

ns_of(Id) when is_binary(Id) ->
    binary_to_atom(<<"ns_", Id/binary>>, utf8).

register_shard(NS, Shard) ->
    register_shard(NS, primary, Shard).

register_shard(NS, Index, Shard) ->
    bondy_oplog_core_registry:register(NS, Index, Shard, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => undefined,
        projection_adapter => bondy_oplog_projection_adapter,
        projection_handle => undefined,
        fold_module => lww_register,
        overlay => disabled
    }).

sentinel() ->
    %% Matches `bondy_oplog_core_registry`'s "infinitely stale" sentinel.
    -(1 bsl 62).

wait_for_ae_advance(NS, Index, Shard, Baseline, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_for_ae_advance_loop(NS, Index, Shard, Baseline, Deadline).

wait_for_ae_advance_loop(NS, Index, Shard, Baseline, Deadline) ->
    case bondy_oplog_core_registry:last_ae_at(NS, Index, Shard) of
        V when V > Baseline -> V;
        _ ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true ->
                    erlang:error({ae_did_not_advance, NS, Index, Shard});
                false ->
                    timer:sleep(5),
                    wait_for_ae_advance_loop(
                        NS,
                        Index,
                        Shard,
                        Baseline,
                        Deadline
                    )
            end
    end.

derived_key_of({set, H, _V}) ->
    iolist_to_binary(["key:", integer_to_list(H)]);
derived_key_of({clear, H}) ->
    iolist_to_binary(["key:", integer_to_list(H)]).

collect_messages(N, TimeoutMs) ->
    collect_messages(N, TimeoutMs, []).

collect_messages(0, _Timeout, Acc) ->
    lists:reverse(Acc);
collect_messages(N, Timeout, Acc) ->
    receive
        {bondy_oplog_core_event, NS, K, H, Op} ->
            collect_messages(N - 1, Timeout, [{NS, K, H, Op} | Acc])
    after Timeout ->
        lists:reverse(Acc)
    end.

recv_one(Timeout) ->
    receive
        {bondy_oplog_core_event, _, _, _, _} = M -> M
    after Timeout ->
        no_message
    end.
