%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% -----------------------------------------------------------------------------
%% The `dry_run` convention: a procedure that declares support performs every
%% check the real call performs, stops before the first act that changes
%% anything, and replies with what it WOULD have done.
%%
%% The convention has two halves and the second is the one that makes it safe:
%%
%%   * SUPPORTED — a declaring procedure simulates, marks the reply, and
%%     changes nothing. Driven from `bondy_task_catalogue` rather than from a
%%     list here, so declaring support without implementing it FAILS.
%%   * UNSUPPORTED — a procedure that does not declare it REFUSES rather than
%%     acting. Without that gate a caller who believed it was simulating would
%%     have performed the thing, which is the one failure this convention
%%     exists to remove.
%%
%% Everything runs through `bondy_wamp_api:handle_call/2`, because the gate
%% lives at that boundary and a direct call to a handler would not meet it.
%% -----------------------------------------------------------------------------
-module(bondy_dry_run_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").

-compile([nowarn_export_all, export_all]).

-define(DOC_ID, <<"ct_dry_run_overlay">>).
%% The MCP overlay URIs are defined inside `bondy_mcp_wamp_api`, not in
%% `bondy_uris.hrl`, so they are spelled out here rather than included.
-define(OVERLAY_LOAD, <<"bondy.mcp.overlay.load">>).
-define(OVERLAY_DELETE, <<"bondy.mcp.overlay.delete">>).
-define(BRIDGE_NAME, <<"ct_dry_run_bridge">>).

all() ->
    [
        every_declared_dry_run_is_implemented,
        a_dry_run_overlay_load_writes_nothing,
        a_dry_run_bridge_add_holds_nothing,
        a_dry_run_leave_removes_no_member,
        a_dry_run_reports_the_listeners_it_would_touch,
        an_undeclared_procedure_refuses_a_dry_run,
        a_malformed_dry_run_value_is_refused,
        a_real_call_carries_no_dry_run_marker
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Config.

end_per_suite(Config) ->
    _ = bondy_mcp_gateway:delete(?DOC_ID),
    {save_config, Config}.

end_per_testcase(_, Config) ->
    %% A case that failed mid-way may have left the bridge behind, and a
    %% leaked bridge is a name collision for every later run in the same VM.
    _ = bondy_bridge_relay_manager:remove_bridge(?BRIDGE_NAME),
    %% Defensive, and not idle: every case here asserts that a dry run did
    %% NOT act, so the way each one FAILS is by having acted. A suite that
    %% leaves `normal` suspended breaks every suite after it in the same VM,
    %% which would turn one honest failure into a run-wide mystery.
    ok = bondy_listener_manager:resume(normal),
    Config.

%% =============================================================================
%% CASES
%% =============================================================================

%% Driven from the catalogue, so a task declaring `dry_run => true` that never
%% reads the KWArg fails here rather than lying to an agent that trusted the
%% declaration. Every argument below is chosen to be harmless IF the dry run
%% were ignored and the call ran for real — except that it must not be, which
%% is what `a_dry_run_overlay_load_writes_nothing` proves separately.
every_declared_dry_run_is_implemented(_) ->
    Declared = [
        Id
     || #{id := Id, dry_run := true} <- bondy_task_catalogue:list()
    ],
    %% Vacuity guard: nothing is proven if nothing declares support.
    ?assert(length(Declared) >= 3),
    _ = [
        begin
            Reply = call(Id, args_for(Id), #{dry_run => true}),
            ?assertEqual(true, maps:get(<<"dry_run">>, Reply, undefined), Id),
            ?assert(is_binary(maps:get(<<"would">>, Reply, undefined)), Id)
        end
     || Id <- Declared
    ],
    ok.

%% The bridge half of the same property. `bondy.router.bridge.add` declares
%% `dry_run` so that the family stops needing `check_spec` as a second idiom,
%% which is only true if the dry run genuinely holds nothing: the manager must
%% not know the bridge afterwards.
%%
%% Falsified by making the dry-run branch call `add_bridge/2` — the reply looks
%% identical and `bondy.router.bridge.get` then finds the bridge.
a_dry_run_bridge_add_holds_nothing(_) ->
    ?assertEqual(
        {error, not_found}, bondy_bridge_relay_manager:get_bridge(?BRIDGE_NAME)
    ),
    Reply = call(?BONDY_ROUTER_BRIDGE_ADD, [bridge_spec()], #{dry_run => true}),
    ?assertEqual(true, maps:get(<<"dry_run">>, Reply)),
    ?assertMatch(#{<<"bridge">> := #{}}, Reply),
    ?assertEqual(
        {error, not_found},
        bondy_bridge_relay_manager:get_bridge(?BRIDGE_NAME),
        "the dry run added the bridge"
    ),

    %% The other half of "cannot pass where the real call would fail": the
    %% name rule. `check_bridge/2` and `add_bridge_to_state/2` share
    %% `assert_absent/2`, so a dry run of a name already held must refuse —
    %% otherwise the dry run would sanction a call that then throws
    %% `already_exists`. Killed by making `check_bridge` skip the name check.
    Spec = bridge_spec(),
    {ok, _} = bondy_bridge_relay_manager:add_bridge(Spec, #{}),
    try
        _ = call_error(?BONDY_ROUTER_BRIDGE_ADD, [Spec], #{dry_run => true})
    after
        ok = bondy_bridge_relay_manager:remove_bridge(?BRIDGE_NAME)
    end.

%% `bondy.cluster.leave` is the only `destructive` task, so its dry run is the
%% one that most has to hold. Membership is the reclamation authority — a node
%% removed from it stops being counted, and the retirement pass may reap its
%% origins — so a dry run that actually removed a member would be unrecoverable
%% from the reply alone.
%%
%% Falsified by making the dry-run branch call `partisan_peer_service:leave/1`:
%% the reply is identical and this node vanishes from its own membership.
a_dry_run_leave_removes_no_member(_) ->
    Self = partisan:node(),
    {ok, Before} = partisan_peer_service:members(),
    ?assert(lists:member(Self, Before)),

    Reply = call(
        ?BONDY_CLUSTER_LEAVE, [atom_to_binary(Self)], #{dry_run => true}
    ),
    ?assertEqual(true, maps:get(<<"dry_run">>, Reply)),
    ?assertEqual(atom_to_binary(Self), maps:get(<<"node">>, Reply)),

    {ok, After} = partisan_peer_service:members(),
    ?assertEqual(
        lists:sort(Before),
        lists:sort(After),
        "the dry run changed cluster membership"
    ).

%% The property the whole convention rests on. A reply saying "I would have"
%% is worthless unless nothing was written, and the only way to know is to
%% look afterwards.
a_dry_run_overlay_load_writes_nothing(_) ->
    _ = bondy_mcp_gateway:delete(?DOC_ID),
    ?assertEqual({error, not_found}, bondy_mcp_gateway:lookup(?DOC_ID)),

    Reply = call(
        ?OVERLAY_LOAD, [overlay_doc()], #{dry_run => true}
    ),
    ?assertEqual(true, maps:get(<<"dry_run">>, Reply)),
    ?assertEqual(?DOC_ID, maps:get(<<"id">>, Reply)),
    ?assertEqual(
        {error, not_found},
        bondy_mcp_gateway:lookup(?DOC_ID),
        "the dry run wrote the document"
    ),

    %% And the real call does write it — otherwise the assertion above would
    %% hold for a load that is simply broken.
    ok = call_ok(?OVERLAY_LOAD, [overlay_doc()], #{}),
    ?assertMatch({ok, _}, bondy_mcp_gateway:lookup(?DOC_ID)),
    _ = bondy_mcp_gateway:delete(?DOC_ID),
    ok.

%% The second shape of dry run: not validation, but SCOPE. Whether this node
%% accepts connections is invisible from the WAMP API — no procedure reports
%% listener state — so this is the only way to see what a phase names before
%% suspending it.
a_dry_run_reports_the_listeners_it_would_touch(_) ->
    Reply = call(?BONDY_LISTENER_SUSPEND, [<<"normal">>], #{dry_run => true}),
    ?assertEqual(<<"normal">>, maps:get(<<"phase">>, Reply)),
    Listeners = maps:get(<<"listeners">>, Reply),
    ?assert(is_list(Listeners)),
    ?assertMatch([_ | _], Listeners, "the normal phase named no listeners"),
    ?assert(lists:all(fun is_binary/1, Listeners)),
    %% It reports what `suspend/1` would touch, so the two must agree.
    Expected = [
        atom_to_binary(N, utf8)
     || N <- bondy_listener_manager:names_in_phase(normal)
    ],
    ?assertEqual(lists:sort(Expected), lists:sort(Listeners)),
    %% Nothing was suspended — asserted against a real socket, the same way
    %% `bondy_listener_api_SUITE:suspending_normal_refuses_new_connections`
    %% asserts the opposite. A `dry_run` reply that says "I would have" is
    %% worthless unless the listener is still accepting afterwards, and only a
    %% connection can say that: `bondy_listener_manager:listeners/0` reports
    %% the CONFIGURED inventory and reads the same before and after a suspend.
    Name = a_normal_phase_tcp_listener(),
    Port = ranch:get_port(Name),
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary], 5000),
    ok = gen_tcp:close(Sock).

%% The gate. `bondy.mcp.overlay.delete` does not declare `dry_run`, so a call
%% carrying it must be REFUSED — not performed, and not silently simulated.
an_undeclared_procedure_refuses_a_dry_run(_) ->
    ok = call_ok(?OVERLAY_LOAD, [overlay_doc()], #{}),
    ?assertMatch({ok, _}, bondy_mcp_gateway:lookup(?DOC_ID)),

    ?assertMatch(
        #error{error_uri = ?WAMP_INVALID_ARGUMENT},
        call_error(?OVERLAY_DELETE, [?DOC_ID], #{dry_run => true})
    ),
    ?assertMatch(
        {ok, _},
        bondy_mcp_gateway:lookup(?DOC_ID),
        "the refused dry run deleted the document anyway"
    ),
    _ = bondy_mcp_gateway:delete(?DOC_ID),
    ok.

%% Neither reading is safe: `false` performs a call that asked not to be
%% performed, `true` refuses work that was asked for. So it refuses instead of
%% choosing.
a_malformed_dry_run_value_is_refused(_) ->
    ?assertMatch(
        #error{error_uri = ?WAMP_INVALID_ARGUMENT},
        call_error(?BONDY_LISTENER_SUSPEND, [<<"normal">>], #{dry_run => 1})
    ),
    ?assertMatch(
        #error{error_uri = ?WAMP_INVALID_ARGUMENT},
        call_error(
            ?BONDY_LISTENER_SUSPEND, [<<"normal">>], #{dry_run => <<"yes">>}
        )
    ).

%% The marker means "nothing happened", so it must never appear on a call that
%% did happen. A caller that cannot tell the two apart is back where it started.
a_real_call_carries_no_dry_run_marker(_) ->
    ok = call_ok(?OVERLAY_LOAD, [overlay_doc()], #{}),
    _ = bondy_mcp_gateway:delete(?DOC_ID),
    Catalogue = call(?BONDY_TASK_CATALOGUE, [], #{}),
    ?assertNot(maps:is_key(<<"dry_run">>, Catalogue)).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
%% Arguments that are VALID for each declaring procedure, so a dry run reaches
%% the simulation rather than an argument error.
args_for(<<"bondy.listener.", _/binary>>) -> [<<"normal">>];
args_for(<<"bondy.cluster.leave">>) -> [atom_to_binary(partisan:node())];
args_for(<<"bondy.router.bridge.add">>) -> [bridge_spec()];
args_for(<<"bondy.mcp.overlay.load">>) -> [overlay_doc()].

%% @private
%% A minimal bridge relay specification that PARSES. It names an endpoint
%% nothing is listening on, deliberately: the dry run must not connect, and a
%% case that passed only because the endpoint was unreachable would be proving
%% nothing about the dry run. `restart => transient` keeps a real add — which
%% is what `a_dry_run_bridge_add_holds_nothing` proves does not happen — out
%% of the durable store.
bridge_spec() ->
    {Pub, Priv} = crypto:generate_key(eddsa, ed25519),
    #{
        <<"name">> => ?BRIDGE_NAME,
        <<"transport">> => <<"tcp">>,
        <<"endpoint">> => <<"127.0.0.1:18099">>,
        <<"restart">> => <<"transient">>,
        <<"realms">> => [
            #{
                <<"uri">> => ?MASTER_REALM_URI,
                <<"authid">> => <<"ct_dry_run_bridge">>,
                <<"cryptosign">> => #{
                    <<"pubkey">> => hex(Pub),
                    <<"privkey">> => hex(Priv)
                }
            }
        ]
    }.

%% @private
hex(Bin) ->
    binary:encode_hex(Bin, lowercase).

%% @private
%% A minimal, valid overlay document naming the master realm, which always
%% exists. `check/1` asserts realm existence, so a document naming a realm this
%% suite did not create would fail validation and the case would pass for the
%% wrong reason.
overlay_doc() ->
    #{
        <<"id">> => ?DOC_ID,
        <<"entries">> => [
            #{
                <<"realm">> => ?MASTER_REALM_URI,
                <<"kind">> => <<"tool">>,
                <<"name">> => <<"ct_dry_run_tool">>,
                <<"wamp_procedure">> => <<"bondy.ping">>
            }
        ]
    }.

%% @private
%% A listener bound to a real TCP port in the `normal` phase, so a connection
%% attempt is a meaningful test of whether the phase is accepting.
a_normal_phase_tcp_listener() ->
    Candidates = [
        Name
     || #{name := Name, start_phase := normal, bind := {port, _}} <-
            bondy_listener_manager:listeners()
    ],
    case Candidates of
        [Name | _] -> Name;
        [] -> ct:fail(no_normal_phase_tcp_listener)
    end.

%% @private
handle(Proc, Args, KWArgs) ->
    Ctxt = bondy_context:local_context(?MASTER_REALM_URI),
    M = bondy_wamp_message:call(1, #{}, Proc, Args, KWArgs),
    bondy_wamp_api:handle_call(M, Ctxt).

%% @private
call(Proc, Args, KWArgs) ->
    case handle(Proc, Args, KWArgs) of
        {reply, #result{args = [Reply]}} -> Reply;
        Other -> ct:fail({expected_result, Proc, Other})
    end.

%% @private
call_ok(Proc, Args, KWArgs) ->
    case handle(Proc, Args, KWArgs) of
        {reply, #result{}} -> ok;
        Other -> ct:fail({expected_result, Proc, Other})
    end.

%% @private
call_error(Proc, Args, KWArgs) ->
    try handle(Proc, Args, KWArgs) of
        {reply, #error{} = E} -> E;
        Other -> ct:fail({expected_error, Proc, Other})
    catch
        error:#error{} = E -> E
    end.
