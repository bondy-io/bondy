-module(bondy_reliable).


-export([enqueue/2]).
-export([enqueue/3]).





%% =============================================================================
%% API
%% =============================================================================



enqueue(QueueName, Term) ->
    enqueue(QueueName, Term, #{}).


enqueue(_QueueName, {_M, _F, _A}, _Opts) ->
    %% Return uuid
    {ok, undefined};

enqueue(_QueueName, Fun, _Opts) when is_function(Fun, 0) ->
    %% Return uuid
    {ok, undefined};

enqueue(_QueueName, List, _Opts) when is_list(List) ->
    %% Return uuid
    {ok, undefined}.
