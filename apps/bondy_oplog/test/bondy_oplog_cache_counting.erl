%% =============================================================================
%% Test-only `bondy_oplog_cache_adapter` that counts lifecycle calls.
%% Used to pin behaviour contracts the substrate makes about adapter
%% lifecycle (e.g., that `close/1` is NOT invoked on owner DOWN).
%%
%% The handle is a small ETS counter table the test owns; the test
%% reads counters via `close_count/1` and friends to assert behaviour.
%% =============================================================================

-module(bondy_oplog_cache_counting).

-behaviour(bondy_oplog_cache_adapter).

-export([
    init/4,
    close/1,
    get/3,
    put/4,
    delete/3,
    invalidate_all/1,
    info/1
]).

%% Test helpers.
-export([new_counter/0, close_count/1, delete_counter/1]).

init(_NS, _Index, _Shard, #{counter := Counter}) ->
    _ = ets:update_counter(Counter, init_calls, {2, 1}, {init_calls, 0}),
    {ok, Counter}.

close(Counter) ->
    _ = ets:update_counter(Counter, close_calls, {2, 1}, {close_calls, 0}),
    ok.

get(_Counter, _Bucket, _Key) ->
    not_found.

put(_Counter, _Bucket, _Key, _Value) ->
    ok.

delete(_Counter, _Bucket, _Key) ->
    ok.

invalidate_all(_Counter) ->
    ok.

info(_Counter) ->
    #{}.

%% =============================================================================
%% Test helpers
%% =============================================================================

new_counter() ->
    ets:new(?MODULE, [set, public]).

close_count(Counter) ->
    case ets:lookup(Counter, close_calls) of
        [{_, N}] -> N;
        [] -> 0
    end.

delete_counter(Counter) ->
    true = ets:delete(Counter),
    ok.
