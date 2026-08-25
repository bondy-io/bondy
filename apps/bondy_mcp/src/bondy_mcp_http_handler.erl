%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mcp_http_handler).

-moduledoc """
Cowboy handler for both MCP paths, selected by the `action` key in its route
state: the JSON-RPC endpoint (`rpc`) and the OAuth protected-resource
metadata document (`oauth_metadata`).

The MCP protocol is not implemented yet: every request is answered with
`501 Not Implemented`. What this stub does establish is the mounting
contract — the routes exist exactly when a listener declares the `mcp`
service, and the route state carries the listener's resolved `mcp` carrier
configuration.
""".

-export([init/2]).

init(Req0, #{action := _} = St) ->
    Req = cowboy_req:reply(
        501,
        #{<<"content-type">> => <<"application/json">>},
        <<"{\"error\":\"mcp_not_implemented\"}">>,
        Req0
    ),
    {ok, Req, St}.
