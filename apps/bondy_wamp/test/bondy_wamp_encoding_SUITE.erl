-module(bondy_wamp_encoding_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("bondy_wamp.hrl").
-compile(export_all).



all() ->
    common:all().

groups() ->
    [{main, [parallel], common:tests(?MODULE)}].




%% =============================================================================
%% JSON
%% =============================================================================


init_per_suite(Config) ->
    _ = application:ensure_all_started(bondy_wamp),
    ok = bondy_wamp_config:init(),
    Config.

end_per_suite(_) ->
    ok.


hello_json_test(_) ->
    M = bondy_wamp_message:hello(<<"realm1">>, #{
        <<"roles">> => #{
            <<"caller">> => #{}
        }}),
    Bin = bondy_wamp_encoding:encode(M, json),

    ?assertEqual(
        hello,
        bondy_wamp_encoding:decode_message_name({ws, text, json}, Bin)
    ),
    ?assertMatch(
        {[M], <<>>},
        bondy_wamp_encoding:decode({ws, text, json}, Bin)
    ).

welcome_json_test(_) ->
    M = bondy_wamp_message:welcome(1, #{
        <<"realm">> => <<"realm1">>,
        <<"authid">> => <<"foo">>,
        <<"authrole">> => <<"default">>,
        <<"roles">> => #{
            <<"dealer">> => #{},
            <<"broker">> => #{}
        }}),
    Bin = bondy_wamp_encoding:encode(M, json),
    welcome = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

