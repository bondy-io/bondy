%% -----------------------------------------------------------------------------
%% @doc This module implements a partition queue on a tuplespace using
%% {@link tuplespace}.
%% It provides two interfaces:
%%  * a normal FIFO queue interface with the functions {@link enqueue/2}
%% and {@link dequeue/1}
%% * a FIFO queue with expiration with the functions {@link enqueue/3}
%% and {@link dequeue_expired/1}
%% @end
%% -----------------------------------------------------------------------------
-module(tuplespace_queue).
-include("tuplespace.hrl").

-export([dequeue_expired/1]).
-export([dequeue_expired/2]).
-export([dequeue/1]).
-export([dequeue/2]).
-export([enqueue/2]).
-export([enqueue/3]).
-export([size/1]).
-export([is_empty/1]).

-compile({no_auto_import,[size/1]}).

%% -----------------------------------------------------------------------------
%% @doc
%% Returns an integer representing the number of elements found in the
%% queue.
%% @end
%% -----------------------------------------------------------------------------
-spec size(atom()) -> non_neg_integer().
size(Q) ->
    tuplespace:size(Q).


%% @doc Tests if Q is empty and returns 'true' if so and 'false' otherwise.
-spec is_empty(atom()) -> boolean().
is_empty(Q) ->
    size(Q) == 0.


%% @doc Inserts Item at the rear of queue Q. Returns the atom 'ok'.
%% Calls {@link enqueue/3} with TTLSecs equal to 'infinity'.
-spec enqueue(atom(), any()) -> ok.
enqueue(Q, Item) ->
    enqueue(Q, Item, infinity).


%% @doc Inserts Item at the rear of queue Q, setting a time to live TTLSecs in
%% seconds. Returns the atom 'ok'.
-spec enqueue(atom(), any(), non_neg_integer()) -> ok.
enqueue(Q, Item, TTLSecs) when is_integer(TTLSecs) orelse TTLSecs == infinity ->
    TS = erlang:system_time(micro_seconds),
    FT = erlang:system_time(seconds) + TTLSecs,
    ets:insert(?QUEUE_TABLE(Q), {{Q, TS, FT, Item}}),
    ok.

%% @doc Removes the item at the front of queue Q. Returns Item, where Item is
%% the item removed. If Q is empty, the atom 'empty' is returned.
%% The item will be removed regardless of its time-to-live. If you want to
%% respect the time-to-live use {@link dequeue_expired/1} instead.
-spec dequeue(atom()) -> any() | empty.
dequeue(Q) ->
    case dequeue(Q, 1) of
        [] -> empty;
        [Item] -> Item
    end.


%% @doc Removes N items at the front of queue Q. Returns Items, where Items is
%% the list of items removed. If Q is empty, the empty list is returned.
%% The items will be removed regardless of their time-to-live. If you want to
%% respect the time-to-live use {@link dequeue_expired/2} instead.
-spec dequeue(atom(), N :: non_neg_integer()) -> Items :: list().
dequeue(_Q, 0) ->
    [];
dequeue(Q, 1) ->
    Tab = ?QUEUE_TABLE(Q),
    case ets:first(Tab) of
        {_, _, _, Term} = Key ->
            ets:delete(Tab, Key),
            [Term];
        '$end_of_table' ->
            []
    end;
dequeue(Q, N) ->
    Tab = ?QUEUE_TABLE(Q),
    Limit = erlang:min(N, 1000),
    MP = {{Q, '_', '_', '_'}},
    MS = [{MP, [], ['$$']}],
    case ets:select(Tab, MS, Limit) of
        '$end_of_table' ->
            [];
        {Objs, _} ->
            Fun = fun({{_, _, _, Term} = K}, Acc) ->
                ets:delete(Tab, K),
                [Term|Acc]
            end,
            lists:foldl(Fun, [], Objs)
    end.


%% @doc Starting at the front of the queue Q, it removes the first expired item.
%% An expired item is one for which its time-to-live (TTLSecs) has been reached.
%% Returns the removed item or the atom 'empty' if there are no expired items.
%% Items that have been inserted in the queue using {@link enqueue/2} will be
%% skipped.
-spec dequeue_expired(atom()) -> Items :: list().
dequeue_expired(Q) ->
    case dequeue_expired(Q, 1) of
        [] -> empty;
        [Term] -> Term
    end.


%% @doc Starting at the front of the queue Q, it removes N expired items.
%% Returns Items, where Items is the list of items removed.
%% An expired item if one for which its time-to-live (TTLSecs) has been reached.
%% If Q is empty, the empty list is returned.
%% Items that have been inserted in the queue using {@link enqueue/2} will be
%% skipped.
-spec dequeue_expired(atom(), N :: non_neg_integer()) -> Items :: list().
dequeue_expired(_Q, 0) ->
    [];
dequeue_expired(Q, 1) ->
    Tab = ?QUEUE_TABLE(Q),
    Now = erlang:system_time(seconds),
    case ets:first(Tab) of
        {_, _, FTS, Term} = Key when FTS < Now ->
            ets:delete(Tab, Key),
            [Term];
        _ ->
            []
    end;
dequeue_expired(Q, N) ->
    Tab = ?QUEUE_TABLE(Q),
    Now = erlang:system_time(seconds),
    Limit = erlang:min(N, 1000),
    MP = {{Q, '_', '$1', '_'}},
    Conds = [{'<', '$1', Now}],
    MS = [{MP, Conds, ['$$']}],
    case ets:select(Tab, MS, Limit) of
        {Objs, _} ->
            Fun = fun({{_, _, _, Term} = K}, Acc) ->
                ets:delete(Tab, K),
                [Term|Acc]
            end,
            lists:foldl(Fun, [], Objs);
        '$end_of_table' ->
            []
    end.
