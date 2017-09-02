
%% =============================================================================
%%  bondy_context.erl -
%%
%%  Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
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


%% =============================================================================
%% @doc
%% A Bondy Context lets you access information that defines the state of an
%% interaction. In a typical interacion, several actors or objects have a hand
%% in what is going on e.g. bondy_session, wamp_realm, etc.
%%
%% The Bondy Context is passed as an argument through the whole request-response
%%  loop to provide access to that information.
%% @end
%% =============================================================================
-module(bondy_context).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").

-type subprotocol_2()        ::  subprotocol()
                                | {http, text, json | msgpack}.


-type context()       ::  #{
    id => id(),
    %% Realm and Session
    realm_uri => uri(),
    session => bondy_session:session() | undefined,
    %% Peer Info
    peer => bondy_session:peer(),
    authmethod => binary(),
    authid => binary(),
    roles => map(),
    %% Protocol State
    goodbye_initiated => boolean(),
    challenge_sent => {true, AuthMethod :: any()} | false,
    awaiting_calls => sets:set(),
    request_id => id(),
    request_timeout => non_neg_integer(),
    request_details => map(),
    %% Metadata
    user_info => map()
}.
-export_type([context/0]).


-export([close/1]).
-export([has_session/1]).
-export([is_feature_enabled/3]).
-export([new/0]).
-export([new/2]).
-export([peer/1]).
-export([add_awaiting_call/2]).
-export([awaiting_calls/1]).
-export([realm_uri/1]).
-export([request_id/1]).
-export([request_timeout/1]).
-export([reset/1]).
-export([roles/1]).
-export([session/1]).
-export([session_id/1]).
-export([peer_id/1]).
-export([set_peer/2]).
-export([remove_awaiting_call/2]).
-export([set_subprotocol/2]).
-export([subprotocol/1]).
-export([set_request_id/2]).
-export([set_request_timeout/2]).
-export([set_roles/2]).
-export([set_session/2]).


%% -----------------------------------------------------------------------------
%% @doc
%% Initialises a new context.
%% @end
%% -----------------------------------------------------------------------------
-spec new() -> context().
new() ->
    Ctxt = #{
        id => bondy_utils:get_id(global),
        goodbye_initiated => false,
        request_id => undefined,
        request_timeout => bondy_config:request_timeout(),
        awaiting_calls => sets:new()
    },
    set_roles(Ctxt, #{}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(bondy_session:peer(), subprotocol_2()) -> context().
new(Peer, Subprotocol) ->
    set_subprotocol(set_peer(new(), Peer), Subprotocol).


%% -----------------------------------------------------------------------------
%% @doc
%% Resets the context. Returns a copy of Ctxt where the following attributes
%% have been reset: request_id, request_timeout.
%% @end
%% -----------------------------------------------------------------------------
-spec reset(context()) -> context().
reset(Ctxt) ->
    Ctxt#{
        request_id => undefined,
        request_timeout => 0
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% Closes the context. This function calls {@link bondy_session:close/1}
%% and {@link bondy_router:close_context/1}.
%% @end
%% -----------------------------------------------------------------------------
-spec close(context()) -> ok.

close(Ctxt0) ->
    %% We cleanup router first as cleanup requires the session
    case maps:find(session, bondy_router:close_context(Ctxt0)) of
        {ok, Session} ->
            bondy_session:close(Session);
        error ->
            ok
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the peer of the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec peer(context()) -> bondy_session:peer().
peer(#{peer := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Set the peer to the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec set_peer(context(), bondy_session:peer()) -> context().
set_peer(Ctxt, {{_, _, _, _}, _Port} = Peer) when is_map(Ctxt) ->
    Ctxt#{peer => Peer}.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the peer of the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec subprotocol(context()) -> subprotocol_2().
subprotocol(#{subprotocol := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Set the peer to the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec set_subprotocol(context(), subprotocol_2()) -> context().
set_subprotocol(Ctxt, {_, _, _} = S) when is_map(Ctxt) ->
    Ctxt#{subprotocol => S}.

%% -----------------------------------------------------------------------------
%% @doc
%% Returns the roles of the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec roles(context()) -> map().
roles(#{roles := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Sets the roles to the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec set_roles(context(), map()) -> context().

set_roles(Ctxt, Roles) when is_map(Ctxt), is_map(Roles) ->
    Ctxt#{roles => Roles}.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the realm uri of the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec realm_uri(context()) -> uri().
realm_uri(#{realm_uri := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the sessionId of the provided context or 'undefined'
%% if there is none.
%% @end
%% -----------------------------------------------------------------------------
-spec session_id(context()) -> id() | undefined.
session_id(#{session := S}) ->
    bondy_session:id(S);
session_id(#{}) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns true if the context is associated with a session,
%% false otherwise.
%% @end
%% -----------------------------------------------------------------------------
-spec has_session(context()) -> boolean().
has_session(#{session := _}) -> true;
has_session(#{}) -> false.


%% -----------------------------------------------------------------------------
%% @doc
%% Sets the sessionId to the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec set_session(context(), bondy_session:session()) -> context().
set_session(Ctxt, S) ->
    Ctxt#{session => S}.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec peer_id(context()) -> peer_id().

peer_id(#{session := S}) ->
    %% TODO evaluate caching this as it should be immutable
    {bondy_session:id(S), bondy_session:pid(S)}.


%% -----------------------------------------------------------------------------
%% @doc
%% Fetches and returns the bondy_session for the associated sessionId.
%% @end
%% -----------------------------------------------------------------------------
-spec session(context()) -> bondy_session:session() | no_return().
session(#{session := S}) ->
    S.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the current request id.
%% @end
%% -----------------------------------------------------------------------------
-spec request_id(context()) -> id().
request_id(#{request_id := Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Sets the current request id to the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec set_request_id(context(), id()) -> context().
set_request_id(Ctxt, ReqId) ->
    Ctxt#{set_request_id => ReqId}.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the current request timeout.
%% @end
%% -----------------------------------------------------------------------------
-spec request_timeout(context()) -> non_neg_integer().
request_timeout(#{request_timeout := Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Sets the current request timeout to the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec set_request_timeout(context(), non_neg_integer()) -> context().
set_request_timeout(Ctxt, Timeout) when is_integer(Timeout), Timeout >= 0 ->
    Ctxt#{request_timeout => Timeout}.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns true if the feature Feature is enabled for role Role.
%% @end
%% -----------------------------------------------------------------------------
-spec is_feature_enabled(context(), atom(), binary()) -> boolean().

is_feature_enabled(#{roles := Roles}, Role, Feature) ->
    maps_utils:get_path([Role, Feature], Roles, false).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns a list containing the identifiers for the calls the peer performed
%% and it is still awaiting a response for.  This is used by the internal rpc
%% mechanism which is based on promises.
%% @end
%% -----------------------------------------------------------------------------
-spec awaiting_calls(context()) -> [id()].
awaiting_calls(#{awaiting_calls := S}) ->
    sets:to_list(S).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add_awaiting_call(context(), id()) -> ok.
add_awaiting_call(#{awaiting_calls := S} = C, Id) ->
    C#{awaiting_calls => sets:add_element(Id, S)}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove_awaiting_call(context(), id()) -> ok.
remove_awaiting_call(#{awaiting_calls := S} = C, Id) ->
    C#{awaiting_calls => sets:del_element(Id, S)}.