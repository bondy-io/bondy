%% =============================================================================
%%  bondy_api_gateway_SUITE.erl -
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

-module(bondy_api_gateway_SUITE).
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
                                <<"options">> => #{},
                                <<"arguments">> => [
                                    <<"{{request.query_params}}">>
                                ],
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
                                <<"options">> => #{},
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
    Expected = bondy_api_gateway_spec_parser:parse(Spec).
