%% =============================================================================
%% bondy_app - 
%%
%% Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%    http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%% =============================================================================
-module(bondy_app).
-behaviour(application).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").

-define(BONDY_REALM, #{
    <<"description">> => <<"The Bondy administrative realm.">>,
    <<"authmethods">> => [?WAMPCRA_AUTH, ?TICKET_AUTH]
}).


-export([start/2]).
-export([stop/1]).

start(_Type, _Args) ->
    case bondy_sup:start_link() of
        {ok, Pid} ->
            ok = bondy_router:start_pool(),
            ok = bondy_stats:create_metrics(),
            ok = maybe_init_bondy_realm(),
            ok = maybe_start_router_services(),
            qdate:register_parser(iso8601, date_parser()),
            {ok, Pid};
        Other  ->
            Other
    end.


stop(_State) ->
    ok.



%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
maybe_init_bondy_realm() ->
    %% TODO Check what happens when we join the cluster and bondy realm was
    %% already defined in my peers...we should not use LWW here.
    _ = bondy_realm:get(?BONDY_REALM_URI, ?BONDY_REALM),
    ok.


%% @private
maybe_start_router_services() ->
    case bondy_config:is_router() of
        true ->
            ok = bondy_wamp_raw_handler:start_listeners(),
            _ = bondy_api_gateway:start_admin_listeners(),
            _ = bondy_api_gateway:start_listeners();
        false ->
            ok
    end.




%% A custom qdate parser for the ISO8601 dates where timezone == Z.
date_parser() ->
    fun
        (RawDate) when length(RawDate) == 20 ->
            try 
                re:run(RawDate,"^(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2}):(\\d{2})Z",[{capture,all_but_first,list}]) 
            of
                nomatch -> undefined;
                {match, [Y,M,D,H,I,S]} ->
                    Date = {list_to_integer(Y), list_to_integer(M), list_to_integer(D)},
                    Time = {list_to_integer(H), list_to_integer(I), list_to_integer(S)},
                    case calendar:valid_date(Date) of
                        true -> 
                            {{Date, Time}, "UTC"};
                        false -> 
                            undefined
                    end
            catch 
                _:_ -> 
                    undefined
            end;
        (_) -> 
            undefined
    end.