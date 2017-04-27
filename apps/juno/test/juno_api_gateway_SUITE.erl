-module(juno_api_gateway_SUITE).
-include_lib("common_test/include/ct.hrl").
-compile(export_all).

all() ->
    common:all().

groups() ->
    [{main, [parallel], common:tests(?MODULE)}].
    
simple_1_test(_) ->
    Spec = #{
        <<"host">> => <<"myapi.com">>,
        <<"variables">> => #{
            <<"foo">> => 100
        },  
        <<"defaults">> => #{
            <<"timeout">> => 15000
        },
        <<"versions">> =>  #{
            <<"1.0.0">> => #{
                <<"version">> => <<"1.0.0">>,
                <<"variables">> => #{
                    <<"foo">> => 200
                },  
                <<"defaults">> => #{
                    <<"timeout">> => 20000
                },
                <<"paths">> => #{
                    <<"/things">> => #{
                        <<"variables">> => #{
                            <<"foo">> => 300
                        },  
                        <<"defaults">> => #{
                            <<"timeout">> => 30000
                        },
                        <<"get">> => #{
                            <<"action">> => #{
                                <<"type">> => <<"wamp_call">>,
                                <<"procedure">> => <<"com.myapi.foo">>,
                                <<"details">> => #{},
                                <<"arguments">> => [<<"{{variables.foo}}">>],
                                <<"arguments_kw">> => #{}
                            },
                            <<"response">> => #{
                                <<"on_timeout">> => #{
                                
                                },
                                <<"on_error">> => #{
                                
                                },
                                <<"on_result">> => #{
                                
                                }
                            }
                        }
                    }
                }
            }
        }
    },
    juno_api_gateway_spec:analyse(Spec).