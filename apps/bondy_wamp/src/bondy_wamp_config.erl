%% =============================================================================
%%  wamp_config.erl -
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
-module(bondy_wamp_config).
-behaviour(app_config).

-define(APP, wamp).
-define(JSON_ENCODE_OPTS, [
]).

-define(JSON_DECODE_OPTS, [
]).

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
    ok = init_json_serialization_opts(),
    ok = init_defaults(),
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




%% =============================================================================
%% PRIVATE
%% =============================================================================


init_defaults() ->
    case get(uri_strictness, undefined) of
        undefined ->
            set(uri_strictness, loose);
        _ ->
            ok
    end.


init_json_serialization_opts() ->
    case get([serialization, json, encode], undefined) of
        undefined ->
            set([serialization, json, encode], ?JSON_ENCODE_OPTS);
        EncodeOpts0 ->
            EncodeOpts = validate_json_opts(EncodeOpts0, ?JSON_ENCODE_OPTS),
            set([serialization, json, encode], EncodeOpts)
    end,

    case get([serialization, json, decode], undefined) of
        undefined ->
            set([serialization, json, decode], ?JSON_DECODE_OPTS);
        DecodeOpts0 ->
            DecodeOpts = validate_json_opts(DecodeOpts0, ?JSON_DECODE_OPTS),
            set([serialization, json, decode], DecodeOpts)
    end,

    ok.




validate_json_opts(Opts, Default) when is_list(Opts) ->
    validate_json_opts(maps:from_list(proplists:unfold(Opts)), Default);

validate_json_opts(Opts, Default0) when is_map(Opts) ->
    Default1 = maps:from_list(proplists:unfold(Default0)),
    proplists:compact(maps:to_list(maps:merge(Default1, Opts))).