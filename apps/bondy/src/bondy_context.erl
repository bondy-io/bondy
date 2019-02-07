
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
%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_context).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").

-type subprotocol_ex()        ::  subprotocol() | {http, text, json | msgpack}.


-type t()       ::  #{
    id => id(),
    %% Realm and Session
    realm_uri => uri(),
    node => atom(),
    transport_info => bondy_wamp_peer:transport_info(),
    peer => bondy_wamp_peer:local() | undefined,
    session_id => id(),
    session => bondy_session:session() | undefined,
    authmethod => binary(),
    authid => binary(),
    roles => map(),
    request_id => id(),
    request_timestamp => integer(),
    request_timeout => non_neg_integer(),
    request_details => map(),
    %% Metadata
    user_info => map()
}.
-export_type([t/0]).

-export([agent/1]).
-export([authid/1]).
-export([close/1]).
-export([encoding/1]).
-export([has_session/1]).
-export([is_feature_enabled/3]).
-export([local_context/1]).
-export([new/0]).
-export([new/2]).
-export([node/1]).
-export([peer/1]).
-export([peername/1]).
-export([realm_uri/1]).
-export([request_id/1]).
-export([request_timeout/1]).
-export([request_timestamp/1]).
-export([reset/1]).
-export([roles/1]).
-export([session/1]).
-export([session_id/1]).
-export([set_request_id/2]).
-export([set_request_timeout/2]).
-export([set_request_timestamp/2]).
-export([set_session_id/2]).
-export([set_session/2]).
-export([subprotocol/1]).
-export([transport_info/1]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
local_context(RealmUri) when is_binary(RealmUri) ->
    Ctxt = new(),
    Ctxt#{realm_uri => RealmUri}.


%% -----------------------------------------------------------------------------
%% @doc
%% Initialises a new context.
%% @end
%% -----------------------------------------------------------------------------
-spec new() -> t().
new() ->
    #{
        id => bondy_utils:get_id(global),
        node => bondy_peer_service:mynode(),
        request_id => undefined,
        request_timeout => bondy_config:request_timeout()
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(subprotocol_ex(), bondy_wamp_peer:transport_info()) -> t().
new(Subproto, TransportInfo) ->
    Ctxt = new(),
    Ctxt#{
        subprotocol => Subproto,
        transport_info => TransportInfo
    }.



%% -----------------------------------------------------------------------------
%% @doc
%% Resets the context. Returns a copy of Ctxt where the following attributes
%% have been reset: request_id, request_timeout, request_timestamp
%% @end
%% -----------------------------------------------------------------------------
-spec reset(t()) -> t().
reset(Ctxt) ->
    Ctxt#{
        request_timestamp => undefined,
        request_id => undefined,
        request_timeout => 0
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% Closes the context. This function calls {@link bondy_session:close/1}
%% and {@link bondy_router:close_context/1}.
%% @end
%% -----------------------------------------------------------------------------
-spec close(t()) -> ok.

