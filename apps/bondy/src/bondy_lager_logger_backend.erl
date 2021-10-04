%% =============================================================================
%%  bondy_auth_anonymous.erl -
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


-module(bondy_lager_logger_backend).
-behaviour(gen_event).

-include_lib("lager/include/lager.hrl").


%% API
-export([init/1]).
-export([handle_call/2]).
-export([handle_event/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).





%% =============================================================================
%% GEN_EVENT CALLBACKS
%% =============================================================================



init(_) ->
    {ok, undefined}.


handle_call(get_loglevel, undefined) ->
    Level = lager_util:config_to_mask(
        maps:get(level, logger:get_primary_config(), notice)
    ),
    {ok, Level, undefined};

handle_call({set_loglevel, _}, undefined) ->
    %% We set level directly in logger
    {ok, ok, undefined};

handle_call(_Request, undefined) ->
    {ok, ok, undefined}.


handle_event({log, Msg}, undefined) ->
    logger:log(
        lager_msg:severity(Msg),
        #{
            description => iolist_to_binary(lager_msg:message(Msg)),
            log_source => lager
        },
        to_metadata(Msg)
    ),
    {ok, undefined};

handle_event(_Event, undefined) ->
    {ok, undefined}.

%% @private
handle_info(_Info, undefined) ->
    {ok, undefined}.

%% @private
terminate(_Reason, undefined) ->
    ok.

%% @private
code_change(_OldVsn, undefined, _Extra) ->
    {ok, undefined}.





%% =============================================================================
%% PRIVATE
%% =============================================================================



to_metadata(Msg) ->
    Meta0 = maps:from_list(lager_msg:metadata(Msg)),

    Meta = maps:without([module, function, line], Meta0),
    Meta#{
        mfa => {
            maps:get(module, Meta0, undefined),
            maps:get(function, Meta0, undefined),
            %% Lager does not have the arity of the function so we put a large
            %% number
            100
        },
        pid => maps:get(pid, Meta0, undefined),
        line => maps:get(line, Meta0, 0),
        time => to_unixtime(lager_msg:timestamp(Msg))
    }.

to_unixtime({MegaSecs, Secs, Microsecs}) ->
    MegaSecs * 1000000 * 1000000 + Secs * 1000000 + Microsecs.