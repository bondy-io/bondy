%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mcp_http_auth).

-moduledoc """
Authentication for the modern per-request edge (design §6): the realm's
configured methods decide what the `Authorization` header may carry — a
Bearer JWT (OAuth2), a Bearer Bondy ticket, or Basic — and an absent
header falls through to the anonymous principal when the realm admits
one.

Split out of `bondy_mcp_http_handler` for cohesion: this is the one layer
of the edge that decides identity, it is shared verbatim by both eras and
by all five call sites, and it needs none of the handler's HTTP
orchestration.

`authenticate/2` returns `#{authid, authroles, is_anonymous}` or THROWS
`{unauthorized, Reason, Req}` with NOTHING started — no process, no
stored session, no auth state outlives the throw. The handler turns that
throw into a `401` with `WWW-Authenticate`.
""".

-include_lib("bondy_router/include/bondy_security.hrl").

-export([authenticate/2]).

%% =============================================================================
%% API — establishing the principal
%% =============================================================================

-doc """
Authenticates an MCP request against `RealmUri` and returns the principal as
`#{authid, authroles, is_anonymous}`.

The realm decides what is accepted. With security disabled the request is
anonymous with a generated `authid`. With security enabled the
`Authorization` header selects the method: `Bearer` is an OAuth2 JWT when it
carries a `sub` claim and a Bondy ticket otherwise, `Basic` is password
authentication, and an absent header is the anonymous principal — which
succeeds only where the realm admits `anonymous`.

Throws `{unauthorized, Reason, Req}` on every failure, with nothing started:
no process, no stored session, and no authentication state outlives the throw.
The caller turns that into a `401` carrying `WWW-Authenticate`.
""".
-spec authenticate(Req :: cowboy_req:req(), RealmUri :: binary()) ->
    #{
        authid := binary(),
        authroles := [binary()],
        is_anonymous := boolean()
    }.

authenticate(Req, RealmUri) ->
    case bondy_realm:is_security_enabled(RealmUri) of
        false ->
            #{
                authid => bondy_utils:uuid(),
                authroles => [],
                is_anonymous => true
            };
        true ->
            SourceIP = source_ip(Req),
            case cowboy_req:parse_header(<<"authorization">>, Req) of
                {bearer, Token} ->
                    bearer(Token, RealmUri, SourceIP, Req);
                {basic, Username, Password} ->
                    credential(
                        RealmUri,
                        Username,
                        ?PASSWORD_AUTH,
                        Password,
                        SourceIP,
                        Req
                    );
                undefined ->
                    anonymous(RealmUri, SourceIP, Req);
                _ ->
                    throw({unauthorized, invalid_authorization_header, Req})
            end
    end.

%% @private
%% A Bearer credential is a JWT (OAuth2) or a Bondy ticket, decided by
%% the claims: `bondy_oauth_jwt:decode/1` is an unverified `peek` and
%% decodes ANY compact JWS — a Bondy ticket included — so "does it
%% decode" cannot be the dispatch. An OAuth2 JWT carries `sub`; anything
%% else (a ticket's claims carry `authid`, not `sub`; garbage peeks to
%% nothing) goes to ticket verification, which is what actually
%% validates it. The previous shape threw `invalid_token` for every
%% Bondy ticket — measured by
%% `bondy_mcp_modern_SUITE:delegated_ticket_caps_the_projection`, the
%% first thing to exercise this path.
bearer(Token, RealmUri, SourceIP, Req) ->
    Peeked =
        try bondy_oauth_jwt:decode(Token) of
            Map when is_map(Map) -> Map
        catch
            _:_ -> undefined
        end,
    case Peeked of
        #{<<"sub">> := Sub} ->
            credential(RealmUri, Sub, ?OAUTH2_AUTH, Token, SourceIP, Req);
        _ ->
            case bondy_ticket:verify(Token) of
                {ok, #{authid := Authid}} ->
                    credential(
                        RealmUri,
                        Authid,
                        ?WAMP_TICKET_AUTH,
                        Token,
                        SourceIP,
                        Req
                    );
                {error, _} ->
                    throw({unauthorized, invalid_token, Req})
            end
    end.

%% @private
anonymous(RealmUri, SourceIP, Req) ->
    SessionId = bondy_session_id:new(),
    case
        bondy_auth:init(
            SessionId, RealmUri, anonymous, [<<"anonymous">>], SourceIP
        )
    of
        {ok, Ctxt} ->
            case bondy_auth:authenticate(?WAMP_ANON_AUTH, <<>>, #{}, Ctxt) of
                {ok, _, _} ->
                    #{
                        authid => bondy_utils:uuid(),
                        authroles => [<<"anonymous">>],
                        is_anonymous => true
                    };
                {error, Reason} ->
                    throw({unauthorized, Reason, Req})
            end;
        {error, Reason} ->
            throw({unauthorized, Reason, Req})
    end.

%% @private
credential(RealmUri, UserId, Method, Credential, SourceIP, Req) ->
    SessionId = bondy_session_id:new(),
    case bondy_auth:init(SessionId, RealmUri, UserId, all, SourceIP) of
        {ok, Ctxt} ->
            case bondy_auth:authenticate(Method, Credential, #{}, Ctxt) of
                {ok, _, Ctxt1} ->
                    #{
                        authid => UserId,
                        authroles => bondy_auth:roles(Ctxt1),
                        is_anonymous => false
                    };
                {error, Reason} ->
                    throw({unauthorized, Reason, Req})
            end;
        {error, Reason} ->
            throw({unauthorized, Reason, Req})
    end.

%% @private
source_ip(Req) ->
    {IP, _} = cowboy_req:peer(Req),
    IP.
