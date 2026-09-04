%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_api_gateway_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-compile([nowarn_export_all, export_all]).

all() ->
    bondy_ct:all().

groups() ->
    [{main, [parallel], bondy_ct:tests(?MODULE)}].

%% The spec parser validates WAMP URIs through `bondy_wamp_config`, so the
%% suite needs Bondy running — without this it only passed when an earlier
%% suite in the same run had already started it (order dependence).
init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Config.

end_per_suite(Config) ->
    {save_config, Config}.

simple_1_test(_) ->
    Spec = #{
        <<"id">> => <<"com.myapi">>,
        <<"name">> => <<"com.myapi">>,
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
        <<"versions">> => #{
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
                                <<"procedure">> =>
                                    <<"com.magenta.things.list">>,
                                <<"options">> => #{},
                                <<"args">> => [
                                    <<"{{request.query_params}}">>
                                ],
                                <<"kwargs">> => #{}
                            },
                            <<"response">> => #{
                                <<"on_error">> => #{},
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
                                <<"args">> => [<<"{{variables.foo}}">>],
                                <<"kwargs">> => #{}
                            },
                            <<"response">> => #{
                                <<"on_error">> => #{},
                                <<"on_result">> => #{}
                            }
                        }
                    }
                }
            }
        }
    },
    bondy_http_gateway_api_spec_parser:parse(Spec).

call_timeout_merge_test(_) ->
    Merge = fun bondy_http_gateway_rest_handler:merge_call_timeout/2,

    %% The action timeout is merged when options define no timeout
    ?assertEqual(#{<<"timeout">> => 90000}, Merge(90000, #{})),

    %% Per WAMP, options.timeout = 0 means the Call Timeout feature is
    %% disabled, so the action timeout applies
    ?assertEqual(
        #{<<"timeout">> => 90000},
        Merge(90000, #{<<"timeout">> => 0})
    ),

    %% An explicit non-zero options.timeout wins over the action timeout
    ?assertEqual(
        #{<<"timeout">> => 120000},
        Merge(90000, #{<<"timeout">> => 120000})
    ),
    ?assertEqual(
        #{timeout => 120000},
        Merge(90000, #{timeout => 120000})
    ),

    %% An unset or invalid action timeout leaves the options untouched
    ?assertEqual(#{}, Merge(0, #{})),
    ?assertEqual(#{}, Merge(undefined, #{})).

%% Regression test: the action `timeout` (inherited from `defaults.timeout`)
%% must survive parsing and, once merged, govern the WAMP call options.
%% Previous versions parsed the value but discarded it before calling
%% `bondy:call/5`, so the spec's timeout had no effect.
call_timeout_spec_flow_test(_) ->
    Spec = #{
        <<"id">> => <<"com.timeout_api">>,
        <<"name">> => <<"com.timeout_api">>,
        <<"host">> => <<"timeout-api.com">>,
        <<"realm_uri">> => <<"com.timeout_api">>,
        <<"defaults">> => #{
            <<"timeout">> => 95000,
            <<"security">> => #{},
            <<"schemes">> => [<<"http">>]
        },
        <<"versions">> => #{
            <<"1.0.0">> => #{
                <<"base_path">> => <<"/v1.0">>,
                <<"paths">> => #{
                    <<"/things">> => #{
                        <<"get">> => #{
                            <<"action">> => #{
                                <<"type">> => <<"wamp_call">>,
                                <<"procedure">> => <<"com.timeout_api.get">>,
                                <<"options">> => #{},
                                <<"args">> => [],
                                <<"kwargs">> => #{}
                            },
                            <<"response">> => #{
                                <<"on_error">> => #{},
                                <<"on_result">> => #{}
                            }
                        }
                    }
                }
            }
        }
    },
    Parsed = bondy_http_gateway_api_spec_parser:parse(Spec),
    Action = maps_utils:get_path(
        [
            <<"versions">>,
            <<"1.0.0">>,
            <<"paths">>,
            <<"/things">>,
            <<"get">>,
            <<"action">>
        ],
        Parsed
    ),
    #{<<"timeout">> := Timeout, <<"options">> := Opts} = Action,
    ?assertEqual(95000, Timeout),
    ?assertEqual(
        #{<<"timeout">> => 95000},
        bondy_http_gateway_rest_handler:merge_call_timeout(Timeout, Opts)
    ).
