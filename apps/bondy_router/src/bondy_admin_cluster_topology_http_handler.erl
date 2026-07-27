%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_admin_cluster_topology_http_handler).
-moduledoc """
Admin API endpoint (`GET /cluster/topology`) returning this node's view of the
cluster as a Grafana Node Graph payload (`bondy_cluster_topology:graph/0`),
JSON-encoded. Consumed by an Infinity datasource to render the cluster node
graph — see `_design/OBSERVABILITY_GAPS.md`.
""".
-include("http_api.hrl").

-export([init/2]).

%% =============================================================================
%% API
%% =============================================================================

init(Req0, State) ->
    Req1 = bondy_http_utils:set_all_headers(Req0),
    Req2 = handle(cowboy_req:method(Req1), Req1),
    {ok, Req2, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
handle(<<"GET">>, Req) ->
    Body = json:encode(bondy_cluster_topology:graph()),
    cowboy_req:reply(
        ?HTTP_OK,
        #{<<"content-type">> => <<"application/json">>},
        Body,
        Req
    );
handle(_, Req) ->
    cowboy_req:reply(?HTTP_METHOD_NOT_ALLOWED, Req).
