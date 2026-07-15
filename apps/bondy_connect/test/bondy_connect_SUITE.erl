%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([nowarn_export_all, export_all]).

all() ->
    [
        app_starts_and_stops,
        sup_tree
    ].

%% The skeleton must boot (with its library deps) and shut down cleanly,
%% without any dependency on the bondy router.
app_starts_and_stops(_) ->
    {ok, Started} = application:ensure_all_started(bondy_connect),
    ?assert(lists:member(bondy_connect, Started)),
    ?assert(is_pid(whereis(bondy_connect_sup))),

    %% No dependency on the router app should have been pulled in.
    ?assertNot(lists:member(bondy, Started)),

    ok = application:stop(bondy_connect),
    ?assertEqual(undefined, whereis(bondy_connect_sup)).

%% The top supervisor is one_for_one and starts the connection manager and the
%% dynamic connections supervisor (it owns no live connections until one is
%% opened).
sup_tree(_) ->
    {ok, _} = application:ensure_all_started(bondy_connect),
    Pid = whereis(bondy_connect_sup),
    ?assert(is_pid(Pid)),

    {ok, {SupFlags, ChildSpecs}} = bondy_connect_sup:init([]),
    ?assertEqual(one_for_one, maps:get(strategy, SupFlags)),
    Ids = [maps:get(id, Spec) || Spec <- ChildSpecs],
    ?assertEqual(
        [bondy_connect_manager, bondy_connect_connections_sup],
        Ids
    ),
    ?assert(is_pid(whereis(bondy_connect_manager))),

    ok = application:stop(bondy_connect).
