%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%% A Juno Context lets you access information that define the context of an
%% interaction. In a typical interacion, several actors or objects have a hand
%% in what is going on e.g. juno_session, wamp_realm, etc.
%%
%% The Juno Context is passed as an argument through the whole request-response
%%  loop to provide access to that information.
%% @end
%% =============================================================================
-module(juno_context).
-include_lib("wamp/include/wamp.hrl").


-type context()       ::  #{
    goodbye_initiated => boolean(),
    realm_uri => uri(),
    request_id => id(),
    request_timeout => non_neg_integer(),
    roles => map(),
    session_id => id(),
    peer => juno_session:peer()
}.
-export_type([context/0]).

-export([is_feature_enabled/3]).
-export([new/0]).
-export([peer/1]).
-export([request_id/1]).
-export([request_timeout/1]).
-export([reset/1]).
-export([roles/1]).
-export([session_id/1]).
-export([session/1]).
-export([set_peer/2]).
-export([set_request_id/2]).
-export([set_request_timeout/2]).
-export([set_roles/2]).
-export([set_session_id/2]).


%% -----------------------------------------------------------------------------
%% @doc
%% Initialises a new context object.
%% @end
%% -----------------------------------------------------------------------------
-spec new() -> context().
new() ->
    Ctxt = #{
        goodbye_initiated => false,
        request_id => undefined,
        request_timeout => juno_config:request_timeout()
    },
    set_roles(Ctxt, #{}).


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
%% Returns the peer of the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec peer(context()) -> juno_session:peer().
peer(#{peer := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Sets the roles to the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec set_peer(context(), juno_session:peer()) -> context().
set_peer(Ctxt, Peer) when is_map(Ctxt) ->
    Ctxt#{peer => Peer}.


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
%% Returns the sessionId of the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec session_id(context()) -> id().
session_id(#{session_id := S}) -> S.


%% -----------------------------------------------------------------------------
%% @doc
%% Sets the sessionId to the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec set_session_id(context(), id()) -> context().
set_session_id(Ctxt, SessionId) ->
    Ctxt#{session_id => SessionId}.


%% -----------------------------------------------------------------------------
%% @doc
%% Fetches and returns the juno_session for the associated sessionId.
%% @end
%% -----------------------------------------------------------------------------
-spec session(context()) -> juno_session:session().
session(#{session_id := SessionId}) ->
    juno_session:fetch(SessionId).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the current request id
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
-spec is_feature_enabled(context(), atom(), atom()) -> boolean().
is_feature_enabled(#{roles := Roles}, Role, Feature) ->
    maps:get(Feature, maps:get(Role, Roles, #{}), false).
