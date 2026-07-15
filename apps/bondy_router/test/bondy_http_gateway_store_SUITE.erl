%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Integration test for the API Gateway spec store after its cut-over from
%% plum_db to bondy_db (design §11.4). Booting bondy_router exercises the
%% cut-over end to end: `bondy_namespace_catalog` provisions the durable
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
    ?assertMatch(
        #{entity_type := api_gateway, db_name := core},
        bondy_namespace_catalog:table(api_gateway)
    ).

%% load → lookup → list → delete, all through the bondy_db-backed store.
crud_roundtrip_test(_) ->
    %% Absent to begin with.
    ?assertEqual({error, not_found}, bondy_http_gateway:lookup(?SPEC_ID)),

    %% Load writes the spec to bondy_db and rebuilds the dispatch tables.
    ok = bondy_http_gateway:load(spec(?SPEC_ID, ?REALM)),

    %% Lookup returns the stored SOURCE spec (with the `ts` field load adds).
    Stored = bondy_http_gateway:lookup(?SPEC_ID),
    ?assert(is_map(Stored)),
    ?assertEqual(?SPEC_ID, maps:get(<<"id">>, Stored)),
    ?assert(maps:is_key(<<"ts">>, Stored)),

    %% list/0 includes it.
    ?assert(has_spec(?SPEC_ID, bondy_http_gateway:list())),

    %% Delete clears the cell and rebuilds; the spec is gone from both reads.
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

%% =============================================================================
%% Helpers
%% =============================================================================

has_spec(Id, Specs) ->
    lists:any(fun(S) -> maps:get(<<"id">>, S) =:= Id end, Specs).

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
