%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Integration test for the bridge relay config store after its cut-over from
%% plum_db to bondy_db (design §11.4 — the second domain migrated). Booting
%% bondy_router exercises the cut-over: `bondy_namespace_catalog` provisions the
%% durable `bondy_bridge_relay` bondy_db table by default, and
%% `bondy_bridge_relay` reads / writes it. The CRUD round-trip proves
%% add → lookup → exists → list → remove all flow through bondy_db, and that a
%% realistic nested bridge config (tuple endpoint, nested realm maps) round-trips
%% through the `lww_register` cell. Storage-only: bridge config has no reactor.

-module(bondy_bridge_relay_store_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([nowarn_export_all, export_all]).

all() ->
    bondy_ct:all().

groups() ->
    [{main, [], bondy_ct:tests(?MODULE)}].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Config.

end_per_suite(Config) ->
    Config.

%% The catalogue provisions the bondy_bridge_relay bondy_db table at boot (it is
%% a migrated domain), so the config store has a live table to read / write.
catalogue_provisions_bridge_relay_test(_) ->
    ?assertMatch(
        #{entity_type := bondy_bridge_relay, db_name := core},
        bondy_namespace_catalog:table(bondy_bridge_relay)
    ).

%% add → lookup → exists → list → remove, all through the bondy_db-backed store.
crud_roundtrip_test(_) ->
    Name = <<"com.bondy.test.bridge_store.crud">>,

    %% Absent to begin with.
    ?assertEqual(false, bondy_bridge_relay:exists(Name)),
    ?assertEqual({error, not_found}, bondy_bridge_relay:lookup(Name)),

    %% add/1 writes the bridge to bondy_db, stamping the owning node.
    ok = bondy_bridge_relay:add(bridge(Name)),

    %% exists + lookup see it.
    ?assert(bondy_bridge_relay:exists(Name)),
    {ok, Stored} = bondy_bridge_relay:lookup(Name),
    ?assertEqual(Name, maps:get(name, Stored)),
    ?assertEqual(bridge_relay, maps:get(type, Stored)),
    %% add/1 stamps this node's nodestring (used by the manager's node filter).
    ?assertEqual(bondy_config:nodestring(), maps:get(nodestring, Stored)),
    %% The nested structure round-trips through the lww cell unchanged.
    ?assertEqual({"localhost", 18092}, maps:get(endpoint, Stored)),
    ?assertMatch([#{uri := <<"com.example.realm">>}], maps:get(realms, Stored)),

    %% list/0 includes it.
    ?assert(has_bridge(Name, bondy_bridge_relay:list())),

    %% add/1 of an existing name is rejected.
    ?assertEqual({error, already_exists}, bondy_bridge_relay:add(bridge(Name))),

    %% remove clears the cell; the bridge is gone from every read.
    ok = bondy_bridge_relay:remove(Name),
    ?assertEqual(false, bondy_bridge_relay:exists(Name)),
    ?assertEqual({error, not_found}, bondy_bridge_relay:lookup(Name)),
    ?assertEqual(false, has_bridge(Name, bondy_bridge_relay:list())).

%% lww `clear` is non-terminal: re-adding a removed bridge reanimates it.
reload_after_remove_test(_) ->
    Name = <<"com.bondy.test.bridge_store.reload">>,
    ok = bondy_bridge_relay:add(bridge(Name)),
    ?assert(bondy_bridge_relay:exists(Name)),
    ok = bondy_bridge_relay:remove(Name),
    ?assertEqual({error, not_found}, bondy_bridge_relay:lookup(Name)),
    ok = bondy_bridge_relay:add(bridge(Name)),
    ?assert(bondy_bridge_relay:exists(Name)),
    ok = bondy_bridge_relay:remove(Name).

%% =============================================================================
%% Helpers
%% =============================================================================

has_bridge(Name, Bridges) ->
    lists:any(fun(B) -> maps:get(name, B) =:= Name end, Bridges).

%% A realistic post-validation bridge config (the shape `bondy_bridge_relay:new/1`
%% produces). `add/1` only requires `type` + `name`; the rest exercises nested
%% term round-tripping (tuple endpoint, list of nested realm maps) through the
%% lww cell.
bridge(Name) ->
    #{
        type => bridge_relay,
        version => <<"1.0">>,
        name => Name,
        enabled => false,
        restart => permanent,
        endpoint => {"localhost", 18092},
        transport => tcp,
        parallelism => 1,
        realms => [
            #{
                uri => <<"com.example.realm">>,
                authid => <<"bridge">>,
                cryptosign => #{pubkey => <<"abcd1234">>},
                procedures => [],
                topics => []
            }
        ]
    }.
