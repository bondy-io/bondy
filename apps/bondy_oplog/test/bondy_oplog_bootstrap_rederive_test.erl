%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% PR-G op-replay gate: a LIVE replica re-bootstrapping from a peer must
%% NOT lose a per-Origin-accumulating CRDT's contributions.
%%
%% The catalogue snapshot install is `replace` (skip-if-older by HLC).
%% That is correct for a register (the higher-HLC value wins) but WRONG for
%% a counter: replacing a counter cell with the peer's higher-HLC state
%% drops the contributions of any Origin that state does not carry. What
%% restores them is the post-bootstrap full re-derive (`op-replay`), which
%% re-folds the complete local+peer event set.
%%
%% This pins the convergence: two live replicas each increment the same
%% counter cell under a distinct Origin, then one re-bootstraps from the
%% other. The peer's cell HLC is forced higher so the replace genuinely
%% INSTALLS (clobbers) the local cell (verified: installed=1, not skipped),
%% and the result must still be the SUM. The post-bootstrap op-replay (a
%% full re-fold of the merged MST) is what guarantees this in general,
%% independent of how a cell's events are laid out across MST pages.

-module(bondy_oplog_bootstrap_rederive_test).

-include_lib("eunit/include/eunit.hrl").

-define(B, <<>>).
-define(K, <<"counter">>).

rederive_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"fold path (pn_counter)",
            {timeout, 30, fun() -> converges_after_clobber(undefined) end}},
        {"native crdt path (flipped pn_counter twin)",
            {timeout, 30, fun() ->
                converges_after_clobber(bondy_oplog_crdt_pn_counter)
            end}}
    ]}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)]
    ],
    ok.

%% `CrdtMod = undefined` exercises the legacy fold kernel; the native
%% `bondy_oplog_crdt_pn_counter` twin exercises the flipped op-based kernel
%% (the default after PR-G). The rederive mechanism is kernel-agnostic, so
%% both must converge identically.
converges_after_clobber(CrdtMod) ->
    {Peer, _} = setup_counter_instance(CrdtMod),
    {Local, LocalEntry} = setup_counter_instance(CrdtMod),

    %% Each live replica increments the SAME counter cell under its own
    %% Origin. Local writes once; Peer writes TWICE (the second is an HLC-
    %% bumping `+0` no-op), so Peer's cell HLC is deterministically higher
    %% than Local's and wins the skip-if-older `replace` — genuinely
    %% INSTALLING (clobbering) Local's +5 in the projection (installed=1,
    %% not skipped). The post-bootstrap op-replay (full re-fold of the
    %% merged MST) is what guarantees convergence to the SUM in general,
    %% independent of how a cell's events are laid out across MST pages.
    ok = inc(Local, 5),
    ok = inc(Peer, 3),
    ok = inc(Peer, 0),

    ?assertEqual(live, bondy_oplog_instance:lifecycle_state(Local)),
    ?assertEqual(5, counter_value(LocalEntry)),

    %% Local re-bootstraps from Peer (replace-install + anti-entropy +
    %% op-replay). The counter must converge to the SUM (5 + 3), proving
    %% both Origins' contributions survived.
    {ok, _} = bondy_oplog_sync_session:bootstrap_catalogue(Local, Peer, #{}),
    ?assertEqual(8, counter_value(LocalEntry)),

    teardown(Peer),
    teardown(Local).

%% =============================================================================
%% Helpers
%% =============================================================================

setup_counter_instance(CrdtMod) ->
    Id = mk_id(),
    NS = ns_of(Id),
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, primary, 0, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, primary, 0, #{}),
    Base = #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        overlay => disabled,
        fold_module => pn_counter
    },
    %% The applier resolves its kernel from the registry entry's
    %% (fold_module, crdt_module): a `crdt_module` selects the native
    %% op-based twin (the flipped default), else the legacy fold.
    RegConfig =
        case CrdtMod of
            undefined -> Base;
            _ -> Base#{crdt_module => CrdtMod}
        end,
    ok = bondy_oplog_core_registry:register(NS, primary, 0, RegConfig),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => pn_counter,
        %% Distinct per-replica origin: a counter accumulates per Origin, so
        %% two replicas sharing an Origin would collide on `{Origin, Seq}`
        %% and dedup each other's increments (the #11 hazard). The default
        %% in-process origin is shared, so pin a fresh one per instance.
        origin => bondy_oplog_origin:new(),
        applier => #{cell_apply_target => {NS, primary, 0}}
    }),
    {ok, Entry} = bondy_oplog_core_registry:lookup(NS, primary, 0),
    {Id, Entry}.

inc(Id, Delta) ->
    _ = bondy_oplog:append(Id, {cell_apply, ?B, ?K, {inc, Delta}}),
    _ = bondy_oplog:projection(Id),
    ok.

counter_value(Entry) ->
    Adapter = bondy_oplog_core_registry:entry_projection_adapter(Entry),
    Handle = bondy_oplog_core_registry:entry_projection_handle(Entry),
    case Adapter:get(Handle, ?B, ?K) of
        not_found ->
            0;
        {ok, Frame} ->
            {_Hlc, StateBytes, _ValueBytes} =
                bondy_oplog_cell_frame:decode_full(Frame),
            bondy_oplog_crdt_pn_counter:to_value(
                bondy_oplog_crdt_pn_counter:decode_state(StateBytes)
            )
    end.

teardown(Id) ->
    bondy_oplog:stop_instance(Id),
    NS = ns_of(Id),
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)],
        N =:= NS
    ],
    ok.

mk_id() ->
    iolist_to_binary([
        "brd_", integer_to_binary(erlang:unique_integer([positive]))
    ]).

ns_of(Id) when is_binary(Id) ->
    binary_to_atom(<<"ns_", Id/binary>>, utf8).
