%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_admin_ping_http_handler).
-include("http_api.hrl").

-export([init/2]).



init(Req0, State) ->
    Req1 = bondy_http_utils:set_meta_headers(Req0),
    Req2 = cowboy_req:reply(?HTTP_NO_CONTENT, Req1),
    {ok, Req2, State}.
