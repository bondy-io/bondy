%% =============================================================================
%%  mop_SUITE.erl -
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

simple_2_0_test(_) ->
   <<"3">> =:= mops:eval(<<"\"{{foo}}\"">>, #{<<"foo">> => 3}).

simple_2_1_test(_) ->
    <<"3">> =:= mops:eval(<<"\"{{foo}}\"">>, #{<<"foo">> => "3"}).

simple_2_2_test(_) ->
    <<"3">> =:= mops:eval(<<"\"{{foo}}\"">>, #{<<"foo">> => <<"3">>}).

simple_3_test(_) ->
   <<"The number is 3">> =:= mops:eval(<<"\"The number is {{foo}}\"">>, #{<<"foo">> => 3}).

simple_4_test(_) ->
    try mops:eval(<<"The number is {{foo}}">>, #{<<"foo">> => 3})
    catch
        error:{badarg, _} -> ok;
        _ -> error(wrong_result)
    end.

simple_5_test(_) ->
   <<"3 3">> =:= mops:eval(<<"\"{{foo}} {{foo}}\"">>, #{<<"foo">> => 3}).

simple_future_1_test(_) ->
    Proxy = mops:proxy(),
    {Proxy, F} = mops:eval(
        <<"\"The number is {{foo}}\"">>, #{<<"foo">> => Proxy}),
    true = is_function(F, 1),
    <<"The number is 3">> = F(#{<<"foo">> => 3}).

simple_future_2_test(_) ->
    Proxy = mops:proxy(),
    {Proxy, F} = mops:eval(
        <<"\"The number is {{foo}} or {{bar}}\"">>, #{<<"foo">> => Proxy, <<"bar">> => Proxy}),
    true = is_function(F, 1),
    {Proxy, F2} = F(#{<<"foo">> => 3, <<"bar">> => Proxy}),
    <<"The number is 3 or 4">> = F2(#{<<"bar">> => 4}).

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


with_1_test(_) ->
    Ctxt = #{
        <<"foo">> => #{
            <<"bar">> => #{
                <<"x">> => 1,
                <<"y">> => 2,
                <<"z">> => 3
            }
        }
    },
    [<<"x">>] =:= maps:keys(
        mops:eval(<<"{{foo.bar |> with([x])}}">>, Ctxt)).


without_1_test(_) ->
    Ctxt = #{
        <<"foo">> => #{
            <<"bar">> => #{
                <<"x">> => 1,
                <<"_y">> => 2,
                <<"z">> => 3
            }
        }
    },
    [<<"x">>] =:= maps:keys(
        mops:eval(<<"{{foo.bar |> without([_y,z])}}">>, Ctxt)).

without_2_test(_) ->
    Ctxt = #{
        <<"foo">> => #{
            <<"key">> => <<"y">>,
            <<"bar">> => #{
                <<"x">> => 1,
                <<"y">> => 2,
                <<"z">> => 3
            }
        }
    },
    Res = mops:eval(<<"{{foo.bar |> without([{{foo.key}},z])}}">>, Ctxt),
    [<<"x">>] = maps:keys(Res).

without_3_test(_) ->
    Ctxt = #{
        <<"foo">> => #{
            <<"bar">> => #{}
        }
    },
    Res = mops:eval(<<"{{foo.bar |> without([a,b,c])}}">>, Ctxt),
    maps:size(Res) =:= 0.


lists_1_test(_) ->
    Ctxt = #{<<"foo">> => [1,2,3]},
    1 =:= mops:eval(<<"{{foo |> head}}">>, Ctxt).

lists_2_test(_) ->
    Ctxt = #{<<"foo">> => [1,2,3]},
    [2,3] =:= mops:eval(<<"{{foo |> tail}}">>, Ctxt).

lists_3_test(_) ->
    Ctxt = #{<<"foo">> => [1,2,3]},
    [3] =:= mops:eval(<<"{{foo |> last}}">>, Ctxt).

