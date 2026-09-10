%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Range tests for `bondy_oplog_projection_ets`.
%%
%% `range/5` is the only callback with a non-obvious cost, and it is the one
%% every band-paging caller re-enters with a rising `Low`. It used to express
%% both bounds as match-spec GUARDS over an unbound key, which an
%% `ordered_set` cannot narrow on: each call re-traversed the bucket from its
%% first key, so paging a band of N rows cost O(N^2 / limit). It now probes
%% `Low` and steps forward with `ets:next_lookup/2`.
%%
%% Two groups:
%%
%%   1. the semantics the seek has to preserve — half-open bounds, an
%%      inclusive `Low` whether or not it is stored, `infinity`, the limit,
%%      and above all CONFINEMENT to the bucket, which is the property the
%%      walk could plausibly break (the successor of a bucket's last key
%%      belongs to the next bucket, and nothing but the key tag stops the
%%      walk there);
%%
%%   2. the cost law, as a ratchet. It is a test and not a benchmark because
%%      it is a statement about which rows are VISITED, not about how fast
%%      the machine is: a page taken at the far end of a bucket must not
%%      touch the rows before it.
%%
%% `bondy_oplog_projection_ets_proper_test` carries the differential
%% property: the seek and the guarded select it replaces agree on every
%% (corpus, bucket, low, high, limit) it can generate.

-module(bondy_oplog_projection_ets_test).

-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_oplog_projection_ets).
-define(B, <<"bucket">>).

range_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun range_is_ascending/1,
        fun range_excludes_the_high_bound/1,
        fun range_low_is_inclusive/1,
        fun range_low_absent_seeks_forward/1,
        fun range_respects_limit/1,
        fun range_limit_larger_than_data_returns_all/1,
        fun range_open_ended_high/1,
        fun range_is_confined_to_its_bucket/1,
        fun range_prefix_buckets_do_not_interleave/1,
        fun range_over_empty_bucket/1,
        fun range_non_positive_limit_is_empty/1,
        fun range_cost_is_flat_in_low/1
    ]}.

