%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mcp_http_service).

-moduledoc """
The `mcp` carrier's contribution to an HTTP listener's dispatch table.

This is the only module in this application that `bondy_router` knows the
name of: `bondy_listener_config:carrier_module(mcp)` names it, and the call
is resolved when a listener's dispatch table is assembled, so no compile-time
dependency exists in either direction.

Both paths are contributed under `'_'` and therefore answer on every virtual
host the listener serves: `bondy_http_services:dispatch/1` replicates
wildcard routes into each named host entry, without which a host an API
Gateway specification declares would take these paths off that host
(`cowboy_router:match/3` commits to the first host entry that matches and
never falls through).

The realm is a path segment, not a listener property: one MCP listener
serves every realm the principal can authenticate into.
""".

-behaviour(bondy_http_service).

-export([routes/3]).

-spec routes(
    atom(), bondy_listener_config:carrier(), bondy_listener_config:t()
) -> [bondy_http_service:route_rule()].

routes(mcp, #{config := Config}, Listener) ->
    St = #{
        listener => maps:get(name, Listener),
        %% Descriptive only, for the §14.1 audit record: the listener a
        %% request arrived on and its transport are a control an auditor
        %% evidences; §6 forbids them from affecting authorization.
        transport => maps:get(transport, Listener),
        %% The public origin, for documents that must publish one. The
        %% operator's `public_base_uri' wins outright; `undefined' means
        %% derive it per request — host from the request, scheme below.
        base_uri => maps:get(public_base_uri, Config),
        %% `https' iff the listener terminates TLS. Behind a TLS-terminating
        %% proxy the listener is plaintext and the request's own scheme is
        %% equally wrong, which is what `public_base_uri' is for.
        scheme => scheme(Listener),
        config => Config
    },
    [
        {'_', [
            {"/mcp/realm/:realm", bondy_mcp_http_handler, St#{action => rpc}},
            {"/.well-known/oauth-protected-resource/realm/:realm",
                bondy_mcp_http_handler, St#{action => oauth_metadata}}
        ]}
    ].

%% @private
scheme(#{transport := tls}) -> <<"https">>;
scheme(#{transport := _}) -> <<"http">>.
