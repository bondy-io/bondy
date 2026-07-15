%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_telemetry).
-moduledoc """
Telemetry helpers for Bondy, including the generation of trace identifiers.
""".

-export([trace_id/0]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Generates a 128 bit random integer to use as a trace id.
""".
-spec trace_id() -> integer().

trace_id() ->
    %% 2 shifted left by 127 == 2 ^ 128
    rand:uniform(2 bsl 127 - 1).
