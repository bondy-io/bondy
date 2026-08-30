%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mcp_wamp_api).

-moduledoc """
The `bondy.mcp.*` Meta API: management of MCP overlay documents (design
§18.4) over WAMP — the overlay's ONLY management surface; no operator flow
goes through a console.

Reached through `bondy_wamp_api:register_handler/2` (registered by
`bondy_mcp_app:start/2`) rather than a static clause in the dispatcher:
this application sits ABOVE `bondy_router` in the dependency graph, so a
clause naming this module would create a router→mcp static edge alongside
the existing mcp→router ones.

All five procedures take the admin authority `bondy.interface.*` takes —
an overlay document may target any realm, so managing one is an operator
act (falsifier:
`bondy_mcp_gateway_SUITE:overlay_wamp_api_requires_master_realm`).

`bondy.mcp.overlay.suggested` is the odd one: it WRITES nothing and
returns the documents `bondy_mcp_sre_overlay` ships, so that an operator
adopting the SRE surface does not have to author them. It takes the same
authority as the rest because deciding what an agent may see is the same
decision, whether or not this call is the one that performs it.
""".

-behaviour(bondy_wamp_api).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-define(BONDY_MCP_OVERLAY_LOAD, <<"bondy.mcp.overlay.load">>).
-define(BONDY_MCP_OVERLAY_GET, <<"bondy.mcp.overlay.get">>).
-define(BONDY_MCP_OVERLAY_LIST, <<"bondy.mcp.overlay.list">>).
-define(BONDY_MCP_OVERLAY_DELETE, <<"bondy.mcp.overlay.delete">>).
-define(BONDY_MCP_OVERLAY_SUGGESTED, <<"bondy.mcp.overlay.suggested">>).

-export([handle_call/3]).

%% =============================================================================
%% API
%% =============================================================================

-spec handle_call(
    Proc :: uri(), M :: bondy_wamp_message:call(), Ctxt :: bondy_context:t()
) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined
    )}
    | {reply, wamp_result() | wamp_error()}.

handle_call(?BONDY_MCP_OVERLAY_LOAD, #call{} = M, Ctxt) ->
    [Document] = bondy_wamp_api_utils:admin_call_args(M, Ctxt, 1),

    %% Loading REPLACES a document, and a document that parses can still be
    %% rejected for naming a realm that does not exist or a tool another
    %% document already claims. A dry run runs exactly those checks and stops
    %% before the write — `bondy_mcp_gateway:check/1` IS `load/1` minus its one
    %% `bondy_db:apply/4`, so it cannot pass where the real call would fail.
    case bondy_wamp_api_utils:dry_run(M) of
        true ->
            case bondy_mcp_gateway:check(Document) of
                {ok, #{id := Id, entries := Entries}} ->
                    R = bondy_wamp_api_utils:dry_run_result(
                        M,
                        <<
                            "Replace this overlay document and recompile "
                            "the manifests of the realms it names."
                        >>,
                        #{
                            ~"id" => Id,
                            ~"entry_count" => length(Entries)
                        }
                    ),
                    {reply, R};
                {error, Reason} ->
                    E = bondy_wamp_api_utils:error(Reason, M),
                    {reply, E}
            end;
        false ->
            case bondy_mcp_gateway:load(Document) of
                ok ->
                    R = bondy_wamp_message:result(M#call.request_id, #{}),
                    {reply, R};
                {error, Reason} ->
                    E = bondy_wamp_api_utils:error(Reason, M),
                    {reply, E}
            end
    end;
handle_call(?BONDY_MCP_OVERLAY_GET, #call{} = M, Ctxt) ->
    [Id] = bondy_wamp_api_utils:admin_call_args(M, Ctxt, 1),

    case bondy_mcp_gateway:lookup(Id) of
        {ok, Document} ->
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Document]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;
handle_call(?BONDY_MCP_OVERLAY_LIST, #call{} = M, Ctxt) ->
    [] = bondy_wamp_api_utils:admin_call_args(M, Ctxt, 0),

    Result = bondy_mcp_gateway:list(),
    R = bondy_wamp_message:result(M#call.request_id, #{}, [Result]),
    {reply, R};
handle_call(?BONDY_MCP_OVERLAY_DELETE, #call{} = M, Ctxt) ->
    [Id] = bondy_wamp_api_utils:admin_call_args(M, Ctxt, 1),

    case bondy_mcp_gateway:delete(Id) of
        ok ->
            R = bondy_wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;
handle_call(?BONDY_MCP_OVERLAY_SUGGESTED, #call{} = M, Ctxt) ->
    [] = bondy_wamp_api_utils:admin_call_args(M, Ctxt, 0),

    %% Read-only, and deliberately not a load: what an agent may see over MCP
    %% is the operator's decision, so Bondy hands over the documents and stops
    %% there. Loading one is the ordinary `bondy.mcp.overlay.load` call, which
    %% is itself a catalogued task.
    Result = #{~"documents" => bondy_mcp_sre_overlay:documents()},
    R = bondy_wamp_message:result(M#call.request_id, #{}, [Result]),
    {reply, R};
handle_call(_, #call{} = M, _) ->
    E = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, E}.
