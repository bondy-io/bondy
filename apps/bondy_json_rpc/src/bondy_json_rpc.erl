%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_json_rpc).

-moduledoc """
A JSON-RPC 2.0 codec: decoding with validation, and response / error
construction. It carries no transport and knows nothing of MCP or WAMP.

`decode/1` accepts one message — MCP's Streamable HTTP transport carries
exactly one JSON-RPC request or notification per HTTP POST, so a batch
(a JSON array) is rejected as an invalid request rather than fanned out.

Errors distinguish the two JSON-RPC failure classes a server must answer
differently: `{parse_error, _}` (the bytes are not JSON — the response
carries no `id` because none could be read) and `{invalid_request, Id}`
(valid JSON that is not a valid JSON-RPC request — `Id` is the request's
`id` when one could be salvaged, else `undefined`).
""".

-include("bondy_json_rpc.hrl").

-type id() :: binary() | integer().
-type request() :: #{
    id := id(),
    method := binary(),
    params := map()
}.
-type notification() :: #{
    method := binary(),
    params := map()
}.
-type decode_error() ::
    {parse_error, any()}
    | {invalid_request, id() | undefined}.

-export_type([id/0]).
-export_type([request/0]).
-export_type([notification/0]).

-export([decode/1]).
-export([encode/1]).
-export([error_object/2]).
-export([error_object/3]).
-export([error_response/3]).
-export([error_response/4]).
-export([notification/2]).
-export([result_response/2]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Decodes and validates one JSON-RPC 2.0 message.
""".
-spec decode(binary()) ->
    {ok, {request, request()} | {notification, notification()}}
    | {error, decode_error()}.

decode(Bin) when is_binary(Bin) ->
    try json:decode(Bin) of
        Decoded -> validate(Decoded)
    catch
        error:Reason -> {error, {parse_error, Reason}}
    end.

-doc "Encodes a response map (UTF-8 JSON binary).".
-spec encode(map()) -> binary().

encode(Map) when is_map(Map) ->
    iolist_to_binary(json:encode(Map)).

-doc "A notification: a request without an `id`, expecting no response.".
-spec notification(Method :: binary(), Params :: map()) -> map().

notification(Method, Params) when is_binary(Method), is_map(Params) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => Method,
        <<"params">> => Params
    }.

-doc "A successful response to the request identified by `Id`.".
-spec result_response(Id :: id(), Result :: map()) -> map().

result_response(Id, Result) when is_map(Result) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"result">> => Result
    }.

-doc """
An error response. `Id` may be `undefined` for a failure on a message whose
id could not be read (a parse error, a malformed request): the JSON-RPC
`id` member is then omitted entirely.
""".
-spec error_response(
    Id :: id() | undefined, Code :: integer(), Message :: binary()
) -> map().

error_response(Id, Code, Message) ->
    with_id(Id, #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"error">> => error_object(Code, Message)
    }).

-spec error_response(
    Id :: id() | undefined,
    Code :: integer(),
    Message :: binary(),
    Data :: any()
) -> map().

error_response(Id, Code, Message, Data) ->
    with_id(Id, #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"error">> => error_object(Code, Message, Data)
    }).

-doc "A bare JSON-RPC error object.".
-spec error_object(Code :: integer(), Message :: binary()) -> map().

error_object(Code, Message) when is_integer(Code), is_binary(Message) ->
    #{<<"code">> => Code, <<"message">> => Message}.

-spec error_object(
    Code :: integer(), Message :: binary(), Data :: any()
) -> map().

error_object(Code, Message, Data) ->
    (error_object(Code, Message))#{<<"data">> => Data}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
validate(#{<<"jsonrpc">> := <<"2.0">>, <<"method">> := Method} = M) when
    is_binary(Method)
->
    Params = maps:get(<<"params">>, M, #{}),
    case is_map(Params) of
        true ->
            case maps:find(<<"id">>, M) of
                {ok, Id} when is_binary(Id); is_integer(Id) ->
                    {ok,
                        {request, #{
                            id => Id, method => Method, params => Params
                        }}};
                {ok, Bad} ->
                    %% Fractional, boolean or null ids are outside the
                    %% RequestId type; nothing sane can correlate to them.
                    {error, {invalid_request, salvage_id(Bad)}};
                error ->
                    {ok, {notification, #{method => Method, params => Params}}}
            end;
        false ->
            %% JSON-RPC also admits by-position (array) params; every MCP
            %% method takes an object, so a non-map is refused here.
            {error,
                {invalid_request, salvage_id(maps:get(<<"id">>, M, undefined))}}
    end;
validate(M) when is_map(M) ->
    {error, {invalid_request, salvage_id(maps:get(<<"id">>, M, undefined))}};
validate(_) ->
    %% A batch (array) or a bare scalar. One POST carries one message.
    {error, {invalid_request, undefined}}.

%% @private
%% An id usable in the error response, when the malformed message carried
%% a well-typed one.
salvage_id(Id) when is_binary(Id); is_integer(Id) -> Id;
salvage_id(_) -> undefined.

%% @private
with_id(undefined, Map) -> Map;
with_id(Id, Map) -> Map#{<<"id">> => Id}.