setup() ->
    {ok, Tab} = ?MOD:open(ns, primary, 0, #{}),
    Tab.

cleanup(Tab) ->
    ok = ?MOD:close(Tab).

%% =============================================================================
%% 1. semantics the seek must preserve
%% =============================================================================

range_is_ascending(Tab) ->
    fun() ->
        ok = put_keys(Tab, ?B, [<<"k03">>, <<"k01">>, <<"k02">>]),
        ?assertEqual(
            [<<"k01">>, <<"k02">>, <<"k03">>],
            keys(?MOD:range(Tab, ?B, <<>>, infinity, #{}))
        )
    end.

range_excludes_the_high_bound(Tab) ->
    fun() ->
        ok = put_keys(Tab, ?B, [<<"k01">>, <<"k02">>, <<"k03">>]),
        ?assertEqual(
            [<<"k01">>, <<"k02">>],
            keys(?MOD:range(Tab, ?B, <<"k01">>, <<"k03">>, #{}))
        )
    end.

range_low_is_inclusive(Tab) ->
    fun() ->
        %% `ets:next_lookup/2` is strictly-greater-than, so a stored `Low`
        %% is reachable only through `first_row/4`'s probe. Drop that probe
        %% and this is the test that fails.
        ok = put_keys(Tab, ?B, [<<"k01">>, <<"k02">>]),
        ?assertEqual(
            [<<"k01">>, <<"k02">>],
            keys(?MOD:range(Tab, ?B, <<"k01">>, infinity, #{}))
        )
    end.

range_low_absent_seeks_forward(Tab) ->
    fun() ->
        %% A `Low` that is not stored must land on its successor, not on
        %% `'$end_of_table'` — the paging callers advance `Low` to
        %% `<<LastKey, 0>>`, which is never itself a stored key.
        ok = put_keys(Tab, ?B, [<<"k02">>, <<"k04">>, <<"k06">>]),
        ?assertEqual(
            [<<"k04">>, <<"k06">>],
            keys(?MOD:range(Tab, ?B, <<"k03">>, infinity, #{}))
        ),
        ?assertEqual(
            [<<"k04">>, <<"k06">>],
            keys(?MOD:range(Tab, ?B, <<"k02", 0>>, infinity, #{}))
        )
    end.

range_respects_limit(Tab) ->
    fun() ->
        ok = put_keys(Tab, ?B, [key_n(I) || I <- lists:seq(1, 10)]),
        ?assertEqual(
            [key_n(1), key_n(2), key_n(3)],
            keys(?MOD:range(Tab, ?B, <<>>, infinity, #{limit => 3}))
        )
    end.

range_limit_larger_than_data_returns_all(Tab) ->
    fun() ->
        ok = put_keys(Tab, ?B, [key_n(I) || I <- lists:seq(1, 5)]),
        ?assertEqual(
            5, length(keys(?MOD:range(Tab, ?B, <<>>, infinity, #{limit => 99})))
        )
    end.

range_open_ended_high(Tab) ->
    fun() ->
        %% `infinity` is an ATOM, and atoms sort BEFORE binaries, so the
        %% upper-bound test cannot be a plain `Key < High` comparison. A
        %% key that would compare "greater than infinity" wrongly is any
        %% key at all — hence every row here, not just the last.
        ok = put_keys(Tab, ?B, [<<"k01">>, <<"k02">>, <<"k03">>]),
        ?assertEqual(
            [<<"k01">>, <<"k02">>, <<"k03">>],
            keys(?MOD:range(Tab, ?B, <<>>, infinity, #{}))
        )
    end.

range_is_confined_to_its_bucket(Tab) ->
    fun() ->
        %% The walk leaves the bucket by falling off its last key into the
        %% NEXT bucket's first key. Neighbours on both sides, so a walk that
        %% forgot to check the key tag reads `<<"c">>`'s rows, and a seek
        %% that started too low reads `<<"a">>`'s.
        ok = put_keys(Tab, <<"a">>, [<<"k01">>, <<"zzz">>]),
        ok = put_keys(Tab, ?B, [<<"k01">>, <<"k02">>]),
        ok = put_keys(Tab, <<"c">>, [<<"aaa">>, <<"k01">>]),
        ?assertEqual(
            [<<"k01">>, <<"k02">>],
            keys(?MOD:range(Tab, ?B, <<>>, infinity, #{}))
        ),
        %% ...and an open-ended scan starting past the last key stops
        %% rather than spilling into `<<"c">>`.
        ?assertEqual(
            [], keys(?MOD:range(Tab, ?B, <<"k03">>, infinity, #{}))
        )
    end.

range_prefix_buckets_do_not_interleave(Tab) ->
    fun() ->
        %% A bucket whose name is a PREFIX of another's. Tuple order
        %% compares element 1 in full before element 2, so `<<"a">>`'s rows
        %% all precede `<<"ab">>`'s and neither scan sees the other.
        ok = put_keys(Tab, <<"a">>, [<<"1">>, <<"9">>]),
        ok = put_keys(Tab, <<"ab">>, [<<"1">>, <<"9">>]),
        ?assertEqual(
            [<<"1">>, <<"9">>],
            keys(?MOD:range(Tab, <<"a">>, <<>>, infinity, #{}))
        ),
        ?assertEqual(
            [<<"1">>, <<"9">>],
            keys(?MOD:range(Tab, <<"ab">>, <<>>, infinity, #{}))
        )
    end.

range_over_empty_bucket(Tab) ->
    fun() ->
        ?assertEqual([], keys(?MOD:range(Tab, ?B, <<>>, infinity, #{}))),
        ok = put_keys(Tab, <<"other">>, [<<"k01">>]),
        ?assertEqual([], keys(?MOD:range(Tab, ?B, <<>>, infinity, #{})))
    end.

range_non_positive_limit_is_empty(Tab) ->
    fun() ->
        %% `Low` is served by a probe of its own, ahead of the walk's limit
        %% accounting, so a zero limit is the one input that can return a
        %% row the caller did not ask for.
        ok = put_keys(Tab, ?B, [<<"k01">>, <<"k02">>]),
        ?assertEqual(
            [], keys(?MOD:range(Tab, ?B, <<"k01">>, infinity, #{limit => 0}))
        )
    end.

%% =============================================================================
%% 2. the cost law
%% =============================================================================

range_cost_is_flat_in_low(Tab) ->
    {timeout, 60, fun() ->
        %% The regression this replaces, stated as a property of which rows
        %% are visited: a page taken near the END of a bucket must not visit
        %% the rows before it. Reductions are the oracle because ETS charges
        %% traversal to the calling process, so they count rows touched
        %% rather than machine speed.
        %%
        %% The guarded-select form scored ~0.95*N here. The bound is N/10 —
        %% loose enough that it is not a benchmark, tight enough that
        %% anything which re-traverses the prefix fails it.
        N = 50_000,
        Limit = 100,
        ok = put_keys(Tab, ?B, [key_n(I) || I <- lists:seq(1, N)]),

        Early = reductions(fun() ->
            ?MOD:range(Tab, ?B, key_n(N div 20), infinity, #{limit => Limit})
        end),
        Late = reductions(fun() ->
            ?MOD:range(Tab, ?B, key_n(N - N div 20), infinity, #{limit => Limit})
        end),

        ?assert(Late < N div 10),
        %% ...and flat, not merely sublinear: the two pages are the same
        %% size, so their costs may not differ by more than a small factor.
        ?assert(Late < 4 * Early)
    end}.

%% =============================================================================
%% HELPERS
%% =============================================================================

%% Reductions charged to this process by `Fun` — ETS traversal included.
reductions(Fun) ->
    {reductions, R0} = erlang:process_info(self(), reductions),
    _ = Fun(),
    {reductions, R1} = erlang:process_info(self(), reductions),
    R1 - R0.

put_keys(Tab, Bucket, Keys) ->
    ?MOD:put_batch(Tab, [{Bucket, K, frame(K)} || K <- Keys]).

%% The adapter stores frames opaquely, so any term round-trips; a tagged
%% tuple keeps a mismatched row identifiable if one ever surfaces.
frame(Key) ->
    {frame, Key}.

keys({ok, Rows}) ->
    [K || {K, _Frame} <- Rows].

key_n(I) ->
    iolist_to_binary(io_lib:format("k~8..0b", [I])).
