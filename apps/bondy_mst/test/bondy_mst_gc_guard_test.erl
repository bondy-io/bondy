%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% The list-mode GC's unservable-root guard.
%%
%% `prune_unreachable/2` marks by walking the keep-roots through PRESENT pages
%% (`fold_pages/4` silently skips a missing one), so a hole under the current
%% root under-marks everything below the hole and the sweep then deletes live,
%% reachable pages — amplifying a small anomaly (Fly s16: two absent pages)
%% into a large permanent loss. `bondy_mst:gc/2` therefore refuses to sweep
%% while the current root is unservable, keeps the garbage for the cycle, and
%% emits `[bondy_mst, gc, aborted]`.
%% =============================================================================

-module(bondy_mst_gc_guard_test).

-include_lib("eunit/include/eunit.hrl").

-define(N, 300).

gc_aborts_on_unservable_root_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    T0 = new_tree(),
    T = lists:foldl(
        fun(K, Acc) -> bondy_mst:put(Acc, K, K) end,
        T0,
        lists:seq(1, ?N)
    ),
    Tab = page_tab(bondy_mst:root(T)),
    {Hash, Row} = drop_root_referenced_page(Tab),

    SizeBefore = ets:info(Tab, size),
    Self = self(),
    Ref = make_ref(),
    HandlerId = {?MODULE, Ref},
    ok = telemetry:attach(
        HandlerId,
        [bondy_mst, gc, aborted],
        fun(_E, Meas, Meta, _) -> Self ! {Ref, Meas, Meta} end,
        undefined
    ),

    try
        T1 = bondy_mst:gc(T, []),

        %% The guard fired, attributed to the store's name (the instance id
        %% in production — what makes the dashboard counter actionable).
        receive
            {Ref, #{missing_count := 1}, #{
                reason := unservable_root, name := <<"gc_guard">>
            }} ->
                ok
        after 1000 ->
            error(gc_abort_event_not_emitted)
        end,

        %% ...and nothing was swept: without the guard the sweep would have
        %% deleted every page below the hole (the amplification).
        ?assertEqual(SizeBefore, ets:info(Tab, size)),

        %% Restoring the page heals the tree, and the next gc runs normally
        %% and leaves it fully servable.
        true = ets:insert(Tab, Row),
        T2 = bondy_mst:gc(T1, []),
        ?assertEqual([], bondy_mst:missing_set(T2, bondy_mst:root(T2))),
        ?assertEqual(?N, length(bondy_mst:to_list(T2))),

        %% And no second abort was emitted.
        receive
            {Ref, _, _} -> error(unexpected_second_abort)
        after 100 -> ok
        end,

        %% Silence unused-variable warnings by asserting identity: the guard
        %% returns the tree unchanged.
        ?assertEqual(bondy_mst:root(T), bondy_mst:root(T1)),
        _ = Hash,
        ok
    after
        telemetry:detach(HandlerId),
        catch bondy_mst:destroy(T)
    end.

%% =============================================================================
%% HELPERS
%% =============================================================================

new_tree() ->
    bondy_mst:new(#{
        store => bondy_mst_ets_store,
        store_opts => #{name => <<"gc_guard">>},
        merger => fun(_K, V, V) -> V end
    }).

%% The store's page table is owned by this (the test) process; identified by
%% its `<<"$root">>` row carrying THIS tree's root hash, so tables leaked by
%% sibling tests in the same runner process cannot be confused with it.
page_tab(RootHash) ->
    Self = self(),
    [Tab | _] = [
        T
     || T <- ets:all(),
        ets:info(T, owner) =:= Self,
        ets:info(T, type) =:= set,
        (catch ets:lookup(T, <<"$root">>)) =:= [{<<"$root">>, RootHash}]
    ],
    Tab.

%% Deletes the first page the root references, returning the row so the test
%% can restore it. The s16 fault, minimally.
drop_root_referenced_page(Tab) ->
    [{<<"$root">>, RootHash}] = ets:lookup(Tab, <<"$root">>),
    [{RootHash, RootPage, _}] = ets:lookup(Tab, RootHash),
    [Ref | _] = bondy_mst_page:refs(RootPage),
    [Row] = ets:lookup(Tab, Ref),
    true = ets:delete(Tab, Ref),
    {Ref, Row}.
