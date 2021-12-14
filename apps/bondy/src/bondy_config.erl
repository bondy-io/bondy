%% =============================================================================
%%  bondy_config.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc An implementation of app_config behaviour.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_config).
-behaviour(app_config).

-include_lib("kernel/include/logger.hrl").
-include_lib("partisan/include/partisan.hrl").
-include("bondy.hrl").

-define(BONDY, bondy).

-export([get/1]).
-export([get/2]).
-export([init/0]).
-export([set/2]).

-export([node/0]).
-export([nodestring/0]).
-export([node_spec/0]).

-compile({no_auto_import, [get/1]}).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
init() ->
    ok = app_config:init(?BONDY, #{callback_mod => ?MODULE}),

    ?LOG_NOTICE(#{description => "Bondy configuration initialised"}),
    ok.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get(Key :: list() | atom() | tuple()) -> term().

get(wamp_call_timeout = Key) ->
    Value = app_config:get(?BONDY, Key),
    Max = app_config:get(?BONDY, wamp_max_call_timeout),
    min(Value, Max);

get(Key) ->
    app_config:get(?BONDY, Key).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get(Key :: list() | atom() | tuple(), Default :: term()) -> term().

get(Key, Default) ->
    app_config:get(?BONDY, Key, Default).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec set(Key :: key_value:key() | tuple(), Value :: term()) -> ok.

set(status, Value) ->
    %% Typically we would change status during application_controller
    %% lifecycle so to avoid a loop (resulting in timeout) we avoid
    %% calling application:set_env/3.
    persistent_term:put({?BONDY, status}, Value);

set(Key, Value) ->
    app_config:set(?BONDY, Key, Value).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec node() -> atom().

node() ->
    partisan_config:get(name).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec nodestring() -> nodestring().

nodestring() ->
    case get(nodestring, undefined) of
        undefined ->
            Node = partisan_config:get(name),
            set(nodestring, atom_to_binary(Node, utf8));
        Nodestring ->
            Nodestring
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec node_spec() -> node_spec().

node_spec() ->
    bondy_peer_service:myself().

