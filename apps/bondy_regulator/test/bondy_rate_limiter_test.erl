%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rate_limiter_test).
-moduledoc "The keyed, GC'd token-bucket rate limiter.".

-include_lib("eunit/include/eunit.hrl").

-define(M, bondy_rate_limiter).
%% Near-zero refill so the bucket does not top up within a test — `capacity`
%% is the deterministic burst size.
-define(OPTS(Cap), #{rate => 0.00001, capacity => Cap}).

rate_limiter_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun allow_within_capacity/0,
        fun deny_over_capacity/0,
        fun reuses_bucket_per_key/0,
        fun distinct_keys_independent/0,
        fun forget_resets/0,
        fun gc_sweeps_idle/0
    ]}.

setup() ->
    %% Start the shared `bondy_regulator` APP rather than its registered
    %% gen_servers directly: `ensure_all_started/1` is idempotent, the
    %% supervisor owns the children, and the app staying up serves every
    %% sibling. The previous shape (`whereis` + direct `start_link/0`)
    %% left UNSUPERVISED registered orphans behind — a later fixture's
    %% `application:start(bondy_regulator)` then failed with
    %% `{already_started, _}` on the sup child (measured: it cancelled
    %% bondy_rate_limit_test's whole fixture in full-eunit runs).
    {ok, _} = application:ensure_all_started(bondy_regulator),
    ok.

cleanup(_) ->
    %% Deliberately NOT stopping the shared app: siblings and later
    %% fixtures keep using it, and `ensure_all_started/1` makes every
    %% setup idempotent against it running.
    ok.

key(Name) ->
    {test, Name, erlang:unique_integer([positive])}.

allow_within_capacity() ->
    K = key(within),
    ?assert(?M:allow(K, ?OPTS(3))),
    ?assert(?M:allow(K, ?OPTS(3))),
    ?assert(?M:allow(K, ?OPTS(3))).

deny_over_capacity() ->
    K = key(over),
    ?assert(?M:allow(K, ?OPTS(2))),
    ?assert(?M:allow(K, ?OPTS(2))),
    ?assertNot(?M:allow(K, ?OPTS(2))).

reuses_bucket_per_key() ->
    %% Repeated calls with the same key deplete the SAME bucket.
    K = key(reuse),
    [?assert(?M:allow(K, ?OPTS(5))) || _ <- lists:seq(1, 5)],
    ?assertNot(?M:allow(K, ?OPTS(5))).

distinct_keys_independent() ->
    K1 = key(indep_a),
    K2 = key(indep_b),
    ?assert(?M:allow(K1, ?OPTS(1))),
    ?assertNot(?M:allow(K1, ?OPTS(1))),
    %% A different key has its own bucket.
    ?assert(?M:allow(K2, ?OPTS(1))).

forget_resets() ->
    K = key(forget),
    ?assert(?M:allow(K, ?OPTS(1))),
    ?assertNot(?M:allow(K, ?OPTS(1))),
    ok = ?M:forget(K),
    %% A fresh bucket is minted after forget.
    ?assert(?M:allow(K, ?OPTS(1))).

gc_sweeps_idle() ->
    K = key(gc),
    ?assert(?M:allow(K, ?OPTS(1))),
    ?assertMatch([_], ets:lookup(bondy_rate_limiter, K)),
    %% Age the entry past any TTL and drive a sweep cycle directly.
    true = ets:update_element(bondy_rate_limiter, K, {3, 0}),
    bondy_rate_limiter ! sweep,
    %% Poll for the sweep to land.
    ok = wait_gone(bondy_rate_limiter, K, 50),
    ?assertEqual([], ets:lookup(bondy_rate_limiter, K)).

wait_gone(_Tab, _K, 0) ->
    {error, still_present};
wait_gone(Tab, K, N) ->
    case ets:lookup(Tab, K) of
        [] ->
            ok;
        _ ->
            timer:sleep(20),
            wait_gone(Tab, K, N - 1)
    end.
