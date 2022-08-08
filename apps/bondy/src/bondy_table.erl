%% =============================================================================
%%  bondy_table.erl -
%%
%%  Copyright (c) 2016-2022 Leapsight. All rights reserved.
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
%% @doc An ets table with a map-like interface.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_table).

-define(TAB, ?MODULE).

-type update_op()   ::  integer()
                        | {
                            Incr :: integer(),
                            Threshold :: integer(),
                            SetValue :: integer()
                        }
                        | {
                            Incr :: integer(),
                            Threshold :: integer(),
                            SetValue :: integer(),
                            Init :: integer()
                        }.
-export([delete/2]).
-export([find/2]).
-export([get/2]).
-export([get/3]).
-export([new/3]).
-export([put/3]).
-export([update_counter/3]).


%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(Name :: atom(), Access :: ets:access(), Managed :: boolean()) -> ok.

new(Name, Access, Managed)
when is_atom(Name), is_atom(Access), is_boolean(Managed) ->
    lists:member(Access, [public, protected, private]) orelse error(badarg),

    Opts = [
        set,
        named_table,
        public,
        {keypos, 1},
        {read_concurrency, true},
        {write_concurrency, true},
        {decentralized_counters, true}
    ],

    case Managed of
        true ->
            {ok, Name} = bondy_table_owner:add(Name, Opts),
            Name;
        false ->
            ets:new(Name, Opts)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get(Key :: term(), Table :: atom()) -> term() | no_return().

get(Key, Table) when is_atom(Table)  ->
    try
        ets:lookup_element(Table, Key, 2)
    catch
        error:badarg:Stacktrace ->
            error(error_reason(Stacktrace))
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get(Key :: term(), Table :: atom(), Default :: term()) ->
    term() | no_return().

get(Key, Table, Default) when is_atom(Table)  ->
    try
        ets:lookup_element(Table, Key, 2)
    catch
        error:badarg:Stacktrace ->
            Reason = error_reason(Stacktrace),
            Reason == badkey orelse error(Reason),
            Default
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec find(Key :: term(), Table :: atom()) -> {ok, term()} | error.

find(Key, Table) when is_atom(Table)  ->
    try
        {ok, get(Key, Table)}
    catch
        error:badkey ->
            error
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec put(Key :: term(), Value :: term(), Table :: atom()) -> ok.

put(Key, Value, Table) when is_atom(Table)  ->
    try
        true = ets:insert(Table, {Key, Value}),
        ok
    catch
        error:badarg ->
            error(badtable)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec delete(Key :: term(), Table :: atom()) -> ok.

delete(Key, Table) when is_atom(Table) ->
    try
        true = ets:delete(Table, Key),
        ok
    catch
        error:badarg ->
            error(badtable)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update_counter(Key :: term(), Incr :: update_op(), Table :: atom()) ->
    Result :: integer().

update_counter(Key, Incr, Table) when is_integer(Incr), is_atom(Table) ->
    try
        ets:update_counter(Table, Key, Incr)
    catch
        error:badarg:Stacktrace ->
            error(error_reason(Stacktrace))
    end;

update_counter(Key, {Incr, Threshold, SetValue}, Table)  ->
    update_counter(Key, {Incr, Threshold, SetValue, 0}, Table);

update_counter(Key, {Incr, Threshold, SetValue, Init}, Table)
when is_integer(Incr),
     is_integer(Threshold),
     is_integer(SetValue),
     is_integer(Init),
     is_atom(Table) ->
    try
        ets:update_counter(Table, Key, {2, Incr, Threshold, SetValue})
    catch
        error:badarg:Stacktrace ->
            error(error_reason(Stacktrace))
    end.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
error_reason(Stacktrace) ->
    case hd(Stacktrace) of
        {ets, _, _, [{error_info, #{cause := id}}]} ->
            badtable;
        {ets, _, _, [{error_info, #{cause := badkey}}]} ->
            badkey;
        _ ->
            badarg
    end.








