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
    auth_method => binary(),
    goodbye_initiated => boolean(),
    peer => juno_session:peer(),
    realm_uri => uri(),
    request_id => id(),
    request_timeout => non_neg_integer(),
    roles => map(),
    session_id => id() | undefined,
    id => id(),
    request_details => map(),
    challenge_sent => boolean(),
    authmethod => binary(),
    authid => binary(),
    awaiting_call_ids => sets:set(),
    rate_limit_window => pos_integer(),       % duration of rate limit window in secs
    rate_limit => pos_integer(),         % max number of messages allowed during window 
    rate_limit_remaining => pos_integer(), % # of messages remaining in window
    rate_limit_resets => pos_integer()      % time when the quota resets in secs
}.
-export_type([context/0]).

-export([add_awaiting_call_id/2]).
-export([awaiting_call_ids/1]).
-export([close/1]).
-export([is_feature_enabled/3]).
-export([new/0]).
-export([peer/1]).
-export([realm_uri/1]).
-export([remove_awaiting_call_id/2]).
-export([request_id/1]).
-export([request_timeout/1]).
-export([reset/1]).
-export([roles/1]).
-export([session/1]).
-export([session_id/1]).
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
        id => wamp_id:new(global),
        goodbye_initiated => false,
        request_id => undefined,
        request_timeout => juno_config:request_timeout(),
        awaiting_call_ids => sets:new()
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
%% @end
%% -----------------------------------------------------------------------------
-spec close(context()) -> ok.

close(#{session_id := SessionId} = Ctxt) ->
    %% We close the session
    case juno_session:lookup(SessionId) of
        not_found ->
            ok;
        Session ->
            juno_session:close(Session)
    end,
    close(maps:without([session_id], Ctxt));

close(Ctxt0) ->
    %% We cleanup session and router data for this Ctxt
    _Ctxt1 = juno_router:close_context(Ctxt0),
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the peer of the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec peer(context()) -> juno_session:peer().
peer(#{peer := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Set the peer to the provided context.
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
%% Returns the realm uri of the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec realm_uri(context()) -> uri().
realm_uri(#{realm_uri := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the sessionId of the provided context.
%% @end
%% -----------------------------------------------------------------------------
-spec session_id(context()) -> id() | undefined.
session_id(#{session_id := S}) -> S;
session_id(#{}) -> undefined.


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
-spec session(context()) -> juno_session:session() | no_return().
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


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec awaiting_call_ids(context()) -> [id()].
awaiting_call_ids(#{awaiting_call_ids := S}) ->
    sets:to_list(S).




%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add_awaiting_call_id(context(), id()) -> ok.
add_awaiting_call_id(#{awaiting_call_ids := S} = C, Id) ->
    C#{awaiting_call_ids => sets:add_element(Id, S)}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove_awaiting_call_id(context(), id()) -> ok.
remove_awaiting_call_id(#{awaiting_call_ids := S} = C, Id) ->
    C#{awaiting_call_ids => sets:del_element(Id, S)}.