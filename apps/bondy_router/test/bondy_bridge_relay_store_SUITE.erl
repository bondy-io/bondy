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
    Main = bondy_namespace_catalog:main_db_name(),
    ?assertMatch(
        #{entity_type := bondy_bridge_relay, db_name := Main},
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

%% "How many unanswered probes mean a dead peer" is ONE judgement, and this end
%% of a bridge has no reason to make it differently from the end that accepts the
%% connection. The two ends are configured by unrelated code — `?PING_SPEC` here,
%% `bondy_listener_config:option_defaults/2` for the listener — so nothing but
%% this makes them agree; the outbound default shipped 2 while every listener
%% shipped 3 (and the bridge schema's own commented example showed 3).
%%
%% Asserted against the listener AND against the literal: the first catches one
%% side moving, the second catches both moving to a value nobody chose. It runs
%% through `new/1` rather than reading a constant, because the default only
%% exists as one, and `new/1` needs a booted node — which is why this case lives
%% in a suite that boots one rather than beside the pure listener tests.
outbound_ping_matches_the_listener_test(_) ->
    Bridge = bondy_bridge_relay:new(unvalidated_bridge()),
    Ping = maps:get(ping, Bridge),
    Attempts = maps:get(max_attempts, Ping),
    Listener = bondy_listener_config:option_defaults(tcp, bridge_relay),
    ?assertEqual(3, Attempts),
    ?assertEqual(maps:get(max_attempts, maps:get(ping, Listener)), Attempts),
    %% The input carries NO ping block, so this also pins that an absent one is
    %% FILLED rather than left as `#{}`. It was `#{}` — a map
    %% `bondy_bridge_relay_client:maybe_enable_ping/2` has no clause for, so the
    %% client died with `function_clause` in `init/1` on any bridge that said
    %% nothing about ping. Asserting the whole block rather than one key,
    %% because all four are read with `maps:get/2` once ping is enabled and any
    %% one of them missing is the same crash.
    ?assertEqual(
        #{
            enabled => true,
            idle_timeout => timer:seconds(20),
            timeout => timer:seconds(10),
            max_attempts => 3
        },
        Ping
    ).

%% The same defect on the sibling blocks, which is why it is worth a case of its
%% own rather than a line in the one above: `ping` was the only one that crashed,
%% so a fix aimed at the crash would have left the rest.
%%
%% `reconnect` was the quiet one — its spec has said `enabled => true` with 100
%% retries the whole time, while a bridge that configured no block got `#{}`,
%% reached `maybe_enable_reconnect/2`'s fall-through clause and never
%% reconnected at all.
%%
%% `socket_opts` was not broken: it spelled out by hand exactly what its spec
%% produces, and is asserted at those same values so that putting it on the
%% shared idiom is pinned as value-preserving.
%%
%% `tls_opts` is the one that is deliberately NOT filled, and this is where that
%% decision is recorded: `?TLS_OPTS_SPEC` defaults `versions` to `['tlsv1.3']`
%% alone, so filling it would pin every bridge that states no TLS options to TLS
%% 1.3 and drop a peer offering only 1.2. Asserting the absence of `versions` is
%% the point — it fails if someone later makes this block uniform with its
%% siblings, which is a change to what a bridge negotiates and not a tidy-up.
outbound_nested_blocks_are_filled_from_their_specs_test(_) ->
    Bridge = bondy_bridge_relay:new(unvalidated_bridge()),
    ?assertEqual(
        #{
            enabled => true,
            max_retries => 100,
            backoff_type => jitter,
            backoff_min => timer:seconds(5),
            backoff_max => timer:seconds(60)
        },
        maps:get(reconnect, Bridge)
    ),
    ?assertEqual(
        #{keepalive => true, nodelay => true}, maps:get(socket_opts, Bridge)
    ),
    ?assertEqual(#{verify => verify_none}, maps:get(tls_opts, Bridge)).

%% =============================================================================
%% Helpers
%% =============================================================================

has_bridge(Name, Bridges) ->
    lists:any(fun(B) -> maps:get(name, B) =:= Name end, Bridges).

%% Input for `new/1`: the three keys `?BRIDGE_RELAY_SPEC` requires without a
%% default. No `ping` block on purpose — what the case reads is what `new/1`
%% fills in.
unvalidated_bridge() ->
    #{
        name => <<"com.bondy.test.bridge_store.defaults">>,
        endpoint => {"localhost", 18092},
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
