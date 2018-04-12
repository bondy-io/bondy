%% =============================================================================
%%  bondy_peer_message -
%%
%%  Copyright (c) 2016-2018 Ngineo Limited t/a Leapsight. All rights reserved.
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

-module(bondy_peer_message).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").

-record(peer_message, {
    id          ::  id(),
    %% Supporting process identifiers in Partisan, without changing the
    %% internal implementation of Erlang’s process identifiers, is not
    %% possible without allowing nodes to directly connect to every
    %% other node.
    %% We use the pid-to-bin trick since we will be using the pid to generate
    %% an ACK.
    from        ::  {uri(), atom()},
    peer_id     ::  remote_peer_id(),
    payload     ::  wamp_invocation()
                    | wamp_error()
                    | wamp_result()
                    | wamp_interrupt()
                    | wamp_event(),
    options     ::  map()
}).


-opaque t()     ::  #peer_message{}.

-export_type([t/0]).


-export([from/1]).
-export([id/1]).
-export([is_message/1]).
-export([new/3]).
-export([peer_node/1]).
-export([options/1]).
-export([payload/1]).
-export([payload_type/1]).
-export([peer_id/1]).
-export([realm_uri/1]).


%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
new({RealmUri, Node} = PeerId, Payload0, Opts) ->
    Node =/= bondy_peer_service:mynode() orelse error(badarg),
    Payload1 = validate_payload(Payload0),

    #peer_message{
        id = bondy_utils:get_id(global),
        from = {RealmUri, bondy_peer_service:mynode()},
        peer_id = PeerId,
        payload = Payload1,
        options = Opts
    };

new({RealmUri, Node, _} = PeerId, Payload0, Opts) ->
    Node =/= bondy_peer_service:mynode() orelse error(badarg),
    Payload1 = validate_payload(Payload0),
    #peer_message{
        id = bondy_utils:get_id(global),
        from = {RealmUri, bondy_peer_service:mynode()},
        peer_id = PeerId,
        payload = Payload1,
        options = Opts
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
is_message(#peer_message{}) -> true;
is_message(_) -> false.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
id(#peer_message{id = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
realm_uri(#peer_message{from = {Val, _}}) -> Val;
realm_uri(#peer_message{from = {Val, _, _}}) -> Val;
realm_uri(#peer_message{from = {Val, _, _, _}}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
peer_node(#peer_message{peer_id = {_, Val}}) -> Val;
peer_node(#peer_message{peer_id = {_, Val, _}}) -> Val;
peer_node(#peer_message{peer_id = {_, Val, _, _}}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
from(#peer_message{from = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
peer_id(#peer_message{peer_id = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
payload(#peer_message{payload = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
payload_type(#peer_message{payload = Val}) -> element(1, Val).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
options(#peer_message{options = Val}) -> Val.



%% =============================================================================
%% PRIVATE
%% =============================================================================

validate_payload(#call{} = M) ->
    M;

validate_payload(#error{request_type = Type} = M)
when Type == ?CALL orelse Type == ?INVOCATION orelse Type == ?INTERRUPT ->
    M;

validate_payload(#interrupt{} = M) ->
    M;

validate_payload(#invocation{} = M) ->
    M;

validate_payload(#result{} = M) ->
    M;

validate_payload(#publish{} = M) ->
    M;

validate_payload(M) ->
    error({badarg, [M]}).
