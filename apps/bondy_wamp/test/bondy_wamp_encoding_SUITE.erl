-module(bondy_wamp_encoding_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
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
    error = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
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
    Args = [
        [{bar, pid_to_list(self())}]
    ],
    M0 = bondy_wamp_message:call(1, #{}, <<"foo">>, Args, #{}),
    Bin = bondy_wamp_encoding:encode(M0, json),
    call = bondy_wamp_encoding:decode_message_name(
        {ws, text, json}, Bin),
    {[M1], <<>>} = bondy_wamp_encoding:decode({ws, text, json}, Bin),
    ?assertMatch(
        {call, 1, _, <<"foo">>, [#{<<"bar">> := _}],
        undefined},
        M1
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
        undefined},
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
    {[{result, 1, #{}, [ResultArg], undefined}], <<>>} = bondy_wamp_encoding:decode(
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