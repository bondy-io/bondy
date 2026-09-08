%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Unit tests for `bondy_oplog_crdt_owned_counter` — the tier_0 carrier for
%% RIB cells, a `bondy_oplog_crdt_pn_counter` plus `reap_origins/2`.
%%
%% Three groups, in the order the design depends on them:
%%
%%   1. it IS a pn_counter — byte-identical encoding and delegated
%%      semantics, so naming it in a table is not a data migration;
%%   2. the reap -> zero -> discard chain, which is how a departed node's
%%      cell is actually reclaimed;
%%   3. the guards: reaping is exact, idempotent, and a miss writes nothing.
%%
%% The state-size law that the tier_2 struct violated (and which is the whole
%% reason this module exists) is in
%% `bondy_oplog_crdt_owned_counter_proper_test`, where it belongs — a bound
%% quantified over write counts is a property, not an example.

-module(bondy_oplog_crdt_owned_counter_test).

-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_oplog_crdt_owned_counter).
-define(PN, bondy_oplog_crdt_pn_counter).
-define(DEAD, <<"dead-origin">>).
-define(LIVE, <<"live-origin">>).
%% Above any HLC these tests mint, so `stabilize/2` always reaches its
%% value test rather than short-circuiting on the stability guard.
-define(STABLE, (1 bsl 62)).

%% =============================================================================
%% 1. it IS a pn_counter
%% =============================================================================

causal_tier_is_tier_0_test() ->
    %% The ratchet. Promoting this carrier to a dot-based tier is what caused
    %% the measured subscribe regression; it must fail a test, not a
    %% benchmark.
    ?assertEqual(tier_0, ?MOD:causal_tier()),
    ?assertEqual(?PN:causal_tier(), ?MOD:causal_tier()).

encoding_is_byte_identical_to_pn_counter_test() ->
    State = counted(?DEAD, 7),
    ?assertEqual(?PN:encode_state(State), ?MOD:encode_state(State)).

decodes_a_pn_counter_encoding_test() ->
    %% Cross-module round-trip: bytes written by the table's previous carrier
    %% are read back identically by this one, which is what makes naming this
    %% module in `bondy_namespace_catalog:fold_opts/1` a carrier swap rather
    %% than a migration.
    State = counted(?DEAD, 5),
    ?assertEqual(State, ?MOD:decode_state(?PN:encode_state(State))),
    ?assertEqual(State, ?PN:decode_state(?MOD:encode_state(State))).

delegated_seam_agrees_with_pn_counter_test() ->
    State = counted(?DEAD, 4),
    ?assertEqual(?PN:to_value(State), ?MOD:to_value(State)),
    ?assertEqual(?PN:hlc(State), ?MOD:hlc(State)),
    ?assertEqual(?PN:state_to_op(State), ?MOD:state_to_op(State)),
    ?assertEqual(?PN:value_equals_state(), ?MOD:value_equals_state()),
    ?assertEqual(?PN:order_independent(), ?MOD:order_independent()),
    ?assertEqual(
        ?PN:stabilize(?STABLE, State), ?MOD:stabilize(?STABLE, State)
    ).

%% =============================================================================
%% 2. the reap -> zero -> discard chain
%% =============================================================================

reap_all_origins_zeroes_and_discards_test() ->
    %% The mechanism, end to end in one cell: a single-writer RIB cell whose
    %% only writer has departed. `reap_one_cell/6` re-encodes a
    %% VALUE-PRESERVING frame, so reclamation rests on `stabilize/2` reading
    %% the shrunk STATE — hence asserting the discard, not the value column.
    State = counted(?DEAD, 3),
    ?assertEqual(3, ?MOD:to_value(State)),
    ?assertEqual(keep, ?MOD:stabilize(?STABLE, State)),

    {Reaped, Ids} = ?MOD:reap_origins(State, [?DEAD]),

    ?assertEqual([?DEAD], Ids),
    ?assertEqual(0, ?MOD:to_value(Reaped)),
    ?assertEqual(discard, ?MOD:stabilize(?STABLE, Reaped)).

