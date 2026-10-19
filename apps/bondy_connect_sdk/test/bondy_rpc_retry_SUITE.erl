%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rpc_retry_SUITE).
-moduledoc """
A router-internal caller (`bondy_router_peer:call/5`, the path the HTTP
gateway's `wamp_call` action takes) against `bondy_connect_sdk` callees over
TCP, and the dealer's retry of a call to an idempotent procedure
(`bondy_dealer:retry/1`).

Each callee handler reports every invocation it receives, numbered, so a case
asserts how many attempts the dealer made, not only what the caller got. The
attempts that time out sleep past the call timeout; the promise manager evicts
expired promises once a second, so a timed-out attempt is noticed up to a
second late, and the deadlines leave room for that.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include_lib("bondy_router/include/bondy.hrl").
-include_lib("bondy_router/include/bondy_uris.hrl").
-include("bondy_connect.hrl").

-define(REALM, ~"com.example.test.rpc_retry").
-define(IDEMPOTENT, #{'_idempotent' => true, invoke => ~"first"}).
-define(TIMEOUT_URIS, [?BONDY_ERROR_TIMEOUT, ?WAMP_ERROR_TIMEOUT]).
-define(API, ~"com.example.test.rpc_retry.api").

-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).
-export([call_leaves_unrelated_messages_alone/1]).
-export([timeout_retries_an_idempotent_call/1]).
-export([retries_without_a_deadline_use_the_call_timeouts/1]).
-export([binary_keyed_options_wait_for_the_retries/1]).
-export([gateway_call_retries_an_idempotent_call/1]).
-export([callee_loss_retries_an_idempotent_call/1]).
-export([a_call_to_a_procedure_not_idempotent_is_not_retried/1]).
-export([callee_loss_of_a_procedure_not_idempotent_is_not_retried/1]).
-export([no_attempt_starts_after_the_deadline/1]).
-export([retries_that_are_not_an_integer_are_ignored/1]).
-export([progressive_results_call_is_not_retried/1]).
-export([progressive_input_call_is_not_retried/1]).
-export([forwarded_call_times_out_at_the_call_timeout/1]).
-export([forwarded_timeout_retries_an_idempotent_call/1]).
-export([forwarded_callee_loss_retries_an_idempotent_call/1]).
-export([forwarded_miss_reports_the_retries_left/1]).
-export([entry_addressed_call_is_not_retried/1]).
-export([rerouted_call_keeps_its_retries/1]).
-export([final_miss_hides_the_routing_details/1]).
-export([owner_timeout_settles_a_call_still_waiting/1]).
-export([call_to_a_peer_waits_for_the_retry_deadline/1]).
-export([call_to_a_peer_without_retries_waits_one_timeout/1]).
-export([progressive_results_call_to_a_peer_waits_one_timeout/1]).
-export([progressive_input_call_to_a_peer_waits_one_timeout/1]).
-export([no_such_procedure_waits_for_a_registration/1]).
-export([no_such_procedure_without_retries_fails_at_once/1]).
-export([no_such_procedure_gives_up_when_retries_run_out/1]).
-export([no_such_procedure_gives_up_before_the_deadline/1]).
-export([progressive_results_call_to_no_procedure_fails_at_once/1]).
-export([a_waiting_call_can_be_cancelled/1]).
-export([sdk_caller_waits_for_the_retries/1]).
-export([sdk_async_caller_waits_until_the_deadline/1]).

all() ->
    [
        call_leaves_unrelated_messages_alone,
        timeout_retries_an_idempotent_call,
        retries_without_a_deadline_use_the_call_timeouts,
        binary_keyed_options_wait_for_the_retries,
        gateway_call_retries_an_idempotent_call,
        callee_loss_retries_an_idempotent_call,
        a_call_to_a_procedure_not_idempotent_is_not_retried,
        callee_loss_of_a_procedure_not_idempotent_is_not_retried,
        no_attempt_starts_after_the_deadline,
        retries_that_are_not_an_integer_are_ignored,
        progressive_results_call_is_not_retried,
        progressive_input_call_is_not_retried,
        forwarded_call_times_out_at_the_call_timeout,
        forwarded_timeout_retries_an_idempotent_call,
        forwarded_callee_loss_retries_an_idempotent_call,
        forwarded_miss_reports_the_retries_left,
        entry_addressed_call_is_not_retried,
        rerouted_call_keeps_its_retries,
        final_miss_hides_the_routing_details,
        owner_timeout_settles_a_call_still_waiting,
        call_to_a_peer_waits_for_the_retry_deadline,
        call_to_a_peer_without_retries_waits_one_timeout,
        progressive_results_call_to_a_peer_waits_one_timeout,
        progressive_input_call_to_a_peer_waits_one_timeout,
        no_such_procedure_waits_for_a_registration,
        no_such_procedure_without_retries_fails_at_once,
        no_such_procedure_gives_up_when_retries_run_out,
        no_such_procedure_gives_up_before_the_deadline,
        progressive_results_call_to_no_procedure_fails_at_once,
        a_waiting_call_can_be_cancelled,
        sdk_caller_waits_for_the_retries,
        sdk_async_caller_waits_until_the_deadline
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    {ok, _} = application:ensure_all_started(bondy_connect_sdk),
    _ = bondy_realm:create(#{
        uri => ?REALM,
        authmethods => [?WAMP_ANON_AUTH],
        security_enabled => false
    }),
    Config.

end_per_suite(Config) ->
    Config.

%% The connections belong to the test case process: CT runs each case in its
%% own process, and a connection dies with the process that opened it.
init_per_testcase(Case, Config) ->
    ok = set_progressive_features(
        lists:prefix("progressive", atom_to_list(Case))
    ),
    [{callee, connect()} | Config].

end_per_testcase(_, Config) ->
    ok = set_progressive_features(false),
    _ = bondy_connect_client:disconnect(?config(callee, Config)),
    ok.

%% =============================================================================
%% CASES
%% =============================================================================

%% The caller's mailbox holds messages that are not the reply. Waiting for the
%% reply must neither consume them nor return one as the call's outcome.
call_leaves_unrelated_messages_alone(Config) ->
    Proc = ~"com.example.test.rpc_retry.echo",
    ok = register(Config, Proc, [reply], #{}),
    self() ! unrelated,
    ?assertMatch({ok, #{args := [1]}}, call(Proc, #{})),
    receive
        unrelated -> ok
    after 0 ->
        ct:fail(unrelated_message_consumed)
    end.

timeout_retries_an_idempotent_call(Config) ->
    Proc = ~"com.example.test.rpc_retry.timeout",
    ok = register(Config, Proc, [sleep, reply], ?IDEMPOTENT),
    Opts = #{timeout => 1000, '_retries' => 1, '_deadline' => 8000},
    ?assertMatch({ok, #{args := [2]}}, call(Proc, Opts)),
    ?assertEqual([1, 2], attempts(Proc, 0)).

%% Without `_deadline` the call gets `_retries + 1` call timeouts.
retries_without_a_deadline_use_the_call_timeouts(Config) ->
    Proc = ~"com.example.test.rpc_retry.no_deadline",
    ok = register(Config, Proc, [sleep, reply], ?IDEMPOTENT),
    Opts = #{timeout => 2000, '_retries' => 1},
    ?assertMatch({ok, #{args := [2]}}, call(Proc, Opts)),
    ?assertEqual([1, 2], attempts(Proc, 0)).

%% The HTTP gateway passes the action's call options with binary keys.
binary_keyed_options_wait_for_the_retries(Config) ->
    Proc = ~"com.example.test.rpc_retry.binary_keys",
    ok = register(Config, Proc, [sleep, reply], ?IDEMPOTENT),
    Opts = #{~"timeout" => 1000, ~"_retries" => 1, ~"_deadline" => 8000},
    ?assertMatch({ok, #{args := [2]}}, call(Proc, Opts)),
    ?assertEqual([1, 2], attempts(Proc, 0)).

%% A `wamp_call` action's `retries` reach the call, and its `timeout` bounds
%% each attempt.
gateway_call_retries_an_idempotent_call(Config) ->
    Proc = ~"com.example.test.rpc_retry.gateway",
    ok = register(Config, Proc, [sleep, reply], ?IDEMPOTENT),
    Get = #{
        ~"action" => #{
            ~"type" => ~"wamp_call",
            ~"procedure" => Proc,
            ~"options" => #{},
            ~"args" => [],
            ~"kwargs" => #{},
            ~"timeout" => 2000,
            ~"retries" => 1
        },
        ~"response" => #{
            ~"on_error" => #{},
            ~"on_result" => #{~"body" => ~"{{action.result.args}}"}
        }
    },
    ok = bondy_http_gateway:load(#{
        ~"id" => ?API,
        ~"name" => ?API,
        ~"host" => ~"_",
        ~"realm_uri" => ?REALM,
        ~"defaults" => #{~"security" => #{}, ~"schemes" => [~"http"]},
        ~"versions" => #{
            ~"1.0.0" => #{
                ~"base_path" => ~"/rpc_retry/v1.0",
                ~"paths" => #{~"/gateway" => #{~"get" => Get}}
            }
        }
    }),
    try
        _ = bondy_http_gateway:rebuild_dispatch_tables(),
        {Status, Body} = http_get(
            "http://localhost:18080/rpc_retry/v1.0/gateway", 50
        ),
        ?assertEqual({200, [2]}, {Status, json:decode(Body)}),
        ?assertEqual([1, 2], attempts(Proc, 0))
    after
        bondy_http_gateway:delete(?API)
    end.

%% The callee that took the invocation goes away; the attempt that follows
%% reaches the registration that is left.
callee_loss_retries_an_idempotent_call(Config) ->
    Proc = ~"com.example.test.rpc_retry.callee_loss",
    ok = register(Config, Proc, [die], ?IDEMPOTENT),
    Other = connect(),
    try
        ok = register_on(Other, Proc, [reply], ?IDEMPOTENT),
        Opts = #{timeout => 5000, '_retries' => 1},
        ?assertMatch({ok, #{args := [1]}}, call(Proc, Opts)),
        ?assertEqual([1, 1], attempts(Proc, 0))
    after
        _ = bondy_connect_client:disconnect(Other)
    end.

a_call_to_a_procedure_not_idempotent_is_not_retried(Config) ->
    Proc = ~"com.example.test.rpc_retry.not_idempotent",
    ok = register(Config, Proc, [sleep, reply], #{}),
    Opts = #{timeout => 1000, '_retries' => 1, '_deadline' => 4000},
    assert_timeout(call(Proc, Opts)),
    ?assertEqual([1], attempts(Proc, 3000)).

callee_loss_of_a_procedure_not_idempotent_is_not_retried(Config) ->
    Proc = ~"com.example.test.rpc_retry.not_idempotent_loss",
    ok = register(Config, Proc, [die], #{}),
    Opts = #{timeout => 5000, '_retries' => 1},
    ?assertMatch(
        {error, #{error_uri := ?WAMP_NO_ELIGIBLE_CALLE}}, call(Proc, Opts)
    ),
    ?assertEqual([1], attempts(Proc, 1000)).

%% Every attempt times out, so the call runs out of deadline with retries
%% left; the dealer starts no attempt after it.
no_attempt_starts_after_the_deadline(Config) ->
    Proc = ~"com.example.test.rpc_retry.deadline",
    ok = register(Config, Proc, lists:duplicate(6, sleep), ?IDEMPOTENT),
    Opts = #{timeout => 1000, '_retries' => 5, '_deadline' => 2500},
    Start = erlang:system_time(millisecond),
    assert_timeout(call(Proc, Opts)),
    Started = attempt_times(Proc, 3000),
    ?assert(length(Started) >= 2),
    ?assert(lists:all(fun(T) -> T < Start + 2500 end, Started)).

%% Extension options pass validation untyped, so a `_retries` that is not an
%% integer asks for nothing.
retries_that_are_not_an_integer_are_ignored(Config) ->
    Proc = ~"com.example.test.rpc_retry.bad_retries",
    ok = register(Config, Proc, [sleep, reply], ?IDEMPOTENT),
    Opts = #{timeout => 1000, '_retries' => ~"1", '_deadline' => 4000},
    assert_timeout(call(Proc, Opts)),
    ?assertEqual([1], attempts(Proc, 3000)).

%% The caller may hold some results of a progressive call, so it is never
%% retried.
progressive_results_call_is_not_retried(Config) ->
    Proc = ~"com.example.test.rpc_retry.progressive_results",
    ok = register(Config, Proc, [sleep, reply], ?IDEMPOTENT),
    Opts = #{
        timeout => 1000,
        '_retries' => 1,
        '_deadline' => 6000,
        receive_progress => true
    },
    ?assertEqual(?WAMP_ERROR_TIMEOUT, cast_error(Proc, Opts)),
    ?assertEqual([1], attempts(Proc, 3000)).

progressive_input_call_is_not_retried(Config) ->
    Proc = ~"com.example.test.rpc_retry.progressive_input",
    ok = register(Config, Proc, [sleep, reply], ?IDEMPOTENT),
    Opts = #{
        timeout => 1000,
        '_retries' => 1,
        '_deadline' => 6000,
        progress => true
    },
    ?assertEqual(?WAMP_ERROR_TIMEOUT, cast_error(Proc, Opts)),
    ?assertEqual([1], attempts(Proc, 3000)).

%% The node that owns the callee times the invocation of a forwarded call out
%% at the call's own `timeout`, not at the router's default.
forwarded_call_times_out_at_the_call_timeout(Config) ->
    Proc = ~"com.example.test.rpc_retry.forwarded_timeout",
    ok = register(Config, Proc, [sleep], #{}),
    ?assertMatch(
        #error{error_uri = ?WAMP_ERROR_TIMEOUT},
        forward(Proc, #{timeout => 1000})
    ),
    ?assertEqual([1], attempts(Proc, 0)).

forwarded_timeout_retries_an_idempotent_call(Config) ->
    Proc = ~"com.example.test.rpc_retry.forwarded_retry",
    ok = register(Config, Proc, [sleep, reply], ?IDEMPOTENT),
    Opts = #{timeout => 1000, '_retries' => 1, '_deadline' => 8000},
    ?assertMatch(#result{args = [2]}, forward(Proc, Opts)),
    ?assertEqual([1, 2], attempts(Proc, 0)).

forwarded_callee_loss_retries_an_idempotent_call(Config) ->
    Proc = ~"com.example.test.rpc_retry.forwarded_loss",
    ok = register(Config, Proc, [die], ?IDEMPOTENT),
    Other = connect(),
    try
        ok = register_on(Other, Proc, [reply], ?IDEMPOTENT),
        Opts = #{timeout => 5000, '_retries' => 1},
        ?assertMatch(#result{args = [1]}, forward(Proc, Opts)),
        ?assertEqual([1, 1], attempts(Proc, 0))
    after
        _ = bondy_connect_client:disconnect(Other)
    end.

%% The attempt after the callee loss finds no registration on this node. Its
%% ERROR carries the retries that attempt had, for the caller's node to route
%% the call to another node with.
forwarded_miss_reports_the_retries_left(Config) ->
    Proc = ~"com.example.test.rpc_retry.forwarded_miss",
    ok = register(Config, Proc, [die], ?IDEMPOTENT),
    Opts = #{timeout => 5000, '_retries' => 2},
    ?assertMatch(
        #error{
            error_uri = ?WAMP_NO_ELIGIBLE_CALLE,
            details = #{rib_completion_miss := true, '_retries' := 1}
        },
        forward(Proc, Opts)
    ),
    ?assertEqual([1], attempts(Proc, 0)).

%% A call forwarded to a registration chosen by the caller's node, as a bridge
%% relay forwards one, is not retried.
entry_addressed_call_is_not_retried(Config) ->
    Proc = ~"com.example.test.rpc_retry.entry_addressed",
    ok = register(Config, Proc, [sleep, reply], ?IDEMPOTENT),
    [Entry] = bondy_registry:find_matches(registration, ?REALM, Proc),
    Call0 = rib_call(Proc, #{timeout => 1000, '_retries' => 1}),
    #{'$private' := Private} = Options = Call0#call.options,
    Call = Call0#call{
        options = Options#{
            '$private' := Private#{
                registration_id := bondy_registry_entry:id(Entry)
            }
        }
    },
    ok = bondy_dealer:forward(
        Call,
        bondy_registry_entry:ref(Entry),
        #{realm_uri => ?REALM, from => bondy_ref:new(internal)}
    ),
    ?assertMatch(
        #error{error_uri = ?WAMP_ERROR_TIMEOUT},
        settlement(Call#call.request_id)
    ),
    ?assertEqual([1], attempts(Proc, 3000)).

%% Another node missed the call with one retry left. This node takes it over
%% with the call's own timeout per attempt, so the retry fits in what is left.
rerouted_call_keeps_its_retries(Config) ->
    Proc = ~"com.example.test.rpc_retry.rerouted",
    ok = register(Config, Proc, [sleep, reply], ?IDEMPOTENT),
    Caller = bondy_ref:new(internal),
    Call = rib_call(Proc, #{timeout => 1000, '_retries' => 2}),
    ok = add_rib_promise(Caller, Call, 1, 10000),
    ok = bondy_dealer:forward(
        miss(Call, #{'_retries' => 1}), Caller, #{realm_uri => ?REALM}
    ),
    ?assertMatch(#result{args = [2]}, settlement(Call#call.request_id)),
    ?assertEqual([1, 2], attempts(Proc, 0)).

final_miss_hides_the_routing_details(_) ->
    Caller = bondy_ref:new(internal),
    Call = rib_call(~"com.example.test.rpc_retry.final_miss", #{}),
    ok = add_rib_promise(Caller, Call, 0, 10000),
    ok = bondy_dealer:forward(
        miss(Call, #{'_retries' => 1}), Caller, #{realm_uri => ?REALM}
    ),
    #error{error_uri = ?WAMP_NO_ELIGIBLE_CALLE, details = Details} =
        settlement(Call#call.request_id),
    ?assertEqual([], [
        K
     || K <- [rib_completion_miss, '_retries'], is_map_key(K, Details)
    ]).

%% The call promise on the caller's node is still active, waiting for the
%% retry deadline, when the owner node gives up on the call.
owner_timeout_settles_a_call_still_waiting(_) ->
    Caller = bondy_ref:new(internal),
    Call = rib_call(~"com.example.test.rpc_retry.owner_timeout", #{}),
    ok = add_rib_promise(Caller, Call, 1, 10000),
    Timeout = bondy_wamp_message:error(
        ?CALL, Call#call.request_id, #{}, ?WAMP_ERROR_TIMEOUT
    ),
    ok = bondy_dealer:forward(Timeout, Caller, #{realm_uri => ?REALM}),
    ?assertMatch(
        #error{error_uri = ?WAMP_ERROR_TIMEOUT},
        settlement(Call#call.request_id)
    ).

%% Whether the owner node retries depends on its registration, which the
%% caller's node cannot see, so it waits for the retry deadline.
call_to_a_peer_waits_for_the_retry_deadline(_) ->
    Opts = #{timeout => 1000, '_retries' => 1, '_deadline' => 8000},
    {Start, Expiry} = peer_call_expiry(~"rpc_retry.peer_wait", Opts),
    ?assert(Expiry >= Start + 7000).

call_to_a_peer_without_retries_waits_one_timeout(_) ->
    Opts = #{timeout => 1000, '_deadline' => 8000},
    {Start, Expiry} = peer_call_expiry(~"rpc_retry.peer_once", Opts),
    ?assert(Expiry =< Start + 2000).

progressive_results_call_to_a_peer_waits_one_timeout(_) ->
    Opts = #{
        timeout => 1000,
        '_retries' => 1,
        '_deadline' => 8000,
        receive_progress => true
    },
    {Start, Expiry} = peer_call_expiry(~"rpc_retry.peer_results", Opts),
    ?assert(Expiry =< Start + 2000).

progressive_input_call_to_a_peer_waits_one_timeout(_) ->
    Opts = #{
        timeout => 1000,
        '_retries' => 1,
        '_deadline' => 8000,
        progress => true
    },
    {Start, Expiry} = peer_call_expiry(~"rpc_retry.peer_input", Opts),
    ?assert(Expiry =< Start + 2000).

%% The callee registers while the call waits for it.
no_such_procedure_waits_for_a_registration(Config) ->
    Proc = ~"com.example.test.rpc_retry.noproc_wait",
    Opts = #{timeout => 1000, '_retries' => 5, '_deadline' => 10000},
    Caller = spawn_call(Proc, Opts),
    timer:sleep(1000),
    ok = register(Config, Proc, [reply], #{}),
    ?assertMatch({ok, #{args := [1]}}, call_result(Caller)).

no_such_procedure_without_retries_fails_at_once(_) ->
    Proc = ~"com.example.test.rpc_retry.noproc_once",
    ?assertMatch(
        {error, #{error_uri := ?WAMP_NO_SUCH_PROCEDURE}},
        call(Proc, #{timeout => 1000})
    ).

%% Each wait counts against `_retries`; the caller gets `no_such_procedure`
%% when they run out, well before the deadline.
no_such_procedure_gives_up_when_retries_run_out(_) ->
    Proc = ~"com.example.test.rpc_retry.noproc_spent",
    Opts = #{timeout => 1000, '_retries' => 2, '_deadline' => 30000},
    Start = erlang:system_time(millisecond),
    ?assertMatch(
        {error, #{error_uri := ?WAMP_NO_SUCH_PROCEDURE}}, call(Proc, Opts)
    ),
    ?assert(erlang:system_time(millisecond) - Start < 10000).

%% The shortest wait is half a second, which does not fit in the deadline.
no_such_procedure_gives_up_before_the_deadline(_) ->
    Proc = ~"com.example.test.rpc_retry.noproc_deadline",
    Opts = #{timeout => 1000, '_retries' => 5, '_deadline' => 300},
    Start = erlang:system_time(millisecond),
    ?assertMatch(
        {error, #{error_uri := ?WAMP_NO_SUCH_PROCEDURE}}, call(Proc, Opts)
    ),
    ?assert(erlang:system_time(millisecond) - Start < 300).

progressive_results_call_to_no_procedure_fails_at_once(_) ->
    Proc = ~"com.example.test.rpc_retry.noproc_progressive",
    Opts = #{
        timeout => 1000,
        '_retries' => 2,
        '_deadline' => 8000,
        receive_progress => true
    },
    Start = erlang:system_time(millisecond),
    ?assertEqual(?WAMP_NO_SUCH_PROCEDURE, cast_error(Proc, Opts)),
    ?assert(erlang:system_time(millisecond) - Start < 300).

%% A `kill` CANCEL waits for the callee's ERROR, and a waiting call has no
%% callee, so the CANCEL settles it. No attempt follows.
a_waiting_call_can_be_cancelled(Config) ->
    Proc = ~"com.example.test.rpc_retry.noproc_cancel",
    Ctxt = context(),
    Opts = #{timeout => 1000, '_retries' => 5, '_deadline' => 8000},
    {ok, ReqId} = bondy_router_peer:cast(Proc, Opts, [1], #{}, Ctxt),
    Cancel = bondy_wamp_message:cancel(ReqId, #{mode => ~"kill"}),
    _ = bondy_router:forward(Cancel, Ctxt),
    receive
        {?BONDY_REQ, _, ?REALM, #error{request_id = ReqId} = Error} ->
            ?assertEqual(?WAMP_CANCELLED, Error#error.error_uri)
    after 1000 ->
        ct:fail(not_cancelled)
    end,
    ok = register(Config, Proc, [reply], #{}),
    ?assertEqual([], attempts(Proc, 3000)).

%% A `bondy_connect_sdk` caller waits for the attempts the dealer makes, not one
%% call timeout.
sdk_caller_waits_for_the_retries(Config) ->
    Proc = ~"com.example.test.rpc_retry.sdk_caller",
    ok = register(Config, Proc, [sleep, reply], ?IDEMPOTENT),
    Caller = connect(),
    try
        ?assertMatch(
            {ok, #{args := [2]}},
            bondy_connect_client:call(
                Caller, Proc, [1], #{}, #{timeout => 1000, '_retries' => 1}
            )
        ),
        ?assertEqual([1, 2], attempts(Proc, 0))
    after
        bondy_connect_client:disconnect(Caller)
    end.

%% The callee registers after `_retries + 1` call timeouts have passed, but
%% before the `_deadline`, while the dealer waits for a registration.
sdk_async_caller_waits_until_the_deadline(Config) ->
    Proc = ~"com.example.test.rpc_retry.sdk_async_caller",
    Caller = connect(),
    try
        {ok, Token} = bondy_connect_client:call_async(
            Caller,
            Proc,
            [1],
            #{},
            #{timeout => 300, '_retries' => 5, '_deadline' => 8000}
        ),
        timer:sleep(2500),
        ok = register(Config, Proc, [reply], #{}),
        receive
            {bondy_connect_client, Token, Reply} ->
                ?assertMatch({ok, #{args := [1]}}, Reply)
        after 10000 ->
            ct:fail(no_reply)
        end
    after
        bondy_connect_client:disconnect(Caller)
    end.

%% =============================================================================
%% HELPERS
%% =============================================================================

connect() ->
    {ok, Conn} = bondy_connect_client:connect(#{
        realm => ?REALM,
        transport => tcp,
        endpoint => {"127.0.0.1", 18082},
        serializers => [json],
        auth => #{method => ?WAMP_ANON_AUTH}
    }),
    Conn.

register(Config, Proc, Behaviours, RegOpts) ->
    register_on(?config(callee, Config), Proc, Behaviours, RegOpts).

%% Registers `Proc` on `Conn` with a handler that reports each invocation as
%% `{attempt, Proc, N, StartedAt}` and then behaves as the Nth of `Behaviours`
%% says: `reply` answers `[N]`, `sleep` outlasts any call timeout here, and
%% `die` closes `Conn` with the invocation in flight.
register_on(Conn, Proc, Behaviours, RegOpts) ->
    Self = self(),
    Counter = counters:new(1, []),
    Handler = fun(_, _, _) ->
        ok = counters:add(Counter, 1, 1),
        N = counters:get(Counter, 1),
        Self ! {attempt, Proc, N, erlang:system_time(millisecond)},
        case lists:nth(N, Behaviours) of
            reply ->
                {ok, #{args => [N]}};
            sleep ->
                timer:sleep(10000),
                {ok, #{args => [N]}};
            die ->
                _ = spawn(fun() -> bondy_connect_client:disconnect(Conn) end),
                timer:sleep(10000),
                {ok, #{args => [N]}}
        end
    end,
    {ok, _} = bondy_connect_client:register(Conn, Proc, Handler, RegOpts),
    ok.

%% The attempt numbers reported for `Proc`, in arrival order, once no report
%% has arrived for `Quiet` milliseconds.
attempts(Proc, Quiet) ->
    [N || {N, _} <- reports(Proc, Quiet)].

attempt_times(Proc, Quiet) ->
    [T || {_, T} <- reports(Proc, Quiet)].

reports(Proc, Quiet) ->
    receive
        {attempt, Proc, N, T} -> [{N, T} | reports(Proc, Quiet)]
    after Quiet ->
        []
    end.

assert_timeout({error, #{error_uri := Uri}}) ->
    ?assert(lists:member(Uri, ?TIMEOUT_URIS)).

%% Dispatch table rebuilds are debounced, so the route answers 404 until it is
%% mounted; a 404 never reaches the action.
http_get(_, 0) ->
    ct:fail(route_not_mounted);
http_get(Url, N) ->
    {ok, Status, _, Ref} = hackney:request(get, Url, [], <<>>, []),
    {ok, Body} = hackney:body(Ref),
    case Status of
        404 ->
            timer:sleep(100),
            http_get(Url, N - 1);
        _ ->
            {Status, Body}
    end.

%% Calls with the shape of context the HTTP gateway's `wamp_call` action builds,
%% announcing the progressive features a case may enable.
call(Proc, Opts) ->
    bondy_router_peer:call(Proc, Opts, [1], #{}, context()).

spawn_call(Proc, Opts) ->
    Self = self(),
    spawn_link(fun() -> Self ! {call_result, self(), call(Proc, Opts)} end).

call_result(Pid) ->
    receive
        {call_result, Pid, Result} -> Result
    after 15000 ->
        ct:fail(no_call_result)
    end.

%% Sends the CALL without waiting in `bondy_router_peer:call/5`, which does not
%% take progressive results, and returns the URI of the ERROR that settles it.
cast_error(Proc, Opts) ->
    {ok, ReqId} = bondy_router_peer:cast(Proc, Opts, [1], #{}, context()),
    receive
        {?BONDY_REQ, _, ?REALM, #error{request_id = ReqId, error_uri = Uri}} ->
            Uri
    after 10000 ->
        ct:fail(no_error)
    end.

%% Hands `Proc` to the dealer as a peer node forwards a node-addressed CALL,
%% with the test process as the remote caller, and returns the RESULT or
%% ERROR that settles it.
forward(Proc, Opts) ->
    Call = rib_call(Proc, Opts),
    ok = bondy_dealer:forward(
        Call,
        undefined,
        #{
            realm_uri => ?REALM,
            from => bondy_ref:new(internal),
            rib_completion => true
        }
    ),
    settlement(Call#call.request_id).

%% A CALL as the caller's node forwards it to the node it routed it to, for
%% that node to choose the registration.
rib_call(Proc, Opts) ->
    ReqId = bondy_message_id:global(),
    Call = bondy_wamp_message:call(ReqId, Opts, Proc),
    Private = #{
        call_id => ReqId,
        registration_id => undefined,
        invocation_details => #{procedure => Proc, trust_level => 0}
    },
    Call#call{options = (Call#call.options)#{'$private' => Private}}.

settlement(ReqId) ->
    receive
        {?BONDY_REQ, _, ?REALM, #result{request_id = ReqId} = Result} ->
            bondy_wamp_message:decode_partial(Result);
        {?BONDY_REQ, _, ?REALM, #error{request_id = ReqId} = Error} ->
            Error
    after 10000 ->
        ct:fail(no_settlement)
    end.

%% The call promise of `Call`, forwarded to a node that is not in the cluster,
%% with `Remaining` more nodes to try.
add_rib_promise(Caller, #call{request_id = ReqId} = Call, Remaining, Timeout) ->
    Promise = bondy_rpc_promise:new_call(?REALM, Caller, ReqId, #{
        procedure_uri => Call#call.procedure_uri,
        timeout => Timeout,
        rib_retry => #{
            call => Call,
            opts => #{},
            tried => [~"missed@nohost"],
            remaining => Remaining
        }
    }),
    bondy_rpc_promise:add(Promise).

miss(#call{request_id = ReqId}, Details) ->
    Error = bondy_wamp_message:error(
        ?CALL, ReqId, #{}, ?WAMP_NO_ELIGIBLE_CALLE
    ),
    Error#error{
        details = maps:merge(Error#error.details, Details#{
            rib_completion_miss => true
        })
    }.

%% Calls a procedure that only a node outside the cluster registered, and
%% returns when the call started and when its promise on this node expires.
peer_call_expiry(Name, Opts) ->
    Proc = <<"com.example.test.", Name/binary>>,
    Stub = term_to_binary({?REALM, ?EXACT_MATCH, Proc, ~"peer@nohost"}),
    ok = bondy_registry_rib:on_remote_set(registration, Stub, #{
        invoke => ?INVOKE_SINGLE, count => 1, earliest => 1, latest => 1
    }),
    Ctxt = context(),
    Start = erlang:system_time(millisecond),
    try
        {ok, ReqId} = bondy_router_peer:cast(Proc, Opts, [1], #{}, Ctxt),
        Key = bondy_rpc_promise:call_key_pattern(
            ?REALM, bondy_context:ref(Ctxt), ReqId
        ),
        {ok, Promise} = bondy_rpc_promise:take(Key),
        {Start, bondy_rpc_promise:expiry(Promise)}
    after
        ok = bondy_registry_rib:on_remote_clear(registration, Stub)
    end.

context() ->
    Peer = {{127, 0, 0, 1}, 0},
    Session = bondy_session:new(?REALM, #{
        peer => Peer,
        is_anonymous => true,
        authid => ~"anonymous",
        authroles => [],
        roles => #{
            caller => #{
                features => #{
                    call_timeout => true,
                    progressive_call_results => true,
                    progressive_calls => true
                }
            }
        }
    }),
    bondy_context:new(Peer, {http, text, json}, #{session => Session}).

set_progressive_features(Bool) ->
    ok = bondy_config:set(
        [wamp, dealer, features, progressive_call_results], Bool
    ),
    bondy_config:set([wamp, dealer, features, progressive_calls], Bool).
