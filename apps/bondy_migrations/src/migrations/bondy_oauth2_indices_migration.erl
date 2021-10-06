%% =============================================================================
%%  oauth2_db_indices.erl -
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

-module(bondy_oauth2_indices_migration).
-behaviour(bondy_migration).


-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").


-record(state, {
    relations = []      ::  [{Realm :: uri(), ClienId :: binary()}]
}).

%% BONDY_MIGRATION CALLBACKS
-export([phases/0]).
-export([dependencies/0]).
-export([init/0]).
-export([terminate/2]).

%% PHASE OPERATIONS
-export([prepare/1]).
-export([nop/1]).
-export([revoke_dangling_tokens/1]).
-export([rebuild_token_indices/1]).




%% =============================================================================
%% BONDY_MIGRATION CALLBACKS
%% =============================================================================


phases() ->
    [
        bondy_migration:new_phase(
            <<"Prepare">>, prepare, nop),
        bondy_migration:new_phase(
            <<"Rebuild token indices">>, rebuild_token_indices, nop),
        bondy_migration:new_phase(
            <<"Revoke dangling refresh tokens">>, revoke_dangling_tokens, nop),
        bondy_migration:new_phase(
            <<"Finish">>, set_migration_flags, unset_migration_flags)
    ].


dependencies() ->
    [].


init() ->
    State = #state{},
    {ok, State}.


terminate(_Reason, _State) ->
    ok.



%% =============================================================================
%% OPERATIONS
%% =============================================================================



prepare(State0) ->
    Realms = [bondy_realm:uri(R) || R <- bondy_realm:list()],

    Filter =fun({Username, PL}, {Realm, Acc}) when is_list(PL) ->
        Groups = proplists:get_value(<<"groups">>, PL, []),
        case lists:member(<<"api_clients">>, Groups)  of
            true -> [{Realm, Username} | Acc];
            false -> Acc
        end
    end,

    L = [
        begin
            Users = bondy_security:list(Realm, user),
            lists:foldl(Filter, {Realm, []}, Users)
        end
        || Realm <- Realms
    ],

    State1 = State0#state{relations = lists:flatten(L)},
    {ok, State1}.


nop(State) ->
    {ok, State}.


rebuild_token_indices(#state{relations = []} = State) ->
    {ok, State};

rebuild_token_indices(#state{relations = Rels} = State) ->
    _ = [
        bondy_oauth2:rebuild_token_indices(Realm, ClientId)
        || {Realm, ClientId} <- Rels
    ],
    {ok, State}.


revoke_dangling_tokens(#state{relations = []} = State) ->
    {ok, State};

revoke_dangling_tokens(#state{relations = Rels} = State) ->
    _ = [
        bondy_oauth2:revoke_dangling_tokens(Realm, ClientId)
        || {Realm, ClientId} <- Rels
    ],
    {ok, State}.

