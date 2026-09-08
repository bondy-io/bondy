%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% PropEr properties for `bondy_oplog_crdt_owned_counter`.
%%
%% The headline property here is `prop_state_size_is_independent_of_writes/0`,
%% and it exists because its absence let a production regression ship. The RIB
%% subscription cell was wrapped in `bondy_oplog_crdt_struct` to carry a
%% `force_reap` policy, which moved it to tier_2, where the add-wins state
%% accumulates one dot per UNSTABILIZED write. Every correctness property
%% still passed — convergence, idempotence, round-trip, the value oracle — and
%% none of them looks at how big the state is. Measured afterwards on the Fly
%% fleet: subscribe latency 198ms -> 6-23s, and locally 152 bytes -> 269 KB
%% over 4096 writes.
%%
%% So: a cost law, quantified over write count, sitting beside the correctness
%% laws. It is the one property that distinguishes this carrier from the one
%% it replaces, which is exactly why it is worth a property rather than an
%% example.
%%
%% The reap laws mirror `bondy_oplog_crdt_struct_proper_test`'s, minus the
%% per-field `force_reap` licensing (this carrier's licence is the table
%% declaration, not a schema — see the module's moduledoc).

-module(bondy_oplog_crdt_owned_counter_proper_test).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_oplog_crdt_owned_counter).
-define(PN, bondy_oplog_crdt_pn_counter).
-define(ORIGINS, [<<"a">>, <<"b">>, <<"c">>]).
-define(DELTAS, [-2, -1, 1, 2]).
-define(STABLE, (1 bsl 62)).
-define(DEFAULT_NUMTESTS, 300).

-export([prop_state_size_is_independent_of_writes/0]).
-export([prop_apply_agrees_with_pn_counter/0]).
-export([prop_encode_state_roundtrip/0]).
-export([prop_reap_removes_exactly_the_retired_contributions/0]).
-export([prop_reap_origins_idempotent/0]).
-export([prop_reap_all_writers_zeroes_and_discards/0]).

%% =============================================================================
%% The cost law
%% =============================================================================

-doc false.
prop_state_size_is_independent_of_writes() ->
    %% The encoded state is bounded by a function of the DISTINCT ORIGINS
    %% alone. The bound is per-origin: `bondy_oplog_crdt_pn_counter`'s
    %% encoding is an 8-byte HLC, a 4-byte count, and per origin a 2-byte
    %% length + the origin bytes + three 8-byte integers. Anything that grows
    %% with the number of writes — a dot per operation, a tombstone per
    %% removal — breaks this, which is the whole point.
    ?FORALL(
        Writes,
        non_empty(list(write_gen())),
        begin
            State = build(Writes),
            Origins = lists:usort([O || {O, _D} <- Writes]),
            Bound =
                8 + 4 +
                    lists:sum([byte_size(O) + 2 + 24 || O <- Origins]),
            byte_size(?MOD:encode_state(State)) =:= Bound
        end
    ).

%% =============================================================================
%% It is a pn_counter
%% =============================================================================

-doc false.
prop_apply_agrees_with_pn_counter() ->
    %% Delegation is total: for any op sequence the two carriers hold the
    %% same state and encode to the same bytes, so naming this module in a
    %% table is a carrier swap, not a data migration.
    ?FORALL(
        Writes,
        list(write_gen()),
        begin
            Mine = build(Writes),
            Theirs = build_with(?PN, Writes),
            Mine =:= Theirs andalso
                ?MOD:encode_state(Mine) =:= ?PN:encode_state(Theirs) andalso
                ?MOD:to_value(Mine) =:= ?PN:to_value(Theirs)
        end
    ).

-doc false.
prop_encode_state_roundtrip() ->
    ?FORALL(
        Writes,
        list(write_gen()),
        begin
            State = build(Writes),
            ?MOD:decode_state(?MOD:encode_state(State)) =:= State
        end
    ).

%% =============================================================================
%% Reap laws
%% =============================================================================

