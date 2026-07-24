%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% PropEr properties for the registry RIB's hierarchical (node-stage)
%% selection: `bondy_rpc_load_balancer:select_node/2`.
%%
%% The claim under test is DISTRIBUTION EQUIVALENCE with single-stage
%% selection: picking a node from the summarized cells and letting the
%% owner select locally must produce the same per-entry outcome
%% (deterministic policies: exact support equality; weighted policies:
%% P(entry) = (count_i/Σcount)·(1/count_i) = 1/Σcount, i.e. the node stage
%% must draw nodes with probability proportional to their counts).
%%
%% Run with:
%%   rebar3 as test eunit --module=bondy_rpc_load_balancer_proper_test
-module(bondy_rpc_load_balancer_proper_test).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(TS_TABLE, bondy_rpc_state).

%% =============================================================================
%% GENERATORS
%% =============================================================================

%% A registration topology: 1..6 nodes, each summarising 1..8 local
%% entries. `earliest` values are unique across nodes (two entries never
%% share a creation timestamp in practice, and uniqueness keeps the
%% deterministic argmin/argmax properties tie-free); `latest >= earliest`.
topology() ->
    ?LET(
        {N, Slack},
        {range(1, 6), vector(6, range(0, 1000))},
        ?LET(
            Counts,
            vector(N, range(1, 8)),
            begin
                Nodes = [nodestring(I) || I <- lists:seq(1, N)],
                Earliest = [I * 1000 || I <- lists:seq(1, N)],
                [
                    {Node, #{
                        invoke => <<"single">>,
                        count => C,
                        earliest => E,
                        latest => E + S
                    }}
                 || {{Node, C, E}, S} <-
                        lists:zip(
                            lists:zip3(Nodes, Counts, Earliest),
                            lists:sublist(Slack, N)
                        )
                ]
            end
        )
    ).

nodestring(I) ->
    <<"node", (integer_to_binary(I))/binary, "@proper">>.

%% =============================================================================
%% PROPERTIES
%% =============================================================================

