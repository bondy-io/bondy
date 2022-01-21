%% =============================================================================
%%  bondy_security.erl -
%%
%%  Copyright (c) 2016-2022 Leapsight. All rights reserved.
%%  Copyright (c) 2013 Basho Technologies, Inc.
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

-module(bondy_security).

-define(STATUS_PREFIX(RealmUri), {security_status, RealmUri}).

%% API
-export([disable/1]).
-export([enable/1]).
-export([is_enabled/1]).
-export([rbac_mod/1]).
-export([status/1]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
rbac_mod(_) ->
    bondy_rbac.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
is_enabled(RealmUri) ->
    bondy_realm:exists(RealmUri) orelse error(no_such_realm),
    case plum_db:get(?STATUS_PREFIX(RealmUri), enabled) of
        true -> true;
        _ -> false
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
enable(RealmUri) ->
    bondy_realm:exists(RealmUri) orelse error(no_such_realm),
    plum_db:put(?STATUS_PREFIX(RealmUri), enabled, true).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
disable(RealmUri) ->
    bondy_realm:exists(RealmUri) orelse error(no_such_realm),
    plum_db:put(?STATUS_PREFIX(RealmUri), enabled, false).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
status(RealmUri) ->
    case is_enabled(RealmUri) of
        true -> enabled;
        _ -> disabled
    end.
