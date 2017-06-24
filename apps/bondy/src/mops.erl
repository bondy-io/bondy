%% 
%%  mops.erl - a mustache inspired map expression language
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



-module(mops).
-define(START, <<"{{">>).
-define(END, <<"}}">>).
-define(PIPE_OP, <<$|,$>>>).
-define(GET_OP, <<$-,$>,$>>>).
-define(DOUBLE_QUOTES, <<$">>).

-define(OPTS_SPEC, #{
    %% Defines the format of the keys in the map
    labels => #{
        required => true,
        default => binary,
        allow_null => false,
        datatype => {in, [binary, atom]}
    },
    %% Allows to register custom pipe operators (aka filters)
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
    sp = binary:compile_pattern(?START)                         ::  any(),
    dqp = binary:compile_pattern(?DOUBLE_QUOTES)                ::  any(),
    pop = binary:compile_pattern(?PIPE_OP)                      ::  any(),
    gop = binary:compile_pattern(?GET_OP)                       ::  any(),
    ep = binary:compile_pattern(?END)                           ::  any()
}).
-type state()       :: #state{}.




-export([eval/2]).
-export([eval/3]).





%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% Calls eval/3.
%% @end
%% -----------------------------------------------------------------------------
-spec eval(any(), Ctxt :: map()) -> any() | no_return().
eval(<<>>, _) ->
    <<>>;

eval(Val, Ctxt) when is_binary(Val) ->
    eval(Val, Ctxt, #{});

eval(Val, _) ->
    Val.

%% -----------------------------------------------------------------------------
%% @doc
%% Evaluates **Term** ( `any()') using the context **Ctxt** (`map()').
%% Returns **Term** in case the term is not a binary and does not contain a 
%% mops expression. Otherwise, it tries to resolve the expression using the
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
%% > mops:eval(<<"{{foo}}">>, #{<<"foo">> => bar}).
%% > bar
%% > mops:eval(<<"{{foo.bar}}">>, #{<<"foo">> => #{<<"bar">> => foobar}}).
%% > foobar
%% </pre>
%% @end
%% -----------------------------------------------------------------------------
-spec eval(Term :: any(), Ctxt :: map(), Opts :: map()) -> any() | no_return().

eval(<<>>, _, _) ->
    <<>>;

eval(Val, Ctxt, Opts) when is_binary(Val), is_map(Ctxt), is_map(Opts) ->
    do_eval(Val, #state{
        context = Ctxt, 
        %% TODO Opts not being used 
        opts = maps_utils:validate(Opts, ?OPTS_SPEC) 
    });

eval(Val, _, _) ->
    Val.




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
-spec do_eval(binary(), state()) -> any() | no_return().

do_eval(<<>>, #state{is_ground = true} = St) ->
    %% The end of a string (quoted expression)
    %% We reverse the list of terms and turn them into iolist()
    Fun = fun
        (X, Acc) -> 
            [term_to_iolist(X)|Acc] 
    end,
    iolist_to_binary(
        lists:foldl(Fun, [], [?DOUBLE_QUOTES | St#state.acc]));

do_eval(<<>>, #state{is_ground = false} = St) ->
    %% The end of a string (quoted expression)
    %% We have functions so we wrap the iolist in a function receiving
    %% a future context as an argument
    fun(Ctxt) ->
        Eval = fun
            (F, Acc) when is_function(F, 1) ->
                [term_to_iolist(F(Ctxt))|Acc];
            (Val, Acc) ->
                [term_to_iolist(Val)|Acc]
        end,
        iolist_to_binary(
            lists:foldl(Eval, [], [?DOUBLE_QUOTES | St#state.acc]))
    end;

do_eval(Bin0, #state{acc = []} = St0) ->
    %% We start processing a binary
    Bin1 = trim(Bin0),
    case binary:match(Bin1, St0#state.sp) of
        nomatch ->
            %% Not a mop expression, so we return and finish
            Bin1;         
        {Pos, 2}  ->
            %% Maybe a mop expression as we found the left moustache
            St1 = St0#state{is_open = true},
            Len = byte_size(Bin1),
            case binary:matches(Bin1, St0#state.dqp) of
                [] when Pos =:= 0 ->
                    %% Not a string so we should have a single 
                    %% mustache expression
                    parse_expr(
                        binary:part(Bin1, 2, Len - 4), St1);
                [{0, 1}, {QPos, 1}] when QPos =:= Len - 1 ->
                    %% A string so we might have multiple 
                    %% mustache expressions
                    %% e.g. "Hello {{foo}}. Today is {{date}}."
                    Unquoted = binary:part(Bin1, 1, Len - 2),
                    [Pre, Rest] = binary:split(Unquoted, St0#state.sp),
                    do_eval(Rest, acc(St1, Pre));
                _ ->
                    %% We found quotes that are in the middle of the string
                    %% or we have no closing quote
                    %% or this is not a string and we have no quotes but chars 
                    %% before opening mustache
                    error(badarg)
            end
    end;

do_eval(Bin, #state{is_open = true} = St0) ->
    %% Split produces a list of binaries that are all referencing Bin. 
    %% This means that the data in Bin is not copied to new binaries, 
    %% and that Bin cannot be garbage collected until the results of the split 
    %% are no longer referenced.
    case binary:split(Bin, St0#state.ep) of
        [Expr, Rest] ->
            St1 = St0#state{is_open = false},
            do_eval(Rest, acc(St1, parse_expr(Expr, St1)));
        _ ->
            %% We did not find a matching closing mustaches
            error(badarg)
    end;

do_eval(Bin, #state{is_open = false} = St) ->
    %% Split produces a list of binaries that are all referencing Bin. 
    %% This means that the data in Bin is not copied to new binaries, 
    %% and that Bin cannot be garbage collected until the results of the split 
    %% are no longer referenced.
    case binary:split(Bin, St#state.sp) of
        [Pre, Rest]->
            do_eval(Rest, acc(St#state{is_open = true}, Pre));
        [Bin] ->
            %% No more mustaches so we finish
            do_eval(<<>>, acc(St, Bin))
    end.
    

%% @private
%% -----------------------------------------------------------------------------
%% @doc
%% Accummulates the evaluation in the case of strings.
%% @end
%% -----------------------------------------------------------------------------
acc(#state{acc = []} = St, Val) ->
    acc(St#state{acc= [?DOUBLE_QUOTES]}, Val);

acc(St, <<>>) ->
    St;

acc(#state{acc = Acc} = St, Val) when is_function(Val, 1) ->
    St#state{acc = [Val | Acc], is_ground = false};

acc(#state{acc = Acc} = St, Val) when is_binary(Val) ->
    St#state{acc = [Val | Acc]};

acc(#state{acc = Acc} = St, Val) ->
    St#state{acc = [io_lib:format("~p", [Val]) | Acc]}.




%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
parse_expr(Bin, #state{context = Ctxt} = St) ->
    case binary:split(Bin, St#state.pop, [global]) of
        [Val] ->
            get_value(trim(Val), Ctxt);
        [Val | Ops] ->
            %% We evaluate the value and apply the ops in the pipe
            apply_ops([trim(P) || P <- Ops], get_value(trim(Val), Ctxt), Ctxt);
        _ ->
            error(badarg)
    end.


%% @private
get_value(Key, Ctxt) ->
    try  
        PathElems = binary:split(Key, <<$.>>, [global]),
        case get(PathElems, Ctxt) of
            {ok, '$mop_proxy', _Rem} ->
                fun(X) -> get_value(Key, X) end;
            {ok, Val} ->
                eval(Val, Ctxt)
        end
    catch
        error:{badkey, _} ->
            %% We blame the full key
            error({badkeypath, Key})
    end.


%% @private


get(Rem, '$mop_proxy') ->
    {ok, '$mop_proxy', Rem};

get([], Term) ->
    {ok, Term};

get(Key, F) when is_function(F, 1) ->
    Fun = fun(X) ->
        try 
            get_value(Key, F(X))
        catch
            error:{badkey, _} ->
                error({badkeypath, Key})
        end
    end,
    {ok, Fun};

get([H|T], Ctxt) when is_map(Ctxt) ->
    get(T, maps:get(H, Ctxt)).


%% @private
apply_ops([H|T], Acc, Ctxt) ->
    apply_ops(T, apply_op(H, Acc, Ctxt), Ctxt);

apply_ops([], Acc, _) ->
    Acc.


%% @private
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

apply_op(<<"integer">> = Op, Val, Ctxt) when is_function(Val, 1) ->
    fun(X) -> apply_op(Op, Val(X), Ctxt) end;

apply_op(<<"float">>, Val, _) when is_binary(Val) ->
    binary_to_float(Val);

apply_op(<<"float">>, Val, _) when is_list(Val) ->
    float(list_to_integer(Val));

apply_op(<<"float">>, Val, _) when is_float(Val) ->
    Val;

apply_op(<<"float">>, Val, _) when is_integer(Val) ->
    float(Val);

apply_op(<<"float">> = Op, Val, Ctxt) when is_function(Val, 1) ->
    fun(X) -> apply_op(Op, Val(X), Ctxt) end;

apply_op(_, [], _) ->
    [];

apply_op(<<"head">>, Val, _) when is_list(Val) ->
    hd(Val);

apply_op(<<"tail">>, Val, _) when is_list(Val) ->
    tl(Val);

apply_op(<<"last">>, Val, _) when is_list(Val) ->
    lists:last(Val);

apply_op(<<"length">>, Val, _) when is_list(Val) ->
    length(Val);

apply_op(Bin, Val, Ctxt) ->
    apply_custom_op(Bin, Val, Ctxt).



apply_custom_op(<<"with([", Rest/binary>> = Op, Val, Ctxt) when is_map(Val)->
    Keys = [eval(K, Ctxt) || K <- get_list_elements(Rest, Op)],
    maps:with(Keys, Val);

apply_custom_op(<<"without([", Rest/binary>> = Op, Val, Ctxt) when is_map(Val)->
    Keys = [eval(K, Ctxt) || K <- get_list_elements(Rest, Op)],
    maps:without(Keys, Val).



get_list_elements(Rest, Op) ->
    Len = byte_size(Rest),
    case binary:matches(Rest, <<"])">>) of
        [{Pos, 2}] when Len - 2 == Pos ->
            Part = binary:part(Rest, 0, Len - 2),
            binary:split(Part, <<$,>>, [global, trim_all]);
        _ ->
            error({invalid_expression, Op})
    end.

    
    



%% @private
%% TODO Replace this as it id not efficient, it generates a new binary each time
trim(Bin) ->
    re:replace(Bin, "^\\s+|\\s+$", "", [{return, binary}, global]).


%% @private
term_to_iolist(Term) when is_binary(Term) ->
    Term;

term_to_iolist(Term) when is_list(Term) ->
    Term;
    
term_to_iolist(Term) ->
    io_lib:format("~p", [Term]).