maps_get_1_test(_) ->
    Ctxt = #{<<"foo">> => #{<<"bar">> => 1, <<"key">> => <<"bar">>}},
    1 =:= mops:eval(<<"{{foo |> get({{foo.key}})}}">>, Ctxt).


maps_get_2_test(_) ->
    Ctxt = #{<<"foo">> => #{<<"key">> => <<"bar">>}},
    1 =:= mops:eval(<<"{{foo |> get({{foo.key}}, 1)}}">>, Ctxt).


maps_get_string_1_test(_) ->
    Ctxt = #{<<"foo">> => #{<<"bar">> => 1}},
    1 =:= mops:eval(<<"{{foo |> get('bar')}}">>, Ctxt).

maps_get_string_2_test(_) ->
    Ctxt = #{<<"foo">> => #{<<"bar">> => 1}},
    1 =:= mops:eval(<<"{{foo |> get(bar)}}">>, Ctxt).

maps_get_string_3_test(_) ->
    Ctxt = #{<<"foo">> => #{<<"a">> => 100}},
    1 =:= mops:eval(<<"{{foo |> get(bar, 1) |> integer}}">>, Ctxt).

maps_get_string_4_test(_) ->
    Ctxt = #{<<"foo">> => #{<<"a">> => 100}},
    <<>> =:= mops:eval(<<"{{foo |> get(bar, '')}}">>, Ctxt).

maps_get_string_5_test(_) ->
    Ctxt = #{<<"foo">> => #{<<"a">> => 100}},
    <<>> =:= mops:eval(<<"{{foo |> get(bar, '' )}}">>, Ctxt).


merge_left_1_test(_) ->
    Ctxt = #{
        <<"foo">> => #{<<"a">> => 1},
        <<"bar">> => #{<<"a">> => 10}
    },
    #{<<"a">> => 10} =:= mops:eval(<<"{{foo |> merge({{bar}})}}">>, Ctxt).

merge_left_2_test(_) ->
    Ctxt = #{
        <<"foo">> => #{<<"a">> => 1},
        <<"bar">> => #{<<"a">> => 10}
    },
    #{<<"a">> => 10} =:= mops:eval(<<"{{foo |> merge(_,{{bar}})}}">>, Ctxt).

merge_right_test(_) ->
    Ctxt = #{
        <<"foo">> => #{<<"a">> => 1},
        <<"bar">> => #{<<"a">> => 10}
    },
    #{<<"a">> => 1} =:= mops:eval(<<"{{foo |> merge({{bar}}, _)}}">>, Ctxt).

merge_right_2_test(_) ->
    Ctxt0 = #{
        <<"map1">> => #{
            <<"a">> => <<"{{map2.c}}">>,
            <<"b">> => 2
        },
        <<"map2">> => '$mops_proxy',
        <<"map3">> => #{}
    },
    Ctxt1 = #{
        <<"map2">> => #{<<"c">> => 1}
    },
    Map = mops:eval(<<"{{map3 |> merge({{map1}})}}">>, Ctxt0),
    #{<<"a">> := 1, <<"b">> := 2} = mops:eval(Map, Ctxt1).


%% merge_right_3_test(_) ->
%%     Ctxt0 = #{
%%         <<"wamp_error_override">> => #{
%%             <<"code">> => <<"{{action.error.error_uri}}">>,
%%             <<"message">> => <<"{{action.error.arguments |> head}}">>
%%         },
%%         <<"action">> => '$mops_proxy',
%%         <<"wamp_error_body">> => <<"{{action.error.arguments_kw |> merge({{wamp_error_override}})}}">>
%%     },
%%     Ctxt1 = #{
%%         <<"action">> => #{
%%             <<"error">> => #{
%%                 <<"error_uri">> => <<"com.foo">>,
%%                 <<"arguments">> => [<<"foobar">>],
%%                 <<"arguments_kw">> =>#{}
%%             }
%%         }
%%     },
%%     Map = mops:eval(<<"{{wamp_error_body}}">>, Ctxt0),
%%     #{<<"code">> := <<"com.foo">>, <<"message">> := <<"foobar">>} = mops:eval(Map, Ctxt1).