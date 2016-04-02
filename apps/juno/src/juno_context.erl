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
    session_id => id(),
    realm_uri => uri(),
    subprotocol => subprotocol(),
    goodbye_initiated => false
}.
-export_type([context/0]).

-export([new/0]).
-export([session_id/1]).
-export([session/1]).
-export([set_session_id/2]).


%% -----------------------------------------------------------------------------
%% @doc
%% Initialises a new context object.
%% @end
%% -----------------------------------------------------------------------------
-spec new() -> context().
new() ->
    #{}.


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
