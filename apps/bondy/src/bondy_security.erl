%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
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
    bondy_realm:exists(RealmUri) orelse error({no_such_realm, RealmUri}),
    case plum_db:get(?STATUS_PREFIX(RealmUri), enabled) of
        true -> true;
        _ -> false
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
enable(RealmUri) ->
    bondy_realm:exists(RealmUri) orelse error({no_such_realm, RealmUri}),
    plum_db:put(?STATUS_PREFIX(RealmUri), enabled, true).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
disable(RealmUri) ->
    bondy_realm:exists(RealmUri) orelse error({no_such_realm, RealmUri}),
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
