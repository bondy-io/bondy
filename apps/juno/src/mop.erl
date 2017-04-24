% dbg:tracer(), dbg:p(all,c), dbg:tpl(mop, '_', []).
% Bin = <<"\"{{foo}}\"">>.
% Len = byte_size(Bin).
% mop:eval(Bin, #{<<"foo">> => 3}).
% mop:eval(<<"\"Hello {{foo}}, {{foo}}\"">>, #{<<"foo">> => 3}).
% mop:eval(<<"\"Hello {{foo |> float |> integer}}, {{foo |> integer}}\"">>, #{<<"foo">> => 3}).
% [_, Fun, _]=mop:eval(<<"\"{{foo.bar.a |> integer}}\"">>, #{<<"foo">> => fun(X) -> X end}).
% Fun(#{<<"foo">> => #{<<"bar">> => #{<<"a">> => 3.0}}}).
% mop:eval(<<"\"{{fullname}}\"">>, #{<<"fullname">> => <<"\"{{name}} {{surname}}\"">>, <<"name">> => <<"Alejandro">>, <<"surname">> => <<"Ramallo">>}).
% mop:eval(<<"\"{{fullname}}\"">>, #{<<"fullname">> => <<"{{name}}">>, <<"name">> => <<"Alejandro">>, <<"surname">> => <<"Ramallo">>}).
-module(mop).
-define(START, <<"{{">>).
-define(END, <<"}}">>).
-define(PIPE_OP, <<$|,$>>>).
-define(DOUBLE_QUOTES, <<$">>).

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

-export([apply_op/2]).





%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% Calls eval/3.
%% @end
%% -----------------------------------------------------------------------------
-spec eval(any(), Ctxt :: map()) -> any() | no_return().
eval(Val, Ctxt) ->
    eval(Val, Ctxt, #{}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec eval(any(), Ctxt :: map(), Opts :: map()) -> any() | no_return().
eval(<<>>, _, _) ->
    <<>>;

eval(Val, Ctxt, Opts) when is_binary(Val), is_map(Opts) ->
    do_eval(Val, #state{context = Ctxt, opts = Opts});

eval(Val, _, _) ->
    Val.




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec do_eval(binary(), state()) -> any() | no_return().
do_eval(<<>>, #state{is_ground = true} = St) ->
    iolist_to_binary(lists:reverse([?DOUBLE_QUOTES | St#state.acc]));

do_eval(<<>>, St) ->
    lists:reverse([?DOUBLE_QUOTES | St#state.acc]); 

do_eval(Bin0, #state{acc = []} = St0) ->
    Bin1 = trim(Bin0),
    case binary:match(Bin1, ?START) of
        nomatch ->
            Bin1;         
        {Pos, 2}  ->
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
            error(badarg)
    end;

do_eval(Bin, #state{is_open = false} = St) ->
    case binary:split(Bin, ?START) of
        [Pre, Rest]->
            do_eval(Rest, acc(St#state{is_open = true}, Pre));
        [Bin] ->
            do_eval(<<>>, acc(St, Bin))
    end.

    

%% @private
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
        [Val | Pipes] ->
            apply_ops([trim(P) || P <- Pipes], get_value(trim(Val), Ctxt));
        _ ->
            error(badarg)
    end.


%% @private
get_value(Key, Ctxt) ->
    try 
        Val = case binary:split(Key, <<$.>>) of
            [Key] ->
                maps:get(Key, Ctxt);
            [A, B] ->
                case maps:get(A, Ctxt) of
                    V when is_map(V) ->
                        get_value(B, V);
                    V when is_function(V, 1) ->
                        fun(X) ->
                            try 
                                get_value(Key, V(X))
                            catch
                                error:{badkey, _} ->
                                    error({badkey, Key})
                            end
                        end;
                    {{M, F, A}} ->
                        {{ ?MODULE, get_value, [{{M, F, A}}, Ctxt] }}
                end
        end,
        eval(Val, Ctxt)
    catch
        error:{badkey, _} ->
            error({badkey, Key})
    end.



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

apply_op(Op, {{M, F, A}}) ->
    {?MODULE, apply_op, [Op, {{M, F, A}}]}.


%% @private
trim(Bin) ->
    re:replace(Bin, "^\\s+|\\s+$", "", [{return, binary}, global]).