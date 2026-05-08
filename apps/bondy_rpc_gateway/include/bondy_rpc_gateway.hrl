%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-ifndef(BONDY_RPC_GATEWAY_HRL).
-define(BONDY_RPC_GATEWAY_HRL, true).

%% Per-call defaults applied when a procedure config does not override them.
%% Schema-level defaults live in schema/bondy_rpc_gateway.schema; these are
%% the runtime fallbacks.
-define(DEFAULT_TIMEOUT,        30000).
-define(DEFAULT_RETRIES,        3).
%% Cap individual retry backoff because the WAMP callback runs INLINE in
%% the dealer's caller process — long sleeps stall everyone behind us in
%% the dispatch path.
-define(RETRY_BACKOFF_BASE_MS,  50).
-define(RETRY_BACKOFF_FLOOR_MS, 30).
-define(RETRY_BACKOFF_CAP_MS,   200).

%% Carries a single registered procedure's full runtime configuration. Built
%% by `bondy_rpc_gateway_callee:register_procedures/1` and passed to the WAMP
%% dealer as the callback args, so `bondy_rpc_gateway_callee_handler` receives
%% it on every invocation. Fields are populated at registration time and are
%% read-only thereafter. If a service's secrets are still resolving at
%% registration time the record carries `vars_resolved = false` and the
%% handler merges secrets per call from the manager's readiness ETS — see
%% the `bondy_rpc_gateway_manager` moduledoc.
-record(rpc_gateway_proc_conf, {
    service_name        ::  binary(),
    base_url            ::  binary(),
    auth_mod            ::  module(),
    auth_conf           ::  map(),
    timeout             ::  pos_integer(),
    retries             ::  non_neg_integer(),
    pool                ::  atom(),
    method              ::  atom(),
    path                ::  binary(),
    %% Precomputed at registration time so the hot path does not re-parse
    %% the path template on every call.
    path_vars           ::  [binary()],
    uri                 ::  binary(),
    realm               ::  binary(),
    %% true once secrets have been resolved AND merged into auth_conf.vars,
    %% or when the service has no secrets to merge. When false, the handler
    %% falls back to a per-call merge driven by the manager's readiness ETS
    %% until the callee is recycled by the supervisor for an unrelated
    %% reason.
    vars_resolved       ::  boolean()
}).

-endif.
