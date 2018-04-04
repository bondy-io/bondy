%% =============================================================================
%%  bondy_partisan_peer_service.erl -
%%
%%  Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
%%  Copyright (c) 2015 Christopher Meiklejohn.  All Rights Reserved.
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
%% Based on: github.com/lasp-lang/lasp/...lasp_partisan_peer_service.erl
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_partisan_peer_service).
-behaviour(bondy_peer_service).


%% bondy_peer_service callbacks
-export([forward_message/3]).
-export([forward_message/4]).
-export([forward_message/5]).
-export([join/1]).
-export([join/2]).
-export([join/3]).
-export([leave/0]).
-export([leave/1]).
-export([manager/0]).
-export([members/0]).
-export([mynode/0]).
-export([myself/0]).
-export([stop/0]).
-export([stop/1]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Prepare node to join a cluster.
%% @end
%% -----------------------------------------------------------------------------
join(Node) ->
    partisan_peer_service:join(Node, true).


%% -----------------------------------------------------------------------------
%% @doc Convert nodename to atom.
%% @end
%% -----------------------------------------------------------------------------
join(NodeStr, Auto) when is_list(NodeStr) ->
    partisan_peer_service:join(NodeStr, Auto);

join(Node, Auto) when is_atom(Node) ->
    partisan_peer_service:join(Node, Auto);

join(#{name := _Name, listen_addrs := _ListenAddrs} = Node, Auto) ->
    partisan_peer_service:join(Node, Auto).


%% -----------------------------------------------------------------------------
%% @doc Initiate join. Nodes cannot join themselves.
%% @end
%% -----------------------------------------------------------------------------
join(Node, Node, Auto) ->
    partisan_peer_service:join(Node, Node, Auto).


%% -----------------------------------------------------------------------------
%% @doc Leave the cluster.
%% @end
%% -----------------------------------------------------------------------------
leave() ->
    partisan_peer_service:leave((partisan_peer_service:manager()):mynode()).


%% -----------------------------------------------------------------------------
%% @doc Leave the cluster.
%% @end
%% -----------------------------------------------------------------------------
leave(Node) ->
    partisan_peer_service:leave(Node).


%% -----------------------------------------------------------------------------
%% @doc Forward message to registered process on the remote side.
%% @end
%% -----------------------------------------------------------------------------
forward_message(Name, ServerRef, Message) ->
    Manager = manager(),
    Manager:forward_message(Name, ServerRef, Message).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
forward_message(Name, Channel, ServerRef, Message) ->
    Manager = manager(),
    Manager:forward_message(Name, Channel, ServerRef, Message).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
forward_message(Name, Channel, ServerRef, Message, Opts) ->
    Manager = manager(),
    Manager:forward_message(Name, Channel, ServerRef, Message, Opts).


%% -----------------------------------------------------------------------------
%% @doc Leave the cluster.
%% @end
%% -----------------------------------------------------------------------------
members() ->
    (partisan_peer_service:manager()):members().

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
manager() ->
    partisan_peer_service:manager().


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
myself() ->
    partisan_peer_service_manager:myself().


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
mynode() ->
    partisan_peer_service_manager:mynode().


%% -----------------------------------------------------------------------------
%% @doc Stop node.
%% @end
%% -----------------------------------------------------------------------------
stop() ->
    stop(stop_request_received).


%% -----------------------------------------------------------------------------
%% @doc Stop node for a given reason.
%% @end
%% -----------------------------------------------------------------------------
stop(Reason) ->
    lager:notice("Stopping; reason=~p", [Reason]),
    partisan_peer_service:stop(Reason).

