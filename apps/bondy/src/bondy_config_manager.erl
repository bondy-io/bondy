%% =============================================================================
%%  bondy_config_manager.erl -
%%
%%  Copyright (c) 2016-2019 Ngineo Limited t/a Leapsight. All rights reserved.
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
-module(bondy_config_manager).
-behaviour(gen_server).
-include("bondy.hrl").


-record(state, {
}).

%% API
-export([apply_config/0]).
-export([load/1]).
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


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec apply_config() -> ok.

apply_config() ->
    gen_server:call(?MODULE, apply_config).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec load(map()) -> ok.

load(Config) when is_map(Config) ->
    gen_server:call(?MODULE, {load, Config}).



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================


init([]) ->
    ok = bondy_config:init(),
    State = #state{},
    {ok, State}.

handle_call(apply_config, _From, State) ->
    %% Res = do_apply_config(),
    Res = ok,
    {reply, Res, State};

handle_call({load, _Map}, _From, State) ->
    try
        %% ok = load_spec(Map),
        {reply, ok, State}
    catch
        ?EXCEPTION(_, Reason, _) ->
            {reply, {error, Reason}, State}
    end;

handle_call(Event, From, State) ->
    _ = lager:error(
        "Error handling call, reason=unsupported_event, event=~p, from=~p", [Event, From]),
    {reply, {error, {unsupported_call, Event}}, State}.


handle_cast(Event, State) ->
    _ = lager:error(
        "Error handling cast, reason=unsupported_event, event=~p", [Event]),
    {noreply, State}.


handle_info(Info, State) ->
    _ = lager:debug("Unexpected message, message=~p, state=~p", [Info, State]),
    {noreply, State}.



terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



