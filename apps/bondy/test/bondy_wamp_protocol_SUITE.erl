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
        init_error,
        init_ok,
        terminate,
        handle_inbound
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    [{realm_uri, <<"com.example.test.wamp_protocol">>}|Config].

end_per_suite(Config) ->
    %% bondy_ct:stop_bondy(),
    {save_config, Config}.

%% -----------------------------------------------------------------------------
%% bondy_wamp_protocol:format_status
%% -----------------------------------------------------------------------------

format_status(_Config) ->
    lists:foreach(
        fun(State) ->
            ?assertError(function_clause, bondy_wamp_protocol:format_status( State))
        end,
        [S || S <- [{}, {wamp_state}]]
    ),

    % No sensitive info at wamp_state level, the reformatting is delegated to other modules.
    lists:foreach(
        fun({SubProtocol, AuthMethod, AuthClaims, AuthContext, AuthTime, Name, Context, Reason}) ->
            State = {wamp_state, SubProtocol, AuthMethod, AuthClaims, AuthContext, AuthTime, Name, Context, Reason},
            NewState = bondy_wamp_protocol:format_status(State),
            ?assertEqual(State, NewState)
        end,
        [{SP, AM, ACl, AC, AT, SN, Co, Re} ||
            SP <- [undefined, {raw, binary, json}],
            AM <- [undefined, cryptosign],
            ACl <- [undefined, #{}],
            AC <- [undefined, #{}],
            AT <- [undefined, 123],
            SN <- [closed, establishing],
            Co <- [undefined, #{}],
            Re <- [normal, logout]
        ]).

%% -----------------------------------------------------------------------------
%% bondy_wamp_protocol:validate_subprotocol
%% -----------------------------------------------------------------------------

-define(PROTOCOLS, [raw, ws]).
-define(FRAMES, [binary, text]).
-define(ENCODINGS, [bert, bert_batched, erl, erl_batched, json, json_batched, msgpack, msgpack_batched]).
-define(SUPPORTED_SUB_PROTOCOLS, [
    {raw, binary, bert},
    {raw, binary, erl},
    {raw, binary, json},
    {raw, binary, msgpack},
    {ws, binary, bert_batched},
    {ws, binary, bert},
    {ws, binary, erl_batched},
    {ws, binary, msgpack_batched},
    {ws, binary, msgpack},
    {ws, text, json_batched},
    {ws, text, json}
]).
-define(WAMP2_ENCODINGS, [
    ?WAMP2_JSON,
    ?WAMP2_MSGPACK,
    ?WAMP2_BERT,
    ?WAMP2_ERL, % not supported
    ?WAMP2_MSGPACK_BATCHED,
    ?WAMP2_JSON_BATCHED,
    ?WAMP2_BERT_BATCHED,
    ?WAMP2_ERL_BATCHED
]).

validate_subprotocol(_Config) ->
    lists:foreach(
        fun(SubProtocol) ->
            ValidateResult = bondy_wamp_protocol:validate_subprotocol(SubProtocol),
            case lists:member(SubProtocol, ?SUPPORTED_SUB_PROTOCOLS) of
                true ->
                    ?assertEqual({ok, SubProtocol}, ValidateResult);
                false ->
                    ?assertEqual({error, invalid_subprotocol}, ValidateResult)
            end
        end,
        [{P, F, E} || P <- ?PROTOCOLS, F <- ?FRAMES, E <- ?ENCODINGS]),

    lists:foreach(
        fun(SubProtocolBinary) ->
            SubProtocol = bondy_wamp_subprotocol:from_binary(SubProtocolBinary),
            ValidateResult = bondy_wamp_protocol:validate_subprotocol(SubProtocolBinary),
            case lists:member(SubProtocol, ?SUPPORTED_SUB_PROTOCOLS) of
                true ->
                    ?assertEqual({ok, SubProtocol}, ValidateResult);
                false ->
                    ?assertEqual({error, invalid_subprotocol}, ValidateResult)
            end
        end,
        ?WAMP2_ENCODINGS),
    
    Error = {error, whatever},
    ?assertEqual(Error, bondy_wamp_protocol:validate_subprotocol(Error)),

    ?assertEqual({error, invalid_subprotocol},
                 bondy_wamp_protocol:validate_subprotocol(<<"wamp.2.not.supported">>)).

%% -----------------------------------------------------------------------------
%% bondy_wamp_protocol:init
%% -----------------------------------------------------------------------------

init_error(_Config) ->
    UnsupportedSubProtocol = {ws, binary, erl},
    Peer = {{127,0,0,1}, 7},
    Options = #{},
    Result = bondy_wamp_protocol:init(UnsupportedSubProtocol, Peer, Options),
    ?assertEqual({error, invalid_subprotocol, undefined}, Result).

init_ok(_Config) ->
    SubProtocol = {raw, binary, erl},
    Peer = {{127,0,0,1}, 7},
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
%% bondy_wamp_protocol:terminate
%% -----------------------------------------------------------------------------

terminate(_Config) ->
    SubProtocol = {raw, binary, erl},

    % undefined context
    StateNoContext = {wamp_state, SubProtocol, cryptosign, undefined, #{}, 123, failed, undefined, normal},
    ?assertEqual(undefined, bondy_wamp_protocol:context(StateNoContext)),
    ?assertEqual(ok, bondy_wamp_protocol:terminate(StateNoContext)),

    % no session
    Peer = {{127,0,0,1}, 7},
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
    StateInvalidSP = {wamp_state, SubProtocolInvalid, wampcra, undefined, #{}, 123, establishing, undefined, normal},
    Error = {unsupported_encoding, EncodingUnsupported},
    ?assertError(Error, bondy_wamp_protocol:handle_inbound(<<>>, StateInvalidSP)).

