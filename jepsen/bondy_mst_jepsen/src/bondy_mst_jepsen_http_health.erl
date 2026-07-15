%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_jepsen_http_health).

-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Body = jsx:encode(bondy_mst_jepsen_cluster:info()),
    Req = cowboy_req:reply(
        200,
        #{<<"content-type">> => <<"application/json">>},
        Body,
        Req0
    ),
    {ok, Req, State}.
