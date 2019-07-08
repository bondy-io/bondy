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



%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
conn_info({IP, _Port}) ->
    [{ip, IP}].
