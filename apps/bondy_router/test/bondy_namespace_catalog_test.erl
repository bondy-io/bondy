%% =============================================================================
%% Tests for `bondy_namespace_catalog` — the bondy_db DB/table declaration
%% point and owner of the durable `core` database.
%%
%% Pins: the twelve-table declaration (db split, shard_by mapping, fold class),
%% the core/registry DB specs, gated provisioning (core tables open + appear in
%% bondy_db:info, fold→CRDT wiring), the disabled no-op path, and teardown.
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
    Core = [S || S <- Tables, maps:get(db, S) =:= core],
    Registry = [S || S <- Tables, maps:get(db, S) =:= registry],
    [
        {"fifteen tables declared", ?_assertEqual(15, length(Tables))},
        {"thirteen core, two registry", fun() ->
            ?assertEqual(13, length(Core)),
            ?assertEqual(2, length(Registry))
        end},
        {"realm_keys is a durable core aw table sharded by key", fun() ->
            %% Realm key material, split out of the realm identity cell so the
            %% realm's bondy_db identity/digest is Uri + config, not key bytes.
            %% Global registry like bondy_realm (key-sharded); aw-map of
            %% kid => key bundle so concurrent rotations merge without loss.
            Spec = maps:get(bondy_realm_keys, ByName),
            ?assertEqual(core, maps:get(db, Spec)),
            ?assertEqual(durable, maps:get(durability, Spec)),
            ?assertEqual(key, maps:get(shard_by, Spec)),
            ?assertEqual(aw, maps:get(fold, Spec)),
            ?assertEqual(true, maps:get(migrated, Spec, false))
        end},
        {"retained_messages is a durable core lww migrated table", fun() ->
            %% Cut over to bondy_db (§11.4): always durable regardless of the
            %% inert `wamp.message_retention.storage_type` knob; storage-only
            %% lww, always provisioned, no secondary index (matched by key).
            Spec = maps:get(retained_messages, ByName),
            ?assertEqual(core, maps:get(db, Spec)),
            ?assertEqual(durable, maps:get(durability, Spec)),
            ?assertEqual(realm, maps:get(shard_by, Spec)),
            ?assertEqual(lww, maps:get(fold, Spec)),
            ?assertEqual(true, maps:get(migrated, Spec, false)),
            ?assertEqual([], maps:get(indexes, Spec, []))
        end},
        {"group membership is a durable core ew fold (cell-per-fact)", fun() ->
            %% Authoritative cell-per-fact add-wins membership (ew_flag); the
            %% forward + reverse presence cells live here (design §3 / §11).
            Spec = maps:get(security_group_members, ByName),
            ?assertEqual(core, maps:get(db, Spec)),
            ?assertEqual(durable, maps:get(durability, Spec)),
            ?assertEqual(realm, maps:get(shard_by, Spec)),
            ?assertEqual(ew, maps:get(fold, Spec)),
            %% Facts co-locate with their leading entity (forward → user shard,
            %% reverse → group shard) so a user's groups / a group's members are
            %% single-shard band scans (`bondy_db:aggregate_root/2`).
            ?assertEqual(second_col, maps:get(aggregate_root, Spec)),
            ?assertEqual(true, maps:get(migrated, Spec, false)),
            ?assertEqual(true, maps:get(publish, Spec, false))
        end},
        {"ticket/oauth_token/realm(+keys) shard by key", fun() ->
            %% ticket/oauth_token prioritise point lookup; bondy_realm and
            %% bondy_realm_keys are global registries under one band, so
            %% realm-sharding would be degenerate (every realm on one shard) —
            %% they shard by key.
            ?assertEqual(key, shard_by(ByName, bondy_ticket)),
            ?assertEqual(key, shard_by(ByName, bondy_oauth_token)),
            ?assertEqual(key, shard_by(ByName, bondy_realm)),
            ?assertEqual(key, shard_by(ByName, bondy_realm_keys))
        end},
        {"all other tables shard by realm", fun() ->
            Others = [
                S
             || S <- Tables,
                not lists:member(
                    maps:get(name, S),
                    [
                        bondy_ticket,
                        bondy_oauth_token,
                        bondy_realm,
                        bondy_realm_keys
                    ]
                )
            ],
            ?assert(
                lists:all(
                    fun(S) -> maps:get(shard_by, S) =:= realm end, Others
                )
            )
        end},
        {"grants + source cut as lww", fun() ->
            %% grants + source declared mv but cut as lww per the CRDT-fork
            %% resolution (honouring mv is deferred to oplog.aae).
            ?assertEqual(lww, fold(ByName, security_group_grants)),
            ?assertEqual(lww, fold(ByName, security_user_grants)),
            ?assertEqual(lww, fold(ByName, security_sources))
        end},
        {"registry tables are ephemeral lww, migrated, published, by_session",
            fun() ->
                %% Cut over to bondy_db (D-7): `lww` IS the presence state machine
                %% (keys unique by SessionId — set=live, clear=dead), provisioned
                %% (`migrated`), `publish => true` wires the merge-side reactor that
                %% maintains the routing trie from peers' registrations (§9.6), with
                %% the `by_session` reverse index for session-close cleanup.
                ?assert(
                    lists:all(
                        fun(S) ->
                            maps:get(fold, S) =:= lww andalso
                                maps:get(durability, S) =:= ephemeral andalso
                                maps:get(migrated, S, false) =:= true andalso
                                maps:get(publish, S, false) =:= true andalso
                                [by_session] =:=
                                    [
                                        bondy_oplog_index_spec:name(I)
                                     || I <- maps:get(indexes, S, [])
                                    ]
                        end,
                        Registry
                    )
                )
            end},
        {"core_db_spec: shared_shards, durable, default shards", fun() ->
            Spec = ?CAT:core_db_spec(),
            ?assertMatch(
                #{
                    name := core,
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
                {"provision_all opens every core table", fun provision_all/0}},
            {timeout, 60,
                {"default provisions only migrated tables",
                    fun migrated_only/0}},
            {timeout, 60,
                {"registry by_session index works end-to-end",
                    fun registry_index/0}}
        ]}.

