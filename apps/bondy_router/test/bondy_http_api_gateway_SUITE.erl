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
    Merge = fun(Timeout, Opts) ->
        bondy_http_gateway_rest_handler:merge_call_option(
            [<<"timeout">>, timeout], Timeout, Opts
        )
    end,

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

call_retries_merge_test(_) ->
    Merge = fun(Retries, Opts) ->
        bondy_http_gateway_rest_handler:merge_call_option(
            [<<"_retries">>, '_retries'], Retries, Opts
        )
    end,
    ?assertEqual(#{<<"_retries">> => 2}, Merge(2, #{})),
    ?assertEqual(#{<<"_retries">> => 2}, Merge(2, #{<<"_retries">> => 0})),
    ?assertEqual(#{<<"_retries">> => 5}, Merge(2, #{<<"_retries">> => 5})),
    ?assertEqual(#{'_retries' => 5}, Merge(2, #{'_retries' => 5})),
    ?assertEqual(#{}, Merge(0, #{})),
    ?assertEqual(#{}, Merge(-1, #{})).

%% The action `timeout` and `retries` (inherited from `defaults`) must survive
%% parsing and, once merged, govern the WAMP call options.
call_timeout_spec_flow_test(_) ->
    Spec = #{
        <<"id">> => <<"com.timeout_api">>,
        <<"name">> => <<"com.timeout_api">>,
        <<"host">> => <<"timeout-api.com">>,
        <<"realm_uri">> => <<"com.timeout_api">>,
        <<"defaults">> => #{
            <<"timeout">> => 95000,
            <<"retries">> => 2,
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
    #{
        <<"timeout">> := Timeout,
        <<"retries">> := Retries,
        <<"options">> := Opts
    } = Action,
    ?assertEqual({95000, 2}, {Timeout, Retries}),
    ?assertEqual(
        #{<<"timeout">> => 95000, <<"_retries">> => 2},
        bondy_http_gateway_rest_handler:merge_call_option(
            [<<"_retries">>, '_retries'],
            Retries,
            bondy_http_gateway_rest_handler:merge_call_option(
                [<<"timeout">>, timeout], Timeout, Opts
            )
        )
    ).

publish_rejects_retries_test(_) ->
    ?assertError(
        {unsupported_action_keys, <<"wamp_publish">>, [<<"retries">>]},
        parse_action(publish_action(#{<<"retries">> => 2}), #{})
    ).

call_rejects_retry_timeout_test(_) ->
    ?assertError(
        {unsupported_action_keys, <<"wamp_call">>, [<<"retry_timeout">>]},
        parse_action(call_action(#{<<"retry_timeout">> => 2000}), #{})
    ).

forward_rejects_an_unbounded_retry_timeout_test(_) ->
    ?assertError(
        #{key := <<"retry_timeout">>},
        parse_action(
            #{
                <<"type">> => <<"forward">>,
                <<"host">> => <<"http://localhost:1">>,
                <<"retry_timeout">> => infinity
            },
            #{}
        )
    ).

call_accepts_an_alias_test(_) ->
    Action = parse_action(
        maps:remove(<<"args">>, call_action(#{<<"arguments">> => [1]})), #{}
    ),
    ?assertMatch(#{<<"args">> := [1]}, Action).

publish_does_not_inherit_retries_test(_) ->
    Action = parse_action(publish_action(#{}), #{<<"retries">> => 2}),
    ?assertNot(maps:is_key(<<"retries">>, Action)).

call_action(Extra) ->
    maps:merge(
        #{
            <<"type">> => <<"wamp_call">>,
            <<"procedure">> => <<"com.actions_api.call">>,
            <<"args">> => []
        },
        Extra
    ).

publish_action(Extra) ->
    maps:merge(
        #{
            <<"type">> => <<"wamp_publish">>,
            <<"topic">> => <<"com.actions_api.topic">>
        },
        Extra
    ).

%% Parses an API whose one path runs `Action`, and returns the parsed action.
parse_action(Action, Defaults) ->
    Spec = #{
        <<"id">> => <<"com.actions_api">>,
        <<"name">> => <<"com.actions_api">>,
        <<"host">> => <<"actions-api.com">>,
        <<"realm_uri">> => <<"com.actions_api">>,
        <<"defaults">> => Defaults#{
            <<"security">> => #{}, <<"schemes">> => [<<"http">>]
        },
        <<"versions">> => #{
            <<"1.0.0">> => #{
                <<"base_path">> => <<"/v1.0">>,
                <<"paths">> => #{
                    <<"/things">> => #{
                        <<"post">> => #{
                            <<"action">> => Action,
                            <<"response">> => #{
                                <<"on_error">> => #{}, <<"on_result">> => #{}
                            }
                        }
                    }
                }
            }
        }
    },
    maps_utils:get_path(
        [
            <<"versions">>,
            <<"1.0.0">>,
            <<"paths">>,
            <<"/things">>,
            <<"post">>,
            <<"action">>
        ],
        bondy_http_gateway_api_spec_parser:parse(Spec)
    ).

%% The response spec sets no `status_code`, and its body is the parser's
%% default, an empty binary.
call_error_without_a_status_keeps_the_error_status_test(_) ->
    Realm = <<"com.example.test.call_error_status">>,
    Api = <<"com.example.test.call_error_status.api">>,
    _ = bondy_realm:create(#{
        uri => Realm,
        authmethods => [<<"anonymous">>],
        security_enabled => false
    }),
    Get = #{
        <<"action">> => #{
            <<"type">> => <<"wamp_call">>,
            <<"procedure">> => <<"com.example.test.call_error_status.none">>
        },
        <<"response">> => #{<<"on_error">> => #{}, <<"on_result">> => #{}}
    },
    ok = bondy_http_gateway:load(#{
        <<"id">> => Api,
        <<"name">> => Api,
        <<"host">> => <<"_">>,
        <<"realm_uri">> => Realm,
        <<"defaults">> => #{
            <<"security">> => #{}, <<"schemes">> => [<<"http">>]
        },
        <<"versions">> => #{
            <<"1.0.0">> => #{
                <<"base_path">> => <<"/call_error_status/v1.0">>,
                <<"paths">> => #{<<"/none">> => #{<<"get">> => Get}}
            }
        }
    }),
    try
        _ = bondy_http_gateway:rebuild_dispatch_tables(),
        ?assertEqual(
            bondy_http_utils:http_status(<<"wamp.error.no_such_procedure">>),
            http_get_status(
                <<"http://localhost:18080/call_error_status/v1.0/none">>, 50
            )
        )
    after
        bondy_http_gateway:delete(Api)
    end.

%% Dispatch table rebuilds are debounced, so the route answers 404 until it is
%% mounted; a 404 never reaches the action.
http_get_status(_, 0) ->
    ct:fail(route_not_mounted);
http_get_status(Url, N) ->
    {ok, Status, _, Ref} = hackney:request(get, Url, [], <<>>, []),
    {ok, _} = hackney:body(Ref),
    case Status of
        404 ->
            timer:sleep(100),
            http_get_status(Url, N - 1);
        _ ->
            Status
    end.
