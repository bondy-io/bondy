-module(tuplespace_config).
-define(APP, tuplespace).


-export([ring_size/0]).

ring_size() ->
    application:get_env(?APP, ring_size, 64).