%% `single` / `first`: the node stage must select the node holding the
%% globally-earliest registration — exactly the entry single-stage argmin
%% selection would pick, so the two paths have equal support.
prop_single_first_earliest() ->
    ?FORALL(
        {Units, Strategy},
        {topology(), oneof([single, first])},
        begin
            {ok, Selected} = bondy_rpc_load_balancer:select_node(
                Units, #{strategy => Strategy}
            ),
            {Expected, _} = lists:foldl(
                fun({N, #{earliest := E}}, {_, EAcc} = Acc) ->
                    case E < EAcc of
                        true -> {N, E};
                        false -> Acc
                    end
                end,
                {undefined, infinity},
                Units
            ),
            Selected =:= Expected
        end
    ).

%% `last`: the node holding the globally-latest registration.
prop_last_latest() ->
    ?FORALL(
        Units,
        topology(),
        begin
            {ok, Selected} = bondy_rpc_load_balancer:select_node(
                Units, #{strategy => last}
            ),
            {Expected, _} = lists:foldl(
                fun({N, #{latest := L}}, {_, LAcc} = Acc) ->
                    case L > LAcc of
                        true -> {N, L};
                        false -> Acc
                    end
                end,
                {undefined, -1},
                Units
            ),
            Selected =:= Expected
        end
    ).

%% `jump_consistent_hash` with a routing key: deterministic (same key and
%% units → same node) and total (the result is one of the units).
prop_jch_deterministic() ->
    ?FORALL(
        {Units, Key},
        {topology(), binary(16)},
        begin
            Opts = #{strategy => jump_consistent_hash, '_routing_key' => Key},
            {ok, A} = bondy_rpc_load_balancer:select_node(Units, Opts),
            {ok, B} = bondy_rpc_load_balancer:select_node(Units, Opts),
            A =:= B andalso lists:keymember(A, 1, Units)
        end
    ).

%% `random` (and the queue_least_loaded family, which the node stage maps
%% to weighted random): node frequencies over many draws must match the
%% count weights — the node stage contributes P(node) = count/Σcount, so
%% composed with the owner's uniform 1/count the per-entry distribution is
%% uniform, exactly as single-stage random selection over all entries.
%% Bounded by a conservative chi-square threshold (few numtests, many
%% draws — see the eunit wrapper).
prop_random_weighted() ->
    ?FORALL(
        Units,
        topology(),
        begin
            Draws = 4000,
            Freq = lists:foldl(
                fun(_, Acc) ->
                    {ok, N} = bondy_rpc_load_balancer:select_node(
                        Units, #{strategy => random}
                    ),
                    maps:update_with(N, fun(C) -> C + 1 end, 1, Acc)
                end,
                #{},
                lists:seq(1, Draws)
            ),
            Total = lists:sum([maps:get(count, S) || {_, S} <- Units]),
            ChiSq = lists:sum([
                begin
                    Expected = Draws * maps:get(count, S) / Total,
                    Observed = maps:get(N, Freq, 0),
                    (Observed - Expected) * (Observed - Expected) / Expected
                end
             || {N, S} <- Units
            ]),
            %% χ² with at most 5 degrees of freedom; 27.9 is the p=1e-5
            %% quantile at df=5 — a false failure is practically
            %% impossible, a broken weighting is far outside it.
            ChiSq < 27.9
        end
    ).

%% `round_robin`: the node-stage rotation is DETERMINISTIC — over any k
%% full cycles (k·Σcount consecutive selections on one procedure) every
%% node is selected exactly k·count times, the exact node marginal
%% single-stage round-robin produces. Runs against a production-shaped
%% rpc state table (keypos 2 — the very shape that broke the original
%% counter row).
prop_round_robin_exact_rotation() ->
    ?FORALL(
        Units,
        topology(),
        begin
            %% A fresh procedure per case: the rotation cursor is keyed
            %% (realm, uri), so this isolates every run.
            Uri = <<
                "com.proper.rr.",
                (integer_to_binary(erlang:unique_integer([positive])))/binary
            >>,
            Opts = #{
                strategy => round_robin,
                realm_uri => <<"com.proper.rr">>,
                uri => Uri
            },
            Total = lists:sum([maps:get(count, S) || {_, S} <- Units]),
            K = 3,
            Freq = lists:foldl(
                fun(_, Acc) ->
                    {ok, N} = bondy_rpc_load_balancer:select_node(Units, Opts),
                    maps:update_with(N, fun(C) -> C + 1 end, 1, Acc)
                end,
                #{},
                lists:seq(1, K * Total)
            ),
            lists:all(
                fun({N, S}) ->
                    maps:get(N, Freq, 0) =:= K * maps:get(count, S)
                end,
                Units
            )
        end
    ).

%% =============================================================================
%% EUNIT WRAPPER
%% =============================================================================

properties_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        Opts = [{to_file, user}, {numtests, 200}],
        %% The statistical property runs thousands of draws per case, so
        %% fewer cases keep the suite fast without weakening the χ² bound.
        StatOpts = [{to_file, user}, {numtests, 25}],
        [
            {timeout, 120,
                ?_assert(proper:quickcheck(prop_single_first_earliest(), Opts))},
            {timeout, 120,
                ?_assert(proper:quickcheck(prop_last_latest(), Opts))},
            {timeout, 120,
                ?_assert(proper:quickcheck(prop_jch_deterministic(), Opts))},
            {timeout, 300,
                ?_assert(proper:quickcheck(prop_random_weighted(), StatOpts))},
            {timeout, 300,
                ?_assert(
                    proper:quickcheck(prop_round_robin_exact_rotation(), Opts)
                )}
        ]
    end}.

%% The rotation cursor lives in the tuplespace-managed rpc state table.
%% Mirror the production shape exactly (set, keypos 2) — a fixture with a
%% different keypos would hide row-shape bugs. Reuse a running tuplespace
%% (a full-app boot sharing this BEAM) rather than reconfiguring it.
setup() ->
    case erlang:whereis(tuplespace_sup) of
        undefined ->
            ok = application:set_env(tuplespace, ring_size, 2),
            ok = application:set_env(tuplespace, static_tables, [
                {?TS_TABLE, [
                    set,
                    {keypos, 2},
                    named_table,
                    public,
                    {read_concurrency, true},
                    {write_concurrency, true}
                ]}
            ]),
            {ok, Started} = application:ensure_all_started(tuplespace),
            Started;
        _ ->
            []
    end.

cleanup(Started) ->
    _ = [application:stop(App) || App <- lists:reverse(Started)],
    ok.
