%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Test-only fixture: a CRDT that declares `causal_tier -> tier_2` and
%% `order_independent -> false`. `bondy_db:open_table` refuses it
%% (`tier_2_requires_order_independent`) and the eager kernel refuses it
%% (`non_commutative_crdt_eager_unsupported`), both before calling anything
%% else, so it implements only these two callbacks.

-module(bondy_oplog_crdt_tier2_bad).

-export([causal_tier/0]).
-export([order_independent/0]).

causal_tier() -> tier_2.

order_independent() -> false.
