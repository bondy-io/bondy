%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_api).
-moduledoc """
Entry point for the Bondy Meta API. Dispatches WAMP `CALL` messages addressed
to `bondy.*` procedures to the appropriate API handler module and resolves
legacy procedure URIs to their current equivalents.
""".
-behaviour(bondy_wamp_callback).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_uris.hrl").

-export([handle_call/2]).
-export([register_handler/2]).
-export([resolve/1]).

%% =============================================================================
%% CALLBACKS
%% =============================================================================

-callback handle_call(
    Procedure :: uri(),
    M :: bondy_wamp_message:call(),
    Ctxt :: bondy_context:t()
) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined
    )}
    | {reply, wamp_result() | wamp_error()}.

%% =============================================================================
%% API
%% =============================================================================

-doc """
Registers `Mod` as the handler for every `bondy.*` procedure under
`Prefix` — the extension seam for applications that sit ABOVE
`bondy_router` in the dependency graph (`bondy_mcp` today), whose handler
modules the static clause table in `do_handle_call/3` therefore cannot
name. The static clauses are matched first, so a registration can extend
the API but never shadow a built-in family.

`Prefix` must be a two-segment prefix of the shape `bondy.<word>.` —
the same grain as the static table — or the call raises `badarg`.

Call it from the registering application's `start/2`. Every registrant is
started by `bondy_app` BEFORE `start_normal_listeners/0` runs, so a
registration is in place before any client can be admitted — the ordering
is by construction, not by luck (falsifier:
`bondy_mcp_gateway_SUITE:overlay_wamp_api_lifecycle` goes through this
seam). Registration is idempotent; there is no unregister — a handler
lives as long as the node.
""".
-spec register_handler(Prefix :: binary(), Mod :: module()) -> ok.

register_handler(<<"bondy.", Sub/binary>> = Prefix, Mod) when is_atom(Mod) ->
    case binary:split(Sub, ~".") of
        [Seg, <<>>] when Seg =/= <<>> ->
            persistent_term:put({?MODULE, Prefix}, Mod);
        _ ->
            error(badarg, [Prefix, Mod])
    end;
register_handler(Prefix, Mod) ->
    error(badarg, [Prefix, Mod]).

-spec handle_call(M :: bondy_wamp_message:call(), Ctxt :: bondy_context:t()) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined
    )}
    | {reply, wamp_result() | wamp_error()}.

handle_call(#call{options = #{ppt_scheme := _}} = Msg, _) ->
    Error = bondy_wamp_message:error(
        ?CALL,
        Msg#call.request_id,
        Msg#call.options,
        ?WAMP_INVALID_ARGUMENT,
        [~"Payload Passthru Mode is not supported on Bondy Meta API."]
    ),
    {reply, Error};
handle_call(#call{procedure_uri = Proc} = M0, Ctxt) ->
    %% We make sure the partial payload is decoded (if any)
    M = bondy_wamp_message:decode_partial(M0),
    do_handle_call(resolve(Proc), M, Ctxt).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
-spec do_handle_call(
    Proc :: uri(), M :: bondy_wamp_message:call(), Ctxt :: bondy_context:t()
) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined
    )}
    | {reply, wamp_result() | wamp_error()}.

do_handle_call(<<"bondy.ping">>, M, _Ctxt) ->
    %% Always authorized
    R = bondy_wamp_message:result(M#call.request_id, #{}, [~"pong"]),
    {reply, R};
do_handle_call(<<"bondy.export.", _/binary>> = Proc, M, Ctxt) ->
    bondy_export_api:handle_call(Proc, M, Ctxt);
do_handle_call(<<"bondy.backup.", _/binary>> = Proc, M, Ctxt) ->
    %% Deprecated alias — dispatches to the same bondy_export_api handler.
    bondy_export_api:handle_call(Proc, M, Ctxt);
do_handle_call(<<"bondy.cert_manager.", _/binary>> = Proc, M, Ctxt) ->
    bondy_cert_manager_wamp_api:handle_call(Proc, M, Ctxt);
do_handle_call(<<"bondy.cluster.", _/binary>> = Proc, M, Ctxt) ->
    bondy_cluster_api:handle_call(Proc, M, Ctxt);
do_handle_call(<<"bondy.grant.", _/binary>> = Proc, M, Ctxt) ->
    bondy_rbac_api:handle_call(Proc, M, Ctxt);
do_handle_call(<<"bondy.group.", _/binary>> = Proc, M, Ctxt) ->
    bondy_rbac_api:handle_call(Proc, M, Ctxt);
do_handle_call(<<"bondy.http_gateway.", _/binary>> = Proc, M, Ctxt) ->
    bondy_http_gateway_api:handle_call(Proc, M, Ctxt);
do_handle_call(<<"bondy.interface.", _/binary>> = Proc, M, Ctxt) ->
    bondy_interface_api:handle_call(Proc, M, Ctxt);
do_handle_call(<<"bondy.listener.", _/binary>> = Proc, M, Ctxt) ->
    bondy_listener_wamp_api:handle_call(Proc, M, Ctxt);
do_handle_call(<<"bondy.mail.", _/binary>> = Proc, M, Ctxt) ->
    bondy_mail_api:handle_call(Proc, M, Ctxt);
do_handle_call(<<"bondy.oauth2.", _/binary>> = Proc, M, Ctxt) ->
    bondy_oauth2_api:handle_call(Proc, M, Ctxt);
do_handle_call(<<"bondy.rbac.", _/binary>> = Proc, M, Ctxt) ->
    bondy_rbac_api:handle_call(Proc, M, Ctxt);
do_handle_call(<<"bondy.realm.", _/binary>> = Proc, M, Ctxt) ->
    bondy_realm_api:handle_call(Proc, M, Ctxt);
do_handle_call(<<"bondy.session.", _/binary>> = Proc, M, Ctxt) ->
    bondy_session_api:handle_call(Proc, M, Ctxt);
do_handle_call(<<"bondy.registration.", _/binary>> = Proc, M, Ctxt) ->
    bondy_registry_api:handle_call(Proc, M, Ctxt);
do_handle_call(<<"bondy.router.bridge.", _/binary>> = Proc, M, Ctxt) ->
    bondy_bridge_relay_api:handle_call(Proc, M, Ctxt);
do_handle_call(<<"bondy.source.", _/binary>> = Proc, M, Ctxt) ->
    bondy_rbac_api:handle_call(Proc, M, Ctxt);
do_handle_call(<<"bondy.subscription.", _/binary>> = Proc, M, Ctxt) ->
    bondy_registry_api:handle_call(Proc, M, Ctxt);
do_handle_call(<<"bondy.telemetry.", _/binary>> = Proc, M, Ctxt) ->
    bondy_telemetry_api:handle_call(Proc, M, Ctxt);
do_handle_call(<<"bondy.ticket.", _/binary>> = Proc, M, Ctxt) ->
    bondy_ticket_api:handle_call(Proc, M, Ctxt);
do_handle_call(<<"bondy.user.", _/binary>> = Proc, M, Ctxt) ->
    bondy_rbac_api:handle_call(Proc, M, Ctxt);
do_handle_call(<<"bondy.", _/binary>> = Proc, M, Ctxt) ->
    %% Registered extension handlers (`register_handler/2`) — currently
    %% bondy_mcp's `bondy.mcp.*`.
    case registered_handler(Proc) of
        undefined ->
            E = bondy_wamp_api_utils:no_such_procedure_error(M),
            {reply, E};
        Mod ->
            Mod:handle_call(Proc, M, Ctxt)
    end.

%% @private
%% The registered handler for `Proc`, or `undefined`. Registrations are
%% keyed by the two-segment prefix `register_handler/2` enforces, so the
%% lookup is one `persistent_term` read, not a table walk.
registered_handler(<<"bondy.", Rest/binary>>) ->
    case binary:split(Rest, ~".") of
        [Seg, _] ->
            Prefix = <<"bondy.", Seg/binary, ".">>,
            persistent_term:get({?MODULE, Prefix}, undefined);
        _ ->
            undefined
    end.

%% @private
-doc """
Resolves old (next to be deprecated URI) into new URI.
""".
-spec resolve(Uri :: uri()) -> uri() | no_return().

resolve(<<"com.bondy.", _/binary>> = Uri) ->
    <<"com.", Rest/binary>> = Uri,
    resolve(Rest);
resolve(<<"com.leapsight.bondy.", _/binary>> = Uri) ->
    <<"com.leapsight.", Rest/binary>> = Uri,
    resolve(Rest);
resolve(?BONDY_HTTP_GATEWAY_GET_OLD) ->
    ?BONDY_HTTP_GATEWAY_GET;
resolve(?BONDY_HTTP_GATEWAY_LIST_OLD) ->
    ?BONDY_HTTP_GATEWAY_LIST;
resolve(?BONDY_HTTP_GATEWAY_LOAD_OLD) ->
    ?BONDY_HTTP_GATEWAY_LOAD;
resolve(?BONDY_OAUTH2_CLIENT_ADD_OLD) ->
    ?BONDY_OAUTH2_CLIENT_ADD;
resolve(?BONDY_OAUTH2_CLIENT_DELETE_OLD) ->
    ?BONDY_OAUTH2_CLIENT_DELETE;
resolve(?BONDY_OAUTH2_CLIENT_GET_OLD) ->
    ?BONDY_OAUTH2_CLIENT_GET;
resolve(?BONDY_OAUTH2_CLIENT_LIST_OLD) ->
    ?BONDY_OAUTH2_CLIENT_LIST;
resolve(?BONDY_OAUTH2_CLIENT_UPDATED_OLD) ->
    ?BONDY_OAUTH2_CLIENT_UPDATED;
resolve(?BONDY_OAUTH2_CLIENT_UPDATE_OLD) ->
    ?BONDY_OAUTH2_CLIENT_UPDATE;
resolve(?BONDY_OAUTH2_RES_OWNER_ADD_OLD) ->
    ?BONDY_OAUTH2_RES_OWNER_ADD;
resolve(?BONDY_OAUTH2_RES_OWNER_DELETE_OLD) ->
    ?BONDY_OAUTH2_RES_OWNER_DELETE;
resolve(?BONDY_OAUTH2_RES_OWNER_GET_OLD) ->
    ?BONDY_OAUTH2_RES_OWNER_GET;
resolve(?BONDY_OAUTH2_RES_OWNER_LIST_OLD) ->
    ?BONDY_OAUTH2_RES_OWNER_LIST;
resolve(?BONDY_OAUTH2_RES_OWNER_UPDATED_OLD) ->
    ?BONDY_OAUTH2_RES_OWNER_UPDATED;
resolve(?BONDY_OAUTH2_RES_OWNER_UPDATE_OLD) ->
    ?BONDY_OAUTH2_RES_OWNER_UPDATE;
resolve(?BONDY_OAUTH2_TOKEN_LOOKUP_OLD) ->
    ?BONDY_OAUTH2_TOKEN_LOOKUP;
resolve(?BONDY_OAUTH2_TOKEN_REVOKE_ALL_OLD) ->
    ?BONDY_OAUTH2_TOKEN_REVOKE_ALL;
resolve(?BONDY_OAUTH2_TOKEN_REVOKE_OLD) ->
    ?BONDY_OAUTH2_TOKEN_REVOKE;
resolve(?BONDY_GROUP_ADD_OLD) ->
    ?BONDY_GROUP_ADD;
resolve(?BONDY_GROUP_DELETE_OLD) ->
    ?BONDY_GROUP_DELETE;
resolve(?BONDY_GROUP_FIND_OLD) ->
    ?BONDY_GROUP_GET;
resolve(?BONDY_GROUP_LIST_OLD) ->
    ?BONDY_GROUP_LIST;
resolve(?BONDY_GROUP_UPDATE_OLD) ->
    ?BONDY_GROUP_UPDATE;
resolve(?BONDY_SOURCE_ADD_OLD) ->
    ?BONDY_SOURCE_ADD;
resolve(?BONDY_SOURCE_DELETE_OLD) ->
    ?BONDY_SOURCE_DELETE;
resolve(?BONDY_SOURCE_FIND_OLD) ->
    ?BONDY_SOURCE_GET;
resolve(?BONDY_SOURCE_LIST_OLD) ->
    ?BONDY_SOURCE_LIST;
resolve(?BONDY_USER_ADD_OLD) ->
    ?BONDY_USER_ADD;
resolve(?BONDY_USER_CHANGE_PASSWORD_OLD) ->
    ?BONDY_USER_CHANGE_PASSWORD;
resolve(?BONDY_USER_DELETE_OLD) ->
    ?BONDY_USER_DELETE;
resolve(?BONDY_USER_FIND_OLD) ->
    ?BONDY_USER_GET;
resolve(?BONDY_USER_LIST_OLD) ->
    ?BONDY_USER_LIST;
resolve(?BONDY_USER_UPDATE_OLD) ->
    ?BONDY_USER_UPDATE;
resolve(?BONDY_REALM_CREATE_OLD) ->
    ?BONDY_REALM_CREATE;
resolve(?BONDY_REALM_DELETE_OLD) ->
    ?BONDY_REALM_DELETE;
resolve(?BONDY_REALM_GET_OLD) ->
    ?BONDY_REALM_GET;
resolve(?BONDY_REALM_LIST_OLD) ->
    ?BONDY_REALM_LIST;
resolve(?BONDY_REALM_SECURITY_DISABLE_OLD) ->
    ?BONDY_REALM_SECURITY_DISABLE;
resolve(?BONDY_REALM_SECURITY_ENABLE_OLD) ->
    ?BONDY_REALM_SECURITY_ENABLE;
resolve(?BONDY_REALM_SECURITY_IS_ENABLED_OLD) ->
    ?BONDY_REALM_SECURITY_IS_ENABLED;
resolve(?BONDY_REALM_SECURITY_STATUS_OLD) ->
    ?BONDY_REALM_SECURITY_STATUS;
resolve(?BONDY_REALM_UPDATE_OLD) ->
    ?BONDY_REALM_UPDATE;
resolve(?BONDY_SUBSCRIPTION_LIST_OLD) ->
    ?BONDY_SUBSCRIPTION_LIST;
resolve(?BONDY_TELEMETRY_METRICS_OLD) ->
    ?BONDY_TELEMETRY_METRICS;
resolve(?BONDY_REGISTRY_CALLEE_LIST_OLD) ->
    ?BONDY_REGISTRATION_CALLEE_LIST;
resolve(Uri) ->
    Uri.
