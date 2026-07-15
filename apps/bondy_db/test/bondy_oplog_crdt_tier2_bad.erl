%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Test-only fixture: a CRDT that mis-declares `causal_tier -> tier_2`
%% while being `order_independent -> false`. Used to exercise the
%% `bondy_db:open_table` fail-fast assertion
%% (`tier_2 requires order_independent`). Deliberately implements only the
%% two callbacks the assertion inspects — it is never actually applied.

-module(bondy_oplog_crdt_tier2_bad).

-export([causal_tier/0]).
-export([order_independent/0]).

causal_tier() -> tier_2.

order_independent() -> false.
