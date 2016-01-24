-module(ramp_encoding_SUITE).
-include_lib("common_test/include/ct.hrl").
-compile(export_all).

all() ->
    common:all().

groups() ->
    [{main, [parallel], common:tests(?MODULE)}].


hello_json_test(_) ->
    M = ramp_message:hello(<<"realm1">>, #{roles => #{
        caller => #{}
    }}),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

welcome_json_test(_) ->
    M = ramp_message:welcome(1, #{roles => #{
        dealer => #{},
        broker => #{}
    }}),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

abort_json_test(_) ->
    M = ramp_message:abort(#{message => <<"foo">>}, <<"wamp.error.foo">>),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

challenge_json_test(_) ->
    M = ramp_message:challenge(<<"foo">>, #{}),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

authenticate_json_test(_) ->
    M = ramp_message:authenticate(<<"foo">>, #{}),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

goodbye_json_test(_) ->
    M = ramp_message:goodbye(
        #{message => <<"The host is shutting down now.">>},
        <<"wamp.error.system_shutdown">>
    ),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

heartbeat_json_test(_) ->
    ok.

error_json_test(_) ->
    M = ramp_message:error(0, 1, #{}, <<"wamp.error.foo">>),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

error_json_2_test(_) ->
    M = ramp_message:error(0, 1, #{}, <<"wamp.error.foo">>, []),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

error_json_3_test(_) ->
    M = ramp_message:error(0, 1, #{}, <<"wamp.error.foo">>, [], #{}),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

publish_json_test(_) ->
    M = ramp_message:publish(1, #{}, <<"com.williamhill.topic1">>),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

publish_json_2_test(_) ->
    M = ramp_message:publish(1, #{}, <<"com.williamhill.topic1">>, []),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

publish_json_3_test(_) ->
    M = ramp_message:publish(1, #{}, <<"com.williamhill.topic1">>, [], #{}),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

published_json_test(_) ->
    M = ramp_message:published(1, 2),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

subscribe_json_test(_) ->
    M = ramp_message:subscribe(1, #{}, <<"com.williamhill.topic1">>),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

subscribed_json_test(_) ->
    M = ramp_message:subscribed(1, 3),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

unsubscribe_json_test(_) ->
    M = ramp_message:unsubscribe(1, 3),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

unsubscribed_json_test(_) ->
    M = ramp_message:unsubscribed(1),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

event_json_test(_) ->
    M = ramp_message:event(3, 2, #{}),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

event_json_2_test(_) ->
    M = ramp_message:event(3, 2, #{}, []),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

event_json_3_test(_) ->
    M = ramp_message:event(3, 2, #{}, [], #{}),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

call_json_test(_) ->
    M = ramp_message:call(1, #{}, <<"com.williamhill.myprocedure1">>),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

call_json_2_test(_) ->
    M = ramp_message:call(1, #{}, <<"com.williamhill.myprocedure1">>, []),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

call_json_3_test(_) ->
    M = ramp_message:call(1, #{}, <<"com.williamhill.myprocedure1">>, [], #{}),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

cancel_json_test(_) ->
    M = ramp_message:cancel(1, #{}),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

result_json_test(_) ->
    M = ramp_message:result(1, #{}),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

result_json_2_test(_) ->
    M = ramp_message:result(1, #{}, []),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

result_json_3_test(_) ->
    M = ramp_message:result(1, #{}, [], #{}),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

register_json_test(_) ->
    M = ramp_message:register(1, #{}, <<"com.williamhill.myprocedure1">>),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

registered_json_2_test(_) ->
    M = ramp_message:registered(1, 4),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

unregister_json_3_test(_) ->
    M = ramp_message:unregister(1, 4),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

unregistered_json_test(_) ->
    M = ramp_message:unregistered(1),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

invocation_json_test(_) ->
    M = ramp_message:invocation(1, 4, #{}),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

invocation_json_2_test(_) ->
    M = ramp_message:invocation(1, 4, #{}, []),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

invocation_json_3_test(_) ->
    M = ramp_message:invocation(1, 4, #{}, [], #{}),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

interrupt_json_test(_) ->
    M = ramp_message:interrupt(1, #{}),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

yield_json_test(_) ->
    M = ramp_message:yield(1, #{}),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

yield_json_2_test(_) ->
    M = ramp_message:yield(1, #{}, []),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).

yield_json_3_test(_) ->
    M = ramp_message:yield(1, #{}, [], #{}),
    {[M], <<>>} = ramp_encoding:decode(ramp_encoding:encode(M, json), text, json).
