-module(bondy_config).
-behaviour(app_config).

-define(APP, bondy).


-export([get/1]).
-export([get/2]).
-export([init/0]).
-export([set/2]).

-compile({no_auto_import, [get/1]}).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
init() ->
    ok = app_config:init(?APP, #{callback_mod => ?MODULE}),
    _ = lager:info("Bondy configuration initialised"),
    ok.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get(Key :: list() | atom() | tuple()) -> term().

get(Key) ->
    app_config:get(?APP, Key).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get(Key :: list() | atom() | tuple(), Default :: term()) -> term().

get(Key, Default) ->
    app_config:get(?APP, Key, Default).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec set(Key :: key_value:key() | tuple(), Value :: term()) -> ok.

set(status, Value) ->
    %% Typically we would change status during application_controller
    %% lifecycle so to avoid a loop (resulting in timeout) we avoid
    %% calling application:set_env/3.
    persistent_term:put({?APP, status}, Value);

set(Key, Value) ->
    app_config:set(?APP, Key, Value).
