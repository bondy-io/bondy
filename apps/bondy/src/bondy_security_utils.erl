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

-type auth_scheme()                 ::  basic | bearer | digest | hmac.
-type auth_scheme_val()             ::  {hmac, binary(), binary(), binary()}
                                        | {basic, binary(), binary()}
                                        | {bearer, binary()}
                                        | {digest, [{binary(), binary()}]}.


-export([authenticate/4]).
-export([authenticate_anonymous/2]).
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
    {ok, bondy_security:context() | map()}
    | {error, auth_error_reason()}.

authenticate(hmac, {hmac, AuthId, Sign, Sign}, Realm, Peer) ->
    PW = bondy_security_user:password(Realm, AuthId),
    HashedPass = maps:get(hash_pass, PW),
    ConnInfo = conn_info(Peer),
    bondy_security:authenticate(Realm, AuthId, {hash, HashedPass}, ConnInfo);

authenticate(hmac, {hmac, _, _, _}, _, _) ->
    %% Signatures do not match
    {error, bad_password};

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
%% @doc
%% @end
%% -----------------------------------------------------------------------------
authenticate_anonymous(Realm, Peer) ->
    bondy_security:authenticate_anonymous(Realm, conn_info(Peer)).



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
    maybe_authorize(Permission, Resource, Ctxt, IsEnabled).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
maybe_authorize(Permission, Resource, Ctxt, true) ->
    do_authorize(Permission, Resource, get_security_context(Ctxt));

maybe_authorize(_, _, _, false) ->
    ok.


%% @private
get_security_context(Ctxt) ->
    case bondy_context:is_anonymous(Ctxt) of
        true ->
            get_anonymous_context(Ctxt);
        false ->
            AuthId = bondy_context:authid(Ctxt),
            RealmUri = bondy_context:realm_uri(Ctxt),
            bondy_security:get_context(RealmUri, AuthId)
    end.


%% @private
get_anonymous_context(Ctxt) ->
    case bondy_config:get(allow_anonymous_user, true) of
        true ->
            AuthId = bondy_context:authid(Ctxt),
            RealmUri = bondy_context:realm_uri(Ctxt),
            bondy_security:get_anonymous_context(RealmUri, AuthId);
        false ->
            error({not_authorized, <<"Anonymous user not allowed.">>})
    end.


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

