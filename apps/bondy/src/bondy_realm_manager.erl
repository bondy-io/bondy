%% =============================================================================
%%  bondy_realm_manager.erl -
%%
%%  Copyright (c) 2018-2022 Leapsight. All rights reserved.
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

-module(bondy_realm_manager).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy_plum_db.hrl").


-record(state, {}).

%% API
-export([start_link/0]).
-export([close/2]).


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


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec close(RealmUri :: uri(), Reason :: any()) -> ok.

close(RealmUri, Reason) ->
    gen_server:cast(?MODULE, {close, RealmUri, Reason}).



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([]) ->
    %% Subscribe this process to receive data updates
    MS = [{
        %% {{{?PLUM_DB_REALM_TAB, Uri} = FullPrefix, Key}, NewObj, ExistingObj}
        {{{'$1', '_'}, '_'}, '_', '_'},
        [
            {'orelse',
                {'=:=', ?PLUM_DB_REALM_TAB, '$1'},
                {'=:=', ?PLUM_DB_REALM_TAB, '$1'}
            }
        ],
        [true]
    }],

    plum_db_events:subscribe(object_update, MS),

    {ok, #state{}}.


handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State}.

handle_cast({close, RealmUri, Reason}, State) ->
    ok = do_close(RealmUri, Reason),
    {noreply, State};


handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.


handle_info({plum_db_event, object_update, {{{_, _}, Uri}, Obj, _}}, State) ->
    Resolved = plum_db_object:resolve(Obj, lww),

    case plum_db_object:value(Resolved) of
        '$deleted' ->
            %% Realm was deleted, call close
            do_close(Uri, deleted);
        _ ->
            %% Realm updated, do nothing
            ok
    end,

    {noreply, State};

handle_info(Info, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Info
    }),
    {noreply, State}.


terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



do_close(RealmUri, Reason) ->
    ?LOG_WARNING(#{
        description => "Closing realm",
        reason => Reason,
        realm => RealmUri
    }),
    bondy_session_manager:close_all(RealmUri, realm_closed).