%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_admin_ping_http_handler).
-moduledoc """
A Cowboy HTTP handler for the Admin API liveness (`/ping`) probe.

Replies with `204 No Content` to signal that the node is alive.
""".
-include("http_api.hrl").

-export([init/2]).

init(Req0, State) ->
    Req1 = bondy_http_utils:set_all_headers(Req0),
    Req2 = cowboy_req:reply(?HTTP_NO_CONTENT, Req1),
    {ok, Req2, State}.
