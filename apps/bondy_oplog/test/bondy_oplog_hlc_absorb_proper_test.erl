%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Step 8 of BONDY_DB_RECLAMATION_PLAN.md (built alongside Step 0b, as the
%% plan directs) — the A3 property on which the entire Canteen→POLog upgrade
%% rests (Case 2 of the Theorem in BONDY_DB_RECLAMATION_PROOF.md):
%%
%%   After delivering an event with HLC `h`, every subsequently created local
%%   event has HLC `> h` — on EVERY delivery path.
%%
%% Three delivery paths, two properties:
%%   - push (`append_remote`) and AAE (`sync` → `integrate_peer_root`),
%%     interleaved with local mints — `prop_interleaved_deliveries_absorb`;
%%   - catalogue-snapshot bootstrap against a COMPACTED peer (the case where
%%     the AAE rescue no-ops on `bondy_mst:last/1 =:= undefined`) —
%%     `prop_bootstrap_absorbs`.
%%
%% GENERATOR SUBTLETY (without this the property is theater): local mints take
%% `max(OldPhys, Wall)`, so delivered HLCs at or below the local wall clock
%% make the property pass vacuously even with absorption broken. Every
%% delivered HLC here is minted with a physical component AHEAD of the wall
%% clock (`?OFFSET_MS`), so a missing absorb is observable.
%% =============================================================================

-module(bondy_oplog_hlc_absorb_proper_test).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(B, <<>>).
%% Far-future physical offsets, milliseconds ahead of the wall clock.
-define(OFFSET_MS, range(60_000, 3_600_000)).

%% =============================================================================
%% EUNIT WRAPPER (the properties also run under `rebar3 proper`)
%% =============================================================================

hlc_absorb_props_test_() ->
    {setup, fun setup_app/0, fun cleanup_app/1, [
        {"interleaved push/AAE deliveries absorb",
            {timeout, 300, fun() ->
                ?assert(
                    proper:quickcheck(
                        prop_interleaved_deliveries_absorb(),
                        [{numtests, 100}, {to_file, user}]
                    )
                )
            end}},
        {"catalogue bootstrap absorbs",
            {timeout, 300, fun() ->
                ?assert(
                    proper:quickcheck(
                        prop_bootstrap_absorbs(),
                        [{numtests, 50}, {to_file, user}]
                    )
                )
            end}}
    ]}.

