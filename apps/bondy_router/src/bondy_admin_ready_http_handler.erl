%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_admin_ready_http_handler).
-moduledoc """
An HTTP handler for the Admin API readiness (`/ready`) probe.

Replies with `204 No Content` when `bondy_app:is_ready/0` — the node's one
readiness oracle — is `true`, otherwise with `503 Service Unavailable`.
""".
-include("http_api.hrl").

-export([init/2]).

%% =============================================================================
%% API
%% =============================================================================

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    Req1 = bondy_http_utils:set_all_headers(Req0),
    Req2 = ready(Method, Req1),
    {ok, Req2, State}.

ready(<<"GET">>, Req) ->
    cowboy_req:reply(status_code(), Req);
ready(_, Req) ->
    cowboy_req:reply(?HTTP_METHOD_NOT_ALLOWED, Req).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% The conditions live in `bondy_app:is_ready/0`, not here: the
%% `bondy_node_ready` gauge answers from the same function, so the probe and
%% the dashboard cannot disagree.
status_code() ->
    case bondy_app:is_ready() of
        true -> ?HTTP_NO_CONTENT;
        false -> ?HTTP_SERVICE_UNAVAILABLE
    end.
