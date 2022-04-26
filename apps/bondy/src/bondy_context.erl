
%% =============================================================================
%%  bondy_context.erl -
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
    realm_uri => uri(),
    session_id => maybe(bondy_session_id:t()),
    session => maybe(bondy_session:t()),
    security_enabled => boolean(),
    %% Peer Info
    peer => bondy_session:peer(),
    authmethod => binary(),
    authid => binary(),
    is_anonymous => boolean(),
    roles => map(),
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
-export([features/2]).
-export([features/3]).
-export([gen_message_id/2]).
-export([has_session/1]).
-export([is_anonymous/1]).
-export([is_feature_enabled/3]).
-export([is_security_enabled/1]).
-export([local_context/1]).
-export([local_context/2]).
-export([new/0]).
-export([new/2]).
-export([peer/1]).
-export([peername/1]).
-export([publisher_details/2]).
-export([rbac_context/1]).
-export([realm_uri/1]).
-export([ref/1]).
-export([request_details/1]).
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
        session_id => bondy_session_id:new(),
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
        security_enabled => bondy_realm:is_security_enabled(RealmUri),
        authid => '$internal'
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
local_context(RealmUri, Ref) when is_binary(RealmUri) ->
    Ctxt0 = local_context(RealmUri),

    Ctxt1 = Ctxt0#{
        ref => Ref
    },

    case bondy_ref:session_id(Ref) of
        undefined ->
            Ctxt1;
        SessionId ->
            Ctxt1#{session_id => SessionId}
    end.




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
%% have been reset: request_details.
%% @end
%% -----------------------------------------------------------------------------
-spec reset(t()) -> t().
reset(Ctxt) ->
    Ctxt#{request_details => undefined}.


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
    try bondy_context:ref(Ctxt) of
        Ref ->
            RealmUri = bondy_context:realm_uri(Ctxt),
            ok = bondy_router:flush(RealmUri, Ref)
    catch
        _:_ ->
            ok
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the sessionId of the provided context or 'undefined'
%% if there is none.
%% @end
%% -----------------------------------------------------------------------------
-spec session_id(t()) -> maybe(id()).

session_id(#{session := S}) ->
    bondy_session:id(S);

session_id(#{session_id := Val}) ->
    Val;

session_id(#{ref := Ref}) ->
    bondy_ref:session_id(Ref);

session_id(_) ->
    undefined.


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
%% @doc Returns the features that the session's owner supports for role `Role'.
%% @end
%% -----------------------------------------------------------------------------
-spec features(t(), bondy_session:peer_role()) -> map().

features(Ctxt, Role) ->
    bondy_session:features(session(Ctxt), Role).


%% -----------------------------------------------------------------------------
%% @doc Returns those features in list `With' that the session's owner supports
%% for role `Role'.
%% @end
%% -----------------------------------------------------------------------------
-spec features(t(), bondy_session:peer_role(), With :: [atom()]) -> map().

features(Ctxt, Role, With) ->
    bondy_session:features(session(Ctxt), Role, With).


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
-spec gen_message_id(Ctxt :: t(), Scope :: global | router | session) -> id().

gen_message_id(_, global) ->
    bondy_utils:gen_message_id(global);

gen_message_id(#{realm_uri := Uri}, router) ->
    bondy_utils:gen_message_id({router, Uri});

gen_message_id(#{session := Session}, session) ->
    bondy_session:gen_message_id(Session);

gen_message_id(_, session) ->
    %% Internal process without sessions
    bondy_utils:gen_message_id(global).


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
    maps:remove(session_id, Ctxt#{session => S}).


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
%% Returns the current request details
%% @end
%% -----------------------------------------------------------------------------
-spec request_details(t()) -> map().
request_details(#{request_details := Val}) ->
    Val.


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

caller_details(#{authid := '$internal'}, Details) ->
    Details;

caller_details(#{session := Session} = Ctxt, Details) ->

    Details#{
        caller => bondy_session:external_id(Session),
        caller_authid => name_to_binary(authid(Ctxt)),
        caller_authrole => authrole(Ctxt),
        x_caller_guid => bondy_session:id(Session)
    }.


%% -----------------------------------------------------------------------------
%% @doc Returns a copy of `Details` where the disclose_publisher feature
%% properties have been added from context `Ctxt'.
%% @end
%% -----------------------------------------------------------------------------
-spec publisher_details(Ctxt :: t(), Details :: map()) -> map().

publisher_details(#{authid := '$internal'}, Details) ->
    Details;

publisher_details(#{session := Session} = Ctxt, Details) ->
    Details#{
        publisher => bondy_session:external_id(Session),
        publisher_authid => name_to_binary(authid(Ctxt)),
        publisher_authrole => authrole(Ctxt),
        x_publisher_guid => bondy_session:id(Session)
    }.


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



%% =============================================================================
%%  PRIVATE
%% =============================================================================



name_to_binary(undefined) ->
    <<"undefined">>;

name_to_binary(anonymous) ->
    <<"anonymous">>;

name_to_binary(Term) when is_binary(Term) ->
    Term.