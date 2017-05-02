-module(juno_api_gateway_SUITE).
-include_lib("common_test/include/ct.hrl").
-compile(export_all).

all() ->
    common:all().

groups() ->
    [{main, [parallel], common:tests(?MODULE)}].
    
simple_1_test(_) ->
    Spec = #{
        <<"host">> => <<"[www.]myapi.com">>,
        <<"realm_uri">> => <<"com.myapi">>,
        <<"variables">> => #{
            <<"foo">> => 100
        },  
        <<"defaults">> => #{
            <<"timeout">> => 15000
        },
        <<"versions">> =>  #{
            <<"1.0.0">> => #{
                <<"base_path">> => <<"/v1.0">>,
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
    Expected = #{
        <<"host">> => <<"[www.]myapi.com">>,
        <<"realm_uri">> => <<"com.myapi">>,
        <<"versions">> => #{
            <<"1.0.0">> => #{
                <<"base_path">> => <<"/v1.0">>,
                <<"is_active">> => false,
                <<"is_deprecated">> => false,
                <<"paths">> => #{
                    <<"/things">> => #{
                        <<"accepts">> => [
                            <<"application/json">>,<<"application/msgpack">>
                        ],
                        <<"provides">> => [
                            <<"application/json">>,<<"application/msgpack">>
                        ],
                        <<"get">> => #{
                            <<"action">> => #{
                                <<"arguments">> => [300],
                                <<"arguments_kw">> => #{},
                                <<"details">> => #{},
                                <<"procedure">> => <<"com.myapi.foo">>,
                                <<"retries">> => 0,
                                <<"timeout">> => 30000,
                                <<"type">> => <<"wamp_call">>
                            },
                            <<"response">> => #{
                                <<"on_error">> => #{
                                    <<"body">> => <<>>,
                                    <<"headers">> => #{}
                                },
                                <<"on_result">> => #{
                                    <<"body">> => <<>>,
                                    <<"headers">> => #{}
                                },
                                <<"on_timeout">> => #{
                                    <<"body">> => <<>>,
                                    <<"headers">> => #{}
                                }
                            }
                        },
                        <<"allowed_methods">> => [<<"get">>],
                        <<"is_collection">> => false
                    }
                }
            }
        }
    },
    Expected =:= juno_rest_api_gateway_spec:analyse(Spec).