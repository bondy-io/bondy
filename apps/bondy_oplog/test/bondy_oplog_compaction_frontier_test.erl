%% =============================================================================
%% Tests for `bondy_oplog_instance:compute_frontier_for/2`, the stability
%% frontier over durable-frontier witnesses.
%%
%% The frontier is the largest local key K such that every local key `=< K` is
%% covered by EVERY witness: its `{Origin, Seq}` is at or below the witness's
%% entry for its origin. The implementation stops a single ascending fold at
%% the first uncovered key; the reference, `oracle_frontier/2`, takes the
%% longest covered prefix of the sorted key list. The two must agree on every
%% local/witness configuration. Event keys `{HLC, Origin, Seq}` with one HLC
%% per seq keep HLC order and seq order aligned.
%% =============================================================================

-module(bondy_oplog_compaction_frontier_test).

-include_lib("eunit/include/eunit.hrl").

%% -----------------------------------------------------------------------------
%% Construction
%% -----------------------------------------------------------------------------

tree(Name, Keys) ->
    T = bondy_mst:new(#{
        store => bondy_mst_ets_store,
        store_opts => #{name => list_to_binary(Name)},
        merger => fun(_K, _V1, V2) -> V2 end
    }),
    lists:foldl(fun(K, A) -> bondy_mst:put(A, K) end, T, Keys).

ekey(Origin, Seq) ->
    bondy_oplog_event:key(Seq, Origin, Seq).

%% -----------------------------------------------------------------------------
%% Reference frontier: the longest covered prefix of the sorted keys
%% -----------------------------------------------------------------------------

oracle_frontier(_Local, []) ->
    undefined;
oracle_frontier(Local, VVs) ->
    Keys = lists:reverse(
        bondy_mst:fold(Local, fun({K, _V}, A) -> [K | A] end, [])
    ),
    lcp(Keys, VVs, undefined).

lcp([], _VVs, Acc) ->
    Acc;
lcp([K | Rest], VVs, Acc) ->
    case lists:all(fun(VV) -> bondy_oplog_event:covered(K, VV) end, VVs) of
        true -> lcp(Rest, VVs, K);
        false -> Acc
    end.

%% -----------------------------------------------------------------------------
%% Hand-checked scenarios: assert new == oracle == expected
%% -----------------------------------------------------------------------------

scenarios() ->
    O1 = <<"o1">>,
    O2 = <<"o2">>,
    L = [ekey(O1, 1), ekey(O1, 2), ekey(O1, 3), ekey(O2, 4)],
    [
        %% {Name, Witnesses, LocalKeys, ExpectedFrontier}
        {"covers_a_prefix", [#{O1 => 2}], L, ekey(O1, 2)},
        {"covers_all", [#{O1 => 3, O2 => 4}], L, ekey(O2, 4)},
        {"covers_more_than_held", [#{O1 => 9, O2 => 9}], L, ekey(O2, 4)},
        %% The least witness decides.
        {"two_witnesses_min", [#{O1 => 3, O2 => 4}, #{O1 => 1}], L,
            ekey(O1, 1)},
        %% An entry below a key's seq stops the prefix there.
        {"entry_too_low", [#{O1 => 1, O2 => 3}], L, ekey(O1, 1)},
        %% The first key uncovered: nothing is confirmed.
        {"first_key_uncovered", [#{O2 => 4}], L, undefined},
        %% An unknown witness confirms nothing, nor do no witnesses at all.
        {"unknown_witness", [#{O1 => 3, O2 => 4}, undefined], L, undefined},
        {"no_witness", [], L, undefined},
        {"empty_local", [#{O1 => 3}], [], undefined}
    ].

frontier_scenarios_test_() ->
    [
        {Name, fun() ->
            Local = tree("frontier_" ++ Name, Keys),
            New = bondy_oplog_instance:compute_frontier_for(Local, Witnesses),
            ?assertEqual(Expected, New),
            ?assertEqual(oracle_frontier(Local, Witnesses), New)
        end}
     || {Name, Witnesses, Keys, Expected} <- scenarios()
    ].

%% -----------------------------------------------------------------------------
%% Randomised sweep: new == oracle on random local/witness configurations
%% -----------------------------------------------------------------------------

random_sweep_test() ->
    _ = rand:seed(exsss, {17, 42, 99}),
    Origins = [<<"a">>, <<"b">>, <<"c">>],
    lists:foreach(
        fun(N) ->
            Keys = [
                ekey(lists:nth(rand:uniform(3), Origins), S)
             || S <- lists:seq(1, 20), rand:uniform() < 0.7
            ],
            Witnesses = [
                maps:from_list([{O, rand:uniform(21) - 1} || O <- Origins])
             || _ <- lists:seq(1, 1 + rand:uniform(3))
            ],
            Local = tree("sweep_" ++ integer_to_list(N), Keys),
            New = bondy_oplog_instance:compute_frontier_for(Local, Witnesses),
            Oracle = oracle_frontier(Local, Witnesses),
            New =:= Oracle orelse
                erlang:error(
                    {frontier_mismatch, #{
                        n => N,
                        witnesses => Witnesses,
                        keys => Keys,
                        new => New,
                        oracle => Oracle
                    }}
                )
        end,
        lists:seq(1, 80)
    ).
