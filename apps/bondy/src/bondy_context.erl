
%% =============================================================================
%%  bondy_context.erl -
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
-behaviour(bondy_sensitive).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").

-type subprotocol_2()        ::  subprotocol()
                                | {http, text, json | msgpack}.


-type t()       ::  #{
    id => id(),
    %% Realm and Session
    realm_uri => uri(),
    node => atom(),
    security_enabled => boolean(),
    session => bondy_session:t() | undefined,
    %% Peer Info
    peer => bondy_session:peer(),
    authmethod => binary(),
    authid => binary(),
    is_anonymous => boolean(),
    roles => map(),
    request_id => id(),
    request_timestamp => integer(),
    request_timeout => non_neg_integer(),
    request_details => map(),
    %% Metadata
    user_info => map()
}.
-export_type([t/0]).


%% BONDY_SENSITIVE CALLBACKS
-export([format_status/2]).

%% API
-export([agent/1]).
-export([authid/1]).
-export([authrole/1]).
-export([authroles/1]).
-export([call_timeout/1]).
-export([caller_details/2]).
-export([close/1]).
-export([close/2]).
-export([encoding/1]).
-export([get_id/2]).
-export([has_session/1]).
-export([id/1]).
-export([is_anonymous/1]).
-export([is_feature_enabled/3]).
-export([is_security_enabled/1]).
-export([local_context/1]).
-export([new/0]).
-export([new/2]).
-export([node/1]).
-export([peer/1]).
-export([ref/1]).
-export([peername/1]).
-export([publisher_details/2]).
-export([rbac_context/1]).
-export([realm_uri/1]).
-export([request_details/1]).
-export([request_id/1]).
-export([request_timeout/1]).
-export([request_timestamp/1]).
-export([reset/1]).
-export([roles/1]).
-export([session/1]).
-export([session_id/1]).
-export([set_authid/2]).
-export([set_call_timeout/2]).
-export([set_is_anonymous/2]).
-export([set_peer/2]).
-export([set_realm_uri/2]).
-export([set_request_details/2]).
-export([set_request_id/2]).
-export([set_request_timeout/2]).
-export([set_request_timestamp/2]).
-export([set_session/2]).
-export([set_subprotocol/2]).
-export([subprotocol/1]).



%% =============================================================================
%% BONDY_SENSITIVE CALLBACKS
%% =============================================================================



-spec format_status(Opts :: normal | terminate, Ctxt :: t()) -> term().

format_status(Opt, Ctxt0) ->
    Ctxt = Ctxt0#{
        authid => bondy_sensitive:wrap(authid(Ctxt0))
    },

    case session(Ctxt) of
        undefined ->
            Ctxt;
        Session ->
            Formatted = bondy_sensitive:format_status(
                Opt, bondy_session, Session
            ),
            Ctxt#{session => Formatted}
    end.


