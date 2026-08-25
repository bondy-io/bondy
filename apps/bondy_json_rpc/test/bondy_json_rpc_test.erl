%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Falsifiers for the JSON-RPC 2.0 codec: each rejection case aims at one
%% validation rule, and the id-salvage behaviour (an error response names
%% the request's id exactly when a well-typed one could be read) is pinned
%% in both directions.
-module(bondy_json_rpc_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("bondy_json_rpc/include/bondy_json_rpc.hrl").

decode(Term) ->
    bondy_json_rpc:decode(iolist_to_binary(json:encode(Term))).

request_roundtrip_test() ->
    ?assertEqual(
        {ok,
            {request, #{
                id => 1,
                method => <<"tools/call">>,
                params => #{<<"name">> => <<"t">>}
            }}},
        decode(#{
            <<"jsonrpc">> => <<"2.0">>,
            <<"id">> => 1,
            <<"method">> => <<"tools/call">>,
            <<"params">> => #{<<"name">> => <<"t">>}
        })
    ),
    %% String ids are equally valid RequestIds.
    ?assertMatch(
        {ok, {request, #{id := <<"r-1">>}}},
        decode(#{
            <<"jsonrpc">> => <<"2.0">>,
            <<"id">> => <<"r-1">>,
            <<"method">> => <<"m">>
        })
    ).

notification_has_no_id_test() ->
    ?assertEqual(
        {ok, {notification, #{method => <<"notifications/x">>, params => #{}}}},
        decode(#{
            <<"jsonrpc">> => <<"2.0">>, <<"method">> => <<"notifications/x">>
        })
    ).

parse_error_test() ->
    ?assertMatch(
        {error, {parse_error, _}}, bondy_json_rpc:decode(<<"{not json">>)
    ).

invalid_request_test() ->
    %% Missing/wrong version.
    ?assertMatch(
        {error, {invalid_request, 7}},
        decode(#{<<"id">> => 7, <<"method">> => <<"m">>})
    ),
    ?assertMatch(
        {error, {invalid_request, undefined}},
        decode(#{<<"jsonrpc">> => <<"1.0">>, <<"method">> => <<"m">>})
    ),
    %% A method that is not a string.
    ?assertMatch(
        {error, {invalid_request, undefined}},
        decode(#{<<"jsonrpc">> => <<"2.0">>, <<"method">> => 42})
    ),
    %% An id outside the RequestId type (null / bool / float).
    ?assertMatch(
        {error, {invalid_request, undefined}},
        decode(#{
            <<"jsonrpc">> => <<"2.0">>,
            <<"id">> => null,
            <<"method">> => <<"m">>
        })
    ),
    %% By-position params.
    ?assertMatch(
        {error, {invalid_request, 3}},
        decode(#{
            <<"jsonrpc">> => <<"2.0">>,
            <<"id">> => 3,
            <<"method">> => <<"m">>,
            <<"params">> => [1, 2]
        })
    ),
    %% A batch: one POST carries one message.
    ?assertMatch(
        {error, {invalid_request, undefined}},
        bondy_json_rpc:decode(<<"[]">>)
    ).

responses_test() ->
    ?assertEqual(
        #{
            <<"jsonrpc">> => <<"2.0">>,
            <<"id">> => 1,
            <<"result">> => #{<<"ok">> => true}
        },
        bondy_json_rpc:result_response(1, #{<<"ok">> => true})
    ),
    ?assertEqual(
        #{
            <<"jsonrpc">> => <<"2.0">>,
            <<"id">> => <<"a">>,
            <<"error">> => #{
                <<"code">> => ?JSONRPC_METHOD_NOT_FOUND,
                <<"message">> => <<"nope">>
            }
        },
        bondy_json_rpc:error_response(
            <<"a">>, ?JSONRPC_METHOD_NOT_FOUND, <<"nope">>
        )
    ),
    %% No id could be read: the member is OMITTED, not null.
    Err = bondy_json_rpc:error_response(
        undefined, ?JSONRPC_PARSE_ERROR, <<"parse">>
    ),
    ?assertNot(maps:is_key(<<"id">>, Err)),
    ?assertMatch(
        #{<<"error">> := #{<<"data">> := #{<<"supported">> := [_]}}},
        bondy_json_rpc:error_response(
            undefined, -32022, <<"v">>, #{<<"supported">> => [<<"x">>]}
        )
    ),
    %% encode/1 round-trips through the json module.
    ?assertEqual(
        Err, json:decode(bondy_json_rpc:encode(Err))
    ).
