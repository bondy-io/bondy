%% =============================================================================
%%  bondy_SUITE.erl -
%%
%%  Copyright (c) 2016-2022 Leapsight. All rights reserved.
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

-module(bondy_wamp_protocol_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("wamp/include/wamp.hrl").

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
    bondy_ct:stop_bondy(),
    {save_config, Config}.

%% -----------------------------------------------------------------------------
%% bondy_wamp_protocol:format_status
%% -----------------------------------------------------------------------------

format_status(_Config) ->
    lists:foreach(
        fun(InvalidOpt) ->
            Error = bondy_wamp_protocol:format_status(InvalidOpt, undefined),
            ?assertEqual({error, invalid_option}, Error)
        end,
        [undefined, invalid]),

    lists:foreach(
        fun({Opt, State}) ->
            NewState = bondy_wamp_protocol:format_status(Opt, State),
            ?assertEqual({error, invalid_state}, NewState)
        end,
        [{O, S} || O <- [normal, terminate], S <- [
            {},
            {wamp_state},
            {wamp_state, undefined, undefined, undefined, undefined, undefined, undefined}
        ]]),

    lists:foreach(
        fun(Opt) ->
            State = bondy_wamp_protocol:format_status(Opt, undefined),
            ?assertEqual(undefined, State)
        end,
        [normal, terminate]),

    % No sensitive info at wamp_state level, the reformatting is delegated to other modules.
    lists:foreach(
        fun({Opt, SubProtocol, AuthMethod, AuthContext, AuthTime, Name, Context, Reason}) ->
            State = {wamp_state, SubProtocol, AuthMethod, AuthContext, AuthTime, Name, Context, Reason},
            NewState = bondy_wamp_protocol:format_status(Opt, State),
            ?assertEqual(State, NewState)
        end,
        [{Op, SP, AM, AC, AT, SN, Co, Re} ||
            Op <- [normal, terminate],
            SP <- [undefined, {raw, binary, json}],
            AM <- [undefined, cryptosign],
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
            SubProtocol = wamp_subprotocol:from_binary(SubProtocolBinary),
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
    StateNoContext = {wamp_state, SubProtocol, cryptosign, #{}, 123, failed, undefined, normal},
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
    StateInvalidSP = {wamp_state, SubProtocolInvalid, wampcra, #{}, 123, establishing, undefined, normal},
    Error = {unsupported_encoding, EncodingUnsupported},
    ?assertError(Error, bondy_wamp_protocol:handle_inbound(<<>>, StateInvalidSP)).

