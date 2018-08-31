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
-include("bondy_security.hrl").

-define(BONDY_REALM, #{
    <<"description">> => <<"The Bondy administrative realm.">>,
    <<"authmethods">> => [?WAMPCRA_AUTH, ?TICKET_AUTH]
}).


-export([start/2]).
-export([stop/1]).
-export([prep_stop/1]).
-export([vsn/0]).



%% =============================================================================
%% API
%% =============================================================================



start(_Type, Args) ->
    case bondy_sup:start_link() of
        {ok, Pid} ->
            ok = setup_env(Args),
            ok = bondy_router_worker:start_pool(),
            ok = bondy_stats:init(),
            ok = bondy_cli:register(),
            ok = setup_partisan(),
            ok = maybe_init_bondy_realm(),
            ok = maybe_start_router_services(),
            ok = setup_internal_subscriptions(),
            {ok, Pid};
        Other  ->
            Other
    end.


prep_stop(_State) ->
    stop_router_services().


stop(_State) ->
    ok.


-spec vsn() -> list().
vsn() ->
    application:get_env(bondy, vsn, "undefined").



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
setup_env(Args) ->
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


stop_router_services() ->
    _ = lager:info("Initiating shutdown"),
    %% We stop accepting new connections on HTTP/Websockets
    ok = bondy_api_gateway:suspend_listeners(),
    %% We stop accepting new connections on TCP/TLS
    ok = bondy_wamp_raw_handler:suspend_listeners(),

    %% We ask the router to shutdown which will send a goodbye to all sessions
    ok = bondy_router:shutdown(),

    %% We sleep for a minute to allow all sessions to terminate gracefully
    Time = 10000,
    _ = lager:info(
        "Awaiting for ~p secs for clients graceful shutdown.",
        [trunc(Time/1000)]
    ),
    ok = timer:sleep(Time),
    _ = lager:info("Terminating all client connections"),

    %% We force the HTTP/WS connections to stop
    ok = bondy_api_gateway:stop_listeners(),
    %% We force the TCP and TLS connections to stop
    ok = bondy_wamp_raw_handler:stop_listeners(),
    ok.


%% TODO moved this into each app when we finish restructuring
setup_internal_subscriptions() ->
    Opts = #{match => <<"exact">>},
    bondy:subscribe(
        ?BONDY_PRIV_REALM_URI,
        Opts,
        ?USER_ADDED,
        fun bondy_api_gateway_wamp_handler:handle_event/2
    ),
    _ = bondy:subscribe(
        ?BONDY_PRIV_REALM_URI,
        Opts,
        ?USER_DELETED,
        fun bondy_api_gateway_wamp_handler:handle_event/2
    ),
    bondy:subscribe(
        ?BONDY_PRIV_REALM_URI,
        Opts,
        ?USER_UPDATED,
        fun bondy_api_gateway_wamp_handler:handle_event/2
    ),
    bondy:subscribe(
        ?BONDY_PRIV_REALM_URI,
        Opts,
        ?PASSWORD_CHANGED,
        fun bondy_api_gateway_wamp_handler:handle_event/2
    ),
    ok.
