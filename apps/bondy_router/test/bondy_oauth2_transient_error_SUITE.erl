%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% A transient condition of the node — the token store refusing a durable
%% write, or the AE freshness fence refusing to authenticate — is reported to
%% the OAuth2 client as `service_unavailable` / `temporarily_unavailable`
%% (503 + `retry-after`), never as `internal_error` remapped to 400 nor as
%% `invalid_client` / `invalid_grant`. Every case here asserts the status the
%% old code produced is NOT what the client gets.
%%
%% The store refusal is injected at the facade (`bondy_db:apply/4`, passthrough
%% for every table but the token table) rather than by saturating a shard: the
%% classification is what is under test, not the oplog's admission control.
%% =============================================================================

-module(bondy_oauth2_transient_error_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("bondy_security.hrl").
-include("bondy_db_tables.hrl").
-include("http_api.hrl").

-define(REALM_URI, <<"com.example.test.oauth2_transient">>).
-define(OWNER, <<"owner_1">>).
-define(CLIENT, <<"client_1">>).
-define(PASS, <<"aWe11KeptSecret">>).

-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([end_per_testcase/2]).

-export([issue_refused_write_is_service_unavailable/1]).
-export([issue_timed_out_barrier_is_service_unavailable/1]).
-export([issue_fault_is_not_service_unavailable/1]).
-export([refresh_refused_write_is_service_unavailable/1]).
-export([revoke_refused_write_is_service_unavailable/1]).
-export([fence_replies_503_not_401/1]).
-export([token_endpoint_replies_503_when_store_refuses/1]).
-export([token_endpoint_replies_503_under_memory_pressure/1]).
-export([token_endpoint_replies_503_when_busy/1]).
-export([token_endpoint_gate_disabled_admits_when_busy/1]).
-export([crafted_refresh_string_with_nul_is_refused_not_crashed/1]).

all() ->
    [
        issue_refused_write_is_service_unavailable,
        issue_timed_out_barrier_is_service_unavailable,
        issue_fault_is_not_service_unavailable,
        refresh_refused_write_is_service_unavailable,
        revoke_refused_write_is_service_unavailable,
        fence_replies_503_not_401,
        token_endpoint_replies_503_when_store_refuses,
        token_endpoint_replies_503_under_memory_pressure,
        token_endpoint_replies_503_when_busy,
        token_endpoint_gate_disabled_admits_when_busy,
        crafted_refresh_string_with_nul_is_refused_not_crashed
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    _ = bondy_realm:create(#{
        uri => ?REALM_URI,
        authmethods => [?WAMP_OAUTH2_AUTH, ?PASSWORD_AUTH],
        security_enabled => true,
        groups => [
            #{name => <<"g">>},
            #{name => <<"api_clients">>},
            #{name => <<"resource_owners">>}
        ],
        users => [
            #{
                username => ?OWNER,
                password => ?PASS,
                groups => [<<"resource_owners">>, <<"g">>]
            },
            #{
                username => ?CLIENT,
                password => ?PASS,
                groups => [<<"api_clients">>]
            }
        ],
        sources => [
            #{
                usernames => <<"all">>,
                authmethod => ?PASSWORD_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ],
        grants => [
            #{
                permissions => [<<"wamp.call">>],
                uri => <<"">>,
                match => <<"prefix">>,
                roles => <<"all">>
            }
        ]
    }),
    Config.

end_per_suite(Config) ->
    {save_config, Config}.

end_per_testcase(_Case, _Config) ->
    _ = [
        try
            meck:unload(M)
        catch
            _:_ -> ok
        end
     || M <- [bondy_db, bondy_auth]
    ],
    ok.

%% =============================================================================
%% TESTS — store refusals at the token module
%% =============================================================================

issue_refused_write_is_service_unavailable(_Config) ->
    ok = refuse_token_writes({error, backpressure}),
    ?assertEqual(
        {error, service_unavailable},
        issue_token(?OWNER, <<"device_1">>)
    ).

issue_timed_out_barrier_is_service_unavailable(_Config) ->
    ok = refuse_token_writes({error, timeout}),
    ?assertEqual(
        {error, service_unavailable},
        issue_token(?OWNER, <<"device_1">>)
    ).

issue_fault_is_not_service_unavailable(_Config) ->
    %% A fault in the store — the write RAISING rather than answering
    %% `{error, _}` — is not the store refusing: it must not be dressed up as
    %% the retryable `service_unavailable`. It surfaces as the fault it is.
    TokenTab = bondy_namespace_catalog:table(?BONDY_DB_OAUTH_TOKEN_TAB),
    TokenType = maps:get(entity_type, TokenTab),
    ok = meck:new(bondy_db, [passthrough, no_link]),
    ok = meck:expect(bondy_db, apply, fun(Table, Realm, Key, Op) ->
        case maps:get(entity_type, Table) of
            TokenType -> error(boom);
            _ -> meck:passthrough([Table, Realm, Key, Op])
        end
    end),
    ?assertEqual({error, boom}, issue_token(?OWNER, <<"device_1">>)).

