%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Differential property for `bondy_oplog_projection_ets:range/5`.
%%
%% The seek-and-walk implementation replaced a match-spec form whose bounds
%% were GUARDS over an unbound key. That form was slow — it re-traversed the
%% bucket from its first key on every call — but it was CORRECT, which makes
%% it the right oracle: it is kept here verbatim, and the property is that
%% the two agree on every input this can generate.
%%
%% That is the falsification the example tests cannot give. The seek walk
%% reconstructs the range from three separate decisions — where to start
%% (`first_row/4`'s probe of `Low`, then the walk), when to stop (the key
%% tag, and an upper bound that must special-case the atom `infinity`), and
%% what counts against the limit — each a place to be off by one row.
%% The generators are tuned so those seams are actually hit: buckets that
%% are prefixes of one another, bounds drawn from the same alphabet as the
%% stored keys (so `Low` and `High` are often stored keys, often not, and
%% often inverted so that `Low >= High`), and limits small enough to
%% truncate.
%%
%% What it does NOT cover: concurrent mutation during a walk. Neither form
%% is a snapshot — both traverse a live `public` table — and no sequential
%% property can produce that interleaving. The walk steps with
%% `ets:next_lookup/2` so that the sharpest case (a row deleted between
%% reading its key and reading its value) cannot arise at all rather than
%% being handled by an untestable branch; see `range/5`'s docs.

-module(bondy_oplog_projection_ets_proper_test).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_oplog_projection_ets).
-define(BUCKETS, [<<"a">>, <<"ab">>, <<"b">>]).
-define(DEFAULT_NUMTESTS, 500).

-export([prop_agrees_with_the_guarded_select/0]).
-export([prop_never_leaves_its_bucket/0]).
-export([prop_deletions_are_reflected/0]).

%% =============================================================================
%% Properties
%% =============================================================================

-doc false.
prop_agrees_with_the_guarded_select() ->
    ?FORALL(
        {Corpus, Bucket, Low, High, Limit},
        {corpus_gen(), oneof(?BUCKETS), key_gen(), high_gen(), limit_gen()},
        with_table(Corpus, fun(Tab) ->
            {ok, Got} = ?MOD:range(Tab, Bucket, Low, High, #{limit => Limit}),
            Got =:= guarded_select(Tab, Bucket, Low, High, Limit)
        end)
    ).

-doc false.
prop_never_leaves_its_bucket() ->
    %% Stated independently of the oracle: whatever the walk returns, every
    %% key of it is stored under the bucket that was asked for. A walk that
    %% ran off the end of its bucket returns the NEXT bucket's rows, whose
    %% keys are indistinguishable from its own by shape alone — so the check
    %% is against the corpus, not against the key.
    ?FORALL(
        {Corpus, Bucket, Low, High, Limit},
        {corpus_gen(), oneof(?BUCKETS), key_gen(), high_gen(), limit_gen()},
        with_table(Corpus, fun(Tab) ->
            {ok, Got} = ?MOD:range(Tab, Bucket, Low, High, #{limit => Limit}),
            Stored = [K || {B, K} <- Corpus, B =:= Bucket],
            lists:all(fun({K, _F}) -> lists:member(K, Stored) end, Got)
        end)
    ).

-doc false.
prop_deletions_are_reflected() ->
    %% Deleting rows leaves GAPS in the bucket, which the walk must close
    %% without losing its place: the page has to be the first `Limit`
    %% SURVIVORS, not the survivors among the first `Limit` stored keys.
    %% (This does not reach a row deleted mid-walk — `ets:delete/3` removes
    %% it before the scan starts, so the traversal never yields it. That
    %% case is designed out, not tested; see the module docs.)
    ?FORALL(
        {Corpus, Bucket, Doomed, Limit},
        {corpus_gen(), oneof(?BUCKETS), list(key_gen()), limit_gen()},
        with_table(Corpus, fun(Tab) ->
            _ = [?MOD:delete(Tab, Bucket, K) || K <- Doomed],
            {ok, Got} = ?MOD:range(Tab, Bucket, <<>>, infinity, #{
                limit => Limit
            }),
            Survivors = lists:usort([
                K
             || {B, K} <- Corpus, B =:= Bucket, not lists:member(K, Doomed)
            ]),
            [K || {K, _F} <- Got] =:= lists:sublist(Survivors, Limit)
        end)
    ).

%% =============================================================================
%% The oracle
%% =============================================================================

%% The implementation `range/5` replaced, verbatim. Correct but O(position):
%% an `ordered_set` narrows on a bound key PATTERN, never on a `>=` GUARD,
%% so this traverses the bucket from its first key every call.
guarded_select(Tab, Bucket, Low, High, Limit) ->
    Guards =
        case High of
            infinity ->
                [
                    {'=:=', '$1', {const, Bucket}},
                    {'>=', '$2', {const, Low}}
                ];
            _ ->
                [
                    {'=:=', '$1', {const, Bucket}},
                    {'>=', '$2', {const, Low}},
                    {'<', '$2', {const, High}}
                ]
        end,
    MS = [{{{'$1', '$2'}, '$3'}, Guards, [{{'$2', '$3'}}]}],
    case ets:select(Tab, MS, Limit) of
        '$end_of_table' -> [];
        {Found, _Cont} -> Found
    end.

%% =============================================================================
%% Generators / helpers
%% =============================================================================

%% Distinct `{Bucket, Key}` pairs. Duplicates would make the corpus and the
%% table disagree on size, which the bucket-confinement property compares
%% against.
corpus_gen() ->
    ?LET(Pairs, list({oneof(?BUCKETS), key_gen()}), lists:usort(Pairs)).

%% Bounds come from the SAME alphabet as the stored keys, so `Low`/`High`
%% land on stored keys about as often as between them — which is what
%% exercises both branches of `first_row/4`.
key_gen() ->
    oneof([<<"k01">>, <<"k02">>, <<"k03">>, <<"k04">>, <<"k05">>]).

high_gen() ->
    oneof([infinity, <<"k01">>, <<"k03">>, <<"k05">>, <<"k99">>, <<>>]).

limit_gen() ->
    oneof([1, 2, 3, 1000]).

with_table(Corpus, Fun) ->
    {ok, Tab} = ?MOD:open(ns, primary, 0, #{}),
    try
        ok = ?MOD:put_batch(Tab, [{B, K, {frame, B, K}} || {B, K} <- Corpus]),
        Fun(Tab)
    after
        ok = ?MOD:close(Tab)
    end.

%% =============================================================================
%% EUnit wrapper
%% =============================================================================

properties_test_() ->
    {timeout, 240, fun() ->
        Opts = [{to_file, user}, {numtests, ?DEFAULT_NUMTESTS}],
        Props = [
            prop_agrees_with_the_guarded_select(),
            prop_never_leaves_its_bucket(),
            prop_deletions_are_reflected()
        ],
        lists:foreach(
            fun(Prop) -> ?assert(proper:quickcheck(Prop, Opts)) end,
            Props
        )
    end}.
