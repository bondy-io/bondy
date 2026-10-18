%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Integration test for the API Gateway spec store on bondy_db. Booting
%% bondy_router exercises the store end to end: `bondy_namespace_catalog`
%% provisions the durable
%% `api_gateway` bondy_db table by default, and `bondy_http_gateway` reads /
%% writes it and subscribes to its change events. The CRUD round-trip proves
%% load → lookup → list → delete all flow through bondy_db.

-module(bondy_http_gateway_store_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, <<"com.bondy.test.gateway_store">>).
-define(SPEC_ID, <<"com.bondy.test.gateway_store">>).

all() ->
    bondy_ct:all().

groups() ->
    [{main, [], bondy_ct:tests(?MODULE)}].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    _ = bondy_realm:create(#{
        uri => ?REALM,
        description => <<"API Gateway store cut-over test realm">>,
        security_enabled => false
    }),
    Config.

end_per_suite(Config) ->
    Config.

%% The catalogue provisions the api_gateway bondy_db table at boot (it is the
%% migrated domain), so a reactor subscription and reads have a live table.
catalogue_provisions_api_gateway_test(_) ->
    Main = bondy_namespace_catalog:main_db_name(),
    ?assertMatch(
        #{entity_type := api_gateway, db_name := Main},
        bondy_namespace_catalog:table(api_gateway)
    ).

%% A catalogue-snapshot bootstrap installs the api_gateway projection
%% WHOLESALE and emits no per-cell event, so the gateway is told with a
%% `bondy_oplog_core_bootstrap_event` instead. `handle_info/2` runs in the
%% gateway's OWN gen_server, so an exception there kills the process that
%% owns every HTTP route on the node. Asserts the process SURVIVES and stays
%% responsive, and that the rebuild it performs is itself callable.
%% Deliberately not mecking `bondy_listener_ranch`: replacing a module under
%% a live listener stack is a bigger risk than the thing under test.
bootstrap_event_rebuilds_and_does_not_kill_the_gateway_test(_) ->
    Pid = whereis(bondy_http_gateway),
    ?assert(is_pid(Pid)),

    %% The rebuild the clause performs must work on its own terms.
    ?assertEqual(ok, bondy_http_gateway:rebuild_dispatch_tables()),

    Pid ! {bondy_oplog_core_bootstrap_event, some_ns, api_gateway},

    %% `sys:get_state/2` is a synchronous round-trip through the gen_server
    %% loop: it returns only once the message above has been handled, so it
    %% doubles as the barrier and the liveness check.
    _ = sys:get_state(Pid, 10000),
    ?assertEqual(
        Pid,
        whereis(bondy_http_gateway),
        "the bootstrap clause must not take down the API Gateway"
    ),

    %% Still serving: a normal call continues to work afterwards.
    ?assertEqual({error, not_found}, bondy_http_gateway:lookup(<<"nope">>)).

%% load → lookup → list → delete, all through the bondy_db-backed store.
crud_roundtrip_test(_) ->
    ?assertEqual({error, not_found}, bondy_http_gateway:lookup(?SPEC_ID)),

    ok = bondy_http_gateway:load(spec(?SPEC_ID, ?REALM)),

    %% Lookup returns the stored SOURCE spec (with the `ts` field load adds).
    Stored = bondy_http_gateway:lookup(?SPEC_ID),
    ?assert(is_map(Stored)),
    ?assertEqual(?SPEC_ID, maps:get(<<"id">>, Stored)),
    ?assert(maps:is_key(<<"ts">>, Stored)),

    ?assert(has_spec(?SPEC_ID, bondy_http_gateway:list())),

    ok = bondy_http_gateway:delete(?SPEC_ID),
    ?assertEqual({error, not_found}, bondy_http_gateway:lookup(?SPEC_ID)),
    ?assertEqual(false, has_spec(?SPEC_ID, bondy_http_gateway:list())).

%% lww `clear` is non-terminal: re-loading a deleted id reanimates it.
reload_after_delete_test(_) ->
    Id = <<"com.bondy.test.gateway_store.reload">>,
    ok = bondy_http_gateway:load(spec(Id, ?REALM)),
    ?assert(is_map(bondy_http_gateway:lookup(Id))),
    ok = bondy_http_gateway:delete(Id),
    ?assertEqual({error, not_found}, bondy_http_gateway:lookup(Id)),
    ok = bondy_http_gateway:load(spec(Id, ?REALM)),
    ?assert(is_map(bondy_http_gateway:lookup(Id))),
    ok = bondy_http_gateway:delete(Id).

