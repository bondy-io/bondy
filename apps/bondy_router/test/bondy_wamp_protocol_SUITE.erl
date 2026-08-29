%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_protocol_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-compile([export_all]).

all() ->
    [
        format_status,
        validate_subprotocol,
        abort_message_preauth_is_generic,
        init_error,
        init_ok,
        terminate,
        handle_inbound,
        throttle_disabled_by_default,
        throttle_when_enabled,
        throttle_message_class,
        hello_admission_when_busy,
        hello_admission_disabled
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    [{realm_uri, <<"com.example.test.wamp_protocol">>} | Config].

end_per_suite(Config) ->
    %% bondy_ct:stop_bondy(),
    {save_config, Config}.

%% -----------------------------------------------------------------------------
%% bondy_wamp_protocol:format_status
%% -----------------------------------------------------------------------------

format_status(_Config) ->
    lists:foreach(
        fun(State) ->
            ?assertError(
                function_clause, bondy_wamp_protocol:format_status(State)
            )
        end,
        [S || S <- [{}, {wamp_state}]]
    ),

    % No sensitive info at wamp_state level, the reformatting is delegated to other modules.
    lists:foreach(
        fun(
            {SubProtocol, AuthMethod, AuthClaims, AuthContext, AuthTime, Name,
                Context, Reason, MsgLimiter, Listener}
        ) ->
            State =
                {wamp_state, SubProtocol, AuthMethod, AuthClaims, AuthContext,
                    AuthTime, Name, Context, Reason, MsgLimiter, Listener},
            NewState = bondy_wamp_protocol:format_status(State),
            ?assertEqual(State, NewState)
        end,
        [
            {SP, AM, ACl, AC, AT, SN, Co, Re, ML, LS}
         || SP <- [undefined, {raw, binary, json}],
            AM <- [undefined, cryptosign],
            ACl <- [undefined, #{}],
            AC <- [undefined, #{}],
            AT <- [undefined, 123],
            SN <- [closed, establishing],
            Co <- [undefined, #{}],
            Re <- [normal, logout],
            ML <- [undefined],
            LS <- [undefined, admin_api]
        ]
    ).

%% -----------------------------------------------------------------------------
%% bondy_wamp_protocol:validate_subprotocol
%% -----------------------------------------------------------------------------

-define(PROTOCOLS, [raw, ws]).
-define(FRAMES, [binary, text]).
-define(ENCODINGS, [
    bert,
    bert_batched,
    erl,
    erl_batched,
    json,
    json_batched,
    msgpack,
    msgpack_batched,
    cbor,
    cbor_batched
]).
%% NOTE: bert / bert_batched are intentionally absent — de-listed as a pre-auth
%% DoS (bert:decode/1 => binary_to_term/1 without [safe]).
-define(SUPPORTED_SUB_PROTOCOLS, [
    {raw, binary, erl},
    {raw, binary, json},
    {raw, binary, cbor},
    {raw, binary, msgpack},
    {ws, binary, erl_batched},
    {ws, binary, msgpack_batched},
    {ws, binary, msgpack},
    {ws, binary, cbor_batched},
    {ws, binary, cbor},
    {ws, text, json_batched},
    {ws, text, json}
]).
-define(WAMP2_ENCODINGS, [
    ?WAMP2_JSON,
    ?WAMP2_MSGPACK,
    ?WAMP2_CBOR,
    ?WAMP2_BERT,
    % not supported
    ?WAMP2_ERL,
    ?WAMP2_CBOR_BATCHED,
    ?WAMP2_MSGPACK_BATCHED,
    ?WAMP2_JSON_BATCHED,
    ?WAMP2_BERT_BATCHED,
    ?WAMP2_ERL_BATCHED
]).

validate_subprotocol(_Config) ->
    lists:foreach(
        fun(SubProtocol) ->
            ValidateResult = bondy_wamp_protocol:validate_subprotocol(
                SubProtocol
            ),
            case lists:member(SubProtocol, ?SUPPORTED_SUB_PROTOCOLS) of
                true ->
                    ?assertEqual({ok, SubProtocol}, ValidateResult);
                false ->
                    ?assertEqual({error, invalid_subprotocol}, ValidateResult)
            end
        end,
        [{P, F, E} || P <- ?PROTOCOLS, F <- ?FRAMES, E <- ?ENCODINGS]
    ),

    lists:foreach(
        fun(SubProtocolBinary) ->
            SubProtocol = bondy_wamp_subprotocol:from_binary(SubProtocolBinary),
            ValidateResult = bondy_wamp_protocol:validate_subprotocol(
                SubProtocolBinary
            ),
            case lists:member(SubProtocol, ?SUPPORTED_SUB_PROTOCOLS) of
                true ->
                    ?assertEqual({ok, SubProtocol}, ValidateResult);
                false ->
                    ?assertEqual({error, invalid_subprotocol}, ValidateResult)
            end
        end,
        ?WAMP2_ENCODINGS
    ),

    Error = {error, whatever},
    ?assertEqual(Error, bondy_wamp_protocol:validate_subprotocol(Error)),

    ?assertEqual(
        {error, invalid_subprotocol},
        bondy_wamp_protocol:validate_subprotocol(<<"wamp.2.not.supported">>)
    ),

    %% bert and bert_batched are de-listed (bert:decode/1 =>
    %% binary_to_term/1 without [safe] is a pre-auth atom-exhaustion DoS).
    ?assertEqual(
        {error, invalid_subprotocol},
        bondy_wamp_subprotocol:from_binary(?WAMP2_BERT)
    ),
    ?assertEqual(
        {error, invalid_subprotocol},
        bondy_wamp_subprotocol:from_binary(?WAMP2_BERT_BATCHED)
    ),
    ?assertEqual(
        {error, invalid_subprotocol},
        bondy_wamp_protocol:validate_subprotocol({ws, binary, bert})
    ),
    ?assertEqual(
        {error, invalid_subprotocol},
        bondy_wamp_protocol:validate_subprotocol({raw, binary, bert})
    ),
    ?assertEqual(
        {error, invalid_subprotocol},
        bondy_wamp_protocol:validate_subprotocol({ws, binary, bert_batched})
    ).

%% -----------------------------------------------------------------------------
%% pre-auth ABORT must not be a user-enumeration oracle
%% -----------------------------------------------------------------------------

abort_message_preauth_is_generic(_Config) ->
    %% Every pre-authentication credential/identity failure must produce a
    %% byte-identical client-facing ABORT (same reason_uri AND details), so a
    %% client cannot distinguish "no such user" / "disabled" from "bad password".
    Reasons = [
        {no_such_user, <<"ghost">>},
        {authentication_failed, {no_such_user, <<"ghost">>}},
        {authentication_failed, user_disabled},
        {authentication_failed, missing_signature},
        {authentication_failed, bad_signature}
    ],
    Aborts = [bondy_wamp_protocol:abort_message(R) || R <- Reasons],
    Uris = lists:usort([U || #abort{reason_uri = U} <- Aborts]),
    Details = lists:usort([D || #abort{details = D} <- Aborts]),
    ?assertEqual([?WAMP_AUTHENTICATION_FAILED], Uris),
    ?assertEqual(1, length(Details)),

    %% no_such_realm stays distinct — realm existence is not a user-enumeration
    %% oracle and is needed for routing.
    #abort{reason_uri = RealmReason} =
        bondy_wamp_protocol:abort_message(no_such_realm),
    ?assertNotEqual(?WAMP_AUTHENTICATION_FAILED, RealmReason).

%% -----------------------------------------------------------------------------
%% bondy_wamp_protocol:init
%% -----------------------------------------------------------------------------

init_error(_Config) ->
    UnsupportedSubProtocol = {ws, binary, erl},
    Peer = {{127, 0, 0, 1}, 7},
    Options = #{},
    Result = bondy_wamp_protocol:init(UnsupportedSubProtocol, Peer, Options),
    ?assertEqual({error, invalid_subprotocol, undefined}, Result).

init_ok(_Config) ->
    SubProtocol = {raw, binary, erl},
    Peer = {{127, 0, 0, 1}, 7},
    Options = #{},
    {ok, State} = bondy_wamp_protocol:init(SubProtocol, Peer, Options),

    Context = bondy_wamp_protocol:context(State),
    SessionId = bondy_context:session_id(Context),
    ?assertEqual(SessionId, bondy_wamp_protocol:session_id(State)),
    ?assertEqual(Peer, bondy_wamp_protocol:peer(State)),
    ?assertEqual(undefined, bondy_wamp_protocol:agent(State)),
    ?assertEqual(undefined, bondy_wamp_protocol:realm_uri(State)),
    ?assertError(function_clause, bondy_wamp_protocol:ref(State)).

%% -----------------------------------------------------------------------------
%% bondy_wamp_protocol:throttle
%% -----------------------------------------------------------------------------

throttle_disabled_by_default(_Config) ->
    %% With the feature off (the default), the throttle is always `ok`.
    ok = bondy_config:set([security, rate_limit], undefined),
    {ok, State} = bondy_wamp_protocol:init(
        {raw, binary, erl}, {{10, 9, 9, 9}, 5000}, #{}
    ),
    [
        ?assertEqual(ok, bondy_wamp_protocol:throttle(auth, State))
     || _ <- lists:seq(1, 50)
    ].

throttle_when_enabled(_Config) ->
    %% Enable with a tiny capacity so the bucket exhausts deterministically.
    ok = bondy_config:set([security, rate_limit], #{
        enabled => true,
        auth => #{rate => 1, capacity => 3}
    }),
    try
        %% A distinct source IP => its own bucket (no interference).
        {ok, State} = bondy_wamp_protocol:init(
            {raw, binary, erl}, {{10, 7, 7, 7}, 5000}, #{}
        ),
        ?assertEqual(ok, bondy_wamp_protocol:throttle(auth, State)),
        ?assertEqual(ok, bondy_wamp_protocol:throttle(auth, State)),
        ?assertEqual(ok, bondy_wamp_protocol:throttle(auth, State)),
        ?assertEqual(throttled, bondy_wamp_protocol:throttle(auth, State)),

        %% A different class (handshake) has its own independent bucket.
        ?assertEqual(ok, bondy_wamp_protocol:throttle(handshake, State))
    after
        ok = bondy_config:set([security, rate_limit], undefined)
    end.

%% A busy node refuses a new HELLO with a retryable
%% wamp.error.unavailable ABORT before doing any realm or auth work.
hello_admission_when_busy(_Config) ->
    Ref = persistent_term:get({bondy_regulator_load, status}),
    %% Suspend the sampler so the forced busy state cannot be reverted
    %% by a tick mid-test (the test node is idle).
    ok = sys:suspend(bondy_regulator_load),
    ok = atomics:put(Ref, 1, 1),
    try
        ?assert(bondy_regulator_load:busy()),

        {ok, St} = bondy_wamp_protocol:init(
            {raw, binary, erl}, {{10, 8, 8, 8}, 5000}, #{}
        ),
        Hello = bondy_wamp_message:hello(
            <<"com.example.test.wamp_protocol">>,
            #{roles => #{caller => #{}}}
        ),
        Data = bondy_wamp_encoding:encode(Hello, erl),

        ?assertMatch(
            {stop, ?WAMP_UNAVAILABLE, [_Abort], _},
            bondy_wamp_protocol:handle_inbound(Data, St)
        )
    after
        ok = atomics:put(Ref, 1, 0),
        ok = sys:resume(bondy_regulator_load)
    end.

%% With the gate disabled a busy node still processes the HELLO (here it
%% fails later on the unknown realm — proving it got past admission).
hello_admission_disabled(_Config) ->
    Ref = persistent_term:get({bondy_regulator_load, status}),
    ok = sys:suspend(bondy_regulator_load),
    ok = atomics:put(Ref, 1, 1),
    ok = bondy_config:set([load_regulation, hello, enabled], false),
    try
        {ok, St} = bondy_wamp_protocol:init(
            {raw, binary, erl}, {{10, 8, 8, 9}, 5000}, #{}
        ),
        Hello = bondy_wamp_message:hello(
            <<"com.example.test.wamp_protocol.does_not_exist">>,
            #{roles => #{caller => #{}}}
        ),
        Data = bondy_wamp_encoding:encode(Hello, erl),

        Result = bondy_wamp_protocol:handle_inbound(Data, St),
        ?assertMatch({stop, _, _, _}, Result),
        {stop, Uri, _, _} = Result,
        ?assertNotEqual(?WAMP_UNAVAILABLE, Uri)
    after
        ok = bondy_config:set([load_regulation, hello, enabled], true),
        ok = atomics:put(Ref, 1, 0),
        ok = sys:resume(bondy_regulator_load)
    end.

throttle_message_class(_Config) ->
    %% The per-message class needs BOTH the master flag AND its own opt-in flag.
    %% Master on but message off => message class disabled.
    ok = bondy_config:set([security, rate_limit], #{
        enabled => true, message => #{enabled => false}
    }),
    ?assertNot(bondy_rate_limit:enabled(message)),
    ?assertEqual(ok, bondy_rate_limit:throttle(message, sess_key())),

    %% Both on => throttles after capacity.
    ok = bondy_config:set([security, rate_limit], #{
        enabled => true,
        message => #{enabled => true, rate => 1, capacity => 2}
    }),
    try
        ?assert(bondy_rate_limit:enabled(message)),
        K = sess_key(),
        ?assertEqual(ok, bondy_rate_limit:throttle(message, K)),
        ?assertEqual(ok, bondy_rate_limit:throttle(message, K)),
        ?assertEqual(throttled, bondy_rate_limit:throttle(message, K))
    after
        ok = bondy_config:set([security, rate_limit], undefined)
    end.

sess_key() ->
    {session, erlang:unique_integer([positive])}.

%% -----------------------------------------------------------------------------
%% bondy_wamp_protocol:terminate
%% -----------------------------------------------------------------------------

terminate(_Config) ->
    SubProtocol = {raw, binary, erl},

    % undefined context
    StateNoContext =
        {wamp_state, SubProtocol, cryptosign, undefined, #{}, 123, failed,
            undefined, normal, undefined, undefined},
    ?assertEqual(undefined, bondy_wamp_protocol:context(StateNoContext)),
    ?assertEqual(ok, bondy_wamp_protocol:terminate(StateNoContext)),

    % no session
    Peer = {{127, 0, 0, 1}, 7},
    {ok, State} = bondy_wamp_protocol:init(SubProtocol, Peer, #{}),
    Context = bondy_wamp_protocol:context(State),
    ?assertNot(bondy_context:has_session(Context)),
    ?assertEqual(ok, bondy_wamp_protocol:terminate(State)).

%% -----------------------------------------------------------------------------
%% bondy_wamp_protocol:handle_inbound
%% -----------------------------------------------------------------------------

handle_inbound(_Config) ->
    % Unsupported protocol
    EncodingUnsupported = unsupported,
    SubProtocolInvalid = {ws, text, EncodingUnsupported},
    StateInvalidSP =
        {wamp_state, SubProtocolInvalid, wampcra, undefined, #{}, 123,
            establishing, undefined, normal, undefined, undefined},
    Error = {unsupported_encoding, EncodingUnsupported},
    ?assertError(
        Error, bondy_wamp_protocol:handle_inbound(<<>>, StateInvalidSP)
    ).
