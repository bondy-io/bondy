-module(juno_encoding_SUITE).
-include_lib("common_test/include/ct.hrl").
-compile(export_all).

all() ->
    common:all().

groups() ->
    [{main, [parallel], common:tests(?MODULE)}].

%%  JSON

hello_json_test(_) ->
    M = juno_message:hello(<<"realm1">>, #{roles => #{
        caller => #{}
    }}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

welcome_json_test(_) ->
    M = juno_message:welcome(1, #{roles => #{
        dealer => #{},
        broker => #{}
    }}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

abort_json_test(_) ->
    M = juno_message:abort(#{message => <<"foo">>}, <<"wamp.error.foo">>),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

challenge_json_test(_) ->
    M = juno_message:challenge(<<"foo">>, #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

authenticate_json_test(_) ->
    M = juno_message:authenticate(<<"foo">>, #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

goodbye_json_test(_) ->
    M = juno_message:goodbye(
        #{message => <<"The host is shutting down now.">>},
        <<"wamp.error.system_shutdown">>
    ),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).


error_json_test(_) ->
    M = juno_message:error(0, 1, #{}, <<"wamp.error.foo">>),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

error_json_2_test(_) ->
    M = juno_message:error(0, 1, #{}, <<"wamp.error.foo">>, []),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

error_json_3_test(_) ->
    M = juno_message:error(0, 1, #{}, <<"wamp.error.foo">>, [], #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

publish_json_test(_) ->
    M = juno_message:publish(1, #{}, <<"com.williamhill.topic1">>),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

publish_json_2_test(_) ->
    M = juno_message:publish(1, #{}, <<"com.williamhill.topic1">>, []),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

publish_json_3_test(_) ->
    M = juno_message:publish(1, #{}, <<"com.williamhill.topic1">>, [], #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

published_json_test(_) ->
    M = juno_message:published(1, 2),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

subscribe_json_test(_) ->
    M = juno_message:subscribe(1, #{}, <<"com.williamhill.topic1">>),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

subscribed_json_test(_) ->
    M = juno_message:subscribed(1, 3),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

unsubscribe_json_test(_) ->
    M = juno_message:unsubscribe(1, 3),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

unsubscribed_json_test(_) ->
    M = juno_message:unsubscribed(1),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

event_json_test(_) ->
    M = juno_message:event(3, 2, #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

event_json_2_test(_) ->
    M = juno_message:event(3, 2, #{}, []),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

event_json_3_test(_) ->
    M = juno_message:event(3, 2, #{}, [], #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

call_json_test(_) ->
    M = juno_message:call(1, #{}, <<"com.williamhill.myprocedure1">>),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

call_json_2_test(_) ->
    M = juno_message:call(1, #{}, <<"com.williamhill.myprocedure1">>, []),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

call_json_3_test(_) ->
    M = juno_message:call(1, #{}, <<"com.williamhill.myprocedure1">>, [], #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

cancel_json_test(_) ->
    M = juno_message:cancel(1, #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

result_json_test(_) ->
    M = juno_message:result(1, #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

result_json_2_test(_) ->
    M = juno_message:result(1, #{}, []),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

result_json_3_test(_) ->
    M = juno_message:result(1, #{}, [], #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

register_json_test(_) ->
    M = juno_message:register(1, #{}, <<"com.williamhill.myprocedure1">>),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

registered_json_2_test(_) ->
    M = juno_message:registered(1, 4),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

unregister_json_3_test(_) ->
    M = juno_message:unregister(1, 4),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

unregistered_json_test(_) ->
    M = juno_message:unregistered(1),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

invocation_json_test(_) ->
    M = juno_message:invocation(1, 4, #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

invocation_json_2_test(_) ->
    M = juno_message:invocation(1, 4, #{}, []),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

invocation_json_3_test(_) ->
    M = juno_message:invocation(1, 4, #{}, [], #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

interrupt_json_test(_) ->
    M = juno_message:interrupt(1, #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

yield_json_test(_) ->
    M = juno_message:yield(1, #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

yield_json_2_test(_) ->
    M = juno_message:yield(1, #{}, []),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).

yield_json_3_test(_) ->
    M = juno_message:yield(1, #{}, [], #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, json), text, json).


%% ERL


hello_erl_test(_) ->
    M = juno_message:hello(<<"realm1">>, #{roles => #{
        caller => #{}
    }}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

welcome_erl_test(_) ->
    M = juno_message:welcome(1, #{roles => #{
        dealer => #{},
        broker => #{}
    }}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

abort_erl_test(_) ->
    M = juno_message:abort(#{message => <<"foo">>}, <<"wamp.error.foo">>),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

challenge_erl_test(_) ->
    M = juno_message:challenge(<<"foo">>, #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

authenticate_erl_test(_) ->
    M = juno_message:authenticate(<<"foo">>, #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

goodbye_erl_test(_) ->
    M = juno_message:goodbye(
        #{message => <<"The host is shutting down now.">>},
        <<"wamp.error.system_shutdown">>
    ),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).


error_erl_test(_) ->
    M = juno_message:error(0, 1, #{}, <<"wamp.error.foo">>),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

error_erl_2_test(_) ->
    M = juno_message:error(0, 1, #{}, <<"wamp.error.foo">>, []),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

error_erl_3_test(_) ->
    M = juno_message:error(0, 1, #{}, <<"wamp.error.foo">>, [], #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

publish_erl_test(_) ->
    M = juno_message:publish(1, #{}, <<"com.williamhill.topic1">>),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

publish_erl_2_test(_) ->
    M = juno_message:publish(1, #{}, <<"com.williamhill.topic1">>, []),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

publish_erl_3_test(_) ->
    M = juno_message:publish(1, #{}, <<"com.williamhill.topic1">>, [], #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

published_erl_test(_) ->
    M = juno_message:published(1, 2),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

subscribe_erl_test(_) ->
    M = juno_message:subscribe(1, #{}, <<"com.williamhill.topic1">>),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

subscribed_erl_test(_) ->
    M = juno_message:subscribed(1, 3),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

unsubscribe_erl_test(_) ->
    M = juno_message:unsubscribe(1, 3),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

unsubscribed_erl_test(_) ->
    M = juno_message:unsubscribed(1),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

event_erl_test(_) ->
    M = juno_message:event(3, 2, #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

event_erl_2_test(_) ->
    M = juno_message:event(3, 2, #{}, []),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

event_erl_3_test(_) ->
    M = juno_message:event(3, 2, #{}, [], #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

call_erl_test(_) ->
    M = juno_message:call(1, #{}, <<"com.williamhill.myprocedure1">>),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

call_erl_2_test(_) ->
    M = juno_message:call(1, #{}, <<"com.williamhill.myprocedure1">>, []),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

call_erl_3_test(_) ->
    M = juno_message:call(1, #{}, <<"com.williamhill.myprocedure1">>, [], #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

cancel_erl_test(_) ->
    M = juno_message:cancel(1, #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

result_erl_test(_) ->
    M = juno_message:result(1, #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

result_erl_2_test(_) ->
    M = juno_message:result(1, #{}, []),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

result_erl_3_test(_) ->
    M = juno_message:result(1, #{}, [], #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

register_erl_test(_) ->
    M = juno_message:register(1, #{}, <<"com.williamhill.myprocedure1">>),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

registered_erl_2_test(_) ->
    M = juno_message:registered(1, 4),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

unregister_erl_3_test(_) ->
    M = juno_message:unregister(1, 4),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

unregistered_erl_test(_) ->
    M = juno_message:unregistered(1),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

invocation_erl_test(_) ->
    M = juno_message:invocation(1, 4, #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

invocation_erl_2_test(_) ->
    M = juno_message:invocation(1, 4, #{}, []),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

invocation_erl_3_test(_) ->
    M = juno_message:invocation(1, 4, #{}, [], #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

interrupt_erl_test(_) ->
    M = juno_message:interrupt(1, #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

yield_erl_test(_) ->
    M = juno_message:yield(1, #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

yield_erl_2_test(_) ->
    M = juno_message:yield(1, #{}, []),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).

yield_erl_3_test(_) ->
    M = juno_message:yield(1, #{}, [], #{}),
    {[M], <<>>} = juno_encoding:decode(juno_encoding:encode(M, erl), text, erl).
