%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_gateway_forward_SUITE).
-moduledoc """
The HTTP gateway's `forward` action against an upstream that the test starts
late, or never, so the gateway meets a refused connection first.

The upstream is a raw TCP listener that reports each request it reads as
`{upstream_request, Port}` and answers it with a fixed status, so a case asserts
how many requests reached the upstream, not only what the client got.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("bondy_security.hrl").

-define(API, ~"com.example.test.http_forward.api").
-define(REALM, ~"com.example.test.http_forward").
-define(BASE_PATH, ~"/http_forward/v1.0").
-define(RETRY_TIMEOUT, 300).

-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([get_is_sent_again_until_the_upstream_answers/1]).
-export([get_without_retries_fails_at_once/1]).
-export([get_fails_when_the_retries_run_out/1]).
-export([post_is_not_sent_again/1]).
-export([an_answer_is_not_retried/1]).
-export([a_response_without_a_status_keeps_the_upstream_status/1]).
-export([an_upstream_that_does_not_answer_times_out/1]).
-export([an_upstream_body_is_returned_as_it_is/1]).
-export([an_upstream_body_keeps_its_content_type/1]).
-export([the_spec_content_type_overrides_the_upstream/1]).
-export([upstream/3]).

all() ->
    [
        get_is_sent_again_until_the_upstream_answers,
        get_without_retries_fails_at_once,
        get_fails_when_the_retries_run_out,
        post_is_not_sent_again,
        an_answer_is_not_retried,
        a_response_without_a_status_keeps_the_upstream_status,
        an_upstream_that_does_not_answer_times_out,
        an_upstream_body_is_returned_as_it_is,
        an_upstream_body_keeps_its_content_type,
        the_spec_content_type_overrides_the_upstream
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    _ = bondy_realm:create(#{
        uri => ?REALM,
        authmethods => [?WAMP_ANON_AUTH],
        security_enabled => false
    }),
    Ports =
        #{
            Case => free_port()
         || Case <- [
                late,
                once,
                never,
                post,
                answer,
                plain_ok,
                plain_error,
                silent,
                json_body,
                text_body,
                typed_body,
                spec_typed_body
            ]
        },
    ok = bondy_http_gateway:load(#{
        ~"id" => ?API,
        ~"name" => ?API,
        ~"host" => ~"_",
        ~"realm_uri" => ?REALM,
        ~"defaults" => #{
            ~"security" => #{},
            ~"schemes" => [~"http"],
            ~"timeout" => 5000,
            ~"retry_timeout" => ?RETRY_TIMEOUT
        },
        ~"versions" => #{
            ~"1.0.0" => #{
                ~"base_path" => ?BASE_PATH,
                ~"paths" => #{
                    ~"/late" => #{~"get" => forward(Ports, late, 3)},
                    ~"/once" => #{~"get" => forward(Ports, once, 0)},
                    ~"/never" => #{~"get" => forward(Ports, never, 2)},
                    ~"/post" => #{~"post" => forward(Ports, post, 3)},
                    ~"/answer" => #{~"get" => forward(Ports, answer, 3)},
                    ~"/plain_ok" => #{~"get" => plain(Ports, plain_ok)},
                    ~"/plain_error" => #{~"get" => plain(Ports, plain_error)},
                    ~"/silent" => #{~"get" => silent(Ports)},
                    ~"/json_body" => #{~"get" => forward(Ports, json_body, 0)},
                    ~"/text_body" => #{~"get" => forward(Ports, text_body, 0)},
                    ~"/typed_body" => #{
                        ~"get" => forward(Ports, typed_body, 0)
                    },
                    ~"/spec_typed_body" => #{~"get" => spec_typed(Ports)}
                }
            }
        }
    }),
    _ = bondy_http_gateway:rebuild_dispatch_tables(),
    [{ports, Ports} | Config].

end_per_suite(_) ->
    bondy_http_gateway:delete(?API).

%% =============================================================================
%% CASES
%% =============================================================================

get_is_sent_again_until_the_upstream_answers(Config) ->
    Port = port(late, Config),
    _ = timer:apply_after(?RETRY_TIMEOUT + 100, ?MODULE, upstream, [
        self(), Port, 200
    ]),
    ?assertMatch({200, _}, request(get, ~"/late")),
    ?assertEqual(1, upstream_requests(Port)).

get_without_retries_fails_at_once(_) ->
    {Elapsed, Response} = timer:tc(
        fun() -> request(get, ~"/once") end, millisecond
    ),
    ok = assert_bad_gateway(Response),
    ?assert(Elapsed < ?RETRY_TIMEOUT).

get_fails_when_the_retries_run_out(_) ->
    {Elapsed, Response} = timer:tc(
        fun() -> request(get, ~"/never") end, millisecond
    ),
    ok = assert_bad_gateway(Response),
    ?assert(Elapsed >= 2 * ?RETRY_TIMEOUT).

%% The upstream starts before a retry would happen, so a retried POST would
%% reach it.
post_is_not_sent_again(Config) ->
    Port = port(post, Config),
    _ = timer:apply_after(?RETRY_TIMEOUT div 3, ?MODULE, upstream, [
        self(), Port, 200
    ]),
    {Elapsed, Response} = timer:tc(
        fun() -> request(post, ~"/post") end, millisecond
    ),
    ok = assert_bad_gateway(Response),
    ?assert(Elapsed < ?RETRY_TIMEOUT),
    ?assertEqual(0, upstream_requests(Port)).

an_answer_is_not_retried(Config) ->
    Port = port(answer, Config),
    ok = upstream(self(), Port, 503),
    ?assertMatch({503, _}, request(get, ~"/answer")),
    ?assertEqual(1, upstream_requests(Port)).

%% The response spec sets no `status_code`, and its body is the parser's
%% default, an empty binary.
a_response_without_a_status_keeps_the_upstream_status(Config) ->
    ok = upstream(self(), port(plain_ok, Config), 200),
    ok = upstream(self(), port(plain_error, Config), 409),
    ?assertMatch({200, _}, request(get, ~"/plain_ok")),
    ?assertMatch({409, _}, request(get, ~"/plain_error")).

an_upstream_that_does_not_answer_times_out(Config) ->
    ok = upstream(self(), port(silent, Config), silent),
    {Status, Body} = request(get, ~"/silent"),
    ?assertEqual(
        {
            bondy_http_utils:http_status(~"bondy.error.gateway_timeout"),
            ~"bondy.error.gateway_timeout"
        },
        {Status, maps:get(~"uri", json:decode(Body))}
    ).

%% The gateway forwards the upstream's bytes; a body that is not JSON is not
%% encoded as a JSON string, and one that is JSON is not decoded.
an_upstream_body_is_returned_as_it_is(Config) ->
    ok = upstream(self(), port(json_body, Config), {200, ~"{\"a\":[1,2]}"}),
    ok = upstream(self(), port(text_body, Config), {200, ~"hello"}),
    ?assertEqual({200, ~"{\"a\":[1,2]}"}, request(get, ~"/json_body")),
    {200, Headers, ~"hello"} = response(get, ~"/text_body"),
    ?assertNot(is_map_key(~"content-type", Headers)).

an_upstream_body_keeps_its_content_type(Config) ->
    ok = upstream(
        self(), port(typed_body, Config), {200, ~"text/plain", ~"hello"}
    ),
    ?assertMatch(
        {200, #{~"content-type" := ~"text/plain"}, ~"hello"},
        response(get, ~"/typed_body")
    ).

the_spec_content_type_overrides_the_upstream(Config) ->
    ok = upstream(
        self(), port(spec_typed_body, Config), {200, ~"text/plain", ~"a,b"}
    ),
    ?assertMatch(
        {200, #{~"content-type" := ~"text/csv"}, ~"a,b"},
        response(get, ~"/spec_typed_body")
    ).

%% =============================================================================
%% HELPERS
%% =============================================================================

forward(Ports, Case, Retries) ->
    #{
        ~"action" => #{
            ~"type" => ~"forward",
            ~"host" => iolist_to_binary([
                "http://127.0.0.1:", integer_to_list(maps:get(Case, Ports))
            ]),
            ~"retries" => Retries
        },
        ~"response" => #{
            ~"on_error" => #{
                ~"status_code" => ~"{{action.error.status_code}}",
                ~"body" => ~"{{action.error.body}}"
            },
            ~"on_result" => #{
                ~"status_code" => ~"{{action.result.status_code}}",
                ~"body" => ~"{{action.result.body}}"
            }
        }
    }.

silent(Ports) ->
    #{~"action" := Action} = Spec = forward(Ports, silent, 0),
    Spec#{~"action" => Action#{~"timeout" => 500}}.

spec_typed(Ports) ->
    #{~"response" := #{~"on_result" := OnResult} = Response} =
        Spec = forward(Ports, spec_typed_body, 0),
    Spec#{
        ~"response" => Response#{
            ~"on_result" => OnResult#{
                ~"headers" => #{~"content-type" => ~"text/csv"}
            }
        }
    }.

plain(Ports, Case) ->
    #{
        ~"action" => maps:get(~"action", forward(Ports, Case, 0)),
        ~"response" => #{~"on_error" => #{}, ~"on_result" => #{}}
    }.

port(Case, Config) ->
    maps:get(Case, ?config(ports, Config)).

free_port() ->
    {ok, Socket} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, Port} = inet:port(Socket),
    ok = gen_tcp:close(Socket),
    Port.

%% Dispatch table rebuilds are debounced, so the route answers 404 until it is
%% mounted; a 404 never reaches the action.
request(Method, Path) ->
    {Status, _, Body} = response(Method, Path),
    {Status, Body}.

response(Method, Path) ->
    response(Method, Path, 50).

response(_, _, 0) ->
    ct:fail(route_not_mounted);
response(Method, Path, N) ->
    Url = iolist_to_binary([
        "http://localhost:18080", ?BASE_PATH, Path
    ]),
    Headers = [{~"content-type", ~"application/json"}],
    {ok, Status, RespHeaders, Ref} = hackney:request(
        Method, Url, Headers, ~"{}", []
    ),
    {ok, Body} = hackney:body(Ref),
    case Status of
        404 ->
            timer:sleep(100),
            response(Method, Path, N - 1);
        _ ->
            {Status, #{string:lowercase(K) => V || {K, V} <- RespHeaders}, Body}
    end.

assert_bad_gateway({Status, Body}) ->
    ?assertEqual(
        {
            bondy_http_utils:http_status(~"bondy.error.bad_gateway"),
            ~"bondy.error.bad_gateway"
        },
        {Status, maps:get(~"uri", json:decode(Body))}
    ).

upstream_requests(Port) ->
    receive
        {upstream_request, Port} -> 1 + upstream_requests(Port)
    after 500 ->
        0
    end.

%% Listens on `Port` and answers every request with `Status`, reporting each to
%% `Owner`. `Status` may carry a body as `{Status, Body}`, and a content type as
%% `{Status, ContentType, Body}`. A `silent` upstream
%% reads each request and never answers it.
upstream(Owner, Port, Status) ->
    Self = self(),
    Ready = make_ref(),
    _ = spawn(fun() ->
        {ok, Listen} = gen_tcp:listen(Port, [
            binary, {active, false}, {reuseaddr, true}, {packet, http_bin}
        ]),
        Self ! Ready,
        accept(Owner, Port, Listen, Status)
    end),
    receive
        Ready -> ok
    after 5000 ->
        ct:fail(upstream_not_listening)
    end.

accept(Owner, Port, Listen, Status) ->
    {ok, Socket} = gen_tcp:accept(Listen),
    ok = read_headers(Socket),
    Owner ! {upstream_request, Port},
    ok = answer(Socket, Status),
    accept(Owner, Port, Listen, Status).

answer(_, silent) ->
    ok;
answer(Socket, Status) when is_integer(Status) ->
    answer(Socket, {Status, <<>>});
answer(Socket, {Status, Body}) ->
    answer(Socket, Status, [], Body);
answer(Socket, {Status, ContentType, Body}) ->
    answer(Socket, Status, ["content-type: ", ContentType, "\r\n"], Body).

answer(Socket, Status, Headers, Body) ->
    ok = gen_tcp:send(Socket, [
        "HTTP/1.1 ",
        integer_to_list(Status),
        " Status\r\n",
        Headers,
        "content-length: ",
        integer_to_list(byte_size(Body)),
        "\r\nconnection: close\r\n\r\n",
        Body
    ]),
    gen_tcp:close(Socket).

read_headers(Socket) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, {http_request, _, _, _}} -> read_headers(Socket);
        {ok, {http_header, _, _, _, _}} -> read_headers(Socket);
        {ok, http_eoh} -> ok
    end.
