-module(bondy_rpc_gateway_callee_handler_SUITE).

-moduledoc """
Tests for `bondy_rpc_gateway_callee_handler`.

Tests the pure/stateless functions: path interpolation, kwarg routing
by HTTP method, HTTP status → WAMP error URI mapping, and the
readiness gate for service secret resolution. Does not require a
running Bondy dealer or HTTP backend.
""".

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Test cases
-export([
    path_no_vars/1,
    path_single_var/1,
    path_multiple_vars/1,
    path_missing_var_throws/1,
    path_var_consumed_from_kwargs/1,

    extract_vars_empty/1,
    extract_vars_single/1,
    extract_vars_multiple/1,

    route_get_empty_kwargs/1,
    route_get_with_kwargs/1,
    route_delete_with_kwargs/1,
    route_head_with_kwargs/1,
    route_post_empty_kwargs/1,
    route_post_with_kwargs/1,
    route_put_with_kwargs/1,
    route_patch_with_kwargs/1,

    error_uri_400/1,
    error_uri_401/1,
    error_uri_403/1,
    error_uri_404/1,
    error_uri_408/1,
    error_uri_422/1,
    error_uri_429/1,
    error_uri_450/1,
    error_uri_502/1,
    error_uri_503/1,
    error_uri_504/1,
    error_uri_550/1,

    success_200_json/1,
    success_201_json/1,
    error_response_includes_status_and_body/1
]).

%% readiness_gate
-export([
    handle_call_pending_service/1,
    handle_call_ready_service/1,
    handle_call_no_secrets_service/1
]).


%% ===================================================================
%% CT callbacks
%% ===================================================================

all() ->
    [{group, path_interpolation},
     {group, extract_path_vars},
     {group, kwarg_routing},
     {group, error_mapping},
     {group, response_shaping},
     {group, readiness_gate}].

groups() ->
    [{path_interpolation, [parallel], [
        path_no_vars,
        path_single_var,
        path_multiple_vars,
        path_missing_var_throws,
        path_var_consumed_from_kwargs
    ]},
    {extract_path_vars, [parallel], [
        extract_vars_empty,
        extract_vars_single,
        extract_vars_multiple
    ]},
    {kwarg_routing, [parallel], [
        route_get_empty_kwargs,
        route_get_with_kwargs,
        route_delete_with_kwargs,
        route_head_with_kwargs,
        route_post_empty_kwargs,
        route_post_with_kwargs,
        route_put_with_kwargs,
        route_patch_with_kwargs
    ]},
    {error_mapping, [parallel], [
        error_uri_400,
        error_uri_401,
        error_uri_403,
        error_uri_404,
        error_uri_408,
        error_uri_422,
        error_uri_429,
        error_uri_450,
        error_uri_502,
        error_uri_503,
        error_uri_504,
        error_uri_550
    ]},
    {response_shaping, [parallel], [
        success_200_json,
        success_201_json,
        error_response_includes_status_and_body
    ]},
    {readiness_gate, [sequence], [
        handle_call_pending_service,
        handle_call_ready_service,
        handle_call_no_secrets_service
    ]}].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(TC, Config)
  when TC =:= handle_call_pending_service;
       TC =:= handle_call_ready_service;
       TC =:= handle_call_no_secrets_service ->
    catch ets:delete(bondy_rpc_gateway_manager),
    ets:new(bondy_rpc_gateway_manager, [
        named_table, protected, set, {read_concurrency, true}
    ]),
    Config;

init_per_testcase(_TC, Config) ->
    Config.

end_per_testcase(TC, _Config)
  when TC =:= handle_call_pending_service;
       TC =:= handle_call_ready_service;
       TC =:= handle_call_no_secrets_service ->
    catch ets:delete(bondy_rpc_gateway_manager),
    ok;

end_per_testcase(_TC, _Config) ->
    ok.


%% ===================================================================
%% Path interpolation tests
%% ===================================================================

