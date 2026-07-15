%% =============================================================================
%% Tests for the projection cell value frame codec
%% (`_design/catalogue_expansion_plan.md` §3.3).
%%
%% Pins the V2 encode/decode round-trip, the wire format
%% (`<<2:8, HasValueColumn:1, _Reserved:7, HlcLen:16, HlcBin,
%%      StateLen:32, StateBytes, [ValueLen:32, ValueBytes]>>`), and edge
%% cases.
%% =============================================================================

-module(bondy_oplog_cell_frame_test).

-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_oplog_cell_frame).

%% =============================================================================
%% encode/4 + decode_full/1 round-trip — HasValueColumn=0 (G-Set shape)
%% =============================================================================

roundtrip_zero_hlc_empty_state_no_value_column_test() ->
    Frame = ?MOD:encode(0, <<>>, undefined, true),
    ?assertEqual({0, <<>>, undefined}, ?MOD:decode_full(Frame)).

roundtrip_small_hlc_no_value_column_test() ->
    Frame = ?MOD:encode(42, <<"payload">>, undefined, true),
    ?assertEqual({42, <<"payload">>, undefined}, ?MOD:decode_full(Frame)).

roundtrip_max_hlc_no_value_column_test() ->
    MaxHlc = 16#FFFFFFFFFFFFFFFF,
    Frame = ?MOD:encode(MaxHlc, <<1, 2, 3>>, undefined, true),
    ?assertEqual({MaxHlc, <<1, 2, 3>>, undefined}, ?MOD:decode_full(Frame)).

roundtrip_large_state_no_value_column_test() ->
    Body = binary:copy(<<"x">>, 65_536),
    Frame = ?MOD:encode(1234, Body, undefined, true),
    ?assertEqual({1234, Body, undefined}, ?MOD:decode_full(Frame)).

%% =============================================================================
%% encode/4 + decode_full/1 round-trip — HasValueColumn=1
%% =============================================================================

roundtrip_with_value_column_test() ->
    Frame = ?MOD:encode(42, <<"state">>, <<"value">>, false),
    ?assertEqual({42, <<"state">>, <<"value">>}, ?MOD:decode_full(Frame)).

roundtrip_empty_value_column_test() ->
    Frame = ?MOD:encode(7, <<"state">>, <<>>, false),
    ?assertEqual({7, <<"state">>, <<>>}, ?MOD:decode_full(Frame)).

roundtrip_empty_state_with_value_column_test() ->
    Frame = ?MOD:encode(7, <<>>, <<"v">>, false),
    ?assertEqual({7, <<>>, <<"v">>}, ?MOD:decode_full(Frame)).

%% =============================================================================
%% Wire-format checks
%% =============================================================================

encoded_frame_no_value_column_layout_test() ->
    Frame = ?MOD:encode(42, <<"abc">>, undefined, true),
    <<2:8, 0:1, _Reserved:7, HlcLen:16/big-unsigned, _Hlc:HlcLen/binary,
        StateLen:32/big-unsigned, StateBytes:StateLen/binary>> = Frame,
    ?assertEqual(8, HlcLen),
    ?assertEqual(<<"abc">>, StateBytes).

encoded_frame_with_value_column_layout_test() ->
    Frame = ?MOD:encode(42, <<"abc">>, <<"v">>, false),
    <<2:8, 1:1, _Reserved:7, HlcLen:16/big-unsigned, _Hlc:HlcLen/binary,
        StateLen:32/big-unsigned, StateBytes:StateLen/binary,
        ValueLen:32/big-unsigned, ValueBytes:ValueLen/binary>> = Frame,
    ?assertEqual(8, HlcLen),
    ?assertEqual(<<"abc">>, StateBytes),
    ?assertEqual(<<"v">>, ValueBytes).

encoded_size_no_value_column_matches_helper_test() ->
    Body = <<"some state bytes">>,
    Frame = ?MOD:encode(1, Body, undefined, true),
    ?assertEqual(
        ?MOD:encoded_size(byte_size(Body), undefined, true),
        byte_size(Frame)
    ).

encoded_size_with_value_column_matches_helper_test() ->
    State = <<"the state">>,
    Value = <<"the value">>,
    Frame = ?MOD:encode(1, State, Value, false),
    ?assertEqual(
        ?MOD:encoded_size(byte_size(State), byte_size(Value), false),
        byte_size(Frame)
    ).

%% =============================================================================
%% extract_head/1 — HEAD wire format
%% =============================================================================

extract_head_no_value_column_returns_state_bytes_test() ->
    Frame = ?MOD:encode(42, <<"abc">>, undefined, true),
    Head = ?MOD:extract_head(Frame),
    ?assertEqual({42, <<"abc">>}, ?MOD:decode_head(Head)).

extract_head_with_value_column_returns_value_bytes_test() ->
    Frame = ?MOD:encode(42, <<"state">>, <<"value">>, false),
    Head = ?MOD:extract_head(Frame),
    ?assertEqual({42, <<"value">>}, ?MOD:decode_head(Head)).

%% =============================================================================
%% Malformed input
%% =============================================================================

decode_full_truncated_frame_raises_test() ->
    ?assertError(function_clause, ?MOD:decode_full(<<>>)),
    ?assertError(function_clause, ?MOD:decode_full(<<0:8>>)).

%% =============================================================================
%% Negative-HLC guard
%% =============================================================================

encode_rejects_negative_hlc_test() ->
    ?assertError(function_clause, ?MOD:encode(-1, <<>>, undefined, true)).
