%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2017. All rights reserved.
%% -----------------------------------------------------------------------------

-module(mop).
-define(START, <<"{{">>).
-define(END, <<"}}">>).
-define(PIPE_OP, <<$|,$>>>).
-define(DOUBLE_QUOTES, <<$">>).

-define(OPTS_SPEC, #{
    labels => #{
        required => true,
        default => binary,
        allow_null => false,
        datatype => {in, [binary, atom]}
    },
    operators => #{
        required => false,
        allow_null => false,
        validator => fun
            ({Name, Fun} = Op) 
            when (is_atom(Name) orelse is_binary(Name)) 
            andalso is_function(Fun, 1) ->
                {ok, Op};
            (_) ->
                false
        end
    }
}).

-record(state, {
    context             :: map(),
    opts                :: map(),
    acc = []            :: any(),
    is_ground = true    :: boolean(),
    is_open = false     :: boolean()
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
%% mop expression. Otherwise, it tries to resolve the expression using the
%% **Ctxt**.
%%
%% The following are valid mop expressions and their meanings:
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
%% > mop:eval(foo, #{<<"foo">> => bar}).
%% > foo
%% > mop:eval(<<"foo">>, #{<<"foo">> => bar}).
%% > <<"foo">>
%% > mop:eval(<<"{{foo}}">>, #{<<"foo">> => bar}).
%% > bar
%% > mop:eval(<<"{{foo.bar}}">>, #{<<"foo">> => #{<<"bar">> => foobar}}).
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
    case binary:match(Bin1, ?START) of
        nomatch ->
            %% Not a mop expression, so we return and finish
            Bin1;         
        {Pos, 2}  ->
            %% Maybe a mop expression as we found the left moustache
            St1 = St0#state{is_open = true},
            Len = byte_size(Bin1),
            case binary:matches(Bin1, ?DOUBLE_QUOTES) of
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
                    [Pre, Rest] = binary:split(Unquoted, ?START),
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
    case binary:split(Bin, ?END) of
        [Expr, Rest] ->
            St1 = St0#state{is_open = false},
            do_eval(Rest, acc(St1, parse_expr(Expr, St1)));
        _ ->
            %% We did not find a matching closing mustaches
            error(badarg)
    end;

do_eval(Bin, #state{is_open = false} = St) ->
    case binary:split(Bin, ?START) of
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
parse_expr(Bin, #state{context = Ctxt}) ->
    case binary:split(Bin, ?PIPE_OP, [global]) of
        [Val] ->
            get_value(trim(Val), Ctxt);
        [Val | Ops] ->
            %% We evaluate the value and apply the ops in the pipe
            apply_ops([trim(P) || P <- Ops], get_value(trim(Val), Ctxt));
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
apply_ops([H|T], Acc) ->
    apply_ops(T, apply_op(H, Acc));

apply_ops([], Acc) ->
    Acc.


%% @private
apply_op(<<"integer">>, Val) when is_binary(Val) ->
    binary_to_integer(Val);

apply_op(<<"integer">>, Val) when is_list(Val) ->
    list_to_integer(Val);

apply_op(<<"integer">>, Val) when is_integer(Val) ->
    Val;

apply_op(<<"integer">>, Val) when is_float(Val) ->
    trunc(Val);

apply_op(<<"integer">> = Op, Val) when is_function(Val, 1) ->
    fun(X) -> apply_op(Op, Val(X)) end;

apply_op(<<"float">>, Val) when is_binary(Val) ->
    binary_to_float(Val);

apply_op(<<"float">>, Val) when is_list(Val) ->
    float(list_to_integer(Val));

apply_op(<<"float">>, Val) when is_float(Val) ->
    Val;

apply_op(<<"float">>, Val) when is_integer(Val) ->
    float(Val);

apply_op(<<"float">> = Op, Val) when is_function(Val, 1) ->
    fun(X) -> apply_op(Op, Val(X)) end;

apply_op(Op, _) ->
    error({unknown_pipe_operator, Op}).



%% @private
trim(Bin) ->
    re:replace(Bin, "^\\s+|\\s+$", "", [{return, binary}, global]).


%% @private
term_to_iolist(Term) when is_binary(Term) ->
    Term;

term_to_iolist(Term) when is_list(Term) ->
    Term;
    
term_to_iolist(Term) ->
    io_lib:format("~p", [Term]).