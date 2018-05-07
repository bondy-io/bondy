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
-export([vsn/0]).

start(_Type, Args) ->
    case bondy_sup:start_link() of
        {ok, Pid} ->
            ok = setup(Args),
            ok = bondy_router_worker:start_pool(),
            ok = bondy_stats:init(),
            ok = maybe_init_bondy_realm(),
            ok = maybe_start_router_services(),
            ok = bondy_cli:register(),
            ok = setup_partisan(),
            {ok, Pid};
        Other  ->
            Other
    end.


stop(_State) ->
    ok.


-spec vsn() -> list().

vsn() ->
    application:get_env(bondy, vsn, "undefined").


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


%% @private
setup(Args) ->
    case lists:keyfind(vsn, 1, Args) of
        {vsn, Vsn} ->
            application:set_env(bondy, vsn, Vsn);
        false ->
            ok
    end.


%% @private
setup_partisan() ->
    Channels0 = partisan_config:get(channels, []),
    partisan_config:set(channels, [wamp_peer_messages | Channels0]).
