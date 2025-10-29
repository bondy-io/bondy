-module(bondy_wamp_message_partial_SUITE).
-include("bondy_wamp.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-compile(export_all).


all() ->
    common:all().

groups() ->
    [{main, [parallel], common:tests(?MODULE)}].


init_per_suite(Config) ->
    _ = application:ensure_all_started(bondy_wamp),
    ok = bondy_wamp_config:init(),
    Config.

end_per_suite(_) ->
    ok.


%% =============================================================================
%% HELPER FUNCTIONS
%% =============================================================================

%% Helper to create a partial message via encode/decode
create_partial(Message) ->
    Bin = bondy_wamp_encoding:encode(Message, json),
    {[PartialMsg], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin),
    PartialMsg.


%% =============================================================================
%% PARTIAL ENCODING/DECODING TESTS
%% Tests that partial messages can be encoded/decoded correctly
%% Note: These tests follow the existing pattern from bondy_wamp_encoding_SUITE
%% and test the encode -> decode (partial) -> re-encode cycle
%% =============================================================================


partial_call_simple_test(_) ->
    M0 = bondy_wamp_message:call(1, #{}, <<"proc">>, [1, 2, 3], #{<<"key">> => <<"value">>}),
    Bin = bondy_wamp_encoding:encode(M0, json),

    %% Decode with partial (default behavior)
    {[M1], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin),
    ?assert(bondy_wamp_message:is_partial(M1)),
    ?assertEqual(undefined, M1#call.args),
    ?assertEqual(undefined, M1#call.kwargs),
    ?assertMatch({json, _}, bondy_wamp_message:partial(M1)),

    %% Re-encode should match original
    ReEncoded = bondy_wamp_encoding:encode(M1, json),
    ?assertEqual(Bin, ReEncoded).


partial_call_with_lists_test(_) ->
    M0 = bondy_wamp_message:call(1, #{}, <<"proc">>, [1, 2, [3, 4]], #{<<"items">> => [<<"a">>, <<"b">>]}),
    Bin = bondy_wamp_encoding:encode(M0, json),

    {[M1], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin),
    ?assert(bondy_wamp_message:is_partial(M1)),

    ReEncoded = bondy_wamp_encoding:encode(M1, json),
    ?assertEqual(Bin, ReEncoded).


partial_result_simple_test(_) ->
    M0 = bondy_wamp_message:result(1, #{}, [42, 43], #{<<"status">> => <<"ok">>}),
    Bin = bondy_wamp_encoding:encode(M0, json),

    {[M1], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin),
    ?assert(bondy_wamp_message:is_partial(M1)),
    ?assertEqual(undefined, M1#result.args),
    ?assertEqual(undefined, M1#result.kwargs),

    ReEncoded = bondy_wamp_encoding:encode(M1, json),
    ?assertEqual(Bin, ReEncoded).


partial_result_with_nested_lists_test(_) ->
    Args = [[[1, 2], [3, 4]], [[5, 6], [7, 8]]],
    M0 = bondy_wamp_message:result(1, #{}, Args, #{<<"nested">> => [[1], [2]]}),
    Bin = bondy_wamp_encoding:encode(M0, json),

    {[M1], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin),
    ?assert(bondy_wamp_message:is_partial(M1)),

    ReEncoded = bondy_wamp_encoding:encode(M1, json),
    ?assertEqual(Bin, ReEncoded).


partial_yield_simple_test(_) ->
    M0 = bondy_wamp_message:yield(1, #{}, [1, 2, 3], #{<<"done">> => true}),
    Bin = bondy_wamp_encoding:encode(M0, json),

    {[M1], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin),
    ?assert(bondy_wamp_message:is_partial(M1)),
    ?assertEqual(undefined, M1#yield.args),
    ?assertEqual(undefined, M1#yield.kwargs),

    ReEncoded = bondy_wamp_encoding:encode(M1, json),
    ?assertEqual(Bin, ReEncoded).


partial_yield_with_objects_list_test(_) ->
    Args = [#{<<"id">> => 1, <<"name">> => <<"Alice">>}, #{<<"id">> => 2, <<"name">> => <<"Bob">>}],
    M0 = bondy_wamp_message:yield(1, #{}, Args, #{<<"count">> => 2}),
    Bin = bondy_wamp_encoding:encode(M0, json),

    {[M1], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin),
    ?assert(bondy_wamp_message:is_partial(M1)),

    ReEncoded = bondy_wamp_encoding:encode(M1, json),
    ?assertEqual(Bin, ReEncoded).


partial_error_simple_test(_) ->
    M0 = bondy_wamp_message:error(?CALL, 1, #{}, <<"error.uri">>, [<<"error">>], #{<<"code">> => 500}),
    Bin = bondy_wamp_encoding:encode(M0, json),

    {[M1], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin),
    ?assert(bondy_wamp_message:is_partial(M1)),
    ?assertEqual(undefined, M1#error.args),
    ?assertEqual(undefined, M1#error.kwargs),

    ReEncoded = bondy_wamp_encoding:encode(M1, json),
    ?assertEqual(Bin, ReEncoded).


partial_error_with_lists_test(_) ->
    Args = [<<"Error">>, [<<"detail1">>, <<"detail2">>]],
    KWArgs = #{<<"trace">> => [<<"line1">>, <<"line2">>]},
    M0 = bondy_wamp_message:error(?CALL, 1, #{}, <<"error.uri">>, Args, KWArgs),
    Bin = bondy_wamp_encoding:encode(M0, json),

    {[M1], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin),
    ?assert(bondy_wamp_message:is_partial(M1)),

    ReEncoded = bondy_wamp_encoding:encode(M1, json),
    ?assertEqual(Bin, ReEncoded).


partial_invocation_simple_test(_) ->
    M0 = bondy_wamp_message:invocation(1, 2, #{}, [100, 200], #{<<"timeout">> => 5000}),
    Bin = bondy_wamp_encoding:encode(M0, json),

    {[M1], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin),
    ?assert(bondy_wamp_message:is_partial(M1)),
    ?assertEqual(undefined, M1#invocation.args),
    ?assertEqual(undefined, M1#invocation.kwargs),

    ReEncoded = bondy_wamp_encoding:encode(M1, json),
    ?assertEqual(Bin, ReEncoded).


partial_invocation_with_complex_data_test(_) ->
    Args = [[[[[1, 2]]]]],
    KWArgs = #{<<"deep">> => #{<<"nested">> => #{<<"list">> => [[[3, 4]]]}}},
    M0 = bondy_wamp_message:invocation(1, 2, #{}, Args, KWArgs),
    Bin = bondy_wamp_encoding:encode(M0, json),

    {[M1], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin),
    ?assert(bondy_wamp_message:is_partial(M1)),

    ReEncoded = bondy_wamp_encoding:encode(M1, json),
    ?assertEqual(Bin, ReEncoded).


partial_publish_simple_test(_) ->
    M0 = bondy_wamp_message:publish(1, #{}, <<"topic">>, [<<"message">>], #{<<"retain">> => true}),
    Bin = bondy_wamp_encoding:encode(M0, json),

    {[M1], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin),
    ?assert(bondy_wamp_message:is_partial(M1)),
    ?assertEqual(undefined, M1#publish.args),
    ?assertEqual(undefined, M1#publish.kwargs),

    ReEncoded = bondy_wamp_encoding:encode(M1, json),
    ?assertEqual(Bin, ReEncoded).


partial_publish_with_unicode_test(_) ->
    Args = [<<"Hello 世界"/utf8>>, <<"Привет мир"/utf8>>, <<"مرحبا"/utf8>>],
    KWArgs = #{<<"langs">> => [<<"中文"/utf8>>, <<"日本語"/utf8>>]},
    M0 = bondy_wamp_message:publish(1, #{}, <<"topic">>, Args, KWArgs),
    Bin = bondy_wamp_encoding:encode(M0, json),

    {[M1], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin),
    ?assert(bondy_wamp_message:is_partial(M1)),

    ReEncoded = bondy_wamp_encoding:encode(M1, json),
    ?assertEqual(Bin, ReEncoded).


%% =============================================================================
%% PARTIAL WITH SPECIAL DATA TYPES
%% =============================================================================


partial_with_empty_lists_test(_) ->
    Args = [[], [[]], [[], []]],
    M0 = bondy_wamp_message:call(1, #{}, <<"proc">>, Args, #{<<"empty">> => []}),
    Bin = bondy_wamp_encoding:encode(M0, json),

    {[M1], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin),
    ?assert(bondy_wamp_message:is_partial(M1)),

    ReEncoded = bondy_wamp_encoding:encode(M1, json),
    ?assertEqual(Bin, ReEncoded).


partial_with_null_values_test(_) ->
    Args = [undefined, 1, undefined, undefined, 2, undefined, 3],
    KWArgs = #{<<"sparse">> => [undefined, undefined, <<"value">>, undefined]},
    M0 = bondy_wamp_message:result(1, #{}, Args, KWArgs),
    Bin = bondy_wamp_encoding:encode(M0, json),

    {[M1], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin),
    ?assert(bondy_wamp_message:is_partial(M1)),

    ReEncoded = bondy_wamp_encoding:encode(M1, json),
    ?assertEqual(Bin, ReEncoded).


partial_with_mixed_types_test(_) ->
    Args = [42, <<"text">>, [1, 2], #{<<"nested">> => true}, undefined, false, 3.14],
    KWArgs = #{<<"mixed">> => [#{}, []]},
    M0 = bondy_wamp_message:yield(1, #{}, Args, KWArgs),
    Bin = bondy_wamp_encoding:encode(M0, json),

    {[M1], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin),
    ?assert(bondy_wamp_message:is_partial(M1)),

    ReEncoded = bondy_wamp_encoding:encode(M1, json),
    ?assertEqual(Bin, ReEncoded).


partial_with_large_list_test(_) ->
    LargeList = lists:seq(1, 100),
    M0 = bondy_wamp_message:call(1, #{}, <<"proc">>, LargeList, #{<<"count">> => 100}),
    Bin = bondy_wamp_encoding:encode(M0, json),

    {[M1], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin),
    ?assert(bondy_wamp_message:is_partial(M1)),

    ReEncoded = bondy_wamp_encoding:encode(M1, json),
    ?assertEqual(Bin, ReEncoded).


partial_with_special_json_values_test(_) ->
    Args = [true, false, undefined, 0, -1, 1.5e-10, -3.14e20],
    KWArgs = #{<<"flags">> => [true, false, undefined], <<"numbers">> => [0, -1, 1.5e-10]},
    M0 = bondy_wamp_message:error(?CALL, 1, #{}, <<"error.uri">>, Args, KWArgs),
    Bin = bondy_wamp_encoding:encode(M0, json),

    {[M1], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin),
    ?assert(bondy_wamp_message:is_partial(M1)),

    ReEncoded = bondy_wamp_encoding:encode(M1, json),
    ?assertEqual(Bin, ReEncoded).


%% =============================================================================
%% INTEGRATION TESTS - FROM FUNCTIONS
%% =============================================================================


event_from_preserves_partial_test(_) ->
    Publish = bondy_wamp_message:publish(1, #{}, <<"topic">>, [<<"data">>], #{<<"meta">> => true}),
    PublishWithPartial = create_partial(Publish),

    Event = bondy_wamp_message:event_from(PublishWithPartial, 100, 200, #{}),

    ?assert(bondy_wamp_message:is_partial(Event)),
    ?assertMatch({json, _}, bondy_wamp_message:partial(Event)).


invocation_from_preserves_partial_test(_) ->
    Call = bondy_wamp_message:call(1, #{}, <<"proc">>, [1, 2, 3], #{<<"opt">> => true}),
    CallWithPartial = create_partial(Call),

    Invocation = bondy_wamp_message:invocation_from(CallWithPartial, 100, 200, #{}),

    ?assert(bondy_wamp_message:is_partial(Invocation)),
    ?assertMatch({json, _}, bondy_wamp_message:partial(Invocation)).


result_from_preserves_partial_test(_) ->
    Yield = bondy_wamp_message:yield(1, #{}, [42], #{<<"status">> => <<"ok">>}),
    YieldWithPartial = create_partial(Yield),

    Result = bondy_wamp_message:result_from(YieldWithPartial, 100, #{}),

    ?assert(bondy_wamp_message:is_partial(Result)),
    ?assertMatch({json, _}, bondy_wamp_message:partial(Result)).


%% =============================================================================
%% FULL DISABLE MODE (NO PARTIAL)
%% =============================================================================


no_partial_call_test(_) ->
    M0 = bondy_wamp_message:call(1, #{}, <<"proc">>, [1, 2, 3], #{<<"key">> => <<"value">>}),
    Bin = bondy_wamp_encoding:encode(M0, json),

    %% Decode with partial_decode disabled
    {[M1], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin, #{partial_decode => false}),
    ?assertNot(bondy_wamp_message:is_partial(M1)),
    ?assertEqual([1, 2, 3], M1#call.args),
    ?assertEqual(#{<<"key">> => <<"value">>}, M1#call.kwargs).


no_partial_with_lists_test(_) ->
    Args = [[[1, 2], [3, 4]]],
    KWArgs = #{<<"items">> => [1, 2, 3], <<"tags">> => [<<"a">>, <<"b">>]},
    M0 = bondy_wamp_message:result(1, #{}, Args, KWArgs),
    Bin = bondy_wamp_encoding:encode(M0, json),

    {[M1], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin, #{partial_decode => false}),
    ?assertNot(bondy_wamp_message:is_partial(M1)),
    ?assertEqual(Args, M1#result.args),
    ?assertEqual(KWArgs, M1#result.kwargs).
