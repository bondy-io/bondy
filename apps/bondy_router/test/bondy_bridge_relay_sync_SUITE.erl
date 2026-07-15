%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Tests the bridge relay full-sync after its cut-over from plum_db to bondy_db.
%% The server reads a realm's security model out of bondy_db as a list of
%% `{TableName, Band, Key, Value, Hlc}' cells (`realm_sync_cells/1'); the client
%% merges each cell into its own bondy_db preserving the origin HLC
%% (`handle_aae_data/2'). Booting bondy_router provisions the catalogue tables
%% the sync reads and writes.

-module(bondy_bridge_relay_sync_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM_A, <<"com.bondy.test.bridge_sync.server">>).
-define(REALM_B, <<"com.bondy.test.bridge_sync.client">>).

all() ->
    bondy_ct:all().

groups() ->
    [{main, [], bondy_ct:tests(?MODULE)}].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Config.

end_per_suite(Config) ->
    Config.

%% The server collects a realm's security model from bondy_db across every
%% synced table, with the realm record's private keys stripped.
realm_sync_cells_reads_security_model_test(_) ->
    _ = bondy_realm:create(realm_config(?REALM_A)),

    Cells = bondy_bridge_relay_server:realm_sync_cells(?REALM_A),

    %% Every cell is a {TableName, Band, Key, Value, Hlc} tuple with a live
    %% (non-tombstone) value.
    [
        begin
            ?assertMatch({_, _, _, _, _}, C),
            {_T, _Band, _Key, Value, _Hlc} = C,
            ?assertNotEqual(undefined, Value)
        end
     || C <- Cells
    ],

    %% The realm record plus the entities bondy_realm:create/1 seeded are all
    %% present.
    Tables = lists:usort([T || {T, _, _, _, _} <- Cells]),
    ?assert(lists:member(bondy_realm, Tables)),
    ?assert(lists:member(security_users, Tables)),
    ?assert(lists:member(security_groups, Tables)),

    %% Exactly one realm cell: empty band, keyed by the realm URI, carrying the
    %% realm record with private keys stripped.
    [{bondy_realm, Band, Key, RealmVal, _}] =
        [C || {bondy_realm, _, _, _, _} = C <- Cells],
    ?assertEqual(<<>>, Band),
    ?assertEqual(?REALM_A, Key),
    Full = bondy_realm:fetch(?REALM_A),
    ?assertEqual(bondy_realm:strip_private_keys(Full), RealmVal),
    %% Sanity: stripping actually removed something (so the test would catch a
    %% missing strip).
    ?assertNotEqual(Full, RealmVal),

    %% A non-existent realm yields no cells.
    ?assertEqual(
        [],
        bondy_bridge_relay_server:realm_sync_cells(
            <<"com.bondy.test.bridge_sync.absent">>
        )
    ).

%% The client merges a shipped cell into bondy_db preserving the origin HLC:
%% a fresh cell applies, an older cell is rejected (newer local value kept), a
%% newer cell wins — exactly the LWW semantics of the old plum_db:merge.
client_apply_preserves_origin_hlc_test(_) ->
    Tab = bondy_namespace_catalog:table(security_users),
    Key = <<"carol">>,

    %% Fresh cell — the client had nothing for this key, so it applies.
    V1 = #{username => Key, v => 1},
    ok = apply_cell(security_users, ?REALM_B, Key, V1, hlc()),
    {ok, {V1, H1}} = bondy_db:read(Tab, ?REALM_B, Key),

    %% Older cell (lower HLC) is rejected — the newer local value is retained.
    V0 = #{username => Key, v => 0},
    ok = apply_cell(security_users, ?REALM_B, Key, V0, H1 - 1),
    ?assertMatch({ok, {V1, _}}, bondy_db:read(Tab, ?REALM_B, Key)),

    %% Newer cell (higher HLC) wins.
    V2 = #{username => Key, v => 2},
    ok = apply_cell(security_users, ?REALM_B, Key, V2, H1 + 1),
    ?assertMatch({ok, {V2, _}}, bondy_db:read(Tab, ?REALM_B, Key)).

%% A cell for a table that is not provisioned is dropped, not crashed on.
client_apply_drops_unprovisioned_table_test(_) ->
    ?assertEqual(
        ok,
        apply_cell(
            no_such_table, ?REALM_B, <<"k">>, #{}, hlc()
        )
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

apply_cell(TableName, Band, Key, Value, Hlc) ->
    bondy_bridge_relay_client:handle_aae_data(
        {cell, TableName, Band, Key, Value, Hlc}, undefined
    ).

hlc() ->
    bondy_oplog_hlc:now(bondy_oplog_hlc:new()).

%% A realm with a group, a user and a group grant so the sync has cells in
%% several tables. No password — the sync test does not exercise auth.
realm_config(Uri) ->
    #{
        uri => Uri,
        description => <<"bridge sync test realm">>,
        security_enabled => true,
        groups => [#{name => <<"viewers">>}],
        users => [
            #{username => <<"alice">>, groups => [<<"viewers">>]}
        ],
        grants => [
            #{
                permissions => [<<"wamp.call">>],
                uri => <<"">>,
                match => <<"prefix">>,
                roles => [<<"viewers">>]
            }
        ]
    }.