refresh_refused_write_is_service_unavailable(_Config) ->
    {ok, T} = issue_token(?OWNER, <<"device_2">>),
    RT = bondy_oauth_token:to_refresh_token(T),
    ok = refuse_token_writes({error, backpressure}),
    ?assertEqual(
        {error, service_unavailable},
        bondy_oauth_token:refresh(?REALM_URI, RT)
    ),
    %% The write was refused, so the presented token was NOT rotated: it
    %% still refreshes once the store accepts writes again.
    ok = meck:unload(bondy_db),
    ?assertMatch({ok, _}, bondy_oauth_token:refresh(?REALM_URI, RT)).

revoke_refused_write_is_service_unavailable(_Config) ->
    {ok, T} = issue_token(?OWNER, <<"device_3">>),
    RT = bondy_oauth_token:to_refresh_token(T),
    ok = refuse_token_writes({error, backpressure}),
    %% RFC 7009 §2.2.1: a refused revocation must not be answered `ok` —
    %% the token still exists.
    ?assertEqual(
        {error, service_unavailable},
        bondy_oauth_token:revoke(?REALM_URI, RT)
    ),
    ok = meck:unload(bondy_db),
    ?assertMatch({ok, _}, bondy_oauth_token:lookup(?REALM_URI, RT)),
    ?assertEqual(ok, bondy_oauth_token:revoke(?REALM_URI, RT)),
    ?assertEqual(
        {error, oauth2_invalid_grant},
        bondy_oauth_token:refresh(?REALM_URI, RT)
    ).

%% =============================================================================
%% TESTS — the handler
%% =============================================================================

fence_replies_503_not_401(_Config) ->
    %% The AE freshness fence lives in `bondy_auth:authenticate/4` and reaches
    %% the handler as a thrown `temporarily_unavailable` from
    %% `do_authenticate/3`. The generic catch used to answer 401
    %% `invalid_client`; the client's credentials were never the problem.
    ok = meck:new(bondy_auth, [passthrough, no_link]),
    ok = meck:expect(bondy_auth, authenticate, fun(_M, _S, _R, _C) ->
        {error, temporarily_unavailable}
    end),

    Req0 = client_request(?CLIENT, ?PASS),
    {cowboy_rest, _, St} = bondy_oauth2_rest_handler:init(Req0, #{
        realm_uri => ?REALM_URI,
        token_path => <<"/token">>,
        revoke_path => <<"/revoke">>
    }),
    ?assertMatch(
        {stop, _, _},
        bondy_oauth2_rest_handler:is_authorized(Req0, St)
    ),
    {Status, Headers, Body} = sent_response(),
    ?assertEqual(?HTTP_SERVICE_UNAVAILABLE, Status),
    ?assertNotEqual(?HTTP_UNAUTHORIZED, Status),
    ?assertEqual(<<"1">>, maps:get(<<"retry-after">>, Headers)),
    ?assertMatch(
        #{<<"uri">> := <<"bondy.error.temporarily_unavailable">>},
        json:decode(iolist_to_binary(Body))
    ).

token_endpoint_replies_503_when_store_refuses(_Config) ->
    %% The customer's symptom end to end: a password grant whose token the
    %% store refuses to write. Through the handler — client auth, body,
    %% owner auth, issue — the client gets 503 + `retry-after`, never the
    %% 400 the old `database_error` → 500 → 400 remap produced.
    ok = refuse_token_writes({error, backpressure}),
    Body = <<
        "grant_type=password&username=owner_1&password=aWe11KeptSecret"
        "&client_device_id=device_e2e"
    >>,
    {Status, Headers, RespBody} = post_token(?CLIENT, ?PASS, Body),
    ?assertEqual(?HTTP_SERVICE_UNAVAILABLE, Status),
    ?assertNotEqual(?HTTP_BAD_REQUEST, Status),
    ?assertEqual(<<"1">>, maps:get(<<"retry-after">>, Headers)),
    ?assertMatch(
        #{<<"uri">> := <<"wamp.error.unavailable">>},
        json:decode(iolist_to_binary(RespBody))
    ),
    %% And with the store back, the same request is a 200 with a token.
    ok = meck:unload(bondy_db),
    {200, _, OkBody} = post_token(?CLIENT, ?PASS, Body),
    ?assertMatch(
        #{<<"access_token">> := _, <<"refresh_token">> := _},
        json:decode(iolist_to_binary(OkBody))
    ).

