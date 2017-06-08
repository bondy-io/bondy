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
            <<"foo">> => 100,
            <<"schemes">> => [<<"http">>],
            <<"oauth2">> => #{
                <<"type">> => <<"oauth2">>,
                <<"flow">> => <<"resource_owner_password_credentials">>,
                <<"token_path">> => <<"/auth/token">>,
                <<"revoke_token_path">> => <<"/auth/revoke_token">>,
                <<"schemes">> => <<"{{variables.schemes}}">>
            }
        },  
        <<"defaults">> => #{
            <<"timeout">> => 15000,
            <<"security">> => <<"{{variables.oauth2}}">>,
            <<"schemes">> => <<"{{variables.schemes}}">>
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
                                <<"procedure">> => <<"com.magenta.things.list">>,
                                <<"details">> => #{},
                                <<"arguments">> => [<<"{{request.query_params}}">>],
                                <<"arguments_kw">> => #{}
                            },
                            <<"response">> => #{
                                <<"on_error">> => #{
                                
                                },
                                <<"on_result">> => #{
                                  <<"body">> => <<"{{action.result}}">>
                                }
                            }
                        }
                    },
                    <<"/agents">> => #{
                        <<"security">> => #{},
                        <<"get">> => #{
                            <<"action">> => #{
                                <<"type">> => <<"wamp_call">>,
                                <<"procedure">> => <<"com.myapi.foo">>,
                                <<"details">> => #{},
                                <<"arguments">> => [<<"{{variables.foo}}">>],
                                <<"arguments_kw">> => #{}
                            },
                            <<"response">> => #{
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
                <<"pool_size">> => 200,
                <<"paths">> => #{
                    <<"/agents">> => #{
                        <<"accepts">> => [<<"application/json">>,<<"application/msgpack">>],
                        <<"allowed_methods">> => [<<"GET">>],
                        <<"get">> => #{
                            <<"action">> => #{
                                <<"arguments">> => [200],
                                <<"arguments_kw">> => #{},
                                <<"details">> => #{},
                                <<"procedure">> => <<"com.myapi.foo">>,
                                <<"retries">> => 0,
                                <<"timeout">> => 20000,
                                <<"type">> => <<"wamp_call">>},
                            <<"response">> => #{<<"on_error">> => #{<<"body">> => <<>>,<<"headers">> => #{}},
                            <<"on_result">> => #{<<"body">> => <<>>,<<"headers">> => #{}}
                            }},
                        <<"is_collection">> => false,
                        <<"provides">> => [<<"application/json">>,<<"application/msgpack">>],
                        <<"schemes">> => [<<"http">>],
                        <<"security">> => #{}
                    },
                    <<"/things">> => #{
                        <<"accepts">> => [<<"application/json">>,<<"application/msgpack">>],
                        <<"allowed_methods">> => [<<"GET">>],
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
                                }
                            }
                        },
                        <<"is_collection">> => false,
                        <<"provides">> => [<<"application/json">>,<<"application/msgpack">>],
                        <<"schemes">> => [<<"http">>],
                        <<"security">> => #{
                            <<"type">> => <<"oauth2">>,
                            <<"flow">> => <<"resource_owner_password_credentials">>,
                            <<"token_path">> => <<"/auth/token">>,
                            <<"revoke_token_path">> => <<"/auth/revoke_token">>,
                            <<"schemes">> => [<<"http">>]
                        }
                    }
                }
            }
        }
    },
    Expected = juno_rest_api_gateway_spec:parse(Spec),
    Result = juno_rest_api_gateway_spec:compile([Expected]),
    Final = juno_rest_api_gateway_spec:load(Result),
    io:format("Result ~p~n", [Final]).