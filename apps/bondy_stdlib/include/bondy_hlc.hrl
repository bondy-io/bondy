%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% The pack layout of a `bondy_hlc` value: 48 bits of physical millisecond
%% timestamp followed by 16 bits of logical counter, comparing as a plain
%% integer.
%% -----------------------------------------------------------------------------

-ifndef(BONDY_HLC_HRL).
-define(BONDY_HLC_HRL, true).

-define(BONDY_HLC_LOGICAL_BITS, 16).
-define(BONDY_HLC_LOGICAL_MASK, 16#FFFF).
-define(BONDY_HLC_LOGICAL_MAX, 16#FFFF).

-endif.