setup_app() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup_app(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

%% =============================================================================
%% PROPERTY 1 — push + AAE, interleaved with local mints
%% =============================================================================

%% Abstract command stream. Sequence numbers and origins are assigned
%% deterministically during execution; the generator only chooses the shape.
cmd() ->
    frequency([
        {4, local},
        {3, {push, ?OFFSET_MS}},
        {2, {seed_peer, ?OFFSET_MS}},
        {2, sync}
    ]).

prop_interleaved_deliveries_absorb() ->
    ?FORALL(
        Cmds,
        non_empty(list(cmd())),
        begin
            ok = setup_app(),
            L = start_plain("hal"),
            P = start_plain("hap"),
            try
                %% Always close with a local mint so a trailing delivery is
                %% checked too.
                St = lists:foldl(
                    fun(Cmd, St0) -> run_cmd(Cmd, L, P, St0) end,
                    #{max_delivered => 0, p_max => 0, seq => 0, ok => true},
                    Cmds ++ [local]
                ),
                ?WHENFAIL(
                    io:format(
                        user,
                        "Cmds: ~p~nFinal: ~p~n",
                        [Cmds, maps:without([ok], St)]
                    ),
                    aggregate(
                        [cmd_name(C) || C <- Cmds],
                        maps:get(ok, St)
                    )
                )
            after
                catch bondy_oplog:stop_instance(L),
                catch bondy_oplog:stop_instance(P)
            end
        end
    ).

%% @private
run_cmd(local, L, _P, #{max_delivered := Max, ok := Ok} = St) ->
    K = bondy_oplog:append(L, {op, maps:get(seq, St)}),
    Hlc = bondy_oplog_event:key_hlc(K),
    %% THE INVARIANT: a local mint strictly dominates every delivered HLC.
    St#{ok := Ok andalso (Max =:= 0 orelse Hlc > Max)};
run_cmd({push, Off}, L, _P, #{seq := Seq} = St) ->
    Hlc = far_hlc(Off),
    ok = bondy_oplog:append_remote(L, remote_event(<<"prop-push">>, Hlc, Seq)),
    St#{
        max_delivered := max(maps:get(max_delivered, St), Hlc),
        seq := Seq + 1
    };
run_cmd({seed_peer, Off}, _L, P, #{seq := Seq} = St) ->
    %% Seeded into the PEER only — not delivered to L until a `sync`.
    Hlc = far_hlc(Off),
    ok = bondy_oplog:append_remote(P, remote_event(<<"prop-seed">>, Hlc, Seq)),
    St#{p_max := max(maps:get(p_max, St), Hlc), seq := Seq + 1};
run_cmd(sync, L, P, #{p_max := PMax} = St) ->
    %% The AAE path: L pulls P's pages; `integrate_peer_root` must absorb.
    {ok, _} = bondy_oplog:sync(L, P),
    St#{max_delivered := max(maps:get(max_delivered, St), PMax)}.

%% @private
cmd_name(local) -> local;
cmd_name({push, _}) -> push;
cmd_name({seed_peer, _}) -> seed_peer;
cmd_name(sync) -> sync.

%% =============================================================================
%% PROPERTY 2 — catalogue-snapshot bootstrap from a compacted peer
%% =============================================================================

prop_bootstrap_absorbs() ->
    ?FORALL(
        {NCells, Off},
        {range(1, 5), ?OFFSET_MS},
        begin
            ok = setup_app(),
            {Peer, PeerNS} = start_catalogue("bap"),
            {Local, LocalNS} = start_catalogue("bal"),
            try
                MaxHlc = far_hlc(Off),
                Hlcs = lists:seq(MaxHlc - NCells + 1, MaxHlc),
                [
                    bondy_oplog:append(
                        Peer,
                        {cell_apply, ?B, integer_to_binary(H),
                            {set, H, <<"v">>}}
                    )
                 || H <- Hlcs
                ],
                ok = bondy_oplog_instance:await_apply(Peer),
                %% Compact the peer's MST away entirely, so the post-bootstrap
                %% AAE round cannot rescue the clock via `bondy_mst:last/1`.
                {ok, LastKey} = bondy_oplog_instance:latest_key(Peer),
                _ = bondy_oplog_instance:truncate_prefix(Peer, LastKey),

                {ok, _} = bondy_oplog_sync_session:bootstrap_catalogue(
                    Local, Peer, #{transport_opts => #{}}
                ),

                ProbeKey = bondy_oplog:append(
                    Local, {cell_apply, ?B, <<"probe">>, {set, <<"p">>}}
                ),
                ProbeHlc = bondy_oplog_event:key_hlc(ProbeKey),
                ?WHENFAIL(
                    io:format(
                        user,
                        "NCells: ~p MaxHlc: ~p ProbeHlc: ~p~n",
                        [NCells, MaxHlc, ProbeHlc]
                    ),
                    ProbeHlc > MaxHlc
                )
            after
                catch bondy_oplog:stop_instance(Peer),
                catch bondy_oplog:stop_instance(Local),
                unregister_ns(PeerNS),
                unregister_ns(LocalNS)
            end
        end
    ).

%% =============================================================================
%% HELPERS
%% =============================================================================

far_hlc(OffsetMs) ->
    bondy_oplog_hlc:encode(
        erlang:system_time(millisecond) + OffsetMs, 0
    ).

remote_event(Origin, Hlc, Seq) ->
    bondy_oplog_event:new(
        bondy_oplog_event:key(Hlc, Origin, Seq + 1),
        {peer_op, Seq},
        undefined
    ).

start_plain(Prefix) ->
    Id = mk_id(Prefix),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        origin => bondy_oplog_origin:new()
    }),
    Id.

start_catalogue(Prefix) ->
    Id = mk_id(Prefix),
    NS = binary_to_atom(<<"ns_", Id/binary>>, utf8),
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, primary, 0, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, primary, 0, #{}),
    ok = bondy_oplog_core_registry:register(NS, primary, 0, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        overlay => disabled,
        fold_module => lww_register
    }),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        origin => bondy_oplog_origin:new(),
        applier => #{cell_apply_target => {NS, primary, 0}}
    }),
    {Id, NS}.

unregister_ns(NS) ->
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)],
        N =:= NS
    ],
    ok.

mk_id(Prefix) ->
    iolist_to_binary([
        Prefix,
        "_",
        integer_to_binary(erlang:unique_integer([positive, monotonic]))
    ]).
