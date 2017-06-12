-module(mop_SUITE).
-include_lib("common_test/include/ct.hrl").
-compile(export_all).

all() ->
    common:all().

groups() ->
    [{main, [parallel], common:tests(?MODULE)}].
    
% Bin = <<"\"{{foo}}\"">>.
% Len = byte_size(Bin).
% 
% mops:eval(<<"\"Hello {{foo}}, {{foo}}\"">>, #{<<"foo">> => 3}).
% mops:eval(<<"\"Hello {{foo |> float |> integer}}, {{foo |> integer}}\"">>, #{<<"foo">> => 3}).
% [_, Fun, _]=mops:eval(<<"\"{{foo.bar.a |> integer}}\"">>, #{<<"foo">> => fun(X) -> X end}).
% Fun(#{<<"foo">> => #{<<"bar">> => #{<<"a">> => 3.0}}}).
% mops:eval(<<"{{fullname}}>>, #{<<"fullname">> => <<"\"{{name}} {{surname}}\"">>, <<"name">> => <<"Alejandro">>, <<"surname">> => <<"Ramallo">>}).
% mops:eval(<<"{{fullname}}">>, #{<<"fullname">> => <<"{{name}}">>, <<"name">> => <<"Alejandro">>, <<"surname">> => <<"Ramallo">>}).
% mops:eval(<<"{{fullname}}">>, #{<<"fullname">> => <<"{{name}}">>, <<"name">> => <<"Alejandro">>, <<"surname">> => <<"Ramallo">>}).

simple_1_test(_) ->
   3 =:= mops:eval(<<"{{foo}}">>, #{<<"foo">> => 3}).

simple_2_test(_) ->
   <<"3">> =:= mops:eval(<<"\"{{foo}}\"">>, #{<<"foo">> => 3}).

simple_3_test(_) ->
   <<"3">> =:= mops:eval(<<"\"The number is {{foo}}\"">>, #{<<"foo">> => 3}).

simple_4_test(_) ->
    try mops:eval(<<"The number is {{foo}}">>, #{<<"foo">> => 3})
    catch
        error:badarg -> ok;
        _ -> error(wrong_result)
    end.

simple_5_test(_) ->
   <<"3 3">> =:= mops:eval(<<"\"{{foo}} {{foo}}\"">>, #{<<"foo">> => 3}).

pipe_1_test(_) ->
   3 =:= mops:eval(<<"{{foo |> integer}}">>, #{<<"foo">> => 3}).

pipe_2_test(_) ->
   3 =:= mops:eval(<<"{{foo |> integer}}">>, #{<<"foo">> => 3.0}).

pipe_3_test(_) ->
   3.0 =:= mops:eval(<<"{{foo |> integer |> float}}">>, #{<<"foo">> => 3.0}).

recursive_1_test(_) ->
    Ctxt = #{ 
        <<"name">> => <<"{{lastname}}">>, 
        <<"lastname">> => <<"{{surname}}">>,
        <<"surname">> => <<"Ramallo">>
    },
    true = mops:eval(<<"{{surname}}">>, Ctxt) =:= mops:eval(<<"{{lastname}}">>, Ctxt),
    <<"Ramallo">> =:= mops:eval(<<"{{name}}">>, Ctxt).

recursive_2_test(_) ->
    Ctxt = #{
        <<"fullname">> => <<"\"{{name}} {{surname}}\"">>, 
        <<"name">> => <<"Alejandro">>, 
        <<"surname">> => <<"Ramallo">>
    },
    <<"Alejandro Ramallo">> =:= mops:eval(<<"{{fullname}}">>, Ctxt).

recursive_3_test(_) ->
    Ctxt = #{
        <<"fullname">> => <<"\"{{name}} {{surname}}\"">>, 
        <<"name">> => <<"Alejandro">>, 
        <<"surname">> => <<"Ramallo">>
    },
    <<"\"Alejandro Ramallo\"">> =:= mops:eval(<<"\"{{fullname}}\"">>, Ctxt).

funny_1_test(_) ->
    Ctxt = #{
        <<"variables">> => #{
            <<"foo">> => <<"{{variables.bar}}">>,
            <<"bar">> => 200
        },
        <<"defaults">> => #{
            <<"foobar">> => <<"{{variables.foo}}">>
        }
    },
    200 =:= mops:eval(<<"{{defaults.foobar}}">>, Ctxt).

funny_2_test(_) ->
    Ctxt = #{
        <<"variables">> => #{
            <<"foo">> => <<"{{variables.bar}}">>,
            <<"bar">> => 200
        },
        <<"defaults">> => #{
            <<"foobar">> => #{
                <<"value">> => <<"{{variables.foo}}">>
            }
        }
    },
    200 =:= mops:eval(<<"{{defaults.foobar.value}}">>, Ctxt).