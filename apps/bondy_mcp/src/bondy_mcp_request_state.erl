%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mcp_request_state).

-moduledoc """
The MRTR `requestState` envelope (design §11.1): a callee's continuation
state sealed into an opaque string the MCP client round-trips, and opened
on the retry.

The specification is normative here: `requestState` passes through the
client, so the server MUST treat it as attacker-controlled input, MUST
protect its integrity, and MUST reject state failing verification, binding
the authenticated principal, a short expiry and an identifier of the
originating request inside the protected payload. This module seals the
payload as a compact JWE (`RSA-OAEP` + `A256GCM`) under one of the realm's
encryption keys — AEAD rather than a bare MAC, because a callee's
continuation may itself be sensitive and confidentiality costs nothing
extra. The key is the REALM's (replicated with it), never the listener's:
a continuation minted through one endpoint or node must open on any other
serving the same realm (§11.1). Cross-realm replay is structurally
impossible — another realm's keys cannot decrypt the mint.

`open/3` rejects with a uniform `{error, invalid}` for every failure —
oversize, malformed, undecryptable, expired, or bound to a different
principal, method, name or argument digest — so the rejection is not an
oracle for which check failed. The failure shapes of the underlying
`jose` decrypt were established by probe and are pinned by this module's
tests: a tampered ciphertext RETURNS an error tuple while a wrong key
RAISES, and both must land in the same rejection.

The payload is decoded with a plain `binary_to_term/1`: the bytes were
authenticated by the AEAD tag first, so only a holder of the realm key
could have produced them — this is the own-persisted-bytes case, not the
peer-shipped wire case that requires `[safe]`.
""".

%% One knob bounds both directions: a sealed envelope larger than this is
%% refused at mint (the callee's state is oversized — a callee bug), and an
%% inbound `requestState` larger than this is refused before any
%% cryptography is attempted.
-define(DEFAULT_MAX_SIZE, 65536).
%% The spec's "short expiry (TTL)" for replay bounding.
-define(DEFAULT_TTL_MS, 300000).

-type payload() :: #{
    continuation := binary(),
    principal := anonymous | binary(),
    method := binary(),
    name := binary(),
    args_hash := binary(),
    state := any()
}.
-type expect() :: #{
    principal := anonymous | binary(),
    method := binary(),
    name := binary(),
    args_hash := binary()
}.

-export_type([payload/0]).
-export_type([expect/0]).

