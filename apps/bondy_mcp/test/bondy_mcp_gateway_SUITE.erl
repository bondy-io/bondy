%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
-module(bondy_mcp_gateway_SUITE).

-moduledoc """
The MCP manifest cache (design §7.10) and overlay document store (§18.3) on
a booted node: overlay documents load atomically with realm-existence and
cross-document name-exclusivity checks; a realm's manifest is the compiled
join of its interface entries (the base layer) and the overlay (the
naming/annotation layer); an overlay rename REPLACES the URI-named base
entry; a §17 name collision exposes neither side and raises a critical
alarm that clears when the collision does; and the cache is invalidated by
store change events (debounced), with the TTL as backstop.

The suite runs on the shared CT node: realms are suite-unique, no listener
state is touched, and change events from other suites' interface writes
only cause harmless extra rebuilds.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-define(MASTER_REALM, <<"com.leapsight.bondy">>).

-define(REALM, <<"com.bondy.mcp.gw">>).
-define(REALM2, <<"com.bondy.mcp.gw2">>).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        overlay_load_lifecycle,
        overlay_load_is_atomic,
        overlay_load_requires_the_realm,
        overlay_names_are_exclusive_across_documents,
        manifest_is_the_interface_overlay_join,
        overlay_rename_replaces_the_base_entry,
        name_collision_exposes_neither_and_alarms,
        manifest_rebuilds_on_interface_change,
        ttl_is_the_rebuild_backstop,
        unknown_realm_never_grows_the_cache,
        metrics_manifest_series,
        overlay_wamp_api_lifecycle,
        overlay_wamp_api_requires_master_realm,
        curated_mode_exposes_only_overlay_entries,
        overlay_resource_kind_names_a_topic
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    _ = [
        begin
            R = bondy_realm:create(Uri),
            ok = bondy_realm:disable_security(R)
        end
     || Uri <- [?REALM, ?REALM2]
    ],
    %% A short debounce keeps the event-driven cases fast; a very long TTL
    %% guarantees they are proven by the EVENT path, not by TTL expiry.
    Env = [
        {manifest_rebuild_debounce,
            application:get_env(bondy_mcp, manifest_rebuild_debounce, 1000)},
        {manifest_cache_ttl,
            application:get_env(bondy_mcp, manifest_cache_ttl, 60000)},
        {manifest_mode, application:get_env(bondy_mcp, manifest_mode, curated)}
    ],
    ok = application:set_env(bondy_mcp, manifest_rebuild_debounce, 100),
    ok = application:set_env(bondy_mcp, manifest_cache_ttl, 3_600_000),
    %% The join/derivation cases below pin DERIVED semantics — base
    %% entries for every described procedure and topic. The default is
    %% `curated`; `curated_mode_exposes_only_overlay_entries` pins it.
    ok = application:set_env(bondy_mcp, manifest_mode, derived),
    [{saved_env, Env} | Config].

end_per_suite(Config) ->
    _ = [
        application:set_env(bondy_mcp, K, V)
     || {K, V} <- ?config(saved_env, Config)
    ],
    {save_config, Config}.

%% =============================================================================
%% CASES — overlay document store
%% =============================================================================

overlay_load_lifecycle(_) ->
    Id = <<"gw_lifecycle">>,
    Doc1 = doc(Id, [tool(<<"lc_tool">>, <<"com.bondy.mcp.gw.lc.p1">>)]),
    ok = bondy_mcp_gateway:load(Doc1),
    ?assertEqual({ok, Doc1}, bondy_mcp_gateway:lookup(Id)),
    ?assert(lists:member(Doc1, bondy_mcp_gateway:list())),

    %% Reloading one's own document is a replace, never a conflict.
    Doc2 = doc(Id, [tool(<<"lc_tool_v2">>, <<"com.bondy.mcp.gw.lc.p1">>)]),
    ok = bondy_mcp_gateway:load(Doc2),
    ?assertEqual({ok, Doc2}, bondy_mcp_gateway:lookup(Id)),

    ok = bondy_mcp_gateway:delete(Id),
    ?assertEqual({error, not_found}, bondy_mcp_gateway:lookup(Id)),
    ?assertEqual({error, not_found}, bondy_mcp_gateway:delete(Id)).

overlay_load_is_atomic(_) ->
    Id = <<"gw_atomic">>,
    Doc = doc(Id, [
        tool(<<"ok_tool">>, <<"com.bondy.mcp.gw.at.p1">>),
        tool(<<"bad name">>, <<"com.bondy.mcp.gw.at.p2">>)
    ]),
    ?assertMatch({error, {invalid_name, _}}, bondy_mcp_gateway:load(Doc)),
    ?assertEqual({error, not_found}, bondy_mcp_gateway:lookup(Id)).

overlay_load_requires_the_realm(_) ->
    Doc = doc(<<"gw_norealm">>, [
        (tool(<<"t">>, <<"com.bondy.mcp.gw.nr.p1">>))#{
            <<"realm">> => <<"com.bondy.mcp.gw.nonexistent">>
        }
    ]),
    ?assertMatch(
        {error, {no_such_realm, <<"com.bondy.mcp.gw.nonexistent">>}},
        bondy_mcp_gateway:load(Doc)
    ),
    ?assertEqual(
        {error, not_found}, bondy_mcp_gateway:lookup(<<"gw_norealm">>)
    ).

overlay_names_are_exclusive_across_documents(_) ->
    A = doc(<<"gw_excl_a">>, [
        tool(<<"shared_name">>, <<"com.bondy.mcp.gw.ex.p1">>)
    ]),
    ok = bondy_mcp_gateway:load(A),
    %% Another document claiming the same (realm, name) is rejected whole.
    B = doc(<<"gw_excl_b">>, [
        tool(<<"other_name">>, <<"com.bondy.mcp.gw.ex.p2">>),
        tool(<<"shared_name">>, <<"com.bondy.mcp.gw.ex.p3">>)
    ]),
    ?assertMatch(
        {error,
            {conflict, #{name := <<"shared_name">>, owner := <<"gw_excl_a">>}}},
        bondy_mcp_gateway:load(B)
    ),
    ?assertEqual(
        {error, not_found}, bondy_mcp_gateway:lookup(<<"gw_excl_b">>)
    ),
    %% The same name in ANOTHER realm is free.
    C = doc(<<"gw_excl_c">>, [
        (tool(<<"shared_name">>, <<"com.bondy.mcp.gw.ex.p4">>))#{
            <<"realm">> => ?REALM2
        }
    ]),
    ok = bondy_mcp_gateway:load(C),
    ok = bondy_mcp_gateway:delete(<<"gw_excl_a">>),
    ok = bondy_mcp_gateway:delete(<<"gw_excl_c">>).

%% =============================================================================
%% CASES — the compiled manifest
%% =============================================================================

manifest_is_the_interface_overlay_join(_) ->
    P1 = <<"com.bondy.mcp.gw.join.create">>,
    PArgs = <<"com.bondy.mcp.gw.join.args_only">>,
    PPrefix = <<"com.bondy.mcp.gw.join.pfx.">>,
    T1 = <<"com.bondy.mcp.gw.join.changed">>,
    E1 = <<"com.bondy.mcp.gw.join.error">>,
    ok = bondy_interface:load(#{
        <<"id">> => <<"gw_join_iface">>,
        <<"entries">> => [
            #{
                <<"realm">> => ?REALM,
                <<"kind">> => <<"procedure">>,
                <<"uri">> => P1,
                <<"description">> => <<"Create">>,
                <<"kwargs_schema">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"customer">> => #{<<"type">> => <<"string">>}
                    }
                },
                <<"result_kwargs_schema">> => #{<<"type">> => <<"object">>}
            },
            #{
                <<"realm">> => ?REALM,
                <<"kind">> => <<"procedure">>,
                <<"uri">> => PArgs,
                <<"args_schema">> => #{<<"type">> => <<"array">>}
            },
            #{
                <<"realm">> => ?REALM,
                <<"kind">> => <<"procedure">>,
                <<"uri">> => PPrefix,
                <<"match_policy">> => <<"prefix">>
            },
            #{
                <<"realm">> => ?REALM,
                <<"kind">> => <<"topic">>,
                <<"uri">> => T1,
                <<"kwargs_schema">> => #{<<"type">> => <<"object">>}
            },
            #{
                <<"realm">> => ?REALM,
                <<"kind">> => <<"error">>,
                <<"uri">> => E1
            }
        ]
    }),
    Overlay = doc(<<"gw_join_overlay">>, [
        template(<<"join_user">>, <<"com.bondy.mcp.gw.join.get_user">>)
    ]),
    ok = bondy_mcp_gateway:load(Overlay),

    Manifest = fresh_manifest(?REALM),
    #{entries := Entries} = Manifest,

    %% The base tool: named by its URI, schemas flattened per §16.1.
    #{P1 := Tool} = Entries,
    ?assertMatch(
        #{
            kind := tool,
            procedure := P1,
            description := <<"Create">>,
            input_schema := #{
                <<"properties">> := #{<<"customer">> := _}
            },
            output_schema := #{<<"type">> := <<"object">>},
            hash := <<"sha256:", _/binary>>
        },
        Tool
    ),
    %% Args-only flattening wraps under the reserved @args key.
    #{PArgs := ArgsTool} = Entries,
    ?assertMatch(
        #{
            input_schema := #{
                <<"type">> := <<"object">>,
                <<"properties">> := #{
                    <<"@args">> := #{<<"type">> := <<"array">>}
                },
                <<"required">> := [<<"@args">>]
            }
        },
        ArgsTool
    ),
    %% The base resource, at the §17 default URI.
    #{T1 := Resource} = Entries,
    ExpectedUri = <<"wamp:", ?REALM/binary, ":", T1/binary>>,
    ?assertMatch(
        #{kind := resource, topic := T1, uri := ExpectedUri}, Resource
    ),
    %% The overlay resource template stands on its own.
    ?assertMatch(
        #{<<"join_user">> := #{kind := resource_template}}, Entries
    ),
    %% Not exposed: error entries and pattern (non-exact) procedures.
    ?assertNot(maps:is_key(E1, Entries)),
    ?assertNot(maps:is_key(PPrefix, Entries)),

    ok = bondy_interface:delete(<<"gw_join_iface">>),
    ok = bondy_mcp_gateway:delete(<<"gw_join_overlay">>).

overlay_rename_replaces_the_base_entry(_) ->
    P = <<"com.bondy.mcp.gw.ren.create">>,
    ok = bondy_interface:load(#{
        <<"id">> => <<"gw_ren_iface">>,
        <<"entries">> => [
            #{
                <<"realm">> => ?REALM,
                <<"kind">> => <<"procedure">>,
                <<"uri">> => P,
                <<"description">> => <<"From the interface layer">>,
                <<"kwargs_schema">> => #{<<"type">> => <<"object">>}
            }
        ]
    }),
    Overlay = doc(<<"gw_ren_overlay">>, [
        (tool(<<"friendly">>, P))#{
            <<"annotations">> => #{<<"destructive_hint">> => true}
        }
    ]),
    ok = bondy_mcp_gateway:load(Overlay),

    #{entries := Entries} = fresh_manifest(?REALM),
    %% The rename is a rename: the URI-named base entry is GONE and the
    %% friendly name carries the join — the interface layer's description
    %% and schemas under the overlay's name and annotations.
    ?assertNot(maps:is_key(P, Entries)),
    #{<<"friendly">> := Tool} = Entries,
    ?assertMatch(
        #{
            procedure := P,
            description := <<"From the interface layer">>,
            input_schema := #{<<"type">> := <<"object">>},
            annotations := #{<<"destructive_hint">> := true},
            source := #{
                overlay := <<"gw_ren_overlay">>,
                interface := <<"gw_ren_iface">>
            }
        },
        Tool
    ),
    ok = bondy_interface:delete(<<"gw_ren_iface">>),
    ok = bondy_mcp_gateway:delete(<<"gw_ren_overlay">>).

name_collision_exposes_neither_and_alarms(_) ->
    %% Two procedures in the interface; an overlay names its tool with the
    %% LITERAL URI of the other procedure. Load-time exclusivity only sees
    %% other overlay documents, so this reaches the compiler — §17's
    %% "one name, different bindings" case.
    P1 = <<"com.bondy.mcp.gw.col.p1">>,
    P2 = <<"com.bondy.mcp.gw.col.p2">>,
    ok = bondy_interface:load(#{
        <<"id">> => <<"gw_col_iface">>,
        <<"entries">> => [
            #{
                <<"realm">> => ?REALM,
                <<"kind">> => <<"procedure">>,
                <<"uri">> => U
            }
         || U <- [P1, P2]
        ]
    }),
    ok = bondy_mcp_gateway:load(doc(<<"gw_col_overlay">>, [tool(P2, P1)])),

    Col0 = mval(bondy_mcp_manifest_collisions_total, collision_label()),
    #{entries := Entries} = fresh_manifest(?REALM),
    %% Neither the base P2 tool nor the overlay's P2-named tool survives;
    %% P1's base entry was replaced by the overlay claim on P1.
    ?assertNot(maps:is_key(P2, Entries)),
    ?assertNot(maps:is_key(P1, Entries)),
    %% The rebuild counted its collision (§15.1); `>=` because a
    %% debounced rebuild racing this read counts it again.
    ?assert(
        mval(bondy_mcp_manifest_collisions_total, collision_label()) >=
            Col0 + 1
    ),
    AlarmId = {bondy_mcp_name_collision, ?REALM, P2},
    ?assert(
        lists:keymember(AlarmId, 1, bondy_alarm_handler:get_alarms())
    ),

    %% Resolving the collision (deleting the overlay) clears the alarm and
    %% restores both base entries — through the EVENT path: nothing below
    %% calls the manifest before asserting, so only the change-driven
    %% rebuild can update the cache.
    ok = bondy_mcp_gateway:delete(<<"gw_col_overlay">>),
    ok = wait_until(fun() ->
        not lists:keymember(AlarmId, 1, bondy_alarm_handler:get_alarms())
    end),
    #{entries := Entries1} = cached_manifest(?REALM),
    ?assert(maps:is_key(P1, Entries1)),
    ?assert(maps:is_key(P2, Entries1)),
    ok = bondy_interface:delete(<<"gw_col_iface">>).

manifest_rebuilds_on_interface_change(_) ->
    P = <<"com.bondy.mcp.gw.evt.p1">>,
    #{entries := Entries0} = fresh_manifest(?REALM),
    ?assertNot(maps:is_key(P, Entries0)),

    %% The TTL is hours (init_per_suite), so only the debounced
    %% change-event path can refresh the cache within the wait budget.
    ok = bondy_interface:load(#{
        <<"id">> => <<"gw_evt_iface">>,
        <<"entries">> => [
            #{
                <<"realm">> => ?REALM,
                <<"kind">> => <<"procedure">>,
                <<"uri">> => P
            }
        ]
    }),
    ok = wait_until(fun() ->
        #{entries := Entries} = cached_manifest(?REALM),
        maps:is_key(P, Entries)
    end),
    ok = bondy_interface:delete(<<"gw_evt_iface">>),
    ok = wait_until(fun() ->
        #{entries := Entries} = cached_manifest(?REALM),
        not maps:is_key(P, Entries)
    end).

ttl_is_the_rebuild_backstop(_) ->
    #{built_at := Built0} = fresh_manifest(?REALM),
    %% Under the suite's long TTL a re-read serves the same snapshot.
    #{built_at := Built1} = cached_manifest(?REALM),
    ?assertEqual(Built0, Built1),

    %% Past the TTL, the next READ rebuilds — no event needed.
    ok = application:set_env(bondy_mcp, manifest_cache_ttl, 50),
    try
        ok = timer:sleep(100),
        {ok, #{built_at := Built2}} = bondy_mcp_gateway:manifest(?REALM),
        ?assertNotEqual(Built0, Built2)
    after
        application:set_env(bondy_mcp, manifest_cache_ttl, 3_600_000)
    end.

unknown_realm_never_grows_the_cache(_) ->
    %% Make sure the manager (and so the cache table) exists first.
    _ = cached_manifest(?REALM),
    Uri = <<"com.bondy.mcp.gw.no.such.realm">>,
    ?assertEqual(
        {error, no_such_realm}, bondy_mcp_gateway:manifest(Uri)
    ),
    ?assertEqual([], ets:lookup(bondy_mcp_gateway, Uri)).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% =============================================================================
%% CASES — the bondy.mcp.overlay.* WAMP API
%% =============================================================================

%% The overlay's ONLY management surface is WAMP (there is no console step
%% in any operator flow): the four procedures reach
%% `bondy_mcp_wamp_api` through `bondy_wamp_api`'s registered-handler
%% seam — the dispatcher's static clause table cannot name a bondy_mcp
%% module without a router→mcp static edge. Calls go through
%% `bondy_wamp_api:handle_call/2` so every case covers the seam, not just
%% the handler (the listener API suite's pattern).
overlay_wamp_api_lifecycle(_) ->
    Id = <<"gw_wamp_api">>,
    Doc = doc(Id, [tool(<<"wa_tool">>, <<"com.bondy.mcp.gw.wa.p1">>)]),

    {ok, _} = api_call(?MASTER_REALM, <<"bondy.mcp.overlay.load">>, [Doc]),

    {ok, #result{args = [Doc]}} =
        api_call(?MASTER_REALM, <<"bondy.mcp.overlay.get">>, [Id]),

    {ok, #result{args = [Listed]}} =
        api_call(?MASTER_REALM, <<"bondy.mcp.overlay.list">>, []),
    ?assert(lists:member(Doc, Listed)),

    %% An invalid document is refused with an error reply, not a crash.
    #error{} =
        api_call_error(?MASTER_REALM, <<"bondy.mcp.overlay.load">>, [
            #{<<"id">> => <<>>}
        ]),

    {ok, _} = api_call(?MASTER_REALM, <<"bondy.mcp.overlay.delete">>, [Id]),
    #error{} =
        api_call_error(?MASTER_REALM, <<"bondy.mcp.overlay.get">>, [Id]).

%% Admin authority: the same call from an ordinary realm's context is
%% refused — overlay documents can target ANY realm, so managing them is
%% an operator act, exactly like `bondy.interface.*`.
overlay_wamp_api_requires_master_realm(_) ->
    Doc = doc(<<"gw_wamp_authz">>, [
        tool(<<"wa_authz_tool">>, <<"com.bondy.mcp.gw.wa.p2">>)
    ]),
    E = api_call_error(?REALM, <<"bondy.mcp.overlay.load">>, [Doc]),
    ?assertEqual(?WAMP_NOT_AUTHORIZED, E#error.error_uri),
    #error{} = api_call_error(?REALM, <<"bondy.mcp.overlay.list">>, []).

%% Curated mode (`mcp.manifest.mode = curated`, THE DEFAULT): only
%% overlay-named entries exist — describing a procedure or topic for
%% reflection is not consenting to agent exposure. The interface layer
%% still contributes fields to the join, exactly as in derived mode; it
%% just creates nothing by itself. Extends the posture upstream tools
%% already have (projection onto a served manifest is an explicit
%% overlay act) to local procedures.
curated_mode_exposes_only_overlay_entries(_) ->
    PNamed = <<"com.bondy.mcp.gw.cur.named">>,
    PUnnamed = <<"com.bondy.mcp.gw.cur.unnamed">>,
    T = <<"com.bondy.mcp.gw.cur.topic">>,
    ok = bondy_interface:load(#{
        <<"id">> => <<"gw_cur_iface">>,
        <<"entries">> => [
            #{
                <<"realm">> => ?REALM,
                <<"kind">> => <<"procedure">>,
                <<"uri">> => PNamed,
                <<"description">> => <<"Named">>,
                <<"kwargs_schema">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"who">> => #{<<"type">> => <<"string">>}
                    }
                }
            },
            #{
                <<"realm">> => ?REALM,
                <<"kind">> => <<"procedure">>,
                <<"uri">> => PUnnamed
            },
            #{<<"realm">> => ?REALM, <<"kind">> => <<"topic">>, <<"uri">> => T}
        ]
    }),
    ok = bondy_mcp_gateway:load(
        doc(<<"gw_cur_overlay">>, [tool(<<"cur_tool">>, PNamed)])
    ),
    ok = application:set_env(bondy_mcp, manifest_mode, curated),
    try
        #{entries := Entries} = fresh_manifest(?REALM),

        %% The named tool exists AND joined its interface entry.
        ?assertMatch(
            #{
                <<"cur_tool">> := #{
                    kind := tool,
                    procedure := PNamed,
                    description := <<"Named">>,
                    input_schema := #{<<"properties">> := #{<<"who">> := _}}
                }
            },
            Entries
        ),
        %% Described-but-unnamed procedures and topics create NOTHING.
        ?assertNot(maps:is_key(PNamed, Entries)),
        ?assertNot(maps:is_key(PUnnamed, Entries)),
        ?assertNot(maps:is_key(T, Entries)),
        ExpectedUri = <<"wamp:", ?REALM/binary, ":", T/binary>>,
        ?assertNot(maps:is_key(ExpectedUri, Entries)),

        %% The SAME state under derived mode exposes all of them.
        ok = application:set_env(bondy_mcp, manifest_mode, derived),
        #{entries := Derived} = fresh_manifest(?REALM),
        ?assert(maps:is_key(PUnnamed, Derived)),
        ?assert(maps:is_key(T, Derived)),
        ?assert(maps:is_key(<<"cur_tool">>, Derived))
    after
        %% The suite's baseline (init_per_suite) is derived.
        ok = application:set_env(bondy_mcp, manifest_mode, derived),
        _ = bondy_interface:delete(<<"gw_cur_iface">>),
        _ = bondy_mcp_gateway:delete(<<"gw_cur_overlay">>)
    end.

%% The overlay `resource` kind (MCP-D31's curated companion): a plain
%% topic-backed resource is exposable by NAMING its topic — without it, a
%% described topic could never surface under curated mode. The entry
%% joins the topic's interface entry (description; payload schemas
%% flatten into the OUTPUT shape, what a subscriber receives), and in
%% derived mode it REPLACES the topic's URI-named base resource.
overlay_resource_kind_names_a_topic(_) ->
    T = <<"com.bondy.mcp.gw.res.changed">>,
    ok = bondy_interface:load(#{
        <<"id">> => <<"gw_res_iface">>,
        <<"entries">> => [
            #{
                <<"realm">> => ?REALM,
                <<"kind">> => <<"topic">>,
                <<"uri">> => T,
                <<"description">> => <<"Changed">>,
                <<"kwargs_schema">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"state">> => #{<<"type">> => <<"string">>}
                    }
                }
            }
        ]
    }),
    ok = bondy_mcp_gateway:load(
        doc(<<"gw_res_overlay">>, [
            #{
                <<"realm">> => ?REALM,
                <<"name">> => <<"changes">>,
                <<"kind">> => <<"resource">>,
                <<"wamp_topic">> => T
            }
        ])
    ),
    ok = application:set_env(bondy_mcp, manifest_mode, curated),
    try
        #{entries := Entries} = fresh_manifest(?REALM),
        ExpectedUri = <<"wamp:", ?REALM/binary, ":", T/binary>>,
        ?assertMatch(
            #{
                <<"changes">> := #{
                    kind := resource,
                    topic := T,
                    uri := ExpectedUri,
                    description := <<"Changed">>,
                    output_schema := #{
                        <<"properties">> := #{<<"state">> := _}
                    }
                }
            },
            Entries
        ),
        %% The topic's URI-named form does not exist beside it.
        ?assertNot(maps:is_key(T, Entries)),

        %% Derived mode: the named resource REPLACES the base one — one
        %% entry per topic, never both spellings.
        ok = application:set_env(bondy_mcp, manifest_mode, derived),
        #{entries := Derived} = fresh_manifest(?REALM),
        ?assert(maps:is_key(<<"changes">>, Derived)),
        ?assertNot(maps:is_key(T, Derived))
    after
        ok = application:set_env(bondy_mcp, manifest_mode, derived),
        _ = bondy_interface:delete(<<"gw_res_iface">>),
        _ = bondy_mcp_gateway:delete(<<"gw_res_overlay">>)
    end.

%% @private
%% Through the dispatcher, so the registered-handler seam is exercised by
%% every call — a direct bondy_mcp_wamp_api call would pass with the seam
%% unwired.
api_handle(RealmUri, Proc, Args) ->
    Ctxt = bondy_context:local_context(RealmUri),
    M = bondy_wamp_message:call(1, #{}, Proc, Args),
    bondy_wamp_api:handle_call(M, Ctxt).

%% @private
api_call(RealmUri, Proc, Args) ->
    case api_handle(RealmUri, Proc, Args) of
        {reply, #result{} = R} -> {ok, R};
        Other -> ct:fail({expected_result, Proc, Other})
    end.

%% @private
%% Authorization and arity failures RAISE in bondy_wamp_api_utils; plain
%% failures come back as an error reply. Accept both shapes.
api_call_error(RealmUri, Proc, Args) ->
    try api_handle(RealmUri, Proc, Args) of
        {reply, #error{} = E} -> E;
        Other -> ct:fail({expected_error, Proc, Other})
    catch
        error:#error{} = E -> E
    end.

doc(Id, Entries) ->
    #{<<"id">> => Id, <<"entries">> => Entries}.

tool(Name, Procedure) ->
    #{
        <<"realm">> => ?REALM,
        <<"name">> => Name,
        <<"kind">> => <<"tool">>,
        <<"wamp_procedure">> => Procedure
    }.

template(Name, Procedure) ->
    #{
        <<"realm">> => ?REALM,
        <<"name">> => Name,
        <<"kind">> => <<"resource_template">>,
        <<"wamp_procedure">> => Procedure,
        <<"uri_template">> => <<"users:///{id}">>,
        <<"uri_vars_schema">> => #{<<"id">> => #{<<"type">> => <<"integer">>}},
        <<"wamp_kwargs">> => #{<<"id">> => <<"{{id}}">>},
        <<"result_kwargs_schema">> => #{<<"type">> => <<"object">>}
    }.

%% A manifest guaranteed to reflect the CURRENT store content: suites and
%% earlier cases share the cache, so force a rebuild by expiring the cell.
%% =============================================================================
%% CASES — §15 manifest metrics (delta-based: the node is shared)
%% =============================================================================

metrics_manifest_series(_) ->
    Node = bondy_config:node(),
    Demand = #{node => Node, realm => ?REALM, trigger => demand},
    DbEvent = #{node => Node, realm => ?REALM, trigger => db_event},
    DurLabel = #{node => Node, realm => ?REALM},
    ToolGauge = #{node => Node, realm => ?REALM, kind => tool},
    D0 = mval(bondy_mcp_manifest_rebuilds_total, Demand),
    E0 = mval(bondy_mcp_manifest_rebuilds_total, DbEvent),
    H0 = hcount(bondy_mcp_manifest_rebuild_duration_microseconds, DurLabel),

    %% Demand: an expired read rebuilds through the serialization point
    %% (a swapped trigger label increments db_event instead and fails).
    #{entries := Entries0} = fresh_manifest(?REALM),
    ?assertEqual(D0 + 1, mval(bondy_mcp_manifest_rebuilds_total, Demand)),
    ?assertEqual(
        H0 + 1,
        hcount(bondy_mcp_manifest_rebuild_duration_microseconds, DurLabel)
    ),
    Tools0 = census(Entries0, tool),
    ?assertEqual(Tools0, mval(bondy_mcp_manifest_entries, ToolGauge)),

    %% db_event: an overlay load reaches the rebuild via the debounced
    %% change event, and the gauge follows the new census ABSOLUTELY —
    %% a delta-writing gauge double-counts on this second rebuild.
    Id = <<"gw_metrics_doc">>,
    ok = bondy_mcp_gateway:load(
        doc(Id, [tool(<<"metrics_tool">>, <<"com.bondy.mcp.gw.met.p1">>)])
    ),
    ok = wait_until(fun() ->
        mval(bondy_mcp_manifest_rebuilds_total, DbEvent) >= E0 + 1
    end),
    ?assertEqual(Tools0 + 1, mval(bondy_mcp_manifest_entries, ToolGauge)),
    ok = bondy_mcp_gateway:delete(Id),
    ok = wait_until(fun() ->
        mval(bondy_mcp_manifest_entries, ToolGauge) == Tools0
    end).

%% =============================================================================
%% HELPERS — metrics
%% =============================================================================

collision_label() ->
    #{
        node => bondy_config:node(),
        realm => ?REALM,
        kind => name_collision
    }.

census(Entries, Kind) ->
    length([K || #{kind := K} <- maps:values(Entries), K == Kind]).

%% Current value of a counter/gauge cell, 0 when never touched.
mval(Name, Label) ->
    case bondy_metrics:value(#{name => Name, label => Label}) of
        undefined -> 0;
        V when is_integer(V) -> V
    end.

%% Observation count of a histogram cell, 0 when never touched.
hcount(Name, Label) ->
    case bondy_metrics:histogram_snapshot(#{name => Name, label => Label}) of
        {ok, #{count := C}} -> C;
        not_found -> 0
    end.

fresh_manifest(RealmUri) ->
    ok = expire(RealmUri),
    cached_manifest(RealmUri).

cached_manifest(RealmUri) ->
    {ok, Manifest} = bondy_mcp_gateway:manifest(RealmUri),
    Manifest.

%% Force a synchronous rebuild through the public API: with the TTL
%% momentarily at zero every cached cell is stale, so the read rebuilds.
expire(RealmUri) ->
    Ttl = application:get_env(bondy_mcp, manifest_cache_ttl, 60000),
    ok = application:set_env(bondy_mcp, manifest_cache_ttl, 0),
    try
        {ok, _} = bondy_mcp_gateway:manifest(RealmUri),
        ok
    after
        application:set_env(bondy_mcp, manifest_cache_ttl, Ttl)
    end.

wait_until(Fun) ->
    wait_until(Fun, 100).

wait_until(_, 0) ->
    error(timeout);
wait_until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(100),
            wait_until(Fun, N - 1)
    end.
