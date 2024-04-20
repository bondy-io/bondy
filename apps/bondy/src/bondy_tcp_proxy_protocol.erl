%% =============================================================================
%%  bondy_tcp_proxy_protocol.erl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
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
-module(bondy_tcp_proxy_protocol).
-include_lib("partisan/include/partisan_util.hrl").
-include("bondy.hrl").

-type t() :: #{
                enabled := boolean(),
                mode := strict | relaxed,
                proxy_info => ranch_proxy_header:proxy_info() | undefined,
                error => any() | undefined
            }.


-export([init/1]).
-export([init/2]).
-export([enabled/1]).
-export([error/1]).
-export([has_error/1]).
-export([mode/1]).
-export([proxy_info/1]).
-export([source_ip/2]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec init(atom()) -> t().

init(Ref) ->
    init(Ref, 15_000).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec init(atom(), timeout()) -> t().

init(Ref, Timeout) ->
    Opts = maps:from_list(bondy_config:get([Ref, proxy_protocol], [])),

    case maps:get(enabled, Opts, false) of
        true ->
            case ranch:recv_proxy_header(Ref, Timeout) of
                {ok, ProxyInfo} ->
                    Opts#{proxy_info => ProxyInfo};

                {error, Reason} ->
                    Opts#{error => {socket_error, Reason}};

                {error, protocol_error, Reason} ->
                    Opts#{error => {protocol_error, Reason}}
            end;

        false ->
            Opts
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
enabled(#{enabled := Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
mode(#{mode := Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
proxy_info(#{proxy_info := Val}) ->
    Val;

proxy_info(_) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
error(#{error := Val}) ->
    Val;

error(_) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
has_error(#{error := _}) -> true;
has_error(#{}) -> false.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
source_ip(#{enabled := true, mode := relaxed, error := _}, LocalIP)
when ?IS_IP(LocalIP)  ->
    {ok, LocalIP};

source_ip(#{enabled := true, mode := strict, error := Reason}, LocalIP)
when ?IS_IP(LocalIP)  ->
    {error, Reason};

source_ip(#{enabled := true, mode := Mode, proxy_info := Info}, LocalIP)
when ?IS_IP(LocalIP) ->
    case Info of
        #{command := local} ->
            {ok, LocalIP};

        #{command := proxy, src_address := SourceIP} ->
            {ok, SourceIP};

        #{command := proxy} when Mode == relaxed ->
            {ok, LocalIP};

        #{command := proxy} when Mode == strict ->
            {error, {protocol_error, <<"Missing src_address field">>}}
    end;

source_ip(#{enabled := false}, LocalIP) when ?IS_IP(LocalIP) ->
    {ok, LocalIP};

source_ip(#{enabled := _, mode := _} = T, LocalIP) ->
    ?ERROR(badarg, [T, LocalIP], #{1 => "should be a valid IP address"}).