token_endpoint_replies_503_under_memory_pressure(_Config) ->
    %% The admission gate: a node above its memory high watermark refuses
    %% the grant before any credential work — client auth is never entered,
    %% which the passthrough mock on `bondy_auth' pins — with the same 503 +
    %% `retry-after' as every transient refusal and a message naming the
    %% condition. The state is the real sampler's
    %% (`bondy_ct:with_memory_high/1'), not a forced status. Back to normal,
    %% the same request is a 200 with a token, and now auth ran.
    ok = meck:new(bondy_auth, [passthrough, no_link]),
    Body = <<
        "grant_type=password&username=owner_1&password=aWe11KeptSecret"
        "&client_device_id=device_mem"
    >>,
    bondy_ct:with_memory_high(fun() ->
        {Status, Headers, RespBody} = post_token(?CLIENT, ?PASS, Body),
        ?assertEqual(?HTTP_SERVICE_UNAVAILABLE, Status),
        ?assertEqual(<<"1">>, maps:get(<<"retry-after">>, Headers)),
        ?assertMatch(
            #{
                <<"uri">> := <<"wamp.error.unavailable">>,
                <<"nature">> := <<"transient">>,
                <<"message">> :=
                    <<"The server is under memory pressure", _/binary>>
            },
            json:decode(iolist_to_binary(RespBody))
        ),
        ?assertNot(meck:called(bondy_auth, init, '_'))
    end),
    {200, _, OkBody} = post_token(?CLIENT, ?PASS, Body),
    ?assertMatch(
        #{<<"access_token">> := _, <<"refresh_token">> := _},
        json:decode(iolist_to_binary(OkBody))
    ),
    ?assert(meck:called(bondy_auth, init, '_')).

token_endpoint_replies_503_when_busy(_Config) ->
    %% The gate's other sensor: a busy node (deep run queues, the state the
    %% HELLO gate refuses on) refuses the grant the same way — before any
    %% credential work, 503 + `retry-after', a message naming the condition.
    %% The busy state is forced (`bondy_ct:with_load_busy/1'); the memory
    %% monitor is at normal, so this is the load sensor's refusal.
    ok = meck:new(bondy_auth, [passthrough, no_link]),
    Body = <<
        "grant_type=password&username=owner_1&password=aWe11KeptSecret"
        "&client_device_id=device_busy"
    >>,
    bondy_ct:with_load_busy(fun() ->
        ?assertNot(bondy_regulator_memory:high()),
        {Status, Headers, RespBody} = post_token(?CLIENT, ?PASS, Body),
        ?assertEqual(?HTTP_SERVICE_UNAVAILABLE, Status),
        ?assertEqual(<<"1">>, maps:get(<<"retry-after">>, Headers)),
        ?assertMatch(
            #{
                <<"uri">> := <<"wamp.error.unavailable">>,
                <<"nature">> := <<"transient">>,
                <<"message">> := <<"The server is overloaded", _/binary>>
            },
            json:decode(iolist_to_binary(RespBody))
        ),
        ?assertNot(meck:called(bondy_auth, init, '_'))
    end),
    {200, _, OkBody} = post_token(?CLIENT, ?PASS, Body),
    ?assertMatch(
        #{<<"access_token">> := _, <<"refresh_token">> := _},
        json:decode(iolist_to_binary(OkBody))
    ),
    ?assert(meck:called(bondy_auth, init, '_')).

token_endpoint_gate_disabled_admits_when_busy(_Config) ->
    %% `load_regulation.oauth2.enabled = off' takes the gate out: a busy node
    %% still runs the grant (and issues the token), as `hello.enabled' does
    %% for HELLO.
    ok = bondy_config:set([load_regulation, oauth2, enabled], false),
    Body = <<
        "grant_type=password&username=owner_1&password=aWe11KeptSecret"
        "&client_device_id=device_gate_off"
    >>,
    try
        bondy_ct:with_load_busy(fun() ->
            {Status, _, OkBody} = post_token(?CLIENT, ?PASS, Body),
            ?assertEqual(200, Status),
            ?assertMatch(
                #{<<"access_token">> := _},
                json:decode(iolist_to_binary(OkBody))
            )
        end)
    after
        ok = bondy_config:set([load_regulation, oauth2, enabled], true)
    end.

crafted_refresh_string_with_nul_is_refused_not_crashed(_Config) ->
    %% A refresh string is client input that becomes a store key (the
    %% legacy-pointer lookup). One carrying the key codec's separator byte
    %% used to be decoded as a column by the table's `leading_col` routing
    %% and crash the request with `function_clause`; it is a string this
    %% module never minted, and is answered like any other unknown token.
    Crafted = <<"not-a-token", 0, "x">>,
    ?assertEqual(
        {error, oauth2_invalid_grant},
        bondy_oauth_token:refresh(?REALM_URI, Crafted)
    ),
    ?assertEqual(ok, bondy_oauth_token:revoke(?REALM_URI, Crafted)),
    ?assertMatch({error, _}, bondy_oauth_token:lookup(?REALM_URI, Crafted)),
    %% The same through the endpoint: a 400 `invalid_grant`, not a crash.
    Body = <<"grant_type=refresh_token&refresh_token=not-a-token%00x">>,
    {Status, _Headers, RespBody} = post_token(?CLIENT, ?PASS, Body),
    ?assertEqual(?HTTP_BAD_REQUEST, Status),
    ?assertMatch(
        #{<<"uri">> := <<"bondy.error.invalid_grant">>},
        json:decode(iolist_to_binary(RespBody))
    ).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
%% `bondy_db:apply/4` refuses writes on the token table with `Reply`, and
%% passes every other table through untouched.
refuse_token_writes(Reply) ->
    %% A table handle carries no name; its `entity_type` identifies it.
    TokenTab = bondy_namespace_catalog:table(?BONDY_DB_OAUTH_TOKEN_TAB),
    TokenType = maps:get(entity_type, TokenTab),
    ok = meck:new(bondy_db, [passthrough, no_link]),
    ok = meck:expect(bondy_db, apply, fun(Table, Realm, Key, Op) ->
        case maps:get(entity_type, Table) of
            TokenType -> Reply;
            _ -> meck:passthrough([Table, Realm, Key, Op])
        end
    end),
    ok.

%% @private
issue_token(User, DeviceId) ->
    SessionId = bondy_session_id:new(),
    {ok, Ctxt} = bondy_auth:init(
        SessionId, ?REALM_URI, User, [<<"g">>], {127, 0, 0, 1}
    ),
    bondy_oauth_token:issue(password, Ctxt, #{device_id => DeviceId}).

%% @private
%% A cowboy request map with just what `is_authorized/2` and `reply/2` read:
%% the listener ref (CORS config lookup), the peer, the Basic credentials, and
%% the stream identity `cowboy_req:reply/4` sends the response to — this
%% process, so `sent_response/0` can read it back.
client_request(ClientId, Password) ->
    Creds = base64:encode(<<ClientId/binary, ":", Password/binary>>),
    #{
        ref => admin,
        pid => self(),
        streamid => 1,
        method => <<"POST">>,
        peer => {{127, 0, 0, 1}, 5000},
        headers => #{
            <<"authorization">> => <<"Basic ", Creds/binary>>,
            <<"content-type">> => <<"application/x-www-form-urlencoded">>
        }
    }.

%% @private
%% `POST /token` through the handler's own callbacks, with this process
%% playing cowboy's stream: the handler runs in a spawned process whose
%% request names this one as the connection, so the body read
%% (`cowboy_req:read_urlencoded_body/1` casts `read_body` to the
%% connection and waits for `request_body`) and an error reply
%% (`cowboy_req:reply/4` casts `response`) both arrive here as the messages
%% cowboy would exchange. A refusal at `is_authorized/2` stops the request
%% before any body is read, so the body is served only if asked for. A
%% successful grant is `{true, Req, St}` with the token in `Req`'s response
%% body — cowboy_rest, not the handler, sends that 200 — so it is read off
%% the returned request. Returns `{Status, Headers, Body}` either way.
post_token(ClientId, Password, Body) ->
    Req0 = maps:merge(client_request(ClientId, Password), #{
        path => <<"/token">>,
        has_body => true,
        body_length => byte_size(Body)
    }),
    Opts = #{
        realm_uri => ?REALM_URI,
        token_path => <<"/token">>,
        revoke_path => <<"/revoke">>
    },
    Parent = self(),
    Handler = spawn_link(fun() ->
        {cowboy_rest, _, St0} = bondy_oauth2_rest_handler:init(Req0, Opts),
        Result =
            case bondy_oauth2_rest_handler:is_authorized(Req0, St0) of
                {true, Req1, St1} ->
                    bondy_oauth2_rest_handler:accept(Req1, St1);
                {stop, _, _} = Stop ->
                    Stop
            end,
        Parent ! {accepted, self(), Result}
    end),
    serve(Handler, Body).

%% @private
serve(Handler, Body) ->
    receive
        {{_Conn, 1}, {read_body, Handler, Ref, _Length, _Period}} ->
            Handler ! {request_body, Ref, fin, byte_size(Body), Body},
            serve(Handler, Body);
        {accepted, Handler, {stop, _Req, _St}} ->
            sent_response();
        {accepted, Handler, {true, Req, _St}} ->
            {200, maps:get(resp_headers, Req, #{}), maps:get(resp_body, Req)}
    after 5000 ->
        exit(handler_never_finished)
    end.

%% @private
sent_response() ->
    receive
        {{_Pid, 1}, {response, Status, Headers, Body}} ->
            {Status, Headers, Body}
    after 5000 ->
        exit(no_response_sent)
    end.