%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% Initialises a new context.
%% @end
%% -----------------------------------------------------------------------------
-spec new() -> t().
new() ->
    #{
        id => bondy_utils:get_id(global),
        node => bondy_config:node(),
        request_id => undefined,
        call_timeout => bondy_config:get(wamp_call_timeout, undefined),
        request_timeout => bondy_config:get(request_timeout, undefined)
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
local_context(RealmUri) when is_binary(RealmUri) ->
    Ctxt = new(),

    Ctxt#{
        realm_uri => RealmUri,
        security_enabled => bondy_realm:is_security_enabled(RealmUri)
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(bondy_session:peer(), subprotocol_2()) -> t().
new(Peer, Subprotocol) ->
    set_subprotocol(set_peer(new(), Peer), Subprotocol).


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
        request_details => undefined,
        request_timeout => 0
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% Closes the context. This function calls close/2 with `normal' as reason.
%% @end
%% -----------------------------------------------------------------------------
-spec close(t()) -> ok.

close(Ctxt0) ->
    close(Ctxt0, normal).


%% -----------------------------------------------------------------------------
%% @doc
%% Closes the context. This function calls {@link bondy_session:close/1}
%% and {@link bondy_router:close_context/1}.
%% @end
%% -----------------------------------------------------------------------------
-spec close(t(), Reason :: normal | crash | shutdown) -> ok.

close(Ctxt, _Reason) ->
    _ = bondy_router:close_context(Ctxt),
    ok.


%% -----------------------------------------------------------------------------
%% @doc Returns the context identifier.
%% @end
%% -----------------------------------------------------------------------------
-spec id(t()) -> id().

id(#{id := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the peer of the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec peer(t()) -> bondy_session:peer().
peer(#{peer := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the peer of the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec peername(t()) -> binary().

peername(#{peer := Val}) ->
    inet_utils:peername_to_binary(Val).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the peer of the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec node(t()) -> atom().

node(#{session := Session}) ->
    bondy_session:node(Session);

node(#{node := Val}) -> Val.



%% -----------------------------------------------------------------------------
%% @doc
%% Set the peer to the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec set_peer(t(), bondy_session:peer()) -> t().
set_peer(Ctxt, {{_, _, _, _}, _Port} = Peer) when is_map(Ctxt) ->
    Ctxt#{peer => Peer}.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the subprotocol of the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec subprotocol(t()) -> subprotocol_2().
subprotocol(#{subprotocol := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the encoding used by the peer of the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec encoding(t()) -> encoding().
encoding(#{subprotocol := {_, _, Val}}) -> Val.



%% -----------------------------------------------------------------------------
%% @doc
%% Set the peer to the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec set_subprotocol(t(), subprotocol_2()) -> t().
set_subprotocol(Ctxt, {_, _, _} = S) when is_map(Ctxt) ->
    Ctxt#{subprotocol => S}.


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
-spec realm_uri(t()) -> maybe(uri()).
realm_uri(#{session := S}) ->
    bondy_session:realm_uri(S);

realm_uri(#{realm_uri := Val}) ->
    Val;

realm_uri(_) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% Sets the realm uri of the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec set_realm_uri(t(), uri()) -> t().
set_realm_uri(Ctxt, Uri) ->
    Ctxt#{realm_uri => Uri}.


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
%% @end
%% -----------------------------------------------------------------------------
-spec is_security_enabled(t()) -> boolean().

is_security_enabled(#{session := Session}) when Session =/= undefined ->
    bondy_session:is_security_enabled(Session);

is_security_enabled(#{security_enabled := Val}) when is_boolean(Val) ->
    Val;

is_security_enabled(#{realm_uri := Uri}) ->
    bondy_realm:is_security_enabled(Uri).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authid(t()) -> binary() | anonymous | undefined.

authid(#{authid := Val}) ->
    Val;

authid(#{session := Session}) ->
    bondy_session:authid(Session);

authid(#{}) ->
    undefined.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authrole(t()) -> binary() | anonymous | undefined.

authrole(#{authrole := Val}) ->
    Val;

authrole(#{session := Session}) ->
    bondy_session:authrole(Session);

authrole(#{}) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authroles(t()) -> [binary()].

authroles(#{authroles := Val}) ->
    Val;

authroles(#{session := Session}) ->
    bondy_session:authroles(Session);

authroles(#{}) ->
    [].


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec set_authid(t(), binary()) -> t().

set_authid(Ctxt, Val)
when is_map(Ctxt) andalso (is_binary(Val) orelse Val == anonymous) ->
    maps:put(authid, Val, Ctxt).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the sessionId of the provided context or 'undefined'
%% if there is none.
%% @end
%% -----------------------------------------------------------------------------
-spec session_id(t()) -> id() | undefined.
session_id(#{session := S}) ->
    bondy_session:id(S);

session_id(#{session_id := Val}) ->
    %% TODO remove this once we force everyone to have sessions
    Val;

session_id(#{}) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the sessionId of the provided context or 'undefined'
%% if there is none.
%% @end
%% -----------------------------------------------------------------------------
-spec rbac_context(t()) -> bondy_rbac:context() | undefined.

rbac_context(#{session := S}) ->
    bondy_session:rbac_context(S);

rbac_context(#{}) ->
    undefined.



%% -----------------------------------------------------------------------------
%% @doc Returns an ID based on scope. If context does not have a session the
%% global sceop is used.
%% @end
%% -----------------------------------------------------------------------------
-spec get_id(Ctxt :: t(), Scope :: global | router | session) -> id().

get_id(_, global) ->
    bondy_utils:get_id(global);

get_id(#{realm_uri := Uri}, router) ->
    bondy_utils:get_id({router, Uri});

get_id(#{session := Session}, session) ->
    Id = bondy_session:id(Session),
    bondy_utils:get_id({session, Id});

get_id(_, session) ->
    bondy_utils:get_id(global).




%% -----------------------------------------------------------------------------
%% @doc
%% Returns true if the context is associated with a session,
%% false otherwise.
%% @end
%% -----------------------------------------------------------------------------
-spec has_session(t()) -> boolean().

has_session(#{session := _}) -> true;
has_session(#{}) -> false.


%% -----------------------------------------------------------------------------
%% @doc
%% Sets the sessionId to the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec set_session(t(), bondy_session:t()) -> t().
set_session(Ctxt, S) ->
    Ctxt#{session => S}.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec ref(t()) -> bondy_ref:t().

ref(#{session := S}) ->
    bondy_session:ref(S);

ref(#{ref := Ref}) ->
    Ref.


%% -----------------------------------------------------------------------------
%% @doc
%% Fetches and returns the bondy_session for the associated sessionId.
%% @end
%% -----------------------------------------------------------------------------
-spec session(t()) -> bondy_session:t() | no_return().
session(#{session := S}) ->
    S.


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
%% Sets the current request details to the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec set_request_details(t(), map()) -> t().

set_request_details(Ctxt, Details) when is_map(Details) ->
    Ctxt#{request_details => Details}.


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
%% Returns the current request details
%% @end
%% -----------------------------------------------------------------------------
-spec request_details(t()) -> map().
request_details(#{request_details := Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the current WAMP call timeout.
%% @end
%% -----------------------------------------------------------------------------
-spec call_timeout(t()) -> non_neg_integer().

call_timeout(#{call_timeout := Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Sets the current WAMP call timeout to the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec set_call_timeout(t(), non_neg_integer()) -> t().

set_call_timeout(Ctxt, Timeout) when is_integer(Timeout), Timeout >= 0 ->
    Ctxt#{call_timeout => Timeout}.


%% -----------------------------------------------------------------------------
%% @doc Returns a copy of `Details` where the disclose_caller feature
%% properties have been added from context `Ctxt'.
%% @end
%% -----------------------------------------------------------------------------
-spec caller_details(Ctxt :: t(), Details :: map()) -> map().