abort_json_test(_) ->
    M = bondy_wamp_message:abort(#{<<"message">> => <<"foo">>}, <<"wamp.error.foo">>),
    Bin = bondy_wamp_encoding:encode(M, json),
    abort = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

challenge_json_test(_) ->
    M = bondy_wamp_message:challenge(<<"foo">>, #{}),
    Bin = bondy_wamp_encoding:encode(M, json),
    challenge = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

authenticate_json_test(_) ->
    M = bondy_wamp_message:authenticate(<<"foo">>, #{}),
    Bin = bondy_wamp_encoding:encode(M, json),
    authenticate = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

goodbye_json_test(_) ->
    M = bondy_wamp_message:goodbye(
        #{<<"message">> => <<"The host is shutting down now.">>},
        <<"wamp.error.system_shutdown">>
    ),
    Bin = bondy_wamp_encoding:encode(M, json),
    ?assertEqual(
        goodbye,
        bondy_wamp_encoding:decode_message_name(
            {ws, text, json}, Bin
        )
    ),
    ?assertMatch(
        {[M], <<>>},
        bondy_wamp_encoding:decode({ws, text, json}, Bin)
    ).


error_json_test(_) ->
    M = bondy_wamp_message:error(0, 1, #{}, <<"wamp.error.foo">>),
    Bin = bondy_wamp_encoding:encode(M, json),
    error = bondy_wamp_encoding:decode_message_name({ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

error_json_2_test(_) ->
    M = bondy_wamp_message:error(0, 1, #{}, <<"wamp.error.foo">>, []),
    Bin = bondy_wamp_encoding:encode(M, json),
    error = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

error_json_3_test(_) ->
    M = bondy_wamp_message:error(0, 1, #{}, <<"wamp.error.foo">>, [], #{}),Bin = bondy_wamp_encoding:encode(M, json),
    error = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

publish_json_test(_) ->
    M = bondy_wamp_message:publish(1, #{}, <<"com.leapsight.topic1">>),
    Bin = bondy_wamp_encoding:encode(M, json),
    publish = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

publish_json_2_test(_) ->
    M = bondy_wamp_message:publish(1, #{}, <<"com.leapsight.topic1">>),
    Bin = bondy_wamp_encoding:encode(M, json),
    publish = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

publish_json_3_test(_) ->
    M = bondy_wamp_message:publish(1, #{}, <<"com.leapsight.topic1">>, [], #{}),
    Bin = bondy_wamp_encoding:encode(M, json),
    publish = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

published_json_test(_) ->
    M = bondy_wamp_message:published(1, 2),
    Bin = bondy_wamp_encoding:encode(M, json),
    published = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

subscribe_json_test(_) ->
    M = bondy_wamp_message:subscribe(1, #{}, <<"com.leapsight.topic1">>),
    Bin = bondy_wamp_encoding:encode(M, json),
    subscribe = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

subscribed_json_test(_) ->
    M = bondy_wamp_message:subscribed(1, 3),
    Bin = bondy_wamp_encoding:encode(M, json),
    subscribed = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

unsubscribe_json_test(_) ->
    M = bondy_wamp_message:unsubscribe(1, 3),
    Bin = bondy_wamp_encoding:encode(M, json),
    unsubscribe = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

unsubscribed_json_test(_) ->
    M = bondy_wamp_message:unsubscribed(1),
    Bin = bondy_wamp_encoding:encode(M, json),
    unsubscribed = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

event_json_test(_) ->
    M = bondy_wamp_message:event(3, 2, #{}),
    Bin = bondy_wamp_encoding:encode(M, json),
    event = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

event_json_2_test(_) ->
    M = bondy_wamp_message:event(3, 2, #{}, []),
    Bin = bondy_wamp_encoding:encode(M, json),
    event = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

event_json_3_test(_) ->
    M = bondy_wamp_message:event(3, 2, #{}, [], #{}),
    Bin = bondy_wamp_encoding:encode(M, json),
    event = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

call_json_test(_) ->
    M = bondy_wamp_message:call(1, #{}, <<"com.leapsight.myprocedure1">>),
    Bin = bondy_wamp_encoding:encode(M, json),
    call = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

call_json_2_test(_) ->
    M = bondy_wamp_message:call(1, #{}, <<"com.leapsight.myprocedure1">>, []),
    Bin = bondy_wamp_encoding:encode(M, json),
    call = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

call_json_3_test(_) ->
    M = bondy_wamp_message:call(1, #{}, <<"com.leapsight.myprocedure1">>, [], #{}),
    Bin = bondy_wamp_encoding:encode(M, json),
    call = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

call_json_4_test(_) ->
    M0 = bondy_wamp_message:call(
        1, #{}, <<"foo">>,
        [#{bar => pid_to_list(self())}],
        #{baz => [#{1 => 2}]}
    ),
    Bin = bondy_wamp_encoding:encode(M0, json),
    call = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M1], <<>>} = bondy_wamp_encoding:decode(
        {ws, text, json}, Bin, #{partial_decode => false}
    ),
    ?assertMatch(
        {call, 1, _, <<"foo">>,
            [#{<<"bar">> := _}],
            #{<<"baz">> := [#{<<"1">> := 2}]},
            undefined
        },
        M1
    ),
    {[M2], <<>>} = bondy_wamp_encoding:decode(
        {ws, text, json}, Bin, #{partial_decode => true}
    ),
    ?assertMatch(
        {call, 1, _, <<"foo">>, undefined, undefined, {json, _}},
        M2
    ),
    ?assertEqual(
        bondy_wamp_encoding:encode(M1, json),
        bondy_wamp_encoding:encode(M2, json)
    ).

cancel_json_test(_) ->
    M = bondy_wamp_message:cancel(1, #{}),
    Bin = bondy_wamp_encoding:encode(M, json),
    cancel = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

result_json_test(_) ->
    M = bondy_wamp_message:result(1, #{}),
    Bin = bondy_wamp_encoding:encode(M, json),
    result = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

result_json_2_test(_) ->
    M = bondy_wamp_message:result(1, #{}, []),
    Bin = bondy_wamp_encoding:encode(M, json),
    result = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

result_json_3_test(_) ->
    M = bondy_wamp_message:result(1, #{}, [], #{}),
    Bin = bondy_wamp_encoding:encode(M, json),
    result = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

register_json_test(_) ->
    M = bondy_wamp_message:register(1, #{}, <<"com.leapsight.myprocedure1">>),
    Bin = bondy_wamp_encoding:encode(M, json),
    register = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

registered_json_2_test(_) ->
    M = bondy_wamp_message:registered(1, 4),
    Bin = bondy_wamp_encoding:encode(M, json),
    registered = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

unregister_json_3_test(_) ->
    M = bondy_wamp_message:unregister(1, 4),
    Bin = bondy_wamp_encoding:encode(M, json),
    unregister = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

unregistered_json_test(_) ->
    M = bondy_wamp_message:unregistered(1),
    Bin = bondy_wamp_encoding:encode(M, json),
    unregistered = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

invocation_json_test(_) ->
    M = bondy_wamp_message:invocation(1, 4, #{}),
    Bin = bondy_wamp_encoding:encode(M, json),
    invocation = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

invocation_json_2_test(_) ->
    M = bondy_wamp_message:invocation(1, 4, #{}, []),
    Bin = bondy_wamp_encoding:encode(M, json),
    invocation = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

invocation_json_3_test(_) ->
    M = bondy_wamp_message:invocation(1, 4, #{}, [], #{}),
    Bin = bondy_wamp_encoding:encode(M, json),
    invocation = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

interrupt_json_test(_) ->
    M = bondy_wamp_message:interrupt(1, #{}),
    Bin = bondy_wamp_encoding:encode(M, json),
    interrupt = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

yield_json_test(_) ->
    M = bondy_wamp_message:yield(1, #{}),
    Bin = bondy_wamp_encoding:encode(M, json),
    yield = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

yield_json_2_test(_) ->
    M = bondy_wamp_message:yield(1, #{}, []),
    Bin = bondy_wamp_encoding:encode(M, json),
    yield = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).

yield_json_3_test(_) ->
    M = bondy_wamp_message:yield(1, #{}, [], #{}),
    Bin = bondy_wamp_encoding:encode(M, json),
    yield = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin).



%% =============================================================================
%% MSGPACK
%% =============================================================================




hello_msgpack_test(_) ->
    M = bondy_wamp_message:hello(<<"realm1">>, #{
        <<"roles">> => #{
            <<"caller">> => #{}
        }}),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    hello = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode(
        {ws, binary, msgpack}, Bin).

welcome_msgpack_test(_) ->
    M = bondy_wamp_message:welcome(1, #{
        <<"realm">> => <<"realm1">>,
        <<"authid">> => <<"foo">>,
        <<"authrole">> => <<"default">>,
        <<"roles">> => #{
            <<"dealer">> => #{},
            <<"broker">> => #{}
        }}),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    welcome = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

abort_msgpack_test(_) ->
    M = bondy_wamp_message:abort(#{<<"message">> => <<"foo">>}, <<"wamp.error.foo">>),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    abort = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

challenge_msgpack_test(_) ->
    M = bondy_wamp_message:challenge(<<"foo">>, #{}),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    challenge = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

authenticate_msgpack_test(_) ->
    M = bondy_wamp_message:authenticate(<<"foo">>, #{}),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    authenticate = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

goodbye_msgpack_test(_) ->
    M = bondy_wamp_message:goodbye(
        #{<<"message">> => <<"The host is shutting down now.">>},
        <<"wamp.error.system_shutdown">>
    ),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    goodbye = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).


error_msgpack_test(_) ->
    M = bondy_wamp_message:error(0, 1, #{}, <<"wamp.error.foo">>),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    error = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

error_msgpack_2_test(_) ->
    M = bondy_wamp_message:error(0, 1, #{}, <<"wamp.error.foo">>, []),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    error = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

error_msgpack_3_test(_) ->
    M = bondy_wamp_message:error(0, 1, #{}, <<"wamp.error.foo">>, [], #{}),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    error = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

publish_msgpack_test(_) ->
    M = bondy_wamp_message:publish(1, #{}, <<"com.leapsight.topic1">>),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    publish = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

publish_msgpack_2_test(_) ->
    M = bondy_wamp_message:publish(1, #{}, <<"com.leapsight.topic1">>, []),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    publish = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

publish_msgpack_3_test(_) ->
    M = bondy_wamp_message:publish(1, #{}, <<"com.leapsight.topic1">>, [], #{}),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    publish = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

published_msgpack_test(_) ->
    M = bondy_wamp_message:published(1, 2),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    published = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

subscribe_msgpack_test(_) ->
    M = bondy_wamp_message:subscribe(1, #{}, <<"com.leapsight.topic1">>),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    subscribe = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

subscribed_msgpack_test(_) ->
    M = bondy_wamp_message:subscribed(1, 3),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    subscribed = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

unsubscribe_msgpack_test(_) ->
    M = bondy_wamp_message:unsubscribe(1, 3),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    unsubscribe = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

unsubscribed_msgpack_test(_) ->
    M = bondy_wamp_message:unsubscribed(1),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    unsubscribed = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

event_msgpack_test(_) ->
    M = bondy_wamp_message:event(3, 2, #{}),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    event = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

event_msgpack_2_test(_) ->
    M = bondy_wamp_message:event(3, 2, #{}, []),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    event = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

event_msgpack_3_test(_) ->
    M = bondy_wamp_message:event(3, 2, #{}, [], #{}),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    event = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

call_msgpack_test(_) ->
    M = bondy_wamp_message:call(1, #{}, <<"com.leapsight.myprocedure1">>),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    call = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

call_msgpack_2_test(_) ->
    M = bondy_wamp_message:call(1, #{}, <<"com.leapsight.myprocedure1">>, []),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    call = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

call_msgpack_3_test(_) ->
    M = bondy_wamp_message:call(1, #{}, <<"com.leapsight.myprocedure1">>, [], #{}),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    call = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

cancel_msgpack_test(_) ->
    M = bondy_wamp_message:cancel(1, #{}),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    cancel = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

result_msgpack_test(_) ->
    M = bondy_wamp_message:result(1, #{}),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    result = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

result_msgpack_2_test(_) ->
    M = bondy_wamp_message:result(1, #{}, []),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    result = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

result_msgpack_3_test(_) ->
    M = bondy_wamp_message:result(1, #{}, [], #{}),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    result = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

register_msgpack_test(_) ->
    M = bondy_wamp_message:register(1, #{}, <<"com.leapsight.myprocedure1">>),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    register = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

registered_msgpack_2_test(_) ->
    M = bondy_wamp_message:registered(1, 4),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    registered = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

unregister_msgpack_3_test(_) ->
    M = bondy_wamp_message:unregister(1, 4),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    unregister = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

unregistered_msgpack_test(_) ->
    M = bondy_wamp_message:unregistered(1),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    unregistered = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

invocation_msgpack_test(_) ->
    M = bondy_wamp_message:invocation(1, 4, #{}),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    invocation = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

invocation_msgpack_2_test(_) ->
    M = bondy_wamp_message:invocation(1, 4, #{}, []),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    invocation = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

invocation_msgpack_3_test(_) ->
    M = bondy_wamp_message:invocation(1, 4, #{}, [], #{}),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    invocation = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

interrupt_msgpack_test(_) ->
    M = bondy_wamp_message:interrupt(1, #{}),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    interrupt = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

yield_msgpack_test(_) ->
    M = bondy_wamp_message:yield(1, #{}),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    yield = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

yield_msgpack_2_test(_) ->
    M = bondy_wamp_message:yield(1, #{}, []),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    yield = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).

yield_msgpack_3_test(_) ->
    M = bondy_wamp_message:yield(1, #{}, [], #{}),
    Bin = bondy_wamp_encoding:encode(M, msgpack),
    yield = bondy_wamp_encoding:decode_message_name(
        {ws, binary, msgpack}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin).



%% =============================================================================
%% BERT
%% =============================================================================




hello_bert_test(_) ->
    M = bondy_wamp_message:hello(<<"realm1">>, #{
        <<"roles">> => #{
            <<"caller">> => #{}
        }}),
    {[M], <<>>} = bondy_wamp_encoding:decode(
        {ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

welcome_bert_test(_) ->
    M = bondy_wamp_message:welcome(1, #{
        <<"realm">> => <<"realm1">>,
        <<"authid">> => <<"foo">>,
        <<"authrole">> => <<"default">>,
        <<"roles">> => #{
            <<"dealer">> => #{},
            <<"broker">> => #{}
        }}),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

abort_bert_test(_) ->
    M = bondy_wamp_message:abort(#{<<"message">> => <<"foo">>}, <<"wamp.error.foo">>),
    ?assertMatch(
        {[M], <<>>},
        bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert))
    ).

challenge_bert_test(_) ->
    M = bondy_wamp_message:challenge(<<"foo">>, #{}),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

authenticate_bert_test(_) ->
    M = bondy_wamp_message:authenticate(<<"foo">>, #{}),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

goodbye_bert_test(_) ->
    M = bondy_wamp_message:goodbye(
        #{<<"message">> => <<"The host is shutting down now.">>},
        <<"wamp.error.system_shutdown">>
    ),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).


error_bert_test(_) ->
    M = bondy_wamp_message:error(0, 1, #{}, <<"wamp.error.foo">>),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

error_bert_2_test(_) ->
    M = bondy_wamp_message:error(0, 1, #{}, <<"wamp.error.foo">>, []),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

error_bert_3_test(_) ->
    M = bondy_wamp_message:error(0, 1, #{}, <<"wamp.error.foo">>, [], #{}),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

publish_bert_test(_) ->
    M = bondy_wamp_message:publish(1, #{}, <<"com.leapsight.topic1">>),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

publish_bert_2_test(_) ->
    M = bondy_wamp_message:publish(1, #{}, <<"com.leapsight.topic1">>, []),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

publish_bert_3_test(_) ->
    M = bondy_wamp_message:publish(1, #{}, <<"com.leapsight.topic1">>, [], #{}),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

published_bert_test(_) ->
    M = bondy_wamp_message:published(1, 2),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

subscribe_bert_test(_) ->
    M = bondy_wamp_message:subscribe(1, #{}, <<"com.leapsight.topic1">>),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

subscribed_bert_test(_) ->
    M = bondy_wamp_message:subscribed(1, 3),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

unsubscribe_bert_test(_) ->
    M = bondy_wamp_message:unsubscribe(1, 3),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

unsubscribed_bert_test(_) ->
    M = bondy_wamp_message:unsubscribed(1),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

event_bert_test(_) ->
    M = bondy_wamp_message:event(3, 2, #{}),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

event_bert_2_test(_) ->
    M = bondy_wamp_message:event(3, 2, #{}, []),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

event_bert_3_test(_) ->
    M = bondy_wamp_message:event(3, 2, #{}, [], #{}),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

call_bert_test(_) ->
    M = bondy_wamp_message:call(1, #{}, <<"com.leapsight.myprocedure1">>),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

call_bert_2_test(_) ->
    M = bondy_wamp_message:call(1, #{}, <<"com.leapsight.myprocedure1">>, []),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

call_bert_3_test(_) ->
    M = bondy_wamp_message:call(1, #{}, <<"com.leapsight.myprocedure1">>, [], #{}),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

cancel_bert_test(_) ->
    M = bondy_wamp_message:cancel(1, #{}),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

result_bert_test(_) ->
    M = bondy_wamp_message:result(1, #{}),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

result_bert_2_test(_) ->
    M = bondy_wamp_message:result(1, #{}, []),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

result_bert_3_test(_) ->
    M = bondy_wamp_message:result(1, #{}, [], #{}),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

result_bert_4_test(_) ->
    M = bondy_wamp_message:result(1, #{}, [true], #{}),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

result_bert_5_test(_) ->
    M = bondy_wamp_message:result(1, #{}, [false], #{}),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

result_bert_6_test(_) ->
    M = bondy_wamp_message:result(1, #{}, [undefined], #{}),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

result_bert_7_test(_) ->
    M = bondy_wamp_message:result(1, #{}, [#{foo => true, bar => baz}], #{}),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

register_bert_test(_) ->
    M = bondy_wamp_message:register(1, #{}, <<"com.leapsight.myprocedure1">>),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

registered_bert_2_test(_) ->
    M = bondy_wamp_message:registered(1, 4),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

unregister_bert_3_test(_) ->
    M = bondy_wamp_message:unregister(1, 4),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

unregistered_bert_test(_) ->
    M = bondy_wamp_message:unregistered(1),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

invocation_bert_test(_) ->
    M = bondy_wamp_message:invocation(1, 4, #{}),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

invocation_bert_2_test(_) ->
    M = bondy_wamp_message:invocation(1, 4, #{}, []),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

invocation_bert_3_test(_) ->
    M = bondy_wamp_message:invocation(1, 4, #{}, [], #{}),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

interrupt_bert_test(_) ->
    M = bondy_wamp_message:interrupt(1, #{}),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

yield_bert_test(_) ->
    M = bondy_wamp_message:yield(1, #{}),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

yield_bert_2_test(_) ->
    M = bondy_wamp_message:yield(1, #{}, []),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

yield_bert_3_test(_) ->
    M = bondy_wamp_message:yield(1, #{}, [], #{}),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, bondy_wamp_encoding:encode(M, bert)).

%% =============================================================================
%% ERL
%% =============================================================================


hello_erl_test(_) ->
    M = bondy_wamp_message:hello(<<"realm1">>, #{
        <<"roles">> => #{
            <<"caller">> => #{}
        }}),
    Bin = bondy_wamp_encoding:encode(M, erl),
    hello = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

welcome_erl_test(_) ->
    M = bondy_wamp_message:welcome(1, #{
        <<"realm">> => <<"realm1">>,
        <<"authid">> => <<"foo">>,
        <<"authrole">> => <<"default">>,
        <<"roles">> => #{
            <<"dealer">> => #{},
            <<"broker">> => #{}
        }}),
    Bin = bondy_wamp_encoding:encode(M, erl),
    welcome = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

welcome_erl_test_2(_) ->
    M = bondy_wamp_message:welcome(1, #{
        roles => #{
            dealer => #{},
            broker => #{}
        }}),
    Bin = bondy_wamp_encoding:encode(M, erl),
    welcome = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

abort_erl_test(_) ->
    M = bondy_wamp_message:abort(#{<<"message">> => <<"foo">>}, <<"wamp.error.foo">>),
    Bin = bondy_wamp_encoding:encode(M, erl),
    abort = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

challenge_erl_test(_) ->
    M = bondy_wamp_message:challenge(<<"foo">>, #{}),
    Bin = bondy_wamp_encoding:encode(M, erl),
    challenge = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

authenticate_erl_test(_) ->
    M = bondy_wamp_message:authenticate(<<"foo">>, #{}),
    Bin = bondy_wamp_encoding:encode(M, erl),
    authenticate = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

goodbye_erl_test(_) ->
    M = bondy_wamp_message:goodbye(
        #{<<"message">> => <<"The host is shutting down now.">>},
        <<"wamp.error.system_shutdown">>
    ),
    Bin = bondy_wamp_encoding:encode(M, erl),
    goodbye = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).


error_erl_test(_) ->
    M = bondy_wamp_message:error(0, 1, #{}, <<"wamp.error.foo">>),
    Bin = bondy_wamp_encoding:encode(M, erl),
    error = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

error_erl_2_test(_) ->
    M = bondy_wamp_message:error(0, 1, #{}, <<"wamp.error.foo">>, []),
    Bin = bondy_wamp_encoding:encode(M, erl),
    error = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

error_erl_3_test(_) ->
    M = bondy_wamp_message:error(0, 1, #{}, <<"wamp.error.foo">>, [], #{}),
    Bin = bondy_wamp_encoding:encode(M, erl),
    error = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

publish_erl_test(_) ->
    M = bondy_wamp_message:publish(1, #{}, <<"com.leapsight.topic1">>),
    Bin = bondy_wamp_encoding:encode(M, erl),
    publish = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

publish_erl_2_test(_) ->
    M = bondy_wamp_message:publish(1, #{}, <<"com.leapsight.topic1">>, []),
    Bin = bondy_wamp_encoding:encode(M, erl),
    publish = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

publish_erl_3_test(_) ->
    M = bondy_wamp_message:publish(1, #{}, <<"com.leapsight.topic1">>, [], #{}),
    Bin = bondy_wamp_encoding:encode(M, erl),
    publish = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

published_erl_test(_) ->
    M = bondy_wamp_message:published(1, 2),
    Bin = bondy_wamp_encoding:encode(M, erl),
    published = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

subscribe_erl_test(_) ->
    M = bondy_wamp_message:subscribe(1, #{}, <<"com.leapsight.topic1">>),
    Bin = bondy_wamp_encoding:encode(M, erl),
    subscribe = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

subscribed_erl_test(_) ->
    M = bondy_wamp_message:subscribed(1, 3),
    Bin = bondy_wamp_encoding:encode(M, erl),
    subscribed = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

unsubscribe_erl_test(_) ->
    M = bondy_wamp_message:unsubscribe(1, 3),
    Bin = bondy_wamp_encoding:encode(M, erl),
    unsubscribe = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

unsubscribed_erl_test(_) ->
    M = bondy_wamp_message:unsubscribed(1),
    Bin = bondy_wamp_encoding:encode(M, erl),
    unsubscribed = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

event_erl_test(_) ->
    M = bondy_wamp_message:event(3, 2, #{}),
    Bin = bondy_wamp_encoding:encode(M, erl),
    event = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

event_erl_2_test(_) ->
    M = bondy_wamp_message:event(3, 2, #{}, []),
    Bin = bondy_wamp_encoding:encode(M, erl),
    event = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

event_erl_3_test(_) ->
    M = bondy_wamp_message:event(3, 2, #{}, [], #{}),
    Bin = bondy_wamp_encoding:encode(M, erl),
    event = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

call_erl_test(_) ->
    M = bondy_wamp_message:call(1, #{}, <<"com.leapsight.myprocedure1">>),
    Bin = bondy_wamp_encoding:encode(M, erl),
    call = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

call_erl_2_test(_) ->
    M = bondy_wamp_message:call(1, #{}, <<"com.leapsight.myprocedure1">>, []),
    Bin = bondy_wamp_encoding:encode(M, erl),
    call = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

call_erl_3_test(_) ->
    M = bondy_wamp_message:call(1, #{}, <<"com.leapsight.myprocedure1">>, [], #{}),
    Bin = bondy_wamp_encoding:encode(M, erl),
    call = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

call_erl_4_test(_) ->
    Args = [
        [{bar, self()}]
    ],
    M0 = bondy_wamp_message:call(1, #{}, <<"foo">>, Args, #{}),
    Bin = bondy_wamp_encoding:encode(M0, erl),
    call = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M1], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin),
    ?assertMatch(
        {call, 1, _, <<"foo">>, [#{<<"bar">> := _}],
        undefined, undefined},
        M1
    ).

cancel_erl_test(_) ->
    M = bondy_wamp_message:cancel(1, #{}),
    Bin = bondy_wamp_encoding:encode(M, erl),
    cancel = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

result_erl_test(_) ->
    M = bondy_wamp_message:result(1, #{}),
    Bin = bondy_wamp_encoding:encode(M, erl),
    result = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

result_erl_2_test(_) ->
    M = bondy_wamp_message:result(1, #{}, []),
    Bin = bondy_wamp_encoding:encode(M, erl),
    result = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

result_erl_3_test(_) ->
    M = bondy_wamp_message:result(1, #{}, [], #{}),
    Bin = bondy_wamp_encoding:encode(M, erl),
    result = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).


result_erl_4_test(_) ->
    Arg = #{
        a => undefined,
        b => true,
        c => false,
        d => hello,
        e => #{
            a => undefined,
            b => true,
            c => false,
            d => hello,
            e => #{
                a => undefined,
                b => true,
                c => false,
                d => hello
            }
        }
    },
    M = bondy_wamp_message:result(1, #{}, [Arg], #{}),
    Bin = bondy_wamp_encoding:encode(M, erl),
    ExpectedArg = #{
        <<"a">> => undefined,
        <<"b">> => true,
        <<"c">> => false,
        <<"d">> => <<"hello">>,
        <<"e">> => #{
            <<"a">> => undefined,
            <<"b">> => true,
            <<"c">> => false,
            <<"d">> => <<"hello">>,
            <<"e">> => #{
                <<"a">> => undefined,
                <<"b">> => true,
                <<"c">> => false,
                <<"d">> => <<"hello">>
            }
        }
    },
    {[{result, 1, #{}, [ResultArg], undefined, undefined}], <<>>} = bondy_wamp_encoding:decode(
        {ws, binary, erl}, Bin
    ),

    ?assertEqual(
        ExpectedArg,
        ResultArg
    ).

register_erl_test(_) ->
    M = bondy_wamp_message:register(1, #{}, <<"com.leapsight.myprocedure1">>),
    Bin = bondy_wamp_encoding:encode(M, erl),
    register = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

registered_erl_2_test(_) ->
    M = bondy_wamp_message:registered(1, 4),
    Bin = bondy_wamp_encoding:encode(M, erl),
    registered = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

unregister_erl_3_test(_) ->
    M = bondy_wamp_message:unregister(1, 4),
    Bin = bondy_wamp_encoding:encode(M, erl),
    unregister = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

unregistered_erl_test(_) ->
    M = bondy_wamp_message:unregistered(1),
    Bin = bondy_wamp_encoding:encode(M, erl),
    unregistered = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

invocation_erl_test(_) ->
    M = bondy_wamp_message:invocation(1, 4, #{}),
    Bin = bondy_wamp_encoding:encode(M, erl),
    invocation = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

invocation_erl_2_test(_) ->
    M = bondy_wamp_message:invocation(1, 4, #{}, []),
    Bin = bondy_wamp_encoding:encode(M, erl),
    invocation = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

invocation_erl_3_test(_) ->
    M = bondy_wamp_message:invocation(1, 4, #{}, [], #{}),
    Bin = bondy_wamp_encoding:encode(M, erl),
    invocation = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

interrupt_erl_test(_) ->
    M = bondy_wamp_message:interrupt(1, #{}),
    Bin = bondy_wamp_encoding:encode(M, erl),
    interrupt = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

yield_erl_test(_) ->
    M = bondy_wamp_message:yield(1, #{}),
    Bin = bondy_wamp_encoding:encode(M, erl),
    yield = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

yield_erl_2_test(_) ->
    M = bondy_wamp_message:yield(1, #{}, []),
    Bin = bondy_wamp_encoding:encode(M, erl),
    yield = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).

yield_erl_3_test(_) ->
    M = bondy_wamp_message:yield(1, #{}, [], #{}),
    Bin = bondy_wamp_encoding:encode(M, erl),
    yield = bondy_wamp_encoding:decode_message_name(
        {ws, binary, erl}, Bin),
    {[M], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, Bin).



%% =============================================================================
%% EXTENSION KEYS VALIDATION
%% =============================================================================


validate_extension_key_1_test(_) ->
    Keys = [
        '_xyz1',
        '_xyz2',
        '_xyz3',
        %% This should be ignored
        '_foo',
        'bar'
    ],
    Allowed =[{yield, Keys}],
    ok = app_config:set(wamp, extended_options, Allowed),
    Keys = app_config:get(wamp, [extended_options, yield]),

    Expected = #{
        '_xyz1' => 1,
        '_xyz2' => 2,
        '_xyz3' => 3
    },
    Opts = #{
        <<"_xyz1">> => 1,
        <<"_xyz2">> => 2,
        <<"_xyz3">> => 3,
        %% This should be removed
        <<"foo">> => 1,
        <<"_bar">> => 1,
        <<"_x">> => 1
    },

    M1 = bondy_wamp_message:yield(1, Opts),
    ?assertEqual(Expected, bondy_wamp_message:options(M1)),

    M2 = bondy_wamp_message:cancel(1, Opts),
    ?assertEqual(maps:new(), bondy_wamp_message:options(M2)).


%% =============================================================================
%% is_encoding/1 TESTS
%% =============================================================================

is_encoding_test(_) ->
    %% Valid encodings
    ?assert(bondy_wamp_encoding:is_encoding(bert)),
    ?assert(bondy_wamp_encoding:is_encoding(erl)),
    ?assert(bondy_wamp_encoding:is_encoding(json)),
    ?assert(bondy_wamp_encoding:is_encoding(msgpack)),

    %% Invalid encodings
    ?assertNot(bondy_wamp_encoding:is_encoding(xml)),
    ?assertNot(bondy_wamp_encoding:is_encoding(foo)),
    ?assertNot(bondy_wamp_encoding:is_encoding(undefined)),
    ?assertNot(bondy_wamp_encoding:is_encoding(<<>>)),
    ?assertNot(bondy_wamp_encoding:is_encoding(123)).


%% =============================================================================
%% pack/unpack TESTS
%% =============================================================================

pack_unpack_optionals_test(_) ->
    %% Test with undefined args and kwargs (should omit both)
    M1 = bondy_wamp_message:call(1, #{}, <<"proc">>),
    Packed1 = bondy_wamp_encoding:pack(M1),
    ?assertEqual(4, length(Packed1)),  %% [TYPE, ReqId, Options, ProcUri]
    ?assertEqual(M1, bondy_wamp_encoding:unpack(Packed1)),

    %% Test with empty args list (should omit both)
    M2 = bondy_wamp_message:call(1, #{}, <<"proc">>, []),
    Packed2 = bondy_wamp_encoding:pack(M2),
    ?assertEqual(4, length(Packed2)),  %% Empty args should be omitted
    Unpacked2 = bondy_wamp_encoding:unpack(Packed2),
    ?assertEqual(undefined, Unpacked2#call.args),

    %% Test with empty kwargs map (should omit both)
    M3 = bondy_wamp_message:call(1, #{}, <<"proc">>, [1, 2], #{}),
    Packed3 = bondy_wamp_encoding:pack(M3),
    ?assertEqual(5, length(Packed3)),  %% [TYPE, ReqId, Options, ProcUri, Args]
    Unpacked3 = bondy_wamp_encoding:unpack(Packed3),
    ?assertEqual([1, 2], Unpacked3#call.args),
    ?assertEqual(undefined, Unpacked3#call.kwargs),

    %% Test with only kwargs (should include empty args list)
    M4 = bondy_wamp_message:call(1, #{}, <<"proc">>, undefined, #{<<"key">> => <<"val">>}),
    Packed4 = bondy_wamp_encoding:pack(M4),
    ?assertEqual(
        6,
        length(Packed4)
    ),  %% [TYPE, ReqId, Options, ProcUri, [], KWArgs]
    Unpacked4 = bondy_wamp_encoding:unpack(Packed4),
    %% When kwargs is present, args defaults to empty list
    ?assert(
        Unpacked4#call.args =:= [] orelse Unpacked4#call.args =:= undefined
    ),
    ?assertEqual(#{<<"key">> => <<"val">>}, Unpacked4#call.kwargs),

    %% Test with both args and kwargs
    M5 = bondy_wamp_message:call(1, #{}, <<"proc">>, [1], #{<<"key">> => <<"val">>}),
    Packed5 = bondy_wamp_encoding:pack(M5),
    ?assertEqual(
        6,
        length(Packed5)
    ),  %% [TYPE, ReqId, Options, ProcUri, Args, KWArgs]
    ?assertEqual(M5, bondy_wamp_encoding:unpack(Packed5)).


unpack_invalid_message_test(_) ->
    %% Invalid message should error
    ?assertError({invalid_message, _}, bondy_wamp_encoding:unpack([999, 1, #{}])),
    ?assertError({invalid_message, _}, bondy_wamp_encoding:unpack(invalid)),
    ?assertError({invalid_message, _}, bondy_wamp_encoding:unpack([])).


unregistered_with_details_test(_) ->
    %% Unregistered without details
    M1 = bondy_wamp_message:unregistered(123),
    Packed1 = bondy_wamp_encoding:pack(M1),
    ?assertEqual(2, length(Packed1)),  %% [TYPE, ReqId]
    ?assertEqual(M1, bondy_wamp_encoding:unpack(Packed1)),

    %% Unregistered with details
    M2 = bondy_wamp_message:unregistered(123, #{<<"reason">> => <<"test">>}),
    Packed2 = bondy_wamp_encoding:pack(M2),
    ?assertEqual(3, length(Packed2)),  %% [TYPE, ReqId, Details]
    ?assertEqual(M2, bondy_wamp_encoding:unpack(Packed2)).


%% =============================================================================
%% message_name/1 TESTS
%% =============================================================================

message_name_test(_) ->
    %% Test all message types
    ?assertEqual(hello, bondy_wamp_encoding:message_name(1)),
    ?assertEqual(welcome, bondy_wamp_encoding:message_name(2)),
    ?assertEqual(abort, bondy_wamp_encoding:message_name(3)),
    ?assertEqual(challenge, bondy_wamp_encoding:message_name(4)),
    ?assertEqual(authenticate, bondy_wamp_encoding:message_name(5)),
    ?assertEqual(goodbye, bondy_wamp_encoding:message_name(6)),
    ?assertEqual(error, bondy_wamp_encoding:message_name(8)),
    ?assertEqual(publish, bondy_wamp_encoding:message_name(16)),
    ?assertEqual(published, bondy_wamp_encoding:message_name(17)),
    ?assertEqual(subscribe, bondy_wamp_encoding:message_name(32)),
    ?assertEqual(subscribed, bondy_wamp_encoding:message_name(33)),
    ?assertEqual(unsubscribe, bondy_wamp_encoding:message_name(34)),
    ?assertEqual(unsubscribed, bondy_wamp_encoding:message_name(35)),
    ?assertEqual(event, bondy_wamp_encoding:message_name(36)),
    ?assertEqual(call, bondy_wamp_encoding:message_name(48)),
    ?assertEqual(cancel, bondy_wamp_encoding:message_name(49)),
    ?assertEqual(result, bondy_wamp_encoding:message_name(50)),
    ?assertEqual(register, bondy_wamp_encoding:message_name(64)),
    ?assertEqual(registered, bondy_wamp_encoding:message_name(65)),
    ?assertEqual(unregister, bondy_wamp_encoding:message_name(66)),
    ?assertEqual(unregistered, bondy_wamp_encoding:message_name(67)),
    ?assertEqual(invocation, bondy_wamp_encoding:message_name(68)),
    ?assertEqual(interrupt, bondy_wamp_encoding:message_name(69)),
    ?assertEqual(yield, bondy_wamp_encoding:message_name(70)).


%% =============================================================================
%% decode_message_name/2 ERROR HANDLING TESTS
%% =============================================================================

decode_message_name_json_invalid_test(_) ->
    %% Invalid JSON for message name
    ?assertError(badarg, bondy_wamp_encoding:decode_message_name({ws, text, json}, <<"{}">>)),
    ?assertError(badarg, bondy_wamp_encoding:decode_message_name({ws, text, json}, <<"[1">>)),
    ?assertError(
        badarg, bondy_wamp_encoding:decode_message_name({ws, text, json}, <<"invalid">>)
    ).


decode_message_name_erl_invalid_test(_) ->
    %% Invalid Erlang term for message name
    ?assertError(
        badarg,
        bondy_wamp_encoding:decode_message_name(
            {ws, binary, erl}, term_to_binary(#{})
        )
    ),
    ?assertError(
        badarg, bondy_wamp_encoding:decode_message_name({ws, binary, erl}, <<"invalid">>)
    ).


decode_message_name_msgpack_invalid_test(_) ->
    %% Invalid msgpack for message name
    ?assertError(
        badarg,
        bondy_wamp_encoding:decode_message_name({ws, binary, msgpack}, <<"invalid">>)
    ).


%% =============================================================================
%% ERROR HANDLING TESTS
%% =============================================================================

encode_unsupported_encoding_test(_) ->
    %% hello requires roles in details with at least one role
    M = bondy_wamp_message:hello(<<"realm">>, #{<<"roles">> => #{<<"caller">> => #{}}}),
    ?assertError({unsupported_encoding, _}, bondy_wamp_encoding:encode(M, xml)),
    ?assertError({unsupported_encoding, _}, bondy_wamp_encoding:encode(M, foo)).


decode_unsupported_encoding_test(_) ->
    %% Unsupported text encoding
    ?assertError(
        {unsupported_encoding, _},
        bondy_wamp_encoding:decode({ws, text, xml}, <<"data">>)
    ),
    ?assertError(
        {unsupported_encoding, _},
        bondy_wamp_encoding:decode({ws, text, msgpack}, <<"data">>)
    ).


%% =============================================================================
%% PARTIAL ENCODING/DECODING TESTS
%% =============================================================================

partial_decode_publish_test(_) ->
    M = bondy_wamp_message:publish(
        1, #{}, <<"topic">>, [1, 2, 3], #{<<"key">> => <<"value">>}
    ),
    Bin = bondy_wamp_encoding:encode(M, json),

    %% Decode with partial_decode enabled (default)
    {[Decoded], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin),
    ?assertEqual(1, bondy_wamp_message:request_id(Decoded)),
    ?assertEqual(<<"topic">>, Decoded#publish.topic_uri),
    ?assertEqual(undefined, Decoded#publish.args),
    ?assertEqual(undefined, Decoded#publish.kwargs),
    ?assertMatch({json, _}, bondy_wamp_message:partial(Decoded)),

    %% Re-encode partial should work
    ReEncoded = bondy_wamp_encoding:encode(Decoded, json),
    ?assertEqual(Bin, ReEncoded),

    %% Decode with partial_decode disabled
    {[FullDecoded], <<>>} = bondy_wamp_encoding:decode(
        {ws, text, json}, Bin, #{partial_decode => false}
    ),
    ?assertEqual([1, 2, 3], FullDecoded#publish.args),
    ?assertEqual(#{<<"key">> => <<"value">>}, FullDecoded#publish.kwargs),
    ?assertEqual(undefined, bondy_wamp_message:partial(FullDecoded)).


partial_decode_error_test(_) ->
    M = bondy_wamp_message:error(
        16,
        1,
        #{},
        <<"error.uri">>,
        [<<"arg1">>, <<"arg2">>],
        #{<<"k">> => <<"v">>}
    ),
    Bin = bondy_wamp_encoding:encode(M, json),

    %% Decode with partial_decode enabled
    {[Decoded], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin),
    ?assertEqual(undefined, Decoded#error.args),
    ?assertEqual(undefined, Decoded#error.kwargs),
    ?assertMatch({json, _}, bondy_wamp_message:partial(Decoded)),

    %% Re-encode should work
    ReEncoded = bondy_wamp_encoding:encode(Decoded, json),
    ?assertEqual(Bin, ReEncoded).


partial_decode_event_test(_) ->
    %% Note: Event messages may not fully support partial decoding
    %% This test just verifies that decoding works
    M = bondy_wamp_message:event(
        1, 2, #{}, [<<"data1">>, <<"data2">>], #{<<"meta">> => true}
    ),
    Bin = bondy_wamp_encoding:encode(M, json),

    %% Decode with partial disabled to avoid set_partial badarg
    {[Decoded], <<>>} = bondy_wamp_encoding:decode(
        {ws, text, json}, Bin, #{partial_decode => false}
    ),

    %% Verify the decoded message
    ?assertEqual([<<"data1">>, <<"data2">>], Decoded#event.args),
    ?assertEqual(#{<<"meta">> => true}, Decoded#event.kwargs).


partial_decode_result_test(_) ->
    M = bondy_wamp_message:result(1, #{}, [42, 43], #{<<"status">> => <<"ok">>}),
    Bin = bondy_wamp_encoding:encode(M, json),

    {[Decoded], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin),
    ?assertMatch({json, _}, bondy_wamp_message:partial(Decoded)),

    ReEncoded = bondy_wamp_encoding:encode(Decoded, json),
    ?assertEqual(Bin, ReEncoded).


partial_decode_invocation_test(_) ->
    M = bondy_wamp_message:invocation(
        1, 2, #{}, [<<"a">>, <<"b">>], #{<<"opt">> => 1}
    ),
    Bin = bondy_wamp_encoding:encode(M, json),

    {[Decoded], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin),
    ?assertMatch({json, _}, bondy_wamp_message:partial(Decoded)),

    ReEncoded = bondy_wamp_encoding:encode(Decoded, json),
    ?assertEqual(Bin, ReEncoded).


partial_decode_yield_test(_) ->
    M = bondy_wamp_message:yield(1, #{}, [1, 2, 3], #{<<"done">> => true}),
    Bin = bondy_wamp_encoding:encode(M, json),

    {[Decoded], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin),
    ?assertMatch({json, _}, bondy_wamp_message:partial(Decoded)),

    ReEncoded = bondy_wamp_encoding:encode(Decoded, json),
    ?assertEqual(Bin, ReEncoded).


partial_to_other_encoding_test(_) ->
    %% Test that partial JSON messages can be re-encoded
    M = bondy_wamp_message:call(
        1, #{}, <<"proc">>, [1, 2, 3], #{<<"key">> => <<"val">>}
    ),
    JsonBin = bondy_wamp_encoding:encode(M, json),

    %% Decode with partial
    {[PartialMsg], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, JsonBin),
    ?assertMatch({json, _}, bondy_wamp_message:partial(PartialMsg)),

    %% Re-encode to JSON should work
    JsonBin2 = bondy_wamp_encoding:encode(PartialMsg, json),
    ?assert(is_binary(JsonBin2)),

    %% Verify by decoding fully
    {[FullyDecoded], <<>>} = bondy_wamp_encoding:decode(
        {ws, text, json}, JsonBin2, #{partial_decode => false}
    ),
    ?assertEqual([1, 2, 3], FullyDecoded#call.args),
    ?assertEqual(#{<<"key">> => <<"val">>}, FullyDecoded#call.kwargs).


%% =============================================================================
%% SUBPROTOCOL VARIATIONS
%% =============================================================================

raw_binary_subprotocol_test(_) ->
    %% Use a valid welcome message with all required fields
    M = bondy_wamp_message:welcome(
        1,
        #{
            <<"realm">> => <<"test">>,
            <<"roles">> => #{<<"broker">> => #{}},
            <<"authid">> => <<"user">>,
            <<"authrole">> => <<"default">>
        }
    ),

    %% Test with msgpack over raw binary
    MsgpackBin = bondy_wamp_encoding:encode(M, msgpack),
    {[Decoded1], <<>>} = bondy_wamp_encoding:decode(
        {raw, binary, msgpack}, MsgpackBin
    ),
    ?assertEqual(M, Decoded1),

    %% Test with erl over raw binary
    ErlBin = bondy_wamp_encoding:encode(M, erl),
    {[Decoded2], <<>>} = bondy_wamp_encoding:decode({raw, binary, erl}, ErlBin),
    ?assertEqual(M, Decoded2),

    %% Test with bert over raw binary
    BertBin = bondy_wamp_encoding:encode(M, bert),
    {[Decoded3], <<>>} = bondy_wamp_encoding:decode({raw, binary, bert}, BertBin),
    ?assertEqual(M, Decoded3).


%% =============================================================================
%% ERROR MESSAGE WITH BINARY PAYLOAD
%% =============================================================================

error_with_args_only_test(_) ->
    %% Test error message with just args (no kwargs)
    M = bondy_wamp_message:error(16, 1, #{}, <<"error.uri">>, [<<"error message">>]),
    Bin = bondy_wamp_encoding:encode(M, json),

    error = bondy_wamp_encoding:decode_message_name({ws, text, json}, Bin),
    {[Decoded], <<>>} = bondy_wamp_encoding:decode(
        {ws, text, json}, Bin, #{partial_decode => false}
    ),

    %% The args should be preserved
    ?assertEqual(M, Decoded).


error_with_args_msgpack_test(_) ->
    %% Test error message with args via msgpack
    M = bondy_wamp_message:error(16, 1, #{}, <<"error.uri">>, [<<"error">>]),
    Bin = bondy_wamp_encoding:encode(M, msgpack),

    {[Decoded], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, Bin),
    ?assertEqual(M, Decoded).


%% =============================================================================
%% ROUNDTRIP TESTS
%% =============================================================================

roundtrip_all_encodings_test(_) ->
    %% Test basic roundtrip for each encoding separately
    %% Note: Different encodings handle binary/string conversion differently,
    %% so we test encodings individually

    %% JSON roundtrip
    JSONMsg = bondy_wamp_message:result(1, #{}, [42], #{<<"done">> => true}),
    JSONBin = bondy_wamp_encoding:encode(JSONMsg, json),
    {[JSONDecoded], <<>>} = bondy_wamp_encoding:decode(
        {ws, text, json}, JSONBin, #{partial_decode => false}
    ),
    ?assertEqual(JSONMsg, JSONDecoded),

    %% Msgpack roundtrip
    MPMsg = bondy_wamp_message:invocation(1, 2, #{}, [1, 2], #{}),
    MPBin = bondy_wamp_encoding:encode(MPMsg, msgpack),
    {[MPDecoded], <<>>} = bondy_wamp_encoding:decode({ws, binary, msgpack}, MPBin),
    ?assertEqual(MPMsg, MPDecoded),

    %% ERL roundtrip
    ERLMsg = bondy_wamp_message:yield(1, #{}, [<<"result">>], #{}),
    ERLBin = bondy_wamp_encoding:encode(ERLMsg, erl),
    {[ERLDecoded], <<>>} = bondy_wamp_encoding:decode({ws, binary, erl}, ERLBin),
    ?assertEqual(ERLMsg, ERLDecoded),

    %% BERT roundtrip
    BERTMsg = bondy_wamp_message:result(1, #{}, [99], #{}),
    BERTBin = bondy_wamp_encoding:encode(BERTMsg, bert),
    {[BERTDecoded], <<>>} = bondy_wamp_encoding:decode({ws, binary, bert}, BERTBin),
    ?assertEqual(BERTMsg, BERTDecoded).


%% =============================================================================
%% EDGE CASES
%% =============================================================================

empty_details_options_test(_) ->
    %% Messages with minimal valid details/options
    %% hello requires roles in details with at least one role
    M1 = bondy_wamp_message:hello(
        <<"realm">>, #{<<"roles">> => #{<<"caller">> => #{}}}
    ),
    ?assertEqual(M1, bondy_wamp_encoding:unpack(bondy_wamp_encoding:pack(M1))),

    M2 = bondy_wamp_message:call(1, #{}, <<"proc">>),
    ?assertEqual(M2, bondy_wamp_encoding:unpack(bondy_wamp_encoding:pack(M2))),

    M3 = bondy_wamp_message:result(1, #{}),
    ?assertEqual(M3, bondy_wamp_encoding:unpack(bondy_wamp_encoding:pack(M3))).


pack_badarg_test(_) ->
    %% pack with invalid argument should error
    ?assertError(badarg, bondy_wamp_encoding:pack(invalid)),
    ?assertError(badarg, bondy_wamp_encoding:pack({not_a_wamp_message})),
    ?assertError(badarg, bondy_wamp_encoding:pack(undefined)).
