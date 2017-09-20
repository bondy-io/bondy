%% =============================================================================
%%  mops.erl -
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


%% -----------------------------------------------------------------------------
%% @doc
%% This module implements Mops, a very simple mustache-inspired expression
%% language.
%% All expressions in Mops are evaluated against a Context, an erlang `map()`
%% where all keys are of type `binary()`.
%%
%% The following are the key characteristics and features:
%% *
%% @end
%% -----------------------------------------------------------------------------
-module(mops).
-define(START, <<"{{">>).
-define(END, <<"}}">>).
-define(PIPE_OP, <<$|,$>>>).
-define(DOUBLE_QUOTES, <<$">>).

-define(OPTS_SPEC, #{
    %% Defines the format of the keys in the map
    %% not in use at the moment
    labels => #{
        required => true,
        default => binary,
        allow_null => false,
        allow_undefined => false,
        datatype => {in, [binary, atom]}
    },
    %% Allows to register custom pipe operators (aka filters)
    %% not in use at the moment
    operators => #{
        required => false,
        allow_null => false,
        validator => fun
            ({Name, Fun} = Op) when (is_atom(Name)
            orelse is_binary(Name))
            andalso is_function(Fun, 1) ->
                {ok, Op};
            (_) ->
                false
        end
    }
}).

-record(state, {
    context                                                     ::  map(),
    opts                                                        ::  map(),
    acc = []                                                    ::  any(),
    is_ground = true                                            ::  boolean(),
    is_open = false                                             ::  boolean(),
    is_string = false                                           ::  boolean(),
    sp = binary:compile_pattern(?START)                         ::  any(),
    dqp = binary:compile_pattern(?DOUBLE_QUOTES)                ::  any(),
    pop = binary:compile_pattern(?PIPE_OP)                      ::  any(),
    ep = binary:compile_pattern(?END)                           ::  any(),
    re = element(2, re:compile("^\\s+|\\s+$", ""))              ::  any()
}).

%% -record('$mops_proxy', {
%%     value :: any()
%% }).

-type state()       ::  #state{}.
%% -type proxy()       ::  #'$mops_proxy'{}.
-type context()     ::  map().



-export([eval/2]).
-export([eval/3]).
-export([proxy/0]).
-export([is_proxy/1]).






