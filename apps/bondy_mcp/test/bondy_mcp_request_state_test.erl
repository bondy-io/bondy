%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Falsifiers for the §11.1 `requestState` envelope's pure core. The spec's
%% MUSTs are the targets: state failing verification is rejected, and the
%% principal, expiry and originating-request identity bound inside the
%% AEAD-protected payload are each verified on receipt. Every rejection is
%% the uniform `{error, invalid}` — these tests also pin the two distinct
%% failure shapes of the underlying jose decrypt (a tampered ciphertext
%% RETURNS an error tuple, a wrong key RAISES) landing in that one answer.
%%
%% Keys are exercised in the `jose_jwk:to_map/1` form — the exact shape
%% `bondy_realm:get_random_encryption_key/1` hands the realm-facing
%% wrappers.
-module(bondy_mcp_request_state_test).

-include_lib("eunit/include/eunit.hrl").

-define(MAX, 65536).

request_state_test_() ->
    {setup, fun keys/0, fun(_) -> ok end, fun(Keys) ->
        [
            fun() -> roundtrip(Keys) end,
            fun() -> principal_mismatch(Keys) end,
            fun() -> method_mismatch(Keys) end,
            fun() -> name_mismatch(Keys) end,
            fun() -> args_mismatch(Keys) end,
            fun() -> expired(Keys) end,
            fun() -> tampered(Keys) end,
            fun() -> wrong_key(Keys) end,
            fun() -> unknown_kid(Keys) end,
            fun() -> garbage(Keys) end,
            fun() -> oversize_inbound(Keys) end,
            fun() -> oversize_seal(Keys) end
        ]
    end}.

keys() ->
    JWK = jose_jwk:to_map(jose_jwk:generate_key({rsa, 2048, 65537})),
    Other = jose_jwk:to_map(jose_jwk:generate_key({rsa, 2048, 65537})),
    #{kid => <<"kid-1">>, jwk => JWK, other => Other}.

payload(Exp) ->
    #{
        continuation => <<"cont-1">>,
        principal => <<"alice">>,
        method => <<"tools/call">>,
        name => <<"tool_a">>,
        args_hash => bondy_mcp_request_state:args_hash(#{<<"x">> => 1}),
        exp => Exp,
        state => #{<<"step">> => 1, <<"note">> => <<"tomato">>}
    }.

expect() ->
    #{
        principal => <<"alice">>,
        method => <<"tools/call">>,
        name => <<"tool_a">>,
        args_hash => bondy_mcp_request_state:args_hash(#{<<"x">> => 1})
    }.

sealed(#{kid := Kid, jwk := JWK}, Exp) ->
    {ok, Compact} = bondy_mcp_request_state:seal(
        JWK, Kid, payload(Exp), ?MAX
    ),
    Compact.

key_fun(#{kid := Kid, jwk := JWK}) ->
    fun
        (K) when K =:= Kid -> JWK;
        (_) -> undefined
    end.

open(Keys, Compact, Expect) ->
    bondy_mcp_request_state:open(key_fun(Keys), Compact, Expect, 1000, ?MAX).

roundtrip(Keys) ->
    Compact = sealed(Keys, 2000),
    %% Opaque on the wire: a JWE compact form, with no plaintext leaking.
    ?assertEqual(5, length(binary:split(Compact, <<".">>, [global]))),
    ?assertEqual(nomatch, binary:match(Compact, <<"tomato">>)),
    ?assertMatch(
        {ok, #{
            continuation := <<"cont-1">>,
            state := #{<<"step">> := 1}
        }},
        open(Keys, Compact, expect())
    ).

principal_mismatch(Keys) ->
    Compact = sealed(Keys, 2000),
    ?assertEqual(
        {error, invalid},
        open(Keys, Compact, (expect())#{principal => <<"bob">>})
    ),
    %% The anonymous class binding is a different principal too.
    ?assertEqual(
        {error, invalid},
        open(Keys, Compact, (expect())#{principal => anonymous})
    ).

method_mismatch(Keys) ->
    ?assertEqual(
        {error, invalid},
        open(
            Keys,
            sealed(Keys, 2000),
            (expect())#{method => <<"resources/read">>}
        )
    ).

name_mismatch(Keys) ->
    ?assertEqual(
        {error, invalid},
        open(Keys, sealed(Keys, 2000), (expect())#{name => <<"tool_b">>})
    ).

args_mismatch(Keys) ->
    ?assertEqual(
        {error, invalid},
        open(Keys, sealed(Keys, 2000), (expect())#{
            args_hash => bondy_mcp_request_state:args_hash(#{<<"x">> => 2})
        })
    ).

expired(Keys) ->
    %% `open` at Now = 1000 against an envelope expiring at 999.
    ?assertEqual({error, invalid}, open(Keys, sealed(Keys, 999), expect())).

tampered(Keys) ->
    Compact = sealed(Keys, 2000),
    Pos = byte_size(Compact) - 10,
    <<A:Pos/binary, C, B/binary>> = Compact,
    C1 =
        case C of
            $A -> $B;
            _ -> $A
        end,
    ?assertEqual(
        {error, invalid}, open(Keys, <<A/binary, C1, B/binary>>, expect())
    ).

wrong_key(#{other := Other} = Keys) ->
    %% Decrypting with the wrong key RAISES inside jose; still `invalid`.
    Compact = sealed(Keys, 2000),
    WrongKeyFun = fun(_) -> Other end,
    ?assertEqual(
        {error, invalid},
        bondy_mcp_request_state:open(WrongKeyFun, Compact, expect(), 1000, ?MAX)
    ).

unknown_kid(Keys) ->
    Compact = sealed(Keys, 2000),
    NoKeyFun = fun(_) -> undefined end,
    ?assertEqual(
        {error, invalid},
        bondy_mcp_request_state:open(NoKeyFun, Compact, expect(), 1000, ?MAX)
    ).

garbage(Keys) ->
    ?assertEqual({error, invalid}, open(Keys, <<"not-a-jwe">>, expect())),
    ?assertEqual({error, invalid}, open(Keys, <<>>, expect())),
    ?assertEqual({error, invalid}, open(Keys, 42, expect())),
    %% A syntactically plausible compact form with attacker-shaped header.
    Header = base64:encode(<<"{\"kid\":42}">>, #{mode => urlsafe}),
    ?assertEqual(
        {error, invalid},
        open(Keys, <<Header/binary, ".a.b.c.d">>, expect())
    ).

oversize_inbound(Keys) ->
    Compact = sealed(Keys, 2000),
    ?assertEqual(
        {error, invalid},
        bondy_mcp_request_state:open(
            key_fun(Keys), Compact, expect(), 1000, byte_size(Compact) - 1
        )
    ).

oversize_seal(#{kid := Kid, jwk := JWK}) ->
    Payload = (payload(2000))#{state => crypto:strong_rand_bytes(4096)},
    ?assertEqual(
        {error, too_large},
        bondy_mcp_request_state:seal(JWK, Kid, Payload, 1024)
    ).
