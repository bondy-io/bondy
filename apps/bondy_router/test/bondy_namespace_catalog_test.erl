%% =============================================================================
%% Tests for `bondy_namespace_catalog` — the bondy_db DB/table declaration
%% point and owner of the durable `main` database.
%%
%% Pins: the table declarations (db split, aggregate_root routing, fold class),
%% the main/registry DB specs, unconditional provisioning (every declared
%% table opens + appears in bondy_db:info, fold→CRDT wiring), and teardown.
%% =============================================================================

-module(bondy_namespace_catalog_test).

-include_lib("eunit/include/eunit.hrl").

-define(CAT, bondy_namespace_catalog).

%% =============================================================================
%% Pure declaration tests (no setup)
%% =============================================================================

declarations_test_() ->
    Tables = ?CAT:tables(),
    ByName = maps:from_list([{maps:get(name, S), S} || S <- Tables]),
    Main = [S || S <- Tables, maps:get(db, S) =:= main],
    Registry = [S || S <- Tables, maps:get(db, S) =:= registry],
    [
        {"seventeen tables declared", ?_assertEqual(17, length(Tables))},
        {"fifteen main, two registry", fun() ->
            ?assertEqual(15, length(Main)),
            ?assertEqual(2, length(Registry))
        end},
        {"realm_keys is a durable main aw table", fun() ->
            %% Realm key material, split out of the realm identity cell so the
            %% realm's bondy_db identity/digest is Uri + config, not key bytes.
            %% Global registry like bondy_realm; aw-map of
            %% kid => key bundle so concurrent rotations merge without loss.
            Spec = maps:get(bondy_realm_keys, ByName),
            ?assertEqual(main, maps:get(db, Spec)),
            ?assertEqual(durable, maps:get(durability, Spec)),
            ?assertEqual(aw, maps:get(fold, Spec))
        end},
        {"retained_messages is a durable main lww table", fun() ->
            %% Cut over to bondy_db (§11.4): always durable regardless of the
            %% inert `wamp.message_retention.storage_type` knob; storage-only
            %% lww, no secondary index (matched by key).
            Spec = maps:get(retained_messages, ByName),
            ?assertEqual(main, maps:get(db, Spec)),
            ?assertEqual(durable, maps:get(durability, Spec)),
            ?assertEqual(lww, maps:get(fold, Spec)),
            ?assertEqual([], maps:get(indexes, Spec, []))
        end},
        {"group membership is a durable main ew fold (cell-per-fact)", fun() ->
            %% Authoritative cell-per-fact add-wins membership (ew_flag); the
            %% forward + reverse presence cells live here (design §3 / §11).
            Spec = maps:get(security_group_members, ByName),
            ?assertEqual(main, maps:get(db, Spec)),
            ?assertEqual(durable, maps:get(durability, Spec)),
            ?assertEqual(ew, maps:get(fold, Spec)),
            %% Facts co-locate with their leading entity (forward → user shard,
            %% reverse → group shard) so a user's groups / a group's members are
            %% single-shard band scans (`bondy_db:aggregate_root/2`).
            ?assertEqual(second_col, maps:get(aggregate_root, Spec)),
            ?assertEqual(true, maps:get(publish, Spec, false))
        end},
        {"no table declares the retired shard_by key", fun() ->
            %% shard_by was declared/frozen but never consumed by routing
            %% (partition_strategy + aggregate_root is the placement model);
            %% it was deleted — pin that it never reappears in a spec.
            ?assert(
                lists:all(
                    fun(S) -> not maps:is_key(shard_by, S) end, Tables
                )
            )
        end},
        {"grants + source cut as lww", fun() ->
            %% grants + source declared mv but cut as lww per the CRDT-fork
            %% resolution (honouring mv is deferred to db.aae).
            ?assertEqual(lww, fold(ByName, security_group_grants)),
            ?assertEqual(lww, fold(ByName, security_user_grants)),
            ?assertEqual(lww, fold(ByName, security_sources))
        end},
        {"RIB tables are ephemeral CRDT cells, published, no indexes", fun() ->
            %% The replicated routing summary cells: per-field CRDT deltas
            %% (count/invoke/earliest/latest), single-writer-per-key so no
            %% cross-origin merge conflict; `publish => true` readies
            %% merge-side reactor consumption; point-read by cell key only,
            %% so no secondary index.
            ?assert(
                lists:all(
                    fun({S, ExpectedFold}) ->
                        maps:get(fold, S) =:= ExpectedFold andalso
                            maps:get(durability, S) =:= ephemeral andalso
                            maps:get(publish, S, false) =:= true andalso
                            [] =:= maps:get(indexes, S, [])
                    end,
                    [
                        {
                            maps:get(bondy_registration_rib, ByName),
                            rib_registration
                        },
                        {
                            maps:get(bondy_subscription_rib, ByName),
                            rib_subscription
                        }
                    ]
                )
            )
        end},
        {"main_db_spec: shared_shards, durable, default shards", fun() ->
            Spec = ?CAT:main_db_spec(),
            ?assertMatch(
                #{
                    name := main,
                    topology := bondy_db_topology_shared_shards,
                    durability := durable,
                    shard_count := 16
                },
                Spec
            )
        end},
        {"registry_db_spec: memory, ephemeral, four ephemeral knobs", fun() ->
            #{
                topology := Topology,
                durability := Durability,
                table_opts := TOpts
            } = ?CAT:registry_db_spec(),
            ?assertEqual(bondy_db_topology_memory, Topology),
            ?assertEqual(ephemeral, Durability),
            ?assertMatch(
                #{
                    projection_backend := ets,
                    fused := true,
                    oplog_instance_opts := #{
                        backend := ets,
                        wal_backend := mem,
                        durability := ephemeral
                    }
                },
                TOpts
            )
        end}
    ].

%% =============================================================================
%% Lifecycle tests (need the substrate)
%% =============================================================================

lifecycle_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(bondy_db),
            ok
        end,
        fun(_) -> ok end, [
            {timeout, 60,
                {"provisions every declared table", fun provisions_all/0}}
        ]}.

provisions_all() ->
    Tmp = make_tmpdir(),
    set_env(1, Tmp),
    {ok, Pid} = ?CAT:start_link(),
    try
        %% Main DB + every declared main table provisioned and published —
        %% unconditionally, there is no per-table or per-domain gate.
        ?assert(?CAT:is_open()),
        ?assertMatch(#{name := main}, ?CAT:main_db()),
        ?assertMatch(
            #{kind := db, name := main}, bondy_db:info(?CAT:main_db())
        ),
        MainNames = [
            maps:get(name, S)
         || S <- ?CAT:tables(), maps:get(db, S) =:= main
        ],
        lists:foreach(
            fun(Name) ->
                ?assertMatch(
                    #{entity_type := Name, db_name := main},
                    ?CAT:table(Name)
                )
            end,
            MainNames
        ),
        %% The RIB summary tables (D-7) are provisioned in the ephemeral
        %% `registry` DB.
        ?assertMatch(
            #{entity_type := bondy_registration_rib, db_name := registry},
            ?CAT:table(bondy_registration_rib)
        ),
        ?assertMatch(
            #{entity_type := bondy_subscription_rib, db_name := registry},
            ?CAT:table(bondy_subscription_rib)
        ),
        %% Fold → CRDT wiring: the membership table carries the ew_flag CRDT
        %% (cell-per-fact add-wins); lww tables resolve to lww_register. (No mv
        %% table is provisioned — grants + sources were cut as lww per the
        %% CRDT-fork resolution.)
        ?assertMatch(
            #{crdt_module := bondy_oplog_crdt_ew_flag},
            bondy_db:info(?CAT:table(security_group_members))
        ),
        ?assertMatch(
            #{fold_module := lww_register},
            bondy_db:info(?CAT:table(bondy_realm))
        ),
        ?assertMatch(
            #{fold_module := lww_register},
            bondy_db:info(?CAT:table(security_sources))
        ),
        %% RIB tables register the generic CRDT toolkit modules directly (no
        %% per-use-case wrapper) — registration_rib carries its schema as
        %% crdt_opts (bondy_oplog_crdt_struct has none of its own).
        ?assertMatch(
            #{
                crdt_module := bondy_oplog_crdt_struct,
                crdt_opts := #{
                    count := _, invoke := _, earliest := _, latest := _
                }
            },
            bondy_db:info(?CAT:table(bondy_registration_rib))
        ),
        ?assertMatch(
            #{crdt_module := bondy_oplog_crdt_pn_counter},
            bondy_db:info(?CAT:table(bondy_subscription_rib))
        ),
        %% info/0 summary.
        Info = ?CAT:info(),
        ?assertMatch(#{main := #{kind := db}}, Info),
        %% info/0's tables map covers the main DB tables only.
        ?assertEqual(15, map_size(maps:get(tables, Info)))
    after
        ok = stop_catalog(Pid),
        reset_env(),
        rmrf(Tmp)
    end,
    %% Teardown cleared the published handles.
    ?assert(await(fun() -> ?CAT:is_open() =:= false end, 100)),
    ?assertEqual(undefined, ?CAT:main_db()),
    ?assertEqual(undefined, ?CAT:table(bondy_realm)).

%% =============================================================================
%% Helpers
%% =============================================================================

fold(ByName, Name) ->
    maps:get(fold, maps:get(Name, ByName)).

set_env(Shards, Dir) ->
    ok = bondy_db_config:set([databases, main, oplog, shard_count], Shards),
    application:set_env(bondy_router, platform_data_dir, Dir).

reset_env() ->
    ok = bondy_db_config:set([databases, main, oplog, shard_count], 16),
    application:unset_env(bondy_router, platform_data_dir).

stop_catalog(Pid) ->
    _ =
        try
            gen_server:stop(Pid, normal, 30000)
        catch
            _:_ -> ok
        end,
    ok.

make_tmpdir() ->
    Base = filename:join(
        "/tmp/" ++ os:getpid(),
        "bondy_catalog_test_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = filelib:ensure_path(Base),
    Base.

rmrf(Dir) ->
    _ = file:del_dir_r(Dir),
    ok.

%% Poll a predicate up to ~1s — teardown of leveled instances is async.
await(_Pred, 0) ->
    false;
await(Pred, N) ->
    case Pred() of
        true ->
            true;
        false ->
            timer:sleep(10),
            await(Pred, N - 1)
    end.
