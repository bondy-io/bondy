%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Reachability property for the ephemeral (ETS) MST under the fused-instance
%% operation mix — the hunt for the P1 own-root page loss (Fly s16: two pages
%% of the CURRENT root absent from the page store; `diagnose_root` reported
%% `absent => 2`, recovery machinery since built, root cause open).
%%
%% Models exactly what a fused ephemeral instance does to its tree, in the
%% order it does it, all serialized (as production is — every mutation runs in
%% the instance gen_server):
%%
%%   - local installs        → `put/3`
%%   - a peer pull + merge   → `put_page/2` of the peer subtree's pages into
%%                             OUR store (the sync session's writes), then
%%                             `merge(T, T, PeerRoot)` — the production call in
%%                             `do_integrate_peer_root/2`, guarded by the same
%%                             `missing_set/2` pre-check
%%   - a PARTIAL pull        → only a random subset of the peer pages adopted;
%%                             the missing-set guard must then refuse the merge
%%                             (this is the pin-expiry / mid-pull-compaction
%%                             scenario: swept or not-yet-fetched pages)
%%   - compaction            → `gc(truncate(T, W), Pins)` — verbatim
%%                             `truncate_below_or_equal/4`, with pins drawn
%%                             from live AND stale peer roots (a stale pin is a
%%                             pin whose pages compaction already swept)
%%
%% INVARIANT (checked after EVERY op): the current root is fully servable —
%% `missing_set(T, root(T)) =:= []` — and the tree's contents equal the model
%% (an orddict of the puts and merged peer entries that survived truncation).
%% A violation is precisely the s16 defect class.
%%
%% Run:
%%   rebar3 as test proper --module=bondy_mst_gc_reachability_proper_test
%% =============================================================================

-module(bondy_mst_gc_reachability_proper_test).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([prop_own_root_always_servable/0]).

%% Keys are small integers so op sequences collide and share structure —
%% structural sharing is what makes the mark walk and the sweep interesting.
-define(KEY_RANGE, 200).

%% =============================================================================
%% EUNIT ENTRY POINT
%% =============================================================================

%% The property also runs under plain eunit so the whole-suite gate exercises
%% it; the standalone proper invocation gives it a bigger budget.
own_root_always_servable_test_() ->
    {timeout, 300, fun() ->
        ?assert(
            proper:quickcheck(
                prop_own_root_always_servable(),
                [{numtests, 300}, {max_size, 60}]
            )
        )
    end}.

%% =============================================================================
%% PROPERTY
%% =============================================================================

prop_own_root_always_servable() ->
    ?FORALL(
        Ops,
        list(op()),
        begin
            T0 = new_tree(),
            try
                {_T, _Model, _Roots, Result} = lists:foldl(
                    fun apply_op/2, {T0, orddict:new(), [], ok}, Ops
                ),
                Result =:= ok
            after
                try
                    bondy_mst:destroy(T0)
                catch
                    _:_ -> ok
                end
            end
        end
    ).

%% =============================================================================
%% GENERATORS
%% =============================================================================

op() ->
    frequency([
        {6, {put, key(), value()}},
        %% The production install path: every local WAL drain lands as one
        %% `put_batch/2` (`bondy_oplog_instance` install_local_batch).
        {4, {put_batch, non_empty(list(key()))}},
        {2, {merge_peer, peer_keys()}},
        {2, {partial_pull, peer_keys(), float(0.0, 1.0)}},
        {3, {compact, watermark_frac(), pins_selector()}}
    ]).

key() ->
    integer(1, ?KEY_RANGE).

value() ->
    %% Deterministic value per key: a re-put or a peer echo of the same key
    %% always carries the same value, as production event keys do (globally
    %% unique key ⇒ identical value on re-receive). The merger errors on
    %% divergence, which the property would surface as a crash.
    integer(1, 1).

peer_keys() ->
    non_empty(list(key())).

watermark_frac() ->
    float(0.0, 1.0).

pins_selector() ->
    %% Which of the recorded historical peer roots to pin during compaction:
    %% `live` = the most recent (production: an in-flight pull), `stale` = a
    %% random older one (production: an expired-TTL pin), `none` = no pins.
    oneof([none, live, stale]).

%% =============================================================================
%% MODEL
%% =============================================================================

new_tree() ->
    bondy_mst:new(#{
        store => bondy_mst_ets_store,
        store_opts => #{name => <<"gc_reachability">>},
        merger => fun(_K, V, V) -> V end
    }).

apply_op(_Op, {T, Model, Roots, {failed, _} = F}) ->
    %% Stop applying after the first failure; fold to the end.
    {T, Model, Roots, F};
apply_op({put, K, V}, {T0, Model0, Roots, ok}) ->
    T = bondy_mst:put(T0, K, V),
    Model = orddict:store(K, V, Model0),
    check(T, Model, Roots, {put, K});
apply_op({put_batch, Keys}, {T0, Model0, Roots, ok}) ->
    Pairs = [{K, 1} || K <- lists:usort(Keys)],
    T = bondy_mst:put_batch(T0, Pairs),
    Model = lists:foldl(
        fun({K, V}, Acc) -> orddict:store(K, V, Acc) end, Model0, Pairs
    ),
    check(T, Model, Roots, {put_batch, length(Pairs)});