reap_covers_every_state_epoch_of_the_departed_node_test() ->
    %% An origin is an opaque state-epoch identity with no node attribution,
    %% so one node that rebooted contributes under several origins. All of
    %% them are dead once it leaves, and the cell must still reach zero.
    State = lists:foldl(
        fun({Origin, Seq}, Acc) ->
            ?MOD:apply_op(Acc, {inc, 1}, ev_key(Seq, Origin, Seq))
        end,
        ?MOD:init(),
        [{<<"epoch-1">>, 1}, {<<"epoch-1">>, 2}, {<<"epoch-2">>, 3}]
    ),
    ?assertEqual(3, ?MOD:to_value(State)),

    {Reaped, Ids} = ?MOD:reap_origins(
        State, [<<"epoch-2">>, <<"epoch-1">>]
    ),

    ?assertEqual([<<"epoch-1">>, <<"epoch-2">>], Ids),
    ?assertEqual(0, ?MOD:to_value(Reaped)),
    ?assertEqual(discard, ?MOD:stabilize(?STABLE, Reaped)).

%% =============================================================================
%% 3. the guards
%% =============================================================================

reap_is_exact_and_keeps_survivors_test() ->
    %% The control, and the reason this is a separate module rather than a
    %% callback on `bondy_oplog_crdt_pn_counter`: on a cell that is NOT
    %% single-writer, reaping removes exactly the dead origin's contribution
    %% and the survivor's value is real data that `stabilize/2` must keep.
    State = incs([{?DEAD, 10}, {?LIVE, 7}]),
    ?assertEqual(17, ?MOD:to_value(State)),

    {Reaped, Ids} = ?MOD:reap_origins(State, [?DEAD]),

    ?assertEqual([?DEAD], Ids),
    ?assertEqual(7, ?MOD:to_value(Reaped)),
    ?assertEqual(keep, ?MOD:stabilize(?STABLE, Reaped)).

reap_of_an_absent_origin_writes_nothing_test() ->
    %% The empty list is load-bearing: `reap_one_cell/6` skips the frame
    %% rewrite unless at least one origin was reaped, so an unmatched cell
    %% must cost a read and nothing else.
    State = counted(?LIVE, 2),
    ?assertEqual({State, []}, ?MOD:reap_origins(State, [?DEAD])).

reap_is_idempotent_test() ->
    %% A second pass over an already-reaped cell must report nothing, or
    %% every subsequent reap pass rewrites every cell it has ever touched.
    State = counted(?DEAD, 3),
    {Once, [?DEAD]} = ?MOD:reap_origins(State, [?DEAD]),
    ?assertEqual({Once, []}, ?MOD:reap_origins(Once, [?DEAD])).

reap_with_no_retired_origins_is_a_noop_test() ->
    State = counted(?DEAD, 3),
    ?assertEqual({State, []}, ?MOD:reap_origins(State, [])).

reaped_state_round_trips_test() ->
    %% The shrunk state is what gets encoded into the value-preserving frame,
    %% so it has to survive the encoding it is written through.
    {Reaped, _} = ?MOD:reap_origins(incs([{?DEAD, 4}, {?LIVE, 1}]), [?DEAD]),
    ?assertEqual(Reaped, ?MOD:decode_state(?MOD:encode_state(Reaped))).

%% =============================================================================
%% HELPERS
%% =============================================================================

ev_key(Hlc, Origin, Seq) ->
    bondy_oplog_event:key(Hlc, Origin, Seq).

%% One origin, N increments of 1.
counted(Origin, N) ->
    incs([{Origin, N}]).

%% `[{Origin, N}]` — N increments of 1 from each origin, seqs kept
%% per-origin-monotonic so none is dropped as a duplicate.
incs(Spec) ->
    {State, _} = lists:foldl(
        fun({Origin, N}, Acc0) ->
            lists:foldl(
                fun(Seq, {S, Hlc}) ->
                    {
                        ?MOD:apply_op(S, {inc, 1}, ev_key(Hlc, Origin, Seq)),
                        Hlc + 1
                    }
                end,
                Acc0,
                lists:seq(1, N)
            )
        end,
        {?MOD:init(), 1},
        Spec
    ),
    State.
