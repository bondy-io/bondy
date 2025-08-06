%% =============================================================================
%%  bondy_registry_remote_index.erl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_registry_remote_index).

-include("bondy.hrl").
-include("bondy_registry.hrl").

-define(EOT, '$end_of_table').

-type t()               ::  ets:tab().
-type eot()             ::  ?EOT.
-type match_result()    ::  [{entry_type(), entry_key()}]
                            |   {
                                    [{entry_type(), entry_key()}],
                                    eot() | ets:continuation()
                                }
                            | eot().

%% Aliases
-type entry()           ::  bondy_registry_entry:entry().
-type entry_type()      ::  bondy_registry_entry:entry_type().
-type entry_key()       ::  bondy_registry_entry:key().

-export_type([t/0]).
-export_type([eot/0]).
-export_type([match_result/0]).


%% API
-export([new/1]).
-export([add/2]).
-export([delete/2]).
-export([match/3]).
-export([match/1]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(Index :: integer()) -> t().

new(Index) ->
    %% Stores all remote entries indexed by node and timestamp
    Tab = gen_table_name(Index),
    Opts = [
        ordered_set,
        {keypos, 1},
        named_table,
        public,
        {read_concurrency, true},
        {write_concurrency, true},
        {decentralized_counters, true}
    ],
    {ok, Tab} = bondy_table_manager:add_or_claim(Tab, Opts),
    Tab.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add(T :: t(), Entry :: entry()) -> ok.

add(T, Entry) ->
    do(T, Entry, add).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec delete(T :: t(), Entry :: entry()) -> ok.

delete(T, Entry) ->
    do(T, Entry, delete).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match(T :: t(), Node :: node(), Limit :: pos_integer()) ->
    match_result().

match(T, Node, Limit) when is_atom(Node), is_integer(Limit) ->
    %% Key = {node(), entry_type(), entry_key()}.
    Key = {Node, '$1', '$2'},
    %% We use a 1-tuple
    Pattern = {Key},
    MS = [{Pattern, [], [{{'$1', '$2'}}]}],

    ets:select(T, MS, Limit).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match(ets:continuation() | eot()) -> match_result().

match(?EOT) ->
    ?EOT;

match(Cont) ->
    ets:select(Cont).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @private
%% @doc Generates a dynamic ets table name given a generic name and and index
%% (partition number).
%% @end
%% -----------------------------------------------------------------------------
gen_table_name(Index) when is_integer(Index) ->
    list_to_atom("bondy_registry_remote_idx_tab_" ++ integer_to_list(Index)).


%% -----------------------------------------------------------------------------
%% @private
%% @doc If Entry is remote, it adds it to the remote_tab index.
%% This index is solely used by find_by_node/3 function.
%% @end
%% -----------------------------------------------------------------------------
do(Op, Entry, T) ->
    case bondy_registry_entry:is_local(Entry) of
        true ->
            ok;

        false ->
            Node = bondy_registry_entry:node(Entry),
            Type = bondy_registry_entry:type(Entry),
            EntryKey = bondy_registry_entry:key(Entry),

            %% Entry is the value we are interested in but we use it as part of
            %% the key to disambiguate, and avoid adding more elements to the
            %% tuple.
            Key = {Node, Type, EntryKey},

            case Op of
                add ->
                    Object = {Key},
                    true = ets:insert(T, Object);

                delete ->
                    true = ets:match_delete(T, Key)
            end,
            ok
    end.
