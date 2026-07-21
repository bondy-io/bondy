%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Tests `bondy_config:normalize_dynamic_buffer/1` — the boot-time
%% normalisation of the schema's `{min, max}` property list at
%% [Listener, protocol_opts, dynamic_buffer] into the `{Min, Max} | false`
%% shape Cowboy requires. Before this normaliser existed, a configured
%% buffer reached Cowboy as a raw property list, which silently DISABLED
%% dynamic buffering (Cowboy's tuple pattern-match falls through to
%% `false`) while also suppressing Cowboy's own default — the opposite of
%% the operator's intent.
%% =============================================================================
-module(bondy_config_dynamic_buffer_test).

-include_lib("eunit/include/eunit.hrl").

-define(KB, 1024).

unset_is_left_absent_test() ->
    %% `undefined` (key absent) and `[]` both mean unset: the caller leaves
    %% the key out so Cowboy's adaptive default applies.
    ?assertEqual(undefined, bondy_config:normalize_dynamic_buffer(undefined)),
    ?assertEqual(undefined, bondy_config:normalize_dynamic_buffer([])).

valid_bounds_become_a_tuple_test() ->
    ?assertEqual(
        {?KB, 128 * ?KB},
        bondy_config:normalize_dynamic_buffer([
            {min, ?KB}, {max, 128 * ?KB}
        ])
    ),
    %% Property-list order must not matter (cuttlefish emits either).
    ?assertEqual(
        {2 * ?KB, 64 * ?KB},
        bondy_config:normalize_dynamic_buffer([
            {max, 64 * ?KB}, {min, 2 * ?KB}
        ])
    ),
    %% min =:= max pins a fixed buffer size — valid.
    ?assertEqual(
        {4 * ?KB, 4 * ?KB},
        bondy_config:normalize_dynamic_buffer([
            {min, 4 * ?KB}, {max, 4 * ?KB}
        ])
    ).

zero_disables_test() ->
    ?assertEqual(
        false,
        bondy_config:normalize_dynamic_buffer([{min, 0}, {max, 64 * ?KB}])
    ),
    ?assertEqual(
        false,
        bondy_config:normalize_dynamic_buffer([{min, 2 * ?KB}, {max, 0}])
    ),
    %% Order-independent for the zero case too (the pre-rewrite validator
    %% only matched zeroes in one fixed order).
    ?assertEqual(
        false,
        bondy_config:normalize_dynamic_buffer([{max, 64 * ?KB}, {min, 0}])
    ).

invalid_values_are_errors_test() ->
    %% Both bounds are required.
    ?assertMatch(
        {error, _},
        bondy_config:normalize_dynamic_buffer([{min, 2 * ?KB}])
    ),
    ?assertMatch(
        {error, _},
        bondy_config:normalize_dynamic_buffer([{max, 64 * ?KB}])
    ),
    %% Bounds outside [1KB, 128KB].
    ?assertMatch(
        {error, _},
        bondy_config:normalize_dynamic_buffer([{min, 512}, {max, 64 * ?KB}])
    ),
    ?assertMatch(
        {error, _},
        bondy_config:normalize_dynamic_buffer([
            {min, ?KB}, {max, 256 * ?KB}
        ])
    ),
    %% Inverted bounds.
    ?assertMatch(
        {error, _},
        bondy_config:normalize_dynamic_buffer([
            {min, 64 * ?KB}, {max, 2 * ?KB}
        ])
    ),
    %% Not a property list at all.
    ?assertMatch(
        {error, _},
        bondy_config:normalize_dynamic_buffer(#{min => ?KB, max => 2 * ?KB})
    ).
