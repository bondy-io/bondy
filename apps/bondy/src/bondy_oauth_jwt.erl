%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2025 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oauth_jwt).

-include_lib("kernel/include/logger.hrl").

-define(NOW, erlang:system_time(second)).
-define(LEEWAY_SECS, 2 * 60). % 2 mins
-define(EXPIRY_TIME_SECS(Ts, Secs), Ts + Secs + ?LEEWAY_SECS).

-type claims() :: map().
-type error()  :: oauth2_invalid_grant | any().

-export([encode/2]).
-export([decode/1]).
-export([verify/2]).
-export([verify/3]).




%% =============================================================================
%% API
%% =============================================================================


-spec encode(claims(), PrivKey :: binary()) -> binary().

encode(Claims, PrivKey) ->
    {_, JWT} = jose_jws:compact(jose_jwt:sign(PrivKey, Claims)),
    JWT.


-spec decode(binary()) -> claims().

decode(JWT) when is_binary(JWT) andalso byte_size(JWT) >= 32 ->
    {jose_jwt, Map} = jose_jwt:peek(JWT),
    Map;

decode(Term) ->
    error({badarg, [Term]}).



-spec verify(binary(), binary()) -> {ok, map()} | {error, error()}.

verify(RealmUri, JWT) ->
    verify(RealmUri, JWT, #{}).


-spec verify(RealmUri :: binary(), JWT :: binary(), MatchSpec :: map()) ->
    {ok, claims()} | {error, error()}.

verify(RealmUri, JWT, MatchSpec) ->
    maybe_expired(do_verify(RealmUri, JWT, MatchSpec), JWT).



%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
authscope(RealmUri, Claims) ->
    case maps:get(~"auth", Claims, undefined) of
        undefined ->
            %% V1 token
            DeviceId = key_value:get(
                [~"meta", ~"client_device_id"], Claims, all
            ),
            bondy_auth_scope:new(RealmUri, all, DeviceId);

        Auth ->
            %% V1.1 Token
            Scope = key_value:get(~"scope", Auth, #{}),
            ScopeRealm = maps:get(~"realm", Scope, RealmUri),
            ClientId = maps:get(~"client_id", Scope, all),
            DeviceId = maps:get(~"device_id", Scope, all),
            bondy_auth_scope:new(ScopeRealm, ClientId, DeviceId)
    end.


%% @private
matches(RealmUri, Claims, Spec) ->
    TokenScope = authscope(RealmUri, Claims),
    Keys = maps:keys(Spec),

    maybe
        %% TODO we should verify Client and Device if provided
        true ?= bondy_auth_scope:matches_realm(TokenScope, RealmUri),
        true ?=
            maps_utils:collect(Keys, Claims) =:=
            maps_utils:collect(Keys, Spec),
        {ok, Claims}

    else
        false ->
            {error, oauth2_invalid_grant}
    end.



%% @private
-spec do_verify(Realm :: binary(), binary(), map()) ->
    {ok, map()} | {error, error()}.

do_verify(RealmUri, JWT, Spec) ->
    try
        {jose_jwt, Claims} = jose_jwt:peek(JWT),
        #{
            ~"aud" := AuthRealmUri,
            ~"kid" := Kid
        } = Claims,

        AuthRealm = bondy_realm:fetch(AuthRealmUri),

        %% Finally we try to verify the JWT
        case bondy_realm:get_public_key(AuthRealm, Kid) of
            undefined ->
                {error, oauth2_invalid_grant};

            JWK ->
                case jose_jwt:verify(JWK, JWT) of
                    {true, {jose_jwt, Claims}, _} ->
                        matches(RealmUri, Claims, Spec);

                    {false, {jose_jwt, _Claims}, _} ->
                        {error, oauth2_invalid_grant}
                end
        end
    catch
        throw:Reason ->
            {error, Reason};

        error:{not_found, Uri} ->
            {error, {no_such_realm, Uri}};

        error:{no_such_realm, _} = Reason ->
            {error, Reason};

        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {error, internal_error}
    end.


%% @private
maybe_expired({ok, #{<<"iat">> := Ts, <<"exp">> := Secs} = Claims}, _JWT) ->
    case ?EXPIRY_TIME_SECS(Ts, Secs) =< ?NOW of
        true ->
            {error, oauth2_invalid_grant};

        false ->
            {ok, Claims}
    end;

maybe_expired(Error, _) ->
    Error.