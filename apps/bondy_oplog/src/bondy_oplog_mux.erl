%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_mux).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
A generic routing multiplexer — a value addressed by a routing key, in one of
two shapes:

- `{single, V}` — one member; every key routes to `V`. The no-multiplexing case,
  byte-identical to addressing `V` directly.
- `{dir, #{K => V}}` — a directory; each key routes to its own member's `V`.

This is the shared substrate of the one-log-per-shard collapse: one worker fans
work out to several members distinguished by a key carried on each unit of work.
The per-shard oplog instance routes cell-apply events by their entity-type
`Bucket` (`bondy_oplog_cell_apply`); the same primitive is reused wherever a
shared worker multiplexes members keyed by a tag. Only the directory is shared —
how a consumer extracts the key and applies the work stays with the consumer.

`put/3` upgrades a seedless `{single, undefined}` to a `{dir, _}`, so a worker
that may later gain siblings is started with one member and grows. A
`{single, V}` that already holds a founding value but was never given a key
cannot be keyed; adding a member to it is a programmer error — seed it in
directory mode (`dir/1`) instead.
""").

-type key() :: term().
-type value() :: term().
-type t() :: {single, value()} | {dir, #{key() => value()}}.

-export_type([t/0]).
-export_type([key/0]).
-export_type([value/0]).

-export([single/1]).
-export([dir/0]).
-export([dir/1]).
-export([put/3]).
-export([remove/2]).
-export([resolve/2]).
-export([entries/1]).
-export([group_by/2]).

%% =============================================================================
%% API
%% =============================================================================

-doc "A single-member multiplexer: every key resolves to `V`.".
-spec single(V :: value()) -> t().

single(V) ->
    {single, V}.

-doc "An empty directory multiplexer.".
-spec dir() -> t().

dir() ->
    {dir, #{}}.

-doc "A directory multiplexer seeded from a list of `{Key, Value}` members.".
-spec dir(Members :: [{key(), value()}]) -> t().

dir(Members) when is_list(Members) ->
    {dir, maps:from_list(Members)}.

-doc """
Add `Key => Value`. Upgrades a seedless `{single, undefined}` to a directory; a
`{single, V0}` holding a founding value but no key cannot be keyed and raises
`put_requires_dir` (seed in directory mode instead).
""".
-spec put(Mux :: t(), Key :: key(), Value :: value()) -> t().

put({dir, Map}, Key, Value) ->
    {dir, Map#{Key => Value}};
put({single, undefined}, Key, Value) ->
    {dir, #{Key => Value}};
put({single, _V0}, _Key, _Value) ->
    error(put_requires_dir).

-doc """
Remove a member by key. A no-op on a `{single, _}` multiplexer (it has no
directory to remove from).
""".
-spec remove(Mux :: t(), Key :: key()) -> t().

remove({dir, Map}, Key) ->
    {dir, maps:remove(Key, Map)};
remove(Mux, _Key) ->
    Mux.

-doc """
Resolve a key to its member value. A `{single, V}` resolves every key to `V`; a
`{dir, _}` returns the keyed value or `undefined` when absent.
""".
-spec resolve(Mux :: t(), Key :: key()) -> value() | undefined.

resolve({single, V}, _Key) ->
    V;
resolve({dir, Map}, Key) ->
    maps:get(Key, Map, undefined).

-doc """
The multiplexer's members as `[{Key | all, Value}]`. A `{single, V}` has one
member matching every key, represented as `{all, V}`. Lets a caller iterate
per member — e.g. a maintenance pass that must run each registered table
through its own context rather than resolve key-by-key.
""".
-spec entries(Mux :: t()) -> [{key() | all, value()}].

entries({single, V}) ->
    [{all, V}];
entries({dir, Map}) ->
    maps:to_list(Map).

-doc """
Group `Items` by the key `KeyOf` extracts from each (`{ok, Key}` to route it,
`skip` to drop it), preserving each key's original arrival order. The dual of
`resolve/2` on the producing side: a caller groups a batch by key, then resolves
and applies each group under its member.
""".
-spec group_by(
    Items :: [term()],
    KeyOf :: fun((term()) -> {ok, key()} | skip)
) -> [{key(), [term()]}].

group_by(Items, KeyOf) when is_list(Items), is_function(KeyOf, 1) ->
    Map = lists:foldl(
        fun(Item, Acc) ->
            case KeyOf(Item) of
                {ok, Key} ->
                    Acc#{Key => [Item | maps:get(Key, Acc, [])]};
                skip ->
                    Acc
            end
        end,
        #{},
        Items
    ),
    [{Key, lists:reverse(Rev)} || {Key, Rev} <- maps:to_list(Map)].