%% A stored spec that fails to parse is reported `rejected` with its reason,
%% is not loaded, and stays stored; a valid spec beside it still loads. The
%% unparseable spec is written straight into the store, as only a parser
%% change could produce one there.
rejected_spec_is_reported_and_kept_test(_) ->
    Good = <<"com.bondy.test.gateway_store.good">>,
    Bad = <<"com.bondy.test.gateway_store.unparseable">>,
    ok = bondy_http_gateway:load(spec(Good, ?REALM)),
    ok = store_raw(Bad, #{<<"id">> => Bad, <<"name">> => Bad, <<"ts">> => 1}),
    Rules = bondy_http_gateway:routes(#{transport => tcp}),
    ?assertNotEqual([], Rules),
    ?assertMatch(#{status := active}, status_of(Good)),
    ?assertMatch(
        #{status := rejected, reason := Reason} when is_binary(Reason),
        status_of(Bad)
    ),
    ?assert(is_map(bondy_http_gateway:lookup(Bad))),
    ok = bondy_http_gateway:delete(Bad),
    ok = bondy_http_gateway:delete(Good),
    _ = bondy_http_gateway:routes(#{transport => tcp}),
    ?assertEqual(error, find_status(Bad)).

%% A valid spec whose realm does not exist yet is `pending_realm`, and becomes
%% `active` on the first build after the realm is created.
pending_realm_spec_activates_with_its_realm_test(_) ->
    Realm = <<"com.bondy.test.gateway_store.late_realm">>,
    Id = <<"com.bondy.test.gateway_store.pending">>,
    ok = store_raw(Id, (spec(Id, Realm))#{<<"ts">> => 1}),
    _ = bondy_http_gateway:routes(#{transport => tcp}),
    ?assertEqual(
        #{id => Id, status => pending_realm, realm_uri => Realm},
        status_of(Id)
    ),
    _ = bondy_realm:create(#{
        uri => Realm,
        description => <<"API Gateway late realm">>,
        security_enabled => false
    }),
    _ = bondy_http_gateway:routes(#{transport => tcp}),
    ?assertMatch(#{status := active}, status_of(Id)),
    ok = bondy_http_gateway:delete(Id).

%% Loading an invalid spec through the API fails and stores nothing.
invalid_spec_is_not_stored_on_load_test(_) ->
    Id = <<"com.bondy.test.gateway_store.invalid_load">>,
    ?assertMatch(
        {error, _},
        bondy_http_gateway:load(#{<<"id">> => Id, <<"name">> => Id})
    ),
    ?assertEqual({error, not_found}, bondy_http_gateway:lookup(Id)).

%% A configuration file that is not valid JSON is refused with a reason, so the
%% boot that applies it stops instead of running without its specifications.
apply_config_refuses_an_unparseable_file_test(Config) ->
    File = config_file(Config, "unparseable.json", <<"{not json">>),
    with_config_file(File, fun() ->
        ?assertMatch(
            {error, {invalid_json_format, _}},
            bondy_http_gateway:apply_config()
        )
    end).

%% One invalid specification refuses the whole file and stores nothing, so a
%% valid specification listed after it is not loaded half-way.
apply_config_with_an_invalid_spec_stores_none_test(Config) ->
    Good = <<"com.bondy.test.gateway_store.declared_good">>,
    Bad = <<"com.bondy.test.gateway_store.declared_bad">>,
    Json = json:encode([
        #{<<"id">> => Bad, <<"name">> => Bad}, spec(Good, ?REALM)
    ]),
    File = config_file(Config, "invalid_spec.json", Json),
    with_config_file(File, fun() ->
        ?assertMatch(
            {error, {invalid_specifications, [{Bad, _}]}},
            bondy_http_gateway:apply_config()
        ),
        ?assertEqual({error, not_found}, bondy_http_gateway:lookup(Good))
    end).

%% A file of valid specifications loads every one of them.
apply_config_loads_every_valid_spec_test(Config) ->
    A = <<"com.bondy.test.gateway_store.declared_a">>,
    B = <<"com.bondy.test.gateway_store.declared_b">>,
    Json = json:encode([spec(A, ?REALM), spec(B, ?REALM)]),
    File = config_file(Config, "valid_specs.json", Json),
    with_config_file(File, fun() ->
        ?assertEqual(ok, bondy_http_gateway:apply_config()),
        ?assert(is_map(bondy_http_gateway:lookup(A))),
        ?assert(is_map(bondy_http_gateway:lookup(B)))
    end),
    ok = bondy_http_gateway:delete(A),
    ok = bondy_http_gateway:delete(B).

%% A request for a spec whose realm was removed is answered as
%% `no_such_realm`, the error a client can act on, not as an internal error.
%% Exercises the handler's authorization step directly: a spec's routes are
%% installed only while its realm exists, so the realm must vanish between two
%% dispatch rebuilds for a request to get here.
removed_realm_is_answered_as_no_such_realm_test(_) ->
    Self = self(),
    ok = meck:new(cowboy_req, [passthrough, no_link]),
    ok = meck:expect(cowboy_req, reply, fun(Status, _Headers, Body, Req) ->
        Self ! {reply, Status, iolist_to_binary(Body)},
        Req
    end),
    ok = meck:expect(cowboy_req, reply, fun(Status, Req) ->
        Self !
            {reply, Status, iolist_to_binary(maps:get(resp_body, Req, <<>>))},
        Req
    end),
    Request = #{
        <<"id">> => <<"t">>,
        <<"method">> => <<"get">>,
        <<"scheme">> => <<"http">>,
        <<"peername">> => <<"127.0.0.1:1">>,
        <<"path">> => <<"/p">>,
        <<"query_string">> => <<>>,
        <<"bindings">> => #{},
        <<"body_length">> => 0
    },
    St = #{
        realm_uri => <<"com.bondy.test.gateway_store.removed_realm">>,
        api_context => #{<<"request">> => Request},
        body_evaluated => false
    },
    try
        {stop, _, _} = bondy_http_gateway_rest_handler:is_authorized(
            #{ref => default, headers => #{}, resp_headers => #{}}, St
        ),
        receive
            {reply, Status, Body} ->
                #{<<"code">> := Code} = json:decode(Body),
                ?assertEqual(<<"wamp.error.no_such_realm">>, Code),
                ?assertNotEqual(500, Status)
        after 1000 ->
            ct:fail(no_reply)
        end
    after
        meck:unload(cowboy_req)
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

config_file(Config, Name, Contents) ->
    File = filename:join(?config(priv_dir, Config), Name),
    ok = file:write_file(File, Contents),
    File.

%% Applies with `File` as the configured API Gateway file, then restores the
%% previous setting.
with_config_file(File, Fun) ->
    Key = [api_gateway, config_file],
    Prev = bondy_config:get(Key, undefined),
    ok = bondy_config:set(Key, File),
    try
        Fun()
    after
        ok = bondy_config:set(Key, Prev)
    end.

has_spec(Id, Specs) ->
    lists:any(fun(S) -> maps:get(<<"id">>, S) =:= Id end, Specs).

%% Writes `Spec` under `Id` as the gateway stores it, bypassing load/1's
%% validation.
store_raw(Id, Spec) ->
    Table = bondy_namespace_catalog:table(api_gateway),
    bondy_db:apply(Table, <<>>, Id, {set, Spec}).

status_of(Id) ->
    {ok, Status} = find_status(Id),
    Status.

find_status(Id) ->
    case [S || #{id := I} = S <- bondy_http_gateway:status(), I =:= Id] of
        [Status] -> {ok, Status};
        [] -> error
    end.

spec(Id, RealmUri) ->
    #{
        <<"id">> => Id,
        <<"name">> => Id,
        <<"host">> => <<"[www.]myapi.com">>,
        <<"realm_uri">> => RealmUri,
        <<"variables">> => #{
            <<"schemes">> => [<<"http">>]
        },
        <<"defaults">> => #{
            <<"timeout">> => 15000,
            <<"schemes">> => <<"{{variables.schemes}}">>
        },
        <<"versions">> => #{
            <<"1.0.0">> => #{
                <<"base_path">> => <<"/v1.0">>,
                <<"paths">> => #{
                    <<"/things">> => #{
                        <<"get">> => #{
                            <<"action">> => #{
                                <<"type">> => <<"wamp_call">>,
                                <<"procedure">> => <<"com.bondy.things.list">>,
                                <<"options">> => #{},
                                <<"args">> => [<<"{{request.query_params}}">>],
                                <<"kwargs">> => #{}
                            },
                            <<"response">> => #{
                                <<"on_error">> => #{},
                                <<"on_result">> => #{
                                    <<"body">> => <<"{{action.result}}">>
                                }
                            }
                        }
                    }
                }
            }
        }
    }.
