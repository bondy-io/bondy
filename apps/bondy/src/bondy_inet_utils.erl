
%% =============================================================================
%%  bondy_net_utils.erl -
%%
%%  Copyright (c) 2016-2022 Leapsight. All rights reserved.
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
-module(bondy_inet_utils).

-export([net_status/0]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Returns `connected' if the host has at least one non-loopback network
%% interface address. Otherwise returns `disconnected'.
%% @end
%% -----------------------------------------------------------------------------
-spec net_status() -> connected | disconnected.

net_status() ->
    L = net:getifaddrs(
        fun
            (#{addr  := #{family := Family}, flags := Flags})
            when Family == inet orelse Family == inet6 ->
			    not lists:member(loopback, Flags);
            (_) ->
                false
            end
    ),

    case L == [] of
        true -> disconnected;
        false -> connected
    end.

