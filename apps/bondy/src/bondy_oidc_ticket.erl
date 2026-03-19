%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================


-module(bondy_oidc_ticket).
-moduledoc """
Helper module for minting OIDC-specific tickets.

This exists as a separate module from `bondy_ticket` because the standard
`bondy_ticket:issue/2` requires an active `bondy_session`. During the OIDC
callback, there is no WAMP session yet — the user has just authenticated at
the Identity Provider and we need to mint a ticket for them to use when
establishing a WAMP session.

Uses the same signing and storage internals as `bondy_ticket`.
""".

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_security.hrl").

-define(NOW, erlang:system_time(second)).


%% API
-export([issue/5]).



%% =============================================================================
%% API
%% =============================================================================



-doc """
Issues a ticket for a user authenticated via OIDC.

Builds claims with standard `bondy_ticket` fields plus OIDC extensions,
signs with the realm's private key, and stores in PlumDB.
""".
-spec issue(
    RealmUri :: uri(),
    Authid :: binary(),
    OidcProvider :: binary(),
    OidcTokens :: map(),
    Opts :: map()
) -> {ok, JWT :: binary(), Claims :: bondy_ticket:t()} | {error, term()}.

issue(RealmUri, Authid, OidcProvider, OidcTokens, Opts)
when is_binary(RealmUri) andalso is_binary(Authid)
andalso is_binary(OidcProvider) andalso is_map(OidcTokens)
andalso is_map(Opts) ->
    try
        Realm = bondy_realm:fetch(RealmUri),
        Kid = bondy_realm:get_random_kid(Realm),

        IssuedAt = ?NOW,
        ExpirySecs = maps:get(
            expiry_time_secs, Opts,
            bondy_config:get([security, ticket, expiry_time_secs])
        ),
        ExpiresAt = IssuedAt + ExpirySecs,

        ScopeOpts = maps:get(scope, Opts, #{}),
        Scope = #{
            realm => RealmUri,
            client_id => maps:get(client_id, ScopeOpts, <<"all">>),
            device_id => maps:get(device_id, ScopeOpts, <<"all">>)
        },

        %% Extract OIDC token fields
        IdToken = maps:get(id_token, OidcTokens, undefined),
        RefreshToken = maps:get(refresh_token, OidcTokens, undefined),
        AccessTokenExpiresAt = maps:get(
            access_token_expires_at, OidcTokens, undefined
        ),
        Authroles = maps:get(authroles, Opts, []),

        Claims0 = #{
            id => bondy_utils:uuid(),
            authrealm => RealmUri,
            authid => Authid,
            authmethod => ?OIDCRP_AUTH,
            authroles => Authroles,
            issued_by => Authid,
            issued_on => atom_to_binary(bondy_config:node(), utf8),
            issued_at => IssuedAt,
            expires_at => ExpiresAt,
            scope => Scope,
            kid => Kid,
            oidc_provider => OidcProvider
        },

        %% Add optional OIDC fields
        Claims1 = case IdToken of
            undefined -> Claims0;
            _ -> Claims0#{oidc_id_token => IdToken}
        end,

        Claims2 = case RefreshToken of
            undefined -> Claims1;
            _ -> Claims1#{oidc_refresh_token => RefreshToken}
        end,

        Claims = case AccessTokenExpiresAt of
            undefined -> Claims2;
            _ -> Claims2#{oidc_access_token_expires_at => AccessTokenExpiresAt}
        end,

        JWT = jose_jwt:from(Claims),

        PrivKey = bondy_realm:get_private_key(Realm, Kid),
        {_, Ticket} = jose_jws:compact(jose_jwt:sign(PrivKey, JWT)),

        ok = bondy_ticket:store_ticket(RealmUri, Authid, Claims),

        {ok, Ticket, Claims}

    catch
        throw:Reason ->
            {error, Reason};
        error:Reason ->
            {error, Reason}
    end.
