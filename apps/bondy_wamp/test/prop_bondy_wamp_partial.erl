%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Property-based tests for partial (deferred) payload decoding. A JSON or CBOR
%% message decoded off the wire keeps its payload encoded in `partial`;
%% decoding the partial must yield exactly the payload the message was built
%% with, for every message type that is decoded partially, in normal and in
%% Payload Passthru Mode.
-module(prop_bondy_wamp_partial).

-include_lib("proper/include/proper.hrl").
-include("bondy_wamp.hrl").

-export([prop_partial_round_trip/0]).

%% =============================================================================
%% Properties
%% =============================================================================

prop_partial_round_trip() ->
    {ok, _} = application:ensure_all_started(bondy_wamp),
    ?FORALL(
        {Type, {Enc, {Opts, Args, KWArgs}}},
        {message_type(), ?LET(E, encoding(), {E, payload(E)})},
        begin
            M = build(Type, Opts, Args, KWArgs),
            Bin = iolist_to_binary(bondy_wamp_encoding:encode(M, Enc)),
            {[Decoded], <<>>} = bondy_wamp_encoding:decode(
                subprotocol(Enc), Bin
            ),
            Full = bondy_wamp_message:decode_partial(Decoded),
            ?WHENFAIL(
                io:format("~p~n~p~n~p~n", [M, Decoded, Full]),
                conjunction([
                    {partial_kept, element(1, partial(Decoded)) =:= Enc},
                    {partial_cleared, partial(Full) =:= undefined},
                    {payload, payload_of(Full) =:= payload_of(M)}
                ])
            )
        end
    ).

%% =============================================================================
%% Generators
%% =============================================================================

message_type() ->
    oneof([call, publish, event, result, yield, invocation, error]).

encoding() ->
    oneof([json, cbor]).

%% `{Opts, Args, KWArgs}`: a Payload Passthru payload is a single binary (any
%% bytes in CBOR, text in JSON, which has no byte strings) and no KWArgs; a
%% normal one is any list and map of JSON-representable values.
payload(Enc) ->
    oneof([
        {
            exactly(#{ppt_scheme => <<"x_custom">>}),
            ?LET(B, ppt_binary(Enc), [B]),
            exactly(undefined)
        },
        {
            exactly(#{}),
            non_empty(list(value(2))),
            oneof([exactly(undefined), non_empty(map(key(), value(2)))])
        }
    ]).

ppt_binary(json) -> utf8();
ppt_binary(cbor) -> binary().

key() ->
    non_empty(utf8()).

value(0) ->
    oneof([integer(), boolean(), utf8()]);
value(N) ->
    oneof([
        value(0),
        list(value(N - 1)),
        map(key(), value(N - 1))
    ]).

%% =============================================================================
%% Helpers
%% =============================================================================

build(call, O, A, K) ->
    bondy_wamp_message:call(1, O, <<"com.example.p">>, A, K);
build(publish, O, A, K) ->
    bondy_wamp_message:publish(1, O, <<"com.example.t">>, A, K);
build(event, O, A, K) ->
    bondy_wamp_message:event(1, 2, O, A, K);
build(result, O, A, K) ->
    bondy_wamp_message:result(1, O, A, K);
build(yield, O, A, K) ->
    bondy_wamp_message:yield(1, O, A, K);
build(invocation, O, A, K) ->
    bondy_wamp_message:invocation(1, 2, O, A, K);
build(error, O, A, K) ->
    bondy_wamp_message:error(?CALL, 1, O, <<"com.example.e">>, A, K).

partial(M) ->
    case bondy_wamp_message:partial(M) of
        undefined -> undefined;
        {_, _} = P -> P
    end.

payload_of(#call{args = A, kwargs = K}) -> {A, K};
payload_of(#publish{args = A, kwargs = K}) -> {A, K};
payload_of(#event{args = A, kwargs = K}) -> {A, K};
payload_of(#result{args = A, kwargs = K}) -> {A, K};
payload_of(#yield{args = A, kwargs = K}) -> {A, K};
payload_of(#invocation{args = A, kwargs = K}) -> {A, K};
payload_of(#error{args = A, kwargs = K}) -> {A, K}.

subprotocol(json) -> {ws, text, json};
subprotocol(cbor) -> {ws, binary, cbor}.
