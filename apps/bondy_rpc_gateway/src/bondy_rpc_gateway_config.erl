%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rpc_gateway_config).
-moduledoc """
An implementation of the `app_config` behaviour for the `bondy_rpc_gateway`
application — wraps `app_config:get/2,3` and `set/3` keyed by the application
name, plus startup hooks for ssl defaults consumed by transitive deps.
""".
-behaviour(app_config).

-define(APP, bondy_rpc_gateway).

-export([get/1]).
-export([get/2]).
-export([init/0]).
-export([set/2]).

-compile({no_auto_import, [get/1]}).



%% =============================================================================
%% API
%% =============================================================================



-doc """
Initialise application config and ssl defaults for transitive HTTP deps.
Called once during app startup.
""".
-spec init() -> ok.

init() ->
    ok = app_config:init(?APP, #{callback_mod => ?MODULE}),
    ok = init_lhttpc_ssl_options(),
    ok.


-doc "Get a config value by key.".
-spec get(Key :: list() | atom() | tuple()) -> term().

get(Key) ->
    app_config:get(?APP, Key).


-doc "Get a config value by key, falling back to `Default` when unset.".
-spec get(Key :: list() | atom() | tuple(), Default :: term()) -> term().

get(Key, Default) ->
    app_config:get(?APP, Key, Default).


-doc "Set a config value at runtime.".
-spec set(Key :: key_value:key() | tuple(), Value :: term()) -> ok.

set(status, Value) ->
    %% Typically we would change status during application_controller
    %% lifecycle so to avoid a loop (resulting in timeout) we avoid
    %% calling application:set_env/3.
    persistent_term:put({?APP, status}, Value);

set(Key, Value) ->
    app_config:set(?APP, Key, Value).



%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
%% Ensure lhttpc (used by erlcloud) has proper TLS defaults.
%% OTP 27+ defaults to verify_peer which requires cacerts to be set.
init_lhttpc_ssl_options() ->
    case application:get_env(lhttpc, ssl_options) of
        undefined ->
            application:set_env(lhttpc, ssl_options,
                bondy_cert_manager:ssl_opts()
            );
        {ok, _} ->
            ok
    end.


