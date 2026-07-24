%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_pagination_test).

-include_lib("eunit/include/eunit.hrl").

-define(FP, <<"fp-v1">>).

new_cursor_accessors_test() ->
    C = bondy_pagination:new_cursor(?FP, {3, <<"k">>}),
    ?assertEqual(?FP, bondy_pagination:fingerprint(C)),
    ?assertEqual({3, <<"k">>}, bondy_pagination:payload(C)).

result_final_page_test() ->
    R = bondy_pagination:result([a, b, c], undefined),
    ?assertEqual(
        #{values => [a, b, c], next => undefined, has_more => false},
        R
    ).

result_more_pages_test() ->
    C = bondy_pagination:new_cursor(?FP, next_pos),
    R = bondy_pagination:result([a, b], C),
    ?assertMatch(#{values := [a, b], has_more := true}, R),
    ?assertEqual(C, maps:get(next, R)).

codec_roundtrip_test() ->
    C = bondy_pagination:new_cursor(?FP, {7, <<"key/with/slashes">>}),
    Bin = bondy_pagination:encode_cursor(C),
    ?assert(is_binary(Bin)),
    ?assertEqual({ok, C}, bondy_pagination:decode_cursor(?FP, Bin)).

decode_foreign_fingerprint_is_stale_test() ->
    C = bondy_pagination:new_cursor(?FP, payload),
    Bin = bondy_pagination:encode_cursor(C),
    ?assertEqual(
        {error, stale},
        bondy_pagination:decode_cursor(<<"other-fp">>, Bin)
    ).

decode_garbage_is_malformed_test() ->
    ?assertEqual(
        {error, malformed},
        bondy_pagination:decode_cursor(?FP, <<"not-a-cursor">>)
    ),
    %% A validly-base64'd but non-cursor term.
    Bin = base64:encode(term_to_binary({some, other, term})),
    ?assertEqual(
        {error, malformed},
        bondy_pagination:decode_cursor(?FP, Bin)
    ).

to_external_final_page_omits_cursor_test() ->
    R = bondy_pagination:result([<<"a">>, <<"b">>], undefined),
    Ext = bondy_pagination:to_external(R),
    ?assertEqual(
        #{<<"values">> => [<<"a">>, <<"b">>], <<"has_more">> => false},
        Ext
    ),
    ?assertNot(maps:is_key(<<"cursor">>, Ext)).

to_external_more_pages_encodes_cursor_test() ->
    C = bondy_pagination:new_cursor(?FP, {1, <<"k">>}),
    R = bondy_pagination:result([<<"a">>], C),
    Ext = bondy_pagination:to_external(R),
    ?assertEqual(true, maps:get(<<"has_more">>, Ext)),
    Wire = maps:get(<<"cursor">>, Ext),
    ?assert(is_binary(Wire)),
    %% The externalised cursor is exactly the wire binary and round-trips.
    ?assertEqual({ok, C}, bondy_pagination:decode_cursor(?FP, Wire)).

%% The external page must be composed only of encoder-portable scalars so it
%% survives JSON/CBOR/MessagePack: binary keys, and values that are binaries,
%% numbers, booleans, or lists/maps thereof.
to_external_is_encoder_portable_test() ->
    C = bondy_pagination:new_cursor(?FP, {2, <<"k">>}),
    R = bondy_pagination:result(
        [#{<<"id">> => 1}, #{<<"id">> => 2}], C
    ),
    Ext = bondy_pagination:to_external(R),
    ?assert(is_portable(Ext)).

%% @private
is_portable(M) when is_map(M) ->
    maps:fold(
        fun(K, V, Acc) -> Acc andalso is_binary(K) andalso is_portable(V) end,
        true,
        M
    );
is_portable(L) when is_list(L) ->
    lists:all(fun is_portable/1, L);
is_portable(V) ->
    is_binary(V) orelse is_number(V) orelse is_boolean(V).
