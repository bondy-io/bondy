%% =============================================================================
%%  bondy_remote_user_events_handler.erl -
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
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_remote_user_events_handler).
-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").
-include("bondy_plum_db.hrl").


-record(state, {
    subscriptions = #{} :: map()
}).

-export([start_link/0]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).



%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([]) ->
    State = subscribe(#state{}),
    {ok, State}.


handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State}.


handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.


handle_info({plum_db_event, object_update, {{FP, _Key}, _Obj, _Prev}}, State) ->

    case FP of
        {?PLUM_DB_USER_TAB, _RealmUri} ->
            ok;
        {?PLUM_DB_GROUP_TAB, _RealmUri} ->
            ok;
        {?PLUM_DB_USER_GRANT_TAB, _RealmUri} ->
            %% Monotonic queue with a time window
            ok;
        {?PLUM_DB_GROUP_GRANT_TAB, _RealmUri} ->
            ok
    end,

    {noreply, State};


handle_info(Info, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Info
    }),
    {noreply, State}.


terminate(normal, State) ->
    _ = unsubscribe(State),
    ok;

terminate(shutdown, State) ->
    _ = unsubscribe(State),
    ok;

terminate({shutdown, _}, State) ->
    _ = unsubscribe(State),
    ok;

terminate(_Reason, State) ->
    _ = unsubscribe(State),
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
subscribe(State) ->
    %% We subscribe to change notifications in plum_db_events
    %% Object :: {{{_, _} = FullPrefix, Key}, NewObj, ExistingObj}
    MatchHead = {{'$1', '_'}, '_', '_'},
    MS = [
        {MatchHead, [{'==', '$1', ?PLUM_DB_USER_TAB}], [true]},
        {MatchHead, [{'==', '$1', ?PLUM_DB_GROUP_TAB}], [true]},
        {MatchHead, [{'==', '$1', ?PLUM_DB_USER_GRANT_TAB}], [true]},
        {MatchHead, [{'==', '$1', ?PLUM_DB_GROUP_GRANT_TAB}], [true]}
    ],
    ok = plum_db_events:subscribe(object_update, MS),
    State.


%% @private
unsubscribe(State) ->
    _ = plum_db_events:unsubscribe(object_update),

    _ = [
        bondy_broker:unsubscribe(Id, ?MASTER_REALM_URI)
        ||  Id <- maps:keys(State#state.subscriptions)
    ],

    State#state{subscriptions = #{}}.