-doc false.
prop_reap_removes_exactly_the_retired_contributions() ->
    %% Exactness, stated as an oracle rather than a re-implementation: the
    %% reaped value equals the value of a counter built from the surviving
    %% writes alone. Catches both over-reaping (dropping a live origin) and
    %% under-reaping (leaving a dead one in).
    ?FORALL(
        {Writes, Retired},
        {non_empty(list(write_gen())), list(oneof(?ORIGINS))},
        begin
            Dead = lists:usort(Retired),
            {Reaped, Ids} = ?MOD:reap_origins(build(Writes), Dead),
            Survivors = [W || {O, _} = W <- Writes, not lists:member(O, Dead)],
            Present = lists:usort([O || {O, _D} <- Writes]),
            Expected = [O || O <- Dead, lists:member(O, Present)],
            Ids =:= Expected andalso
                ?MOD:to_value(Reaped) =:= ?MOD:to_value(build(Survivors))
        end
    ).

-doc false.
prop_reap_origins_idempotent() ->
    %% A second pass must report `[]`, or every later reap rewrites every
    %% cell it has already touched — `reap_one_cell/6` gates its frame write
    %% on a non-empty id list.
    ?FORALL(
        {Writes, Retired},
        {list(write_gen()), list(oneof(?ORIGINS))},
        begin
            {Once, _} = ?MOD:reap_origins(build(Writes), Retired),
            ?MOD:reap_origins(Once, Retired) =:= {Once, []}
        end
    ).

-doc false.
prop_reap_all_writers_zeroes_and_discards() ->
    %% The reclamation chain for a single-writer RIB cell, generalised: reap
    %% every origin that ever wrote and the state's value is 0, so
    %% `stabilize/2` discards the cell. `reap_one_cell/6` preserves the value
    %% column, so the discard is what actually reclaims.
    ?FORALL(
        Writes,
        non_empty(list(write_gen())),
        begin
            All = lists:usort([O || {O, _D} <- Writes]),
            {Reaped, Ids} = ?MOD:reap_origins(build(Writes), All),
            Ids =:= All andalso
                ?MOD:to_value(Reaped) =:= 0 andalso
                ?MOD:stabilize(?STABLE, Reaped) =:= discard
        end
    ).

%% =============================================================================
%% Generators / helpers
%% =============================================================================

write_gen() ->
    {oneof(?ORIGINS), oneof(?DELTAS)}.

build(Writes) ->
    build_with(?MOD, Writes).

%% Folds `{Origin, Delta}` writes, keeping each origin's seq strictly
%% increasing so no write is dropped as a duplicate by the per-origin
%% `MaxSeq` dedup (which would make the size bound and the value oracle
%% disagree with the write list for reasons unrelated to the property).
build_with(Mod, Writes) ->
    {State, _, _} = lists:foldl(
        fun({Origin, Delta}, {S, Hlc, Seqs}) ->
            Seq = maps:get(Origin, Seqs, 0) + 1,
            Key = bondy_oplog_event:key(Hlc, Origin, Seq),
            {Mod:apply_op(S, {inc, Delta}, Key), Hlc + 1, Seqs#{Origin => Seq}}
        end,
        {Mod:init(), 1, #{}},
        Writes
    ),
    State.

%% =============================================================================
%% EUnit wrapper
%% =============================================================================

properties_test_() ->
    {timeout, 240, fun() ->
        Opts = [{to_file, user}, {numtests, ?DEFAULT_NUMTESTS}],
        Props = [
            prop_state_size_is_independent_of_writes(),
            prop_apply_agrees_with_pn_counter(),
            prop_encode_state_roundtrip(),
            prop_reap_removes_exactly_the_retired_contributions(),
            prop_reap_origins_idempotent(),
            prop_reap_all_writers_zeroes_and_discards()
        ],
        lists:foreach(
            fun(Prop) -> ?assert(proper:quickcheck(Prop, Opts)) end,
            Props
        )
    end}.