caller_details(Ctxt, Details) ->
    Details#{
        caller => session_id(Ctxt),
        caller_authid => authid(Ctxt),
        caller_authrole => authrole(Ctxt),
        caller_authroles => authroles(Ctxt),
        x_caller_node => ?MODULE:node(Ctxt)
    }.


%% -----------------------------------------------------------------------------
%% @doc Returns a copy of `Details` where the disclose_publisher feature
%% properties have been added from context `Ctxt'.
%% @end
%% -----------------------------------------------------------------------------
-spec publisher_details(Ctxt :: t(), Details :: map()) -> map().

publisher_details(Ctxt, Details) ->
    Details#{
        publisher => session_id(Ctxt),
        publisher_authid => authid(Ctxt),
        publisher_authrole => authrole(Ctxt),
        publisher_authroles => authroles(Ctxt),
        x_publisher_node => ?MODULE:node(Ctxt)
    }.

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

%% -----------------------------------------------------------------------------
%% @doc
%% Returns true if the user is anonymous. In that case authid would be a random
%% identifier assigned by Bondy.
%% @end
%% -----------------------------------------------------------------------------
-spec is_anonymous(t()) -> boolean().

is_anonymous(Ctxt) ->
    maps:get(is_anonymous, Ctxt, false).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec set_is_anonymous(t(), boolean()) -> t().

set_is_anonymous(Ctxt, Value) when is_boolean(Value) ->
    Ctxt#{is_anonymous => Value}.

