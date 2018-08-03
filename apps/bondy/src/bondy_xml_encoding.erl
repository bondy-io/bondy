%% =============================================================================
%%  bondy_xml_encoding.erl -
%%
%%  Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
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

-module(bondy_xml_encoding).


-export([encode/1]).
-export([encode/2]).
-export([decode/1]).



%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
decode(Bin) when is_binary(Bin) ->
    try
        to_map(exomler:decode(Bin), #{})
    catch
        error:Reason ->
            _ = lager:debug("Error; reason=~p, trace=~p", [Reason, erlang:get_stacktrace()]),
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
encode(Map) ->
    encode(Map, #{}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
encode(Map, Opts) ->
    Version = maps:get(version, Opts, <<"1.0">>),
    Encoding = maps:get(encoding, Opts, <<"utf-8">>),
    Head = <<
        "<?xml", $\s,
        "version=", $", Version/binary, $", $\s,
        "encoding=", $", Encoding/binary, $", $\s,
        "?>"
    >>,
    Tail = case maps:keys(Map) of
        [] ->
            <<>>;
        [Key] ->
            exomler:encode(to_tree(Key, maps:get(Key, Map)));
        _ ->
            case maps:find(wrapper, Opts) of
                {ok, Key} ->
                    exomler:encode(to_tree(Key, Map));
                error ->
                    error(too_many_keys)
            end
    end,
    <<Head/binary, Tail/binary>>.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
to_tree(Key, Term) when is_binary(Term) ->
    {Key, [], [Term]};

to_tree(Key, Term) when is_map(Term) ->
    Values = [to_tree(K, V) || {K, V} <- maps:to_list(Term)],
    {Key, [], Values}.



%% @private
to_map(Term) ->
    to_map(Term, #{}).


%% @private
to_map({Key, Attributes, Children}, Acc) ->
    Acc#{Key => to_value(Attributes, Children)};

to_map([{Key, Attributes, Children} | T], Acc) ->
    to_map(T, Acc#{Key => to_value(Attributes, Children)});

to_map([], Acc) ->
    Acc.


%% @private
to_value([], []) ->
    null;

to_value([], [Value]) when is_binary(Value) ->
    Value;

to_value([], Values) ->
    to_map(Values);

to_value(Attributes, [Value]) when is_binary(Value) ->
    Attributes#{<<"value">> => Value};

to_value(Attributes, Values) ->
    Attributes#{<<"contents">> => to_list(Values)}.


%% @private
to_list(L) ->
    to_list(L, []).


%% @private
to_list([H|T], Acc) when is_binary(H) ->
    to_list(T, [H | Acc]);

to_list([H|T], Acc) when is_tuple(H) ->
    to_list(T, [to_map(H) | Acc]);

to_list([], Acc) ->
    lists:reverse(Acc).