-export([args_hash/1]).
-export([open/3]).
-export([open/5]).
-export([seal/2]).
-export([seal/4]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
The originating-request argument digest bound inside the envelope: the
retry MUST carry the original `arguments` unchanged, and this is what
enforces it.
""".
-spec args_hash(Arguments :: map()) -> binary().

args_hash(Arguments) when is_map(Arguments) ->
    crypto:hash(sha256, term_to_binary(Arguments, [deterministic])).

-doc """
Seals `Payload` under one of `RealmUri`'s encryption keys, with the expiry
(`mcp.request_state.ttl`) stamped here so the TTL policy lives next to the
seal. `{error, too_large}` when the sealed envelope exceeds
`mcp.request_state.max_size` — the callee's continuation is oversized.
""".
-spec seal(bondy_realm:uri(), payload()) ->
    {ok, binary()} | {error, too_large}.

seal(RealmUri, Payload) when is_binary(RealmUri), is_map(Payload) ->
    %% The atomic pair: encryption keys are minted lazily on first use, so
    %% kid selection and key retrieval must not straddle a stale record.
    {Kid, JWK} = bondy_realm:get_random_encryption_key(RealmUri),
    Exp = erlang:system_time(millisecond) + ttl(),
    seal(JWK, Kid, Payload#{exp => Exp}, max_size()).

-doc """
Seals a complete payload (including `exp`, in milliseconds of system time)
under `JWK`, naming `Kid` in the JWE protected header so `open` can select
the key without decrypting.
""".
-spec seal(JWK :: any(), Kid :: binary(), map(), MaxSize :: pos_integer()) ->
    {ok, binary()} | {error, too_large}.

seal(JWK, Kid, #{exp := _} = Payload, MaxSize) when is_binary(Kid) ->
    Header = #{
        <<"alg">> => <<"RSA-OAEP">>,
        <<"enc">> => <<"A256GCM">>,
        <<"kid">> => Kid
    },
    Plain = term_to_binary(Payload#{v => 1}),
    {_, Compact} = jose_jwe:compact(
        jose_jwk:block_encrypt(Plain, Header, jose_jwk:from(JWK))
    ),
    case byte_size(Compact) =< MaxSize of
        true -> {ok, Compact};
        false -> {error, too_large}
    end.

-doc """
Opens an inbound `requestState` against `RealmUri`'s keys and the identity
of the request presenting it. Every failure is `{error, invalid}`.
""".
-spec open(bondy_realm:uri(), Compact :: any(), expect()) ->
    {ok, #{continuation := binary(), state := any()}} | {error, invalid}.

open(RealmUri, Compact, Expect) when is_binary(RealmUri) ->
    Realm = bondy_realm:fetch(RealmUri),
    KeyFun = fun(Kid) -> bondy_realm:get_encryption_key(Realm, Kid) end,
    open(
        KeyFun, Compact, Expect, erlang:system_time(millisecond), max_size()
    ).

-doc """
Opens `Compact` with the key `KeyFun(Kid)` names (`undefined` rejects),
requiring the payload unexpired at `Now` and its `principal`, `method`,
`name` and `args_hash` each equal to `Expect`'s.
""".
-spec open(
    KeyFun :: fun((binary()) -> any()),
    Compact :: any(),
    expect(),
    Now :: integer(),
    MaxSize :: pos_integer()
) ->
    {ok, #{continuation := binary(), state := any()}} | {error, invalid}.

open(KeyFun, Compact, Expect, Now, MaxSize) ->
    %% One uniform rejection for attacker-controlled input: any raise from
    %% the parsing or cryptography below IS the invalid case.
    try
        do_open(KeyFun, Compact, Expect, Now, MaxSize)
    catch
        _:_ -> {error, invalid}
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
do_open(KeyFun, Compact, Expect, Now, MaxSize) when
    is_binary(Compact), byte_size(Compact) =< MaxSize
->
    JWK = KeyFun(kid(Compact)),
    JWK =/= undefined orelse throw(invalid),
    {Plain, _} = jose_jwk:block_decrypt(Compact, jose_jwk:from(JWK)),
    is_binary(Plain) orelse throw(invalid),
    #{
        v := 1,
        continuation := Continuation,
        principal := Principal,
        method := Method,
        name := Name,
        args_hash := ArgsHash,
        exp := Exp,
        state := State
    } = binary_to_term(Plain),
    Exp >= Now orelse throw(invalid),
    Principal =:= maps:get(principal, Expect) orelse throw(invalid),
    Method =:= maps:get(method, Expect) orelse throw(invalid),
    Name =:= maps:get(name, Expect) orelse throw(invalid),
    ArgsHash =:= maps:get(args_hash, Expect) orelse throw(invalid),
    {ok, #{continuation => Continuation, state => State}};
do_open(_, _, _, _, _) ->
    {error, invalid}.

%% @private
%% The kid from the JWE protected header, read without decrypting.
kid(Compact) ->
    [Protected | _] = binary:split(Compact, <<".">>),
    {ok, HeaderBin} = jose_base64url:decode(Protected),
    #{<<"kid">> := Kid} = json:decode(HeaderBin),
    is_binary(Kid) orelse throw(invalid),
    Kid.

%% @private
ttl() ->
    application:get_env(bondy_mcp, request_state_ttl, ?DEFAULT_TTL_MS).

%% @private
max_size() ->
    application:get_env(bondy_mcp, request_state_max_size, ?DEFAULT_MAX_SIZE).