%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% Evaluates **Term** using the context **Ctxt**
%% Returns **Term** in case the term is not a binary and does not contain a
%% mops expression. Otherwise, it tries to evaluate the expression using the
%% **Ctxt**.
%%
%% The following are example mops expressions and their meanings:
%% - `<<"{{foo}}">>' - resolve the value for key `<<"foo">>` in the context.
%% It fails if the context does not have a key named `<<"foo">>'.
%% - `<<"\"{{foo}}\">>' - return a string by resolving the value for key
%% `<<"foo">>' in the context. It fails if the context does not have a key
%% named `<<"foo">>'.
%% - `<<"{{foo.bar}}">>' - resolve the value for key path in the context.
%% It fails if the context does not have a key named `<<"foo">>' which has a value that is either a `function()` or a `map()` with a key named `<<"bar">>'.
%% - `<<"{{foo |> integer}}">>' - resolves the value for key `<<"foo">>' in the
%% context and converts the result to an integer. If the result was a
%% `function()', it returns a function composition.
%% It fails if the context does not have a key named `<<"foo">>'
%%
%% Examples:
%% <pre language="erlang">
%% > mops:eval(foo, #{<<"foo">> => bar}).
%% > foo
%% > mops:eval(<<"foo">>, #{<<"foo">> => bar}).
%% > <<"foo">>
%% > mops:eval(1, #{<<"foo">> => bar}).
%% > 1
%% > mops:eval(<<"{{foo}}">>, #{<<"foo">> => bar}).
%% > bar
%% > mops:eval(<<"{{foo.bar}}">>, #{<<"foo">> => #{<<"bar">> => foobar}}).
%% > foobar
%% </pre>
%% @end
%% -----------------------------------------------------------------------------
-spec eval(any(), context()) -> any().

eval(T, Ctxt) ->
    eval(T, Ctxt, #{}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec eval(any(), context(), map()) -> any().

eval(T, Ctxt, Opts) ->
    do_eval(T, Ctxt, Opts).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec proxy() -> '$mops_proxy'.

proxy() -> '$mops_proxy'.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_proxy(any()) -> boolean().

is_proxy({'$mops_proxy', _}) -> true;
is_proxy(_) -> false.




%% =============================================================================
%% PRIVATE
%% =============================================================================




%% @private
do_eval(T, Ctxt) ->
    do_eval(T, Ctxt, #{}).


%% @private
-spec do_eval(any(), context(), map()) -> any().

do_eval({'$mops_proxy', F}, Ctxt, Opts) when is_function(F, 1), is_map(Ctxt) ->
   do_eval(F, Ctxt, Opts);

do_eval(F, Ctxt, _Opts) when is_function(F, 1), is_map(Ctxt) ->
    F(Ctxt);

do_eval(T, Ctxt, Opts) when is_map(T), is_map(Ctxt), is_map(Opts) ->
    eval_map(T, Ctxt, Opts);

do_eval(T, Ctxt, Opts) when is_list(T), is_map(Ctxt), is_map(Opts) ->
    eval_list(T, Ctxt, Opts);

do_eval(T, Ctxt, Opts) when is_tuple(T), is_map(Ctxt), is_map(Opts) ->
    list_to_tuple(eval_list(tuple_to_list(T), Ctxt, Opts));

do_eval(<<>>, Ctxt, Opts) when is_map(Ctxt), is_map(Opts) ->
    <<>>;

do_eval(T, Ctxt, Opts) when is_binary(T), is_map(Ctxt), is_map(Opts) ->
    eval_expr(T, #state{
        context = Ctxt,
        opts = maps_utils:validate(Opts, ?OPTS_SPEC)
    });

do_eval(T, Ctxt, Opts) when is_map(Ctxt), is_map(Opts) ->
    T.


%% @private
eval_map(Map, Ctxt, Opts) ->
    Fold = fun(K, V0, {L, R}) ->
        case do_eval(V0, Ctxt, Opts) of
            {'$mops_proxy', _} = V1 ->
                {L, [{K, V1}|R]};
            V1 ->
                {[{K, V1}|L], R}
        end
    end,
    case maps:fold(Fold, {[], []}, Map) of
        {Ls, []} ->
            maps:from_list(Ls);
        {Ls, Rs} ->
            maps:from_list(lists:append(Ls, Rs))
    end.

%% @private
eval_list(List, Ctxt, Opts) ->
    Fold = fun(V0, {L, R}) ->
        case do_eval(V0, Ctxt, Opts) of
            {'$mops_proxy', _} = V1 ->
                {[V1|L], true};
            V1 ->
                {[V1|L], R}
        end
    end,
    case lists:foldl(Fold, {[], false}, List) of
        {L, false} ->
            lists:reverse(L);
        {L, true} ->
            lists:reverse(L)
    end.



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Parses the provided binary to determine if it represents a mops expression,
%% and if it does, evaluates it against the context, otherwise returns it
%% untouched.
%% @end
%% -----------------------------------------------------------------------------
-spec eval_expr(binary(), state()) ->
    {'$mops_proxy', function()} | any() | no_return().

eval_expr(<<>>, #state{is_ground = true, is_string = true} = St) ->
    %% The end of a string (quoted) expression
    %% We reverse the list of terms and turn them into iolist()
    Fun = fun
        (X, Acc) ->
            [term_to_iolist(X)|Acc]
    end,
    iolist_to_binary(
        lists:foldl(Fun, [], St#state.acc));

eval_expr(<<>>, #state{is_ground = false, is_string = true} = St) ->
    %% The end of a string (quoted) expression
    %% We have functions so we wrap the iolist in a function receiving
    %% a future context as an argument

    Fold = fun DoFold(FAcc, FCtxt) ->
        Map = fun
            ({'$mops_proxy', F}, {Flag, Acc}) when is_function(F, 1) ->
                %% DoEval(F, {Flag, Acc});
                case F(FCtxt) of
                    {'$mops_proxy', _} = Res ->
                        {true, [Res|Acc]};
                    Res ->
                        {Flag, [term_to_iolist(Res)|Acc]}
                end;

            %% DoEval(F, {Flag, Acc}) when is_function(F, 1) ->
            %%     case F(FCtxt) of
            %%         {'$mops_proxy', _} = Res ->
            %%             {true, [Res|Acc]};
            %%         Res ->
            %%             {Flag, [term_to_iolist(Res)|Acc]}
            %%     end;

            (Val, {Flag, Acc}) ->
                {Flag, [term_to_iolist(Val)|Acc]}
        end,
        case lists:foldl(Map, {false, []}, FAcc) of
            {true, L} ->
                {'$mops_proxy',
                    fun(OtherCtxt) ->  DoFold(lists:reverse(L), OtherCtxt) end};
            {false, L} ->
                iolist_to_binary(L)
        end
    end,

    {'$mops_proxy', fun(Ctxt) ->  Fold(St#state.acc, Ctxt) end};

eval_expr(Bin0, #state{acc = [], is_string = false} = St0)
when is_binary(Bin0) ->
    %% We start parsing a binary
    Bin1 = maybe_trim(Bin0),
    case binary:match(Bin1, St0#state.sp) of
        nomatch ->
            %% No mustaches found so this is not a mop expression,
            %% we return and finish
            Bin0;
        {Pos, 2}  ->
            %% Maybe a mop expression as we found the left moustache
            %% Bin1 = maybe_trim(Bin0),
            St1 = St0#state{is_open = true},
            Len = byte_size(Bin1),
            %% We first find out if this is a string (quoted) expression
            case binary:matches(Bin1, St0#state.dqp) of
                [] when Pos =:= 0 ->
                    %% Not a string so we should have a single
                    %% mustache expression
                    parse_expr(binary:part(Bin1, 2, Len - 4), St1);
                [] when St1#state.is_string =:= true ->
                    %% An unquoted string so we might have multiple mustache expressions
                    %% e.g. "Hello {{foo}}. Today is {{date}}."
                    [Pre, Rest] = binary:split(Bin1, St0#state.sp),
                    eval_expr(Rest, acc(St1, Pre));
                [{0, 1}, {QPos, 1}] when QPos =:= Len - 1 ->
                    %% A string so we might have multiple mustache expressions
                    %% e.g. "\"Hello {{foo}}. Today is {{date}}.\""
                    Unquoted = binary:part(Bin1, 1, Len - 2),
                    [Pre, Rest] = binary:split(Unquoted, St0#state.sp),
                    eval_expr(Rest, acc(St1#state{is_string = true}, Pre));
                _ ->
                    %% An invalid expression as:
                    %% - we found quotes that are in the middle of the string %% e.g. <<"   \"foo\"">> or <<"\"foo\"   ">>
                    %% - or we have no closing quote
                    %% - or this is not a string and we have no quotes but
                    %% chars before opening mustache
                    error({badarg, Bin0})
            end
    end;

eval_expr(Bin, #state{is_open = true, is_string = true} = St0)
when is_binary(Bin) ->
    %% We continue evaluating a string (quoted) expression
    %% Split produces a list of binaries that are all referencing Bin.
    %% This means that the data in Bin is not copied to new binaries,
    %% and that Bin cannot be garbage collected until the results of the split
    %% are no longer referenced.
    case binary:split(Bin, St0#state.ep) of
        [Expr, Rest] ->
            St1 = St0#state{is_open = false},
            eval_expr(Rest, acc(St1, parse_expr(Expr, St1)));
        _ ->
            %% We did not find matching closing mustaches
            error({badarg, Bin})
    end;

eval_expr(Bin, #state{is_open = false, is_string = true} = St)
when is_binary(Bin) ->
    %% We continue evaluating a string (quoted) expression
    %% Split produces a list of binaries that are all referencing Bin.
    %% This means that the data in Bin is not copied to new binaries,
    %% and that Bin cannot be garbage collected until the results of the split
    %% are no longer referenced.
    case binary:split(Bin, St#state.sp) of
        [Pre, Rest]->
            eval_expr(Rest, acc(St#state{is_open = true}, Pre));
        [Bin] ->
            %% No more mustaches so we finish
            eval_expr(<<>>, acc(St, Bin))
    end.



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Accumulates the evaluation in the case of strings (quoted) expressions.
%% @end
%% -----------------------------------------------------------------------------
%% acc(#state{acc = []} = St, Val) ->
%%     acc(St#state{acc= [?DOUBLE_QUOTES]}, Val);

acc(St, <<>>) ->
    St;

acc(#state{acc = Acc} = St, {'$mops_proxy', _} = Val)  ->
    St#state{acc = [Val | Acc], is_ground = false};

acc(#state{acc = Acc} = St, Val) when is_function(Val, 1) ->
    St#state{acc = [Val | Acc], is_ground = false};

acc(#state{acc = Acc} = St, Val) when is_binary(Val) ->
    St#state{acc = [Val | Acc]};

acc(#state{acc = Acc} = St, Val) ->
    St#state{acc = [io_lib:format("~p", [Val]) | Acc]}.




%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Parses a single mustache expression
%% @end
%% -----------------------------------------------------------------------------
parse_expr(Bin, #state{context = Ctxt} = St) ->
    case binary:split(Bin, St#state.pop, [global]) of
        [Val] ->
            get_value(trim(Val), Ctxt);
        [Val | Ops] ->
            %% A pipe expression
            %% We evaluate the value and apply the ops in the pipe
            apply_ops([trim(P) || P <- Ops], get_value(trim(Val), Ctxt), Ctxt);
        _ ->
            error({badarg, Bin})
    end.


%% @private
get_value(Key, F) when is_function(F, 1) ->
    {'$mops_proxy', fun(X) -> get_value(Key, maybe_eval(F, X)) end};

get_value(Key, {'$mops_proxy', F} = T) when is_function(F, 1) ->
    {'$mops_proxy', fun(X) -> get_value(Key, maybe_eval(T, X)) end};

get_value(Key, Ctxt) when is_binary(Key) ->
    get_value(binary:split(Key, <<$.>>, [global]), Ctxt);

get_value(Path, Ctxt) when is_list(Path) ->
    try
        case get(Path, Ctxt) of
            {ok, '$mops_proxy', _Rem} ->
                {'$mops_proxy', fun(X) -> get_value(Path, X) end};
            {ok, Val} ->
                maybe_eval(Val, Ctxt)
        end
    catch
        error:{badkey, _} ->
            %% We blame the full key
            error({badkeypath, Path})
    end.


%% @private
get(Path, '$mops_proxy') ->
    {ok, '$mops_proxy', Path};

get([], Term) ->
    {ok, Term};

get(Path, Val) when is_function(Val, 1) ->
    Fun = fun(X) ->
        try
            get_value(Path, maybe_eval(Val, X))
        catch
            error:{badkey, _} ->
                error({badkeypath, Path})
        end
    end,
    {ok, {'$mops_proxy', Fun}};

get(Path, {'$mops_proxy', _} = Val) ->
    Fun = fun(X) ->
        try
            get_value(Path, maybe_eval(Val, X))
        catch
            error:{badkey, _} ->
                error({badkeypath, Path})
        end
    end,
    {ok, {'$mops_proxy', Fun}};

get([H|T], Ctxt) when is_map(Ctxt) ->
    get(T, maps:get(H, Ctxt)).


%% @private
apply_ops([H|T], Val, Ctxt) ->
    apply_ops(T, apply_op(H, Val, Ctxt), Ctxt);

apply_ops([], Val, _) ->
    Val.


%% @private
apply_op(Op, {'$mops_proxy', F} = Val, _)
when is_function(F, 1) andalso (
    Op == <<"integer">> orelse
    Op == <<"float">> orelse
    Op == <<"abs">> orelse
    Op == <<"head">> orelse
    Op == <<"tail">> orelse
    Op == <<"last">> orelse
    Op == <<"length">> orelse
    Op == <<"size">>
    ) ->
    {'$mops_proxy', fun(X) -> apply_op(Op, maybe_eval(Val, X), X) end};

apply_op(_, <<>>, _) ->
    <<>>;

apply_op(<<"abs">>, Val, _) when is_number(Val) ->
    abs(Val);

apply_op(<<"integer">>, Val, _) when is_binary(Val) ->
    binary_to_integer(Val);

apply_op(<<"integer">>, Val, _) when is_list(Val) ->
    list_to_integer(Val);

apply_op(<<"integer">>, Val, _) when is_integer(Val) ->
    Val;

apply_op(<<"integer">>, Val, _) when is_float(Val) ->
    trunc(Val);

apply_op(<<"float">>, Val, _) when is_binary(Val) ->
    binary_to_float(Val);

apply_op(<<"float">>, Val, _) when is_list(Val) ->
    float(list_to_integer(Val));

apply_op(<<"float">>, Val, _) when is_float(Val) ->
    Val;

apply_op(<<"float">>, Val, _) when is_integer(Val) ->
    float(Val);

apply_op(<<"head">>, [], _) ->
    <<>>;

apply_op(<<"head">>, Val, _) when is_list(Val) ->
    hd(Val);

apply_op(<<"tail">>, [], _) ->
    %% To avoid getting an exception at runtime we return []
    [];

apply_op(<<"tail">>, Val, _) when is_list(Val) ->
    tl(Val);

apply_op(<<"last">>, [], _) ->
    <<>>;

apply_op(<<"last">>, Val, _) when is_list(Val) ->
    lists:last(Val);

apply_op(<<"length">>, Val, _) when is_list(Val) ->
    length(Val);

apply_op(<<"size">>, Val, _) when is_map(Val) ->
    maps:size(Val);

%% Custom ops
apply_op(Bin, Val, Ctxt) ->
    apply_custom_op(Bin, Val, Ctxt).


%% @private

apply_custom_op(<<"get(", _/binary>> = Op, {'$mops_proxy', F} = Val, _)
when is_function(F, 1) ->
    {'$mops_proxy',
        fun(X) -> apply_custom_op(Op, maybe_eval(Val, X), X) end
    };

apply_custom_op(<<"get(", Rest/binary>> = Op, Val, Ctxt) when is_map(Val)->
    case [maybe_eval(K, Ctxt) || K <- get_arguments(Rest, Op, <<")">>)] of

        [{'$mops_proxy', F} = Key] when is_function(F, 1) ->
            {'$mops_proxy', fun(X) -> maps:get(maybe_eval(Key, X), Val) end};

        [Key] ->
            maps:get(Key, Val);

        [{'$mops_proxy', _} = Key, {'$mops_proxy', _} = Default]  ->
            {'$mops_proxy',
                fun(X) ->
                    maps:get(maybe_eval(Key, X), Val, maybe_eval(Default, X))
                end
            };

        [{'$mops_proxy', _} = Key, Default] ->
            {'$mops_proxy',
                fun(X) -> maps:get(maybe_eval(Key, X), Val, Default) end
            };

        [Key, {'$mops_proxy', _} = Default] ->
            {'$mops_proxy',
                fun(X) -> maps:get(Key, Val, maybe_eval(Default, X)) end
            };

        [Key, Default] ->
            maps:get(Key, Val, Default);

        _ ->
            error({invalid_expression, Op})
    end;

apply_custom_op(<<"put(", _/binary>> = Op, {'$mops_proxy', F} = Val, _)
when is_function(F, 1) ->
    {'$mops_proxy',
        fun(X) -> apply_custom_op(Op, maybe_eval(Val, X), X) end
    };

apply_custom_op(<<"put(", Rest/binary>> = Op, Map, Ctxt) when is_map(Map)->
    case [maybe_eval(K, Ctxt) || K <- get_arguments(Rest, Op, <<")">>)] of

        [{'$mops_proxy', _} = Key, {'$mops_proxy', _} = Value]  ->
            {'$mops_proxy',
                fun(X) ->
                    maps:put(maybe_eval(Key, X), maybe_eval(Value, X), Map)
                end
            };

        [{'$mops_proxy', _} = Key, Value] ->
            {'$mops_proxy',
                fun(X) -> maps:put(maybe_eval(Key, X), Value, Map) end
            };

        [Key, {'$mops_proxy', _} = Value] ->
            {'$mops_proxy',
                fun(X) -> maps:put(Key, maybe_eval(Value, X), Map) end
            };

        [Key, Value] ->
            maps:put(Key, Value, Map);

        _ ->
            error({invalid_expression, Op})
    end;

apply_custom_op(<<"merge(", Rest/binary>> = Op, Expr1, Ctxt) ->

    Args = case
        [maybe_eval(A, Ctxt) || A <- get_arguments(Rest, Op, <<")">>)]
    of
        [Expr2] ->
            {Expr1, Expr2};
        [<<"_">>, Expr2] ->
            {Expr1, Expr2};
        [Expr2, <<"_">>] ->
            {Expr2, Expr1};
        _ ->
            error({invalid_expression, Op})
    end,
    case Args of
        %% {{'$mops_proxy', LT}, {'$mops_proxy', RT}}
        %% when is_map(LT) andalso is_map(RT) ->
        %%     {'$mops_proxy', maps:merge(LT, RT)};

        %% {{'$mops_proxy', LT}, R} when is_map(LT) andalso is_map(R) ->
        %%     {'$mops_proxy', maps:merge(LT, R)};

        %% {L, {'$mops_proxy', RT}} when is_map(L) andalso is_map(RT) ->
        %%     {'$mops_proxy', maps:merge(L, RT)};

        {{'$mops_proxy', _} = L, {'$mops_proxy', _} = R} ->
            {'$mops_proxy',
                fun(X) -> maybe_merge(maybe_eval(L, X), maybe_eval(R, X)) end
            };

        {{'$mops_proxy', _} = L, R} ->
            {'$mops_proxy',
                fun(X) -> maybe_merge(maybe_eval(L, X), R) end
            };

        {L, {'$mops_proxy', _} = R} ->
            {'$mops_proxy',
                fun(X) -> maybe_merge(L, maybe_eval(R, X)) end
            };

        {L, R} when is_map(L), is_map(R) ->
            maps:merge(L, R);

        _ ->
            error({invalid_expression, Op})
    end;

apply_custom_op(<<"with(", _/binary>> = Op, {'$mops_proxy', _} = L, _) ->
    {'$mops_proxy',
        fun(X) -> apply_custom_op(Op, maybe_eval(L, X), X) end
    };

apply_custom_op(<<"without(", _/binary>> = Op, {'$mops_proxy', _} = L, _) ->
    {'$mops_proxy',
        fun(X) -> apply_custom_op(Op, maybe_eval(L, X), X) end
    };

apply_custom_op(<<"with([", Rest/binary>> = Op, Val, Ctxt) when is_map(Val)->
    Fold = fun(Arg, {L, R}) ->
        case maybe_eval(Arg, Ctxt) of
            {'$mops_proxy', _} = V ->
                {L, [V|R]};
            V ->
                {[V|L], R}
        end
    end,
    Args = get_arguments(Rest, Op, <<"])">>),
    case lists:foldl(Fold, {[], []}, Args) of
        {Ls, []} ->
            maps:with(Ls, Val);
        {Ls, Rs} ->
            {'$mops_proxy',
                fun(X) ->
                    Keys = lists:append(Ls, [maybe_eval(R, X) || R <- Rs]),
                    maps:with(Keys, Val)
                end
            }
    end;

apply_custom_op(<<"without([", Rest/binary>> = Op, Val, Ctxt) when is_map(Val)->
    Fold = fun(K, {L, R}) ->
        case maybe_eval(K, Ctxt) of
            {'$mops_proxy', _} = V  ->
                {L, [V|R]};
            V ->
                {[V|L], R}
        end
    end,
    Args = get_arguments(Rest, Op, <<"])">>),
    case lists:foldl(Fold, {[], []}, Args) of
        {Ls, []} ->
            maps:without(Ls, Val);
        {Ls, Rs} ->
            {'$mops_proxy',
                fun(X) ->
                    Keys = lists:append(Ls, [maybe_eval(R, X) || R <- Rs]),
                    maps:with(Keys, Val)
                end
            }
    end;

apply_custom_op(Op, Val, _) ->
    error({invalid_expression, [Op, Val]}).


%% @private
%% maybe_merge({'$mops_proxy', L}, {'$mops_proxy', R})
%% when is_map(L) andalso is_map(R) ->
%%     {'$mops_proxy', maps:merge(L, R)};

maybe_merge({'$mops_proxy', _} = L, {'$mops_proxy', _} = R) ->
    {'$mops_proxy',
        fun(X) -> maybe_merge(maybe_eval(L, X), maybe_eval(R, X)) end
    };

maybe_merge({'$mops_proxy', _} = L, R) ->
    {'$mops_proxy',
        fun(X) -> maybe_merge(maybe_eval(L, X), R) end
    };

maybe_merge(L, {'$mops_proxy', _} = R) ->
    {'$mops_proxy',
        fun(X) -> maybe_merge(L, maybe_eval(R, X)) end
    };

maybe_merge(L, R) ->
    maps:merge(L, R).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Evaluates only binary terms and any other term wrapped in a
%% '$mops_proxy' tuple. For all other terms, returns the term untouched.
%% @end
%% -----------------------------------------------------------------------------
maybe_eval({'$mops_proxy', T}, Ctxt) ->
    do_eval(T, Ctxt);

maybe_eval(Term, Ctxt) when is_binary(Term) ->
    case unquote(Term) of
        {true, Key} ->
            Key;
        {false, Expr} ->
            do_eval(Expr, Ctxt)
    end;

maybe_eval(Term, _Ctxt) ->
    Term.
    %% do_eval(Term, Ctxt).


%% @private
unquote(<<$', Rest/binary>>) ->
    {true, binary:part(Rest, {0, byte_size(Rest) - 1})};

unquote(Other) ->
    {false, Other}.


%% @private
get_arguments(Rest, Op, Terminal) ->
    Len = byte_size(Rest),
    TLen = size(Terminal),
    case binary:matches(Rest, Terminal) of
        [{Pos, TLen}] when Len - TLen == Pos ->
            Part = binary:part(Rest, 0, Len - TLen),
            binary:split(Part, <<$,>>, [global, trim_all]);
        _ ->
            error({invalid_expression, Op})
    end.


%% @private
term_to_iolist(Term) when is_binary(Term) ->
    Term;

term_to_iolist(Term) when is_list(Term) ->
    Term;

term_to_iolist(Term) ->
    io_lib:format("~p", [Term]).



maybe_trim(<<$", _Rest/binary>> = Bin) ->
    Bin;
maybe_trim(Bin) ->
    trim(Bin).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Eliminates whitespaces in a binary
%% @end
%% -----------------------------------------------------------------------------
trim(Bin) ->
    trimb(Bin, <<>>).

%% @private
trimb(<<>>, Acc) ->
    Acc;

trimb(<<C, Rest/binary>>, Acc) when C =:= $\s; C =:= $\t ->
    trimb(Rest, Acc);

trimb(Bin, Acc) ->
    case binary:match(Bin, [<<$\s>>, <<$\t>>], []) of
        nomatch ->
            <<Acc/binary, Bin/binary>>;
        {Pos, 1} ->
            Part = binary:part(Bin, 0, Pos),
            trimb(
                binary:part(Bin, Pos, byte_size(Bin) - Pos),
                <<Acc/binary, Part/binary>>)
    end.
