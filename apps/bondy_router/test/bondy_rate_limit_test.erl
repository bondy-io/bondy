%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rate_limit_test).

-moduledoc """
The scope-aware rate-limit chain (design:
`_plans/2026-08-29-rate-limit-scopes-design.md`): node → listener
composition is AND with no refunds, each scope independently enabled,
and the node-only surface byte-compatible with the pre-scopes module.
Deterministic by construction: every bucket uses `rate => 1` (refill of
1 token/second — negligible within a test) and a fresh key per test.
""".

-include_lib("eunit/include/eunit.hrl").

rate_limit_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun node_only_is_unchanged/0,
        fun scopes_are_independently_enabled/0,
        fun composition_is_and_with_no_refunds/0,
        fun session_limiter_chains_node_and_listener/0,
        fun listener_block_may_be_a_proplist/0,
        fun realm_dimension_fails_open_without_the_realm_store/0
    ]}.

%% The realm scope resolves through `bondy_realm`, which needs the
%% database — NOT running under this fixture (only bondy_regulator is).
%% A realm dimension must then degrade to "no realm budgets": never a
%% raise, never a refusal — the module's fail-open contract at the one
%% resolver that leaves config for storage.
realm_dimension_fails_open_without_the_realm_store() ->
    ok = bondy_config:set([security, rate_limit], #{enabled => false}),
    K = key(),
    Dims = #{realm => <<"com.test.no_store">>},
    ?assertEqual(ok, bondy_rate_limit:throttle(auth, K, Dims)),
    ?assertEqual(ok, bondy_rate_limit:throttle(auth, K, Dims)),
    ?assertEqual(
        undefined, bondy_rate_limit:new_session_limiter(Dims)
    ).

%% The listener splat publishes `bondy.conf`-declared blocks as nested
%% PROPLISTS while an app-env inventory yields maps — the reader must
%% accept both, or conf-file budgets are a silent no-op (the exact shape
%% bug the NODE scope had until 2026-08-26).
listener_block_may_be_a_proplist() ->
    ok = bondy_config:set([security, rate_limit], #{enabled => false}),
    L = listener(),
    ok = bondy_config:set(
        [L, rate_limit], [{http, [{rate, 1}, {capacity, 1}]}]
    ),
    K = key(),
    ?assertEqual(ok, bondy_rate_limit:throttle(http, K, #{listener => L})),
    ?assertEqual(
        throttled, bondy_rate_limit:throttle(http, K, #{listener => L})
    ).

setup() ->
    %% Under the FULL eunit battery an earlier fixture can leave
    %% bondy_regulator half-torn-down, and `ensure_all_started/1` then
    %% fails on the leftover (measured: `{bondy_regulator_app, start, _}`
    %% failure here while the standalone run is green). A stop-then-start
    %% resets the app to a known state either way.
    ok =
        case application:ensure_all_started(bondy_regulator) of
            {ok, _} ->
                ok;
            {error, _} ->
                _ = application:stop(bondy_regulator),
                {ok, _} = application:ensure_all_started(bondy_regulator),
                ok
        end,
    Saved = bondy_config:get([security, rate_limit], undefined),
    Saved.

cleanup(Saved) ->
    bondy_config:set([security, rate_limit], Saved).

key() ->
    {test_ip, erlang:unique_integer([positive])}.

listener() ->
    Name = integer_to_binary(erlang:unique_integer([positive])),
    <<"rl_test_listener_", Name/binary>>.

node_only_is_unchanged() ->
    ok = bondy_config:set(
        [security, rate_limit],
        #{enabled => true, http => #{rate => 1, capacity => 2}}
    ),
    K = key(),
    %% throttle/2 and throttle/3 with no dims are the same surface.
    ?assertEqual(ok, bondy_rate_limit:throttle(http, K)),
    ?assertEqual(ok, bondy_rate_limit:throttle(http, K, #{})),
    ?assertEqual(throttled, bondy_rate_limit:throttle(http, K)),

    %% Disabled ⇒ always ok, dims or not.
    ok = bondy_config:set([security, rate_limit], #{enabled => false}),
    ?assertEqual(ok, bondy_rate_limit:throttle(http, K)),
    ?assertEqual(
        ok, bondy_rate_limit:throttle(http, K, #{listener => listener()})
    ).

%% A listener budget works with the NODE scope entirely off — each scope
%% is its own decision; the node `enabled` flag gates only the node
%% buckets.
scopes_are_independently_enabled() ->
    ok = bondy_config:set([security, rate_limit], #{enabled => false}),
    L = listener(),
    ok = bondy_config:set(
        [L, rate_limit], #{http => #{rate => 1, capacity => 1}}
    ),
    K = key(),
    ?assertEqual(ok, bondy_rate_limit:throttle(http, K, #{listener => L})),
    ?assertEqual(
        throttled, bondy_rate_limit:throttle(http, K, #{listener => L})
    ),
    %% The same key with NO listener dimension sees no budget at all.
    ?assertEqual(ok, bondy_rate_limit:throttle(http, K)).

%% Node is charged BEFORE the listener verdict and not refunded on a
%% listener refusal: with node capacity 2 and listener capacity 1, the
%% second request is refused by the LISTENER yet still consumes the
%% node's last token, so the third is refused by the NODE.
composition_is_and_with_no_refunds() ->
    ok = bondy_config:set(
        [security, rate_limit],
        #{enabled => true, http => #{rate => 1, capacity => 2}}
    ),
    L = listener(),
    ok = bondy_config:set(
        [L, rate_limit], #{http => #{rate => 1, capacity => 1}}
    ),
    K = key(),
    Dims = #{listener => L},
    ?assertEqual(ok, bondy_rate_limit:throttle(http, K, Dims)),
    ?assertEqual(
        {throttled, listener}, bondy_rate_limit:do_throttle(http, K, Dims)
    ),
    ?assertEqual(
        {throttled, node}, bondy_rate_limit:do_throttle(http, K, Dims)
    ).

%% The per-session message limiter is a chain of PRIVATE buckets, one
%% per configured scope, resolved once at session open. Node and
%% listener each bound it independently.
session_limiter_chains_node_and_listener() ->
    L = listener(),
    ok = bondy_config:set(
        [security, rate_limit],
        #{
            enabled => true,
            message => #{enabled => true, rate => 1, capacity => 1}
        }
    ),
    ok = bondy_config:set(
        [L, rate_limit], #{message => #{rate => 1, capacity => 5}}
    ),
    T1 = bondy_rate_limit:new_session_limiter(#{listener => L}),
    ?assertNotEqual(undefined, T1),
    ?assertEqual(ok, bondy_rate_limit:allow_session(T1)),
    %% The node bucket (capacity 1) is the binding constraint.
    ?assertEqual(throttled, bondy_rate_limit:allow_session(T1)),
    ok = bondy_rate_limit:delete_session_limiter(T1),

    %% Node message limiting off, listener on: the listener bucket alone
    %% binds — scopes are independent here too.
    ok = bondy_config:set([security, rate_limit], #{enabled => false}),
    ok = bondy_config:set(
        [L, rate_limit], #{message => #{rate => 1, capacity => 1}}
    ),
    T2 = bondy_rate_limit:new_session_limiter(#{listener => L}),
    ?assertNotEqual(undefined, T2),
    ?assertEqual(ok, bondy_rate_limit:allow_session(T2)),
    ?assertEqual(throttled, bondy_rate_limit:allow_session(T2)),
    ok = bondy_rate_limit:delete_session_limiter(T2),

    %% Nothing configured anywhere ⇒ no limiter at all.
    ok = bondy_config:set([L, rate_limit], undefined),
    ?assertEqual(
        undefined, bondy_rate_limit:new_session_limiter(#{listener => L})
    ).
