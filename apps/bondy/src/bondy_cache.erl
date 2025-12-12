%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_cache).


-export([get/2]).
-export([put/3]).
-export([put/4]).
-export([remove/2]).

%% TODO Evict all caches for Session, User, Client and Realm once any of them are deleted

-spec get(RealmUri :: binary(), any()) -> {ok, any()} | {error, not_found}.
get(_, _) ->
    %%TODO
    {error, not_found}.

put(RealmUri, K, V) ->
    bondy_cache:put(RealmUri, K, V, #{}).


put(_RealmUri, _, _, _Opts) ->
    %%TODO
    ok.

remove(_RealmUri, _) ->
    %%TODO
    ok.

%%TODO factor out all TTL related functionality from tuplespace_queue into a tuplespace_ttl module to be reused