path_no_vars(_Config) ->
    KWArgs = #{<<"foo">> => <<"bar">>},
    {<<"/invoices">>, KWArgs} =
        bondy_rpc_gateway_callee_handler:interpolate_path(
            <<"/invoices">>, KWArgs
        ).

path_single_var(_Config) ->
    KWArgs = #{<<"id">> => <<"INV-001">>, <<"status">> => <<"paid">>},
    {Path, Remaining} =
        bondy_rpc_gateway_callee_handler:interpolate_path(
            <<"/invoices/{{id}}">>, KWArgs
        ),
    ?assertEqual(<<"/invoices/INV-001">>, Path),
    ?assertEqual(#{<<"status">> => <<"paid">>}, Remaining).

path_multiple_vars(_Config) ->
    KWArgs = #{
        <<"org">> => <<"acme">>,
        <<"id">> => <<"42">>,
        <<"extra">> => <<"keep">>
    },
    {Path, Remaining} =
        bondy_rpc_gateway_callee_handler:interpolate_path(
            <<"/orgs/{{org}}/invoices/{{id}}">>, KWArgs
        ),
    ?assertEqual(<<"/orgs/acme/invoices/42">>, Path),
    ?assertEqual(#{<<"extra">> => <<"keep">>}, Remaining).

path_missing_var_throws(_Config) ->
    KWArgs = #{<<"other">> => <<"val">>},
    ?assertException(
        throw, {path_var_missing, <<"id">>},
        bondy_rpc_gateway_callee_handler:interpolate_path(
            <<"/invoices/{{id}}">>, KWArgs
        )
    ).

path_var_consumed_from_kwargs(_Config) ->
    %% After interpolation, the used var should not be in remaining kwargs
    KWArgs = #{<<"id">> => <<"123">>},
    {_Path, Remaining} =
        bondy_rpc_gateway_callee_handler:interpolate_path(
            <<"/items/{{id}}">>, KWArgs
        ),
    ?assertEqual(#{}, Remaining).


%% ===================================================================
%% extract_path_vars tests
%% ===================================================================

extract_vars_empty(_Config) ->
    ?assertEqual(
        [],
        bondy_rpc_gateway_callee_handler:extract_path_vars(<<"/plain/path">>)
    ).

extract_vars_single(_Config) ->
    ?assertEqual(
        [<<"id">>],
        bondy_rpc_gateway_callee_handler:extract_path_vars(<<"/items/{{id}}">>)
    ).

extract_vars_multiple(_Config) ->
    Vars = bondy_rpc_gateway_callee_handler:extract_path_vars(
        <<"/orgs/{{org}}/projects/{{project}}/tasks/{{task}}">>
    ),
    ?assertEqual([<<"org">>, <<"project">>, <<"task">>], Vars).


%% ===================================================================
%% Kwarg routing tests
%% ===================================================================

route_get_empty_kwargs(_Config) ->
    {Url, Body} = bondy_rpc_gateway_callee_handler:route_kwargs(
        get, <<"https://api.example.com/items">>, #{}
    ),
    ?assertEqual(<<"https://api.example.com/items">>, Url),
    ?assertEqual(<<>>, Body).

route_get_with_kwargs(_Config) ->
    {Url, Body} = bondy_rpc_gateway_callee_handler:route_kwargs(
        get, <<"https://api.example.com/items">>,
        #{<<"status">> => <<"active">>}
    ),
    ?assertNotEqual(nomatch, binary:match(Url, <<"status=active">>)),
    ?assertEqual(<<>>, Body).

route_delete_with_kwargs(_Config) ->
    {Url, Body} = bondy_rpc_gateway_callee_handler:route_kwargs(
        delete, <<"https://api.example.com/items">>,
        #{<<"force">> => <<"true">>}
    ),
    ?assertNotEqual(nomatch, binary:match(Url, <<"force=true">>)),
    ?assertEqual(<<>>, Body).

route_head_with_kwargs(_Config) ->
    {Url, Body} = bondy_rpc_gateway_callee_handler:route_kwargs(
        head, <<"https://api.example.com/items">>,
        #{<<"q">> => <<"test">>}
    ),
    ?assertNotEqual(nomatch, binary:match(Url, <<"q=test">>)),
    ?assertEqual(<<>>, Body).

route_post_empty_kwargs(_Config) ->
    {Url, Body} = bondy_rpc_gateway_callee_handler:route_kwargs(
        post, <<"https://api.example.com/items">>, #{}
    ),
    ?assertEqual(<<"https://api.example.com/items">>, Url),
    ?assertEqual(<<>>, Body).

route_post_with_kwargs(_Config) ->
    {Url, Body} = bondy_rpc_gateway_callee_handler:route_kwargs(
        post, <<"https://api.example.com/items">>,
        #{<<"name">> => <<"widget">>}
    ),
    %% URL should not have query params
    ?assertEqual(<<"https://api.example.com/items">>, Url),
    %% Body should be JSON
    Decoded = json:decode(Body),
    ?assertEqual(#{<<"name">> => <<"widget">>}, Decoded).

route_put_with_kwargs(_Config) ->
    {Url, Body} = bondy_rpc_gateway_callee_handler:route_kwargs(
        put, <<"https://api.example.com/items/1">>,
        #{<<"name">> => <<"updated">>}
    ),
    ?assertEqual(<<"https://api.example.com/items/1">>, Url),
    Decoded = json:decode(Body),
    ?assertEqual(#{<<"name">> => <<"updated">>}, Decoded).

route_patch_with_kwargs(_Config) ->
    {Url, Body} = bondy_rpc_gateway_callee_handler:route_kwargs(
        patch, <<"https://api.example.com/items/1">>,
        #{<<"status">> => <<"done">>}
    ),
    ?assertEqual(<<"https://api.example.com/items/1">>, Url),
    Decoded = json:decode(Body),
    ?assertEqual(#{<<"status">> => <<"done">>}, Decoded).


%% ===================================================================
%% Error URI mapping tests
%% ===================================================================

error_uri_400(_Config) ->
    {error, Uri, _, _, _} = bondy_rpc_gateway_callee_handler:http_to_wamp(
        400, <<"{}">>
    ),
    ?assertEqual(<<"wamp.error.invalid_argument">>, Uri).

error_uri_401(_Config) ->
    {error, Uri, _, _, _} = bondy_rpc_gateway_callee_handler:http_to_wamp(
        401, <<"{}">>
    ),
    ?assertEqual(<<"wamp.error.not_authorized">>, Uri).

error_uri_403(_Config) ->
    {error, Uri, _, _, _} = bondy_rpc_gateway_callee_handler:http_to_wamp(
        403, <<"{}">>
    ),
    ?assertEqual(<<"wamp.error.not_authorized">>, Uri).

error_uri_404(_Config) ->
    {error, Uri, _, _, _} = bondy_rpc_gateway_callee_handler:http_to_wamp(
        404, <<"{}">>
    ),
    ?assertEqual(<<"wamp.error.not_found">>, Uri).

error_uri_408(_Config) ->
    {error, Uri, _, _, _} = bondy_rpc_gateway_callee_handler:http_to_wamp(
        408, <<"{}">>
    ),
    ?assertEqual(<<"wamp.error.timeout">>, Uri).

error_uri_422(_Config) ->
    {error, Uri, _, _, _} = bondy_rpc_gateway_callee_handler:http_to_wamp(
        422, <<"{}">>
    ),
    ?assertEqual(<<"wamp.error.invalid_argument">>, Uri).

error_uri_429(_Config) ->
    {error, Uri, _, _, _} = bondy_rpc_gateway_callee_handler:http_to_wamp(
        429, <<"{}">>
    ),
    ?assertEqual(<<"bondy.error.too_many_requests">>, Uri).

error_uri_450(_Config) ->
    %% Generic 4xx
    {error, Uri, _, _, _} = bondy_rpc_gateway_callee_handler:http_to_wamp(
        450, <<"{}">>
    ),
    ?assertEqual(<<"bondy.error.invalid_argument">>, Uri).

error_uri_502(_Config) ->
    {error, Uri, _, _, _} = bondy_rpc_gateway_callee_handler:http_to_wamp(
        502, <<"{}">>
    ),
    ?assertEqual(<<"bondy.error.bad_gateway">>, Uri).

error_uri_503(_Config) ->
    {error, Uri, _, _, _} = bondy_rpc_gateway_callee_handler:http_to_wamp(
        503, <<"{}">>
    ),
    ?assertEqual(<<"bondy.error.bad_gateway">>, Uri).

error_uri_504(_Config) ->
    {error, Uri, _, _, _} = bondy_rpc_gateway_callee_handler:http_to_wamp(
        504, <<"{}">>
    ),
    ?assertEqual(<<"wamp.error.timeout">>, Uri).

error_uri_550(_Config) ->
    %% Generic 5xx
    {error, Uri, _, _, _} = bondy_rpc_gateway_callee_handler:http_to_wamp(
        550, <<"{}">>
    ),
    ?assertEqual(<<"bondy.error.bad_gateway">>, Uri).


%% ===================================================================
%% Response shaping tests
%% ===================================================================

success_200_json(_Config) ->
    JsonBody = iolist_to_binary(json:encode(#{<<"key">> => <<"value">>})),
    {ok, Details, Args, KWArgs} =
        bondy_rpc_gateway_callee_handler:http_to_wamp(200, JsonBody),
    ?assertEqual(#{}, Details),
    ?assertEqual([], Args),
    ?assertEqual(200, maps:get(<<"status">>, KWArgs)),
    ?assertEqual(#{<<"key">> => <<"value">>}, maps:get(<<"body">>, KWArgs)).

success_201_json(_Config) ->
    JsonBody = iolist_to_binary(json:encode(#{<<"id">> => 42})),
    {ok, _, _, KWArgs} =
        bondy_rpc_gateway_callee_handler:http_to_wamp(201, JsonBody),
    ?assertEqual(201, maps:get(<<"status">>, KWArgs)),
    ?assertEqual(#{<<"id">> => 42}, maps:get(<<"body">>, KWArgs)).

error_response_includes_status_and_body(_Config) ->
    JsonBody = iolist_to_binary(json:encode(#{<<"error">> => <<"not found">>})),
    {error, _Uri, _Details, _Args, KWArgs} =
        bondy_rpc_gateway_callee_handler:http_to_wamp(404, JsonBody),
    ?assertEqual(404, maps:get(<<"status">>, KWArgs)),
    ?assertEqual(
        #{<<"error">> => <<"not found">>},
        maps:get(<<"body">>, KWArgs)
    ).


%% ===================================================================
%% Readiness gate tests
%% ===================================================================

handle_call_pending_service(_Config) ->
    ServiceName = <<"pending-svc">>,
    ets:insert(bondy_rpc_gateway_manager, {ServiceName, not_ready}),
    ?assertEqual(
        {error, not_ready},
        bondy_rpc_gateway_manager:get_secrets(ServiceName)
    ).

handle_call_ready_service(_Config) ->
    ServiceName = <<"ready-svc">>,
    ExtraVars = #{client_id => <<"from-secret">>, existing => <<"keep">>},
    ets:insert(
        bondy_rpc_gateway_manager, {ServiceName, {ready, ExtraVars}}
    ),

    {ok, Vars} = bondy_rpc_gateway_manager:get_secrets(ServiceName),
    %% Both vars are returned
    ?assertEqual(<<"keep">>, maps:get(existing, Vars)),
    ?assertEqual(<<"from-secret">>, maps:get(client_id, Vars)).

handle_call_no_secrets_service(_Config) ->
    ServiceName = <<"no-secrets-svc">>,
    %% No ETS entry means service has no secrets — always ready
    ?assertEqual(
        {ok, #{}},
        bondy_rpc_gateway_manager:get_secrets(ServiceName)
    ).
