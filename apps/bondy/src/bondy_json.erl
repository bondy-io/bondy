%% =============================================================================
%%  bondy_json.erl -
%%
%%  Copyright (c) 2016-2022 Leapsight. All rights reserved.
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
%% @doc A utiliy module use to customised the JSON encoding for 3rd-party libs
%% e.g. erlang_jose
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_json).

-export([setup/0]).
-export([decode/1]).
-export([encode/1]).


%% =============================================================================
%% BONDY_CONFIG_MANAGER CALLBACKS
%% =============================================================================


setup() ->
    jose:json_module(?MODULE).


%% =============================================================================
%% JOSE CALLBACKS
%% =============================================================================


encode(Bin) ->
    jsone:encode(Bin, [
        undefined_as_null,
        {datetime_format, iso8601},
        {object_key_type, string}
    ]).


decode(Bin) ->
    jsone:decode(Bin, [undefined_as_null]).