provision_all() ->
    Tmp = make_tmpdir(),
    set_env(true, 1, Tmp),
    {ok, Pid} = ?CAT:start_link(),
    try
        %% Core DB + all twelve core tables provisioned and published.
        ?assert(?CAT:is_open()),
        ?assertMatch(#{name := core}, ?CAT:core_db()),
        ?assertMatch(
            #{kind := db, name := core}, bondy_db:info(?CAT:core_db())
        ),
        CoreNames = [
            maps:get(name, S)
         || S <- ?CAT:tables(), maps:get(db, S) =:= core
        ],
        lists:foreach(
            fun(Name) ->
                ?assertMatch(
                    #{entity_type := Name, db_name := core},
                    ?CAT:table(Name)
                )
            end,
            CoreNames
        ),
        %% Registry tables (migrated, D-7) are provisioned in the ephemeral
        %% `registry` DB, independently of the `oplog.catalog` flag.
        ?assertMatch(
            #{entity_type := bondy_registration, db_name := registry},
            ?CAT:table(bondy_registration)
        ),
        ?assertMatch(
            #{entity_type := bondy_subscription, db_name := registry},
            ?CAT:table(bondy_subscription)
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
        %% info/0 summary.
        Info = ?CAT:info(),
        ?assertMatch(#{provision_all := true, core := #{kind := db}}, Info),
        ?assertEqual(13, map_size(maps:get(tables, Info)))
    after
        ok = stop_catalog(Pid),
        reset_env(),
        rmrf(Tmp)
    end,
    %% Teardown cleared the published handles.
    ?assert(await(fun() -> ?CAT:is_open() =:= false end, 100)),
    ?assertEqual(undefined, ?CAT:core_db()),
    ?assertEqual(undefined, ?CAT:table(bondy_realm)).

%% Default (flag off): only the migrated domains' tables (api_gateway,
%% bondy_realm, bondy_bridge_relay, bondy_ticket, bondy_oauth_token,
%% security_users, security_groups, security_group_members, security_user_grants,
%% security_group_grants, security_sources, retained_messages) are opened; the
%% core DB still comes up to host them, but any not-yet-migrated table stays shut.
migrated_only() ->
    Tmp = make_tmpdir(),
    set_env(false, 1, Tmp),
    {ok, Pid} = ?CAT:start_link(),
    try
        ?assert(?CAT:is_open()),
        ?assertMatch(
            #{entity_type := bondy_realm, db_name := core},
            ?CAT:table(bondy_realm)
        ),
        ?assertMatch(
            #{entity_type := api_gateway, db_name := core},
            ?CAT:table(api_gateway)
        ),
        ?assertMatch(
            #{entity_type := bondy_bridge_relay, db_name := core},
            ?CAT:table(bondy_bridge_relay)
        ),
        ?assertMatch(
            #{entity_type := bondy_ticket, db_name := core},
            ?CAT:table(bondy_ticket)
        ),
        ?assertMatch(
            #{entity_type := bondy_oauth_token, db_name := core},
            ?CAT:table(bondy_oauth_token)
        ),
        ?assertMatch(
            #{entity_type := security_users, db_name := core},
            ?CAT:table(security_users)
        ),
        ?assertMatch(
            #{entity_type := security_groups, db_name := core},
            ?CAT:table(security_groups)
        ),
        ?assertMatch(
            #{entity_type := security_user_grants, db_name := core},
            ?CAT:table(security_user_grants)
        ),
        ?assertMatch(
            #{entity_type := security_group_grants, db_name := core},
            ?CAT:table(security_group_grants)
        ),
        ?assertMatch(
            #{entity_type := security_sources, db_name := core},
            ?CAT:table(security_sources)
        ),
        ?assertMatch(
            #{entity_type := retained_messages, db_name := core},
            ?CAT:table(retained_messages)
        ),
        %% Registry tables (migrated, D-7) come up in the ephemeral `registry`
        %% DB even with the `oplog.catalog` flag off.
        ?assertMatch(
            #{entity_type := bondy_registration, db_name := registry},
            ?CAT:table(bondy_registration)
        ),
        ?assertMatch(
            #{entity_type := bondy_subscription, db_name := registry},
            ?CAT:table(bondy_subscription)
        ),
        %% security_group_members is now a migrated domain (the authoritative
        %% cell-per-fact membership relation), so it is opened even with the
        %% `oplog.catalog` flag off.
        ?assertMatch(
            #{entity_type := security_group_members, db_name := core},
            ?CAT:table(security_group_members)
        ),
        ?assertMatch(
            #{provision_all := false, core := #{kind := db}}, ?CAT:info()
        )
    after
        ok = stop_catalog(Pid),
        reset_env(),
        rmrf(Tmp)
    end.

%% Drives the ephemeral `registry` table exactly as `bondy_registry_store`
%% does — `entry_id` primary key, the `#{session_id, entry}` cell value, the
%% `by_session` reverse index — asserting the storage swap's load-bearing
%% behaviour end-to-end through the provisioned catalogue.
registry_index() ->
    Tmp = make_tmpdir(),
    set_env(false, 1, Tmp),
    {ok, Pid} = ?CAT:start_link(),
    try
        Table = ?CAT:table(bondy_registration),
        ?assertMatch(#{db_name := registry}, Table),
        Realm = <<"com.example">>,
        S1 = <<"session-1">>,
        S2 = <<"session-2">>,

        %% Two entries for S1, one for S2, one session-less (undefined).
        ok = put_entry(Table, Realm, 1, S1),
        ok = put_entry(Table, Realm, 2, S1),
        ok = put_entry(Table, Realm, 3, S2),
        ok = put_entry(Table, Realm, 4, undefined),
        ok = bondy_db:await_index(Table, by_session),

        %% by_session resolves each session's primary keys (the entry_ids).
        ?assertEqual([1, 2], session_ids(Table, Realm, S1)),
        ?assertEqual([3], session_ids(Table, Realm, S2)),
        %% A session-less (undefined) entry is stored but NOT indexed (the index
        %% skips an undefined term), so it appears under no session — the store
        %% resolves such entries via a realm scan, never `index_get`.
        ?assertMatch(
            {ok, {#{session_id := undefined}, _}},
            bondy_db:read(Table, Realm, dbkey(4))
        ),
        ?assertNot(lists:member(4, session_ids(Table, Realm, S1))),
        ?assertNot(lists:member(4, session_ids(Table, Realm, S2))),

        %% Point read returns the wrapped cell value verbatim.
        ?assertMatch(
            {ok, {#{session_id := S1, entry := {fake, 1}}, _Hlc}},
            bondy_db:read(Table, Realm, dbkey(1))
        ),

        %% Clearing an entry drops it from the primary AND every index order.
        ok = bondy_db:apply(Table, Realm, dbkey(1), clear),
        ok = bondy_db:await_index(Table, by_session),
        ?assertEqual({error, not_found}, bondy_db:read(Table, Realm, dbkey(1))),
        ?assertEqual([2], session_ids(Table, Realm, S1)),

        %% Realm isolation: the memory topology buckets by realm, so the same
        %% entry_id in another realm is an independent cell, and the by_session
        %% index restricts to the queried realm.
        Realm2 = <<"com.other">>,
        ok = put_entry(Table, Realm2, 2, S2),
        ok = bondy_db:await_index(Table, by_session),
        ?assertMatch(
            {ok, {#{entry := {fake, 2}}, _}},
            bondy_db:read(Table, Realm, dbkey(2))
        ),
        ?assertEqual([2], session_ids(Table, Realm2, S2)),
        ?assertEqual([], session_ids(Table, Realm2, S1))
    after
        ok = stop_catalog(Pid),
        reset_env(),
        rmrf(Tmp)
    end.

%% @private
put_entry(Table, Realm, EntryId, SessionId) ->
    Value = #{session_id => SessionId, entry => {fake, EntryId}},
    bondy_db:apply(Table, Realm, dbkey(EntryId), {set, Value}).

%% @private
dbkey(EntryId) ->
    term_to_binary(EntryId).

%% @private
%% The entry_ids (decoded primary keys) a session indexes to, sorted.
session_ids(Table, Realm, SessionId) ->
    {ok, Hits} = bondy_db:index_get(Table, Realm, by_session, SessionId, #{}),
    lists:sort([binary_to_term(PKey) || {PKey, _Cols} <- Hits]).

%% =============================================================================
%% Helpers
%% =============================================================================

shard_by(ByName, Name) ->
    maps:get(shard_by, maps:get(Name, ByName)).

fold(ByName, Name) ->
    maps:get(fold, maps:get(Name, ByName)).

set_env(Enabled, Shards, Dir) ->
    application:set_env(bondy_router, oplog_catalog_enabled, Enabled),
    application:set_env(bondy_router, oplog_core_shard_count, Shards),
    application:set_env(bondy_router, platform_data_dir, Dir).

reset_env() ->
    application:unset_env(bondy_router, oplog_catalog_enabled),
    application:unset_env(bondy_router, oplog_core_shard_count),
    application:unset_env(bondy_router, platform_data_dir).

stop_catalog(Pid) ->
    _ = catch gen_server:stop(Pid, normal, 30000),
    ok.

make_tmpdir() ->
    Base = filename:join(
        "/tmp",
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
