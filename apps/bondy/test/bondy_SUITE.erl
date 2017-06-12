-module(bondy_SUITE).
-include_lib("common_test/include/ct.hrl").
-compile(export_all).

all() ->
    common:all().

groups() ->
    [{main, [parallel], common:tests(?MODULE)}].

%%  JSON

hello_json_test(_) ->
    M = wamp_message:hello(<<"realm1">>, #{roles => #{
        caller => #{}
    }}),
    {[M], <<>>} = wamp_encoding:decode(wamp_encoding:encode(M, json), text, json).
