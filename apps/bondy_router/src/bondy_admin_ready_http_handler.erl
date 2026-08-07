%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_admin_ready_http_handler).
-moduledoc """
An HTTP handler for the Admin API readiness (`/ready`) probe.

Replies with `204 No Content` once the node status is `ready`, otherwise with
`503 Service Unavailable`.
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
%% Boot reaching its end is necessary but NOT sufficient. `bondy_app:start/2`
%% sets the status unconditionally once the listeners are up, and the
%% catalogue deliberately survives a failure to open the durable `main` DB
%% (see `bondy_namespace_catalog:open_main_into/1`) — so without the second
%% check a node that will raise `*_not_provisioned` on every durable operation
%% answers 204 and a load balancer sends it traffic it cannot serve.
%%
%% Only `failed` is disqualifying: `idle` means there was nothing to
%% provision, which is a legitimate configuration.
status_code() ->
    case bondy_config:get(status, undefined) of
        ready ->
            case bondy_namespace_catalog:main_status() of
                failed -> ?HTTP_SERVICE_UNAVAILABLE;
                _ -> ?HTTP_NO_CONTENT
            end;
        _ ->
            ?HTTP_SERVICE_UNAVAILABLE
    end.
