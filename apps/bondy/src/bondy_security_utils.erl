%% =============================================================================
%%  bondy_security_utils.erl -
%%
%%  Copyright (c) 2016-2019 Ngineo Limited t/a Leapsight. All rights reserved.
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
-module(bondy_security_utils).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").

-type auth_error_reason()           ::  bondy_oauth2:error()
                                        | invalid_scheme
                                        | no_such_realm.

-type auth_scheme()                 ::  wampcra | basic | bearer | digest.
-type auth_scheme_val()             ::  {wampcra, binary(), binary(), map()}
                                        | {basic, binary(), binary()}
                                        | {bearer, binary()}
                                        | {digest, [{binary(), binary()}]}.


-export([authenticate/4]).
-export([authorize/3]).


%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authenticate(
    auth_scheme(), auth_scheme_val(), uri(), bondy_session:peer()) ->
    {ok, bondy_security:context() | map()} | {error, auth_error_reason()}.

authenticate(?TICKET_AUTH, {?TICKET_AUTH, AuthId, Signature}, Realm, Peer) ->
    authenticate(basic, {basic, AuthId, Signature}, Realm, Peer);

authenticate(?WAMPCRA_AUTH, {?WAMPCRA_AUTH, AuthId, Signature}, Realm, Peer) ->
    bondy_security:authenticate(
        Realm, AuthId, {hash, Signature}, conn_info(Peer));

authenticate(bearer, {bearer, Token}, Realm, _Peer) ->
    bondy_oauth2:verify_jwt(Realm, Token);

authenticate(basic, {basic, Username, Pass}, Realm, Peer) ->
    bondy_security:authenticate(
        Realm, Username, Pass, conn_info(Peer));

authenticate(digest, {digest, _List}, _Realm, _Peer) ->
    %% TODO support
    {error, invalid_scheme};

authenticate(_, undefined, _Realm, _Peer) ->
    {error, invalid_scheme};

authenticate(_, _Scheme, _Realm, _Peer) ->
    {error, invalid_scheme}.




%% -----------------------------------------------------------------------------
%% @doc Returns 'ok' or an exception.
%% @end
%% -----------------------------------------------------------------------------
-spec authorize(binary(), binary(), bondy_context:t()) ->
    ok | no_return().

authorize(Permission, Resource, Ctxt) ->
    %% We could be cashing the security ctxt,
    %% the data is in ets so it should be pretty fast.
    RealmUri = bondy_context:realm_uri(Ctxt),
    IsEnabled = bondy_realm:is_security_enabled(RealmUri),
    maybe_authorize(IsEnabled, Permission, Resource, Ctxt).



%% =============================================================================
%% PRIVATE
%% =============================================================================



maybe_authorize(true, Permission, Resource, Ctxt) ->
    case bondy_context:authid(Ctxt) of
        undefined ->
            error({not_authorized, <<"Not authenticated.">>});
        Username ->
            RealmUri = bondy_context:realm_uri(Ctxt),
            SecCtxt = bondy_security:get_context(RealmUri, Username),
            do_authorize(Permission, Resource, SecCtxt)
    end;

maybe_authorize(false, _, _, _) ->
    ok.


%% @private
do_authorize(Permission, Resource, SecCtxt) ->
    case bondy_security:check_permission({Permission, Resource}, SecCtxt) of
        {true, _SecCtxt1} ->
            ok;
        {false, Mssg, _SecCtxt1} ->
            error({not_authorized, Mssg})
    end.


%% @private
conn_info({IP, _Port}) ->
    [{ip, IP}].