apply_op({merge_peer, Keys}, {T0, Model0, Roots, ok}) ->
    {PeerT, PeerRoot} = peer_tree(Keys),
    try
        %% The pull: adopt EVERY peer page into our store (a completed
        %% multi-round pull), then the guarded integrate.
        T1 = adopt_pages(T0, PeerT, PeerRoot, 1.0),
        case bondy_mst:missing_set(T1, PeerRoot) of
            [] ->
                T = bondy_mst:merge(T1, T1, PeerRoot),
                Model = lists:foldl(
                    fun(K, Acc) -> orddict:store(K, 1, Acc) end, Model0, Keys
                ),
                check(T, Model, [PeerRoot | Roots], {merge_peer, PeerRoot});
            _ ->
                %% Adoption of every page cannot leave a hole.
                {T1, Model0, Roots, {failed, {pull_incomplete, PeerRoot}}}
        end
    after
        try
            bondy_mst:destroy(PeerT)
        catch
            _:_ -> ok
        end
    end;
apply_op({partial_pull, Keys, Fraction}, {T0, Model0, Roots, ok}) ->
    %% A pull abandoned mid-flight (session death, pin expiry + sweep): only
    %% a fraction of the peer pages land in our store. The tree must remain
    %% servable — the partial subtree is unreachable garbage until a later
    %% complete pull — and the production integrate guard (`missing_set`)
    %% must refuse the merge unless the adoption happened to be complete.
    {PeerT, PeerRoot} = peer_tree(Keys),
    try
        T1 = adopt_pages(T0, PeerT, PeerRoot, Fraction),
        case bondy_mst:missing_set(T1, PeerRoot) of
            [] ->
                %% Complete after all (small tree / fraction ~ 1.0): merging
                %% is then legal, mirroring production.
                T = bondy_mst:merge(T1, T1, PeerRoot),
                Model = lists:foldl(
                    fun(K, Acc) -> orddict:store(K, 1, Acc) end, Model0, Keys
                ),
                check(T, Model, [PeerRoot | Roots], {partial_pull, PeerRoot});
            [_ | _] ->
                %% Guard refused — our own root must be untouched.
                check(T1, Model0, [PeerRoot | Roots], {partial_refused})
        end
    after
        try
            bondy_mst:destroy(PeerT)
        catch
            _:_ -> ok
        end
    end;
apply_op({compact, Frac, PinSel}, {T0, Model0, Roots, ok}) ->
    Watermark = watermark(Model0, Frac),
    Pins = pins(PinSel, Roots),
    T =
        case Watermark of
            undefined ->
                bondy_mst:gc(T0, Pins);
            _ ->
                %% Verbatim `truncate_below_or_equal/4` (ets branch).
                bondy_mst:gc(bondy_mst:truncate(T0, Watermark), Pins)
        end,
    Model =
        case Watermark of
            undefined ->
                Model0;
            _ ->
                orddict:filter(fun(K, _) -> K > Watermark end, Model0)
        end,
    check(T, Model, Roots, {compact, Watermark, Pins}).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% The invariant: the current root is fully servable and the contents match
%% the model. Checked after EVERY op, as `diagnose_root` would.
check(T, Model, Roots, OpTag) ->
    case bondy_mst:root(T) of
        undefined ->
            %% An empty tree is vacuously servable; the model must agree.
            case orddict:size(Model) of
                0 ->
                    {T, Model, Roots, ok};
                _ ->
                    {T, Model, Roots, {failed, {tree_emptied, OpTag, Model}}}
            end;
        Root ->
            check_root(T, Root, Model, Roots, OpTag)
    end.

%% @private
check_root(T, Root, Model, Roots, OpTag) ->
    case bondy_mst:missing_set(T, Root) of
        [] ->
            Expected = orddict:to_list(Model),
            case lists:sort(bondy_mst:to_list(T)) of
                Expected ->
                    {T, Model, Roots, ok};
                Got ->
                    {T, Model, Roots,
                        {failed, {content_mismatch, OpTag, Expected, Got}}}
            end;
        Missing ->
            {T, Model, Roots, {failed, {own_root_unservable, OpTag, Missing}}}
    end.

%% Builds the peer's tree in its OWN store, as a real peer would hold it.
peer_tree(Keys) ->
    PeerT0 = new_tree(),
    PeerT = lists:foldl(
        fun(K, Acc) -> bondy_mst:put(Acc, K, 1) end, PeerT0, Keys
    ),
    {PeerT, bondy_mst:root(PeerT)}.

%% The sync session's page writes: walk the peer tree's pages and `put_page`
%% a fraction of them into OUR store. Fraction 1.0 = a completed pull.
%% Deterministic subset (every Nth) so shrinking stays meaningful.
adopt_pages(T0, PeerT, PeerRoot, Fraction) ->
    Pages = lists:reverse(
        bondy_mst:fold_pages(
            PeerT,
            fun({_Hash, Page}, Acc) -> [Page | Acc] end,
            [],
            #{root => PeerRoot}
        )
    ),
    Keep = max(0, round(length(Pages) * Fraction)),
    lists:foldl(
        fun(Page, Acc) ->
            {_Hash, Acc1} = bondy_mst:put_page(Acc, Page),
            Acc1
        end,
        T0,
        lists:sublist(Pages, Keep)
    ).

watermark(Model, Frac) ->
    case orddict:fetch_keys(Model) of
        [] ->
            undefined;
        Keys ->
            lists:nth(max(1, round(length(Keys) * Frac)), Keys)
    end.

pins(none, _) -> [];
pins(_, []) -> [];
pins(live, [R | _]) -> [R];
pins(stale, Roots) -> [lists:last(Roots)].