close(#{session_id := SessionId} = Ctxt0) ->
    %% We cleanup router first as cleanup requires the session
    _ = bondy_router:close_context(Ctxt0),
    bondy_session:close(SessionId);

close(_) ->
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the WAMP Peer of the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec authid(t()) -> binary() | undefined.

authid(#{authid := Val}) ->  Val;
authid(#{}) -> undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the WAMP Peer of the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec peer(t()) -> bondy_wamp_peer:local().

peer(#{peer := Val}) ->  Val;
peer(#{}) -> undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec peername(t()) -> {inet:ip_address(), non_neg_integer()}.

peername(#{peer := Peer}) ->
    bondy_wamp_peer:peername(Peer);

peername(#{transport_info := #{peername := Val}}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the peer of the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec node(t()) -> atom().
node(#{node := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the subprotocol of the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec subprotocol(t()) -> subprotocol_ex().
subprotocol(#{subprotocol := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the module representing the transport e.g. ranch_tcp
%% @end
%% -----------------------------------------------------------------------------
-spec transport_info(t()) -> bondy_wamp_peer:transport_info().
transport_info(#{transport_info := Val}) -> Val;
transport_info(#{}) -> undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the encoding used by the peer of the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec encoding(t()) -> encoding().
encoding(#{subprotocol := {_, _, Val}}) -> Val;
encoding(#{}) -> undefined.



%% -----------------------------------------------------------------------------
%% @doc
%% Returns the roles of the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec roles(t()) -> map().
roles(Ctxt) ->
    bondy_session:roles(session(Ctxt)).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the realm uri of the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec realm_uri(t()) -> uri().
realm_uri(#{realm_uri := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the agent of the provided context or 'undefined'
%% if there is none.
%% @end
%% -----------------------------------------------------------------------------
-spec agent(t()) -> binary() | undefined.
agent(#{session := S}) ->
    bondy_session:agent(S);
agent(#{}) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the sessionId of the provided context or 'undefined'
%% if there is none.
%% @end
%% -----------------------------------------------------------------------------
-spec session_id(t()) -> id() | undefined.
session_id(#{session_id := SessionId}) ->
    SessionId;
session_id(#{}) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns true if the context is associated with a session,
%% false otherwise.
%% @end
%% -----------------------------------------------------------------------------
-spec has_session(t()) -> boolean().
has_session(#{session_id := _}) -> true;
has_session(#{}) -> false.


%% -----------------------------------------------------------------------------
%% @doc
%% Sets the sessionId to the provided context.
%% This creates a new `bondy_wamp_peer:local()' and sets its value to the
%% `peer' property.
%% @end
%% -----------------------------------------------------------------------------
-spec set_session_id(t(), id) -> t().
set_session_id(#{peer := _}, _) ->
    error(badarg);

set_session_id(Ctxt, SessionId) when is_integer(SessionId) ->
    #{
        realm_uri := RealmUri,
        transport_info := TransportInfo
    } = Ctxt,

    Node = bondy_peer_service:mynode(),
    Peer = bondy_wamp_peer:new(RealmUri, Node, SessionId, TransportInfo),

    Ctxt#{session => undefined, session_id => SessionId, peer => Peer}.


%% -----------------------------------------------------------------------------
%% @doc
%% Fetches and returns the bondy_session for the associated sessionId.
%% @end
%% -----------------------------------------------------------------------------
-spec session(t()) -> bondy_session:session() | no_return().


session(#{session := undefined, session_id := Id}) ->
    bondy_session:fetch(Id);

session(#{session := S}) ->
    S;

session(#{session_id := Id}) ->
    bondy_session:fetch(Id).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
set_session(Ctxt, Session) ->
    #{
        realm_uri := RealmUri,
        transport_info := TransportInfo
    } = Ctxt,

    Node = bondy_peer_service:mynode(),
    SessionId = bondy_session:id(Session),
    Peer = bondy_wamp_peer:new(RealmUri, Node, SessionId, TransportInfo),

    Ctxt#{session => Session, session_id => SessionId, peer => Peer}.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the current request id.
%% @end
%% -----------------------------------------------------------------------------
-spec request_id(t()) -> id().
request_id(#{request_id := Val}) ->
    Val.

%% -----------------------------------------------------------------------------
%% @doc
%% Sets the current request id to the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec set_request_id(t(), id()) -> t().
set_request_id(Ctxt, ReqId) ->
    Ctxt#{set_request_id => ReqId}.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the current request timeout.
%% @end
%% -----------------------------------------------------------------------------
-spec request_timeout(t()) -> non_neg_integer().
request_timeout(#{request_timeout := Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Sets the current request timeout to the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec set_request_timeout(t(), non_neg_integer()) -> t().
set_request_timeout(Ctxt, Timeout) when is_integer(Timeout), Timeout >= 0 ->
    Ctxt#{request_timeout => Timeout}.



%% -----------------------------------------------------------------------------
%% @doc
%% Returns the current request timestamp.
%% @end
%% -----------------------------------------------------------------------------
-spec request_timestamp(t()) -> integer().
request_timestamp(#{request_timestamp := Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Sets the current request timeout to the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec set_request_timestamp(t(), integer()) -> t().
set_request_timestamp(Ctxt, Timestamp) when is_integer(Timestamp) ->
    Ctxt#{request_timestamp => Timestamp}.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns true if the feature Feature is enabled for role Role.
%% @end
%% -----------------------------------------------------------------------------
-spec is_feature_enabled(t(), atom(), binary()) -> boolean().

is_feature_enabled(Ctxt, Role, Feature) ->
    maps_utils:get_path([Role, Feature], roles(Ctxt), false).
