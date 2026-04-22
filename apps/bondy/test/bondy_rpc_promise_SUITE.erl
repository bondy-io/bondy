%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rpc_promise_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-include("bondy.hrl").
-include("bondy_plum_db.hrl").
-include("bondy_security.hrl").

-define(REALM, <<"com.leapsight.test.bondy_rpc_promise">>).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        add_new,
        add_existing,
        properties,
        flush_invocation_with_callback,
        flush_call_no_callback_trigger,
        flush_other_ref_untouched,
        flush_backward_compat,
        flush_bad_opts,
        dealer_flush_callee_promises_delivers_error
    ].


init_per_suite(Config) ->

    bondy_ct:start_bondy(),
    %% We disable eviction so that we can test it manually
    bondy_config:set(rpc_promise_eviction, false),
    Config.


end_per_suite(Config) ->
    % bondy_ct:stop_bondy(),
    {save_config, Config}.


add_new(_) ->
    Me = self(),
    % meck:new(bondy_rpc_promise_manager, [passthrough]),
    % meck:expect(bondy_rpc_promise_manager, on_evict_fun, fun() ->
    %     fun(P) -> Me ! {evicted, P} end
    % end),

    CallerSessionId = bondy_session_id:new(),
    CalleeSessionId = bondy_session_id:new(),
    Caller = bondy_ref:new(client, self(), CallerSessionId),
    Callee = bondy_ref:new(client, self(), CalleeSessionId),

    Promise = bondy_rpc_promise:new_invocation(?REALM, Caller, 1, Callee, 1, #{
        procedure_uri => <<"com.example.test">>,
        timeout => 1000
    }),

    Key = bondy_rpc_promise:key(Promise),

    Pattern = bondy_rpc_promise:invocation_key_pattern(
        ?REALM, Caller, 1, Callee, 1
    ),

    ?assertEqual(ok, bondy_rpc_promise:add(Promise)),

    ?assertEqual({ok, Promise}, bondy_rpc_promise:find(Key)),

    ?assertEqual({ok, Promise}, bondy_rpc_promise:find(Pattern)),

    timer:sleep(3000),

    ok = bondy_rpc_promise:evict_expired(#{
        parallel => false,
        on_evict => fun(P) -> Me ! {evicted, P} end
    }),

    Res = receive
        {evicted, P} when P == Promise ->
            Promise;
        {evicted, Other} ->
            Other
    after
        0 ->
            {error, on_evict_failed}
    end,

    % meck:unload(bondy_rpc_promise_manager),

    ?assertEqual(
        Promise,
        Res,
        "Promise should have been evicted and the on_evict fun applied"
    ),

    ?assertEqual(
        error,
        bondy_rpc_promise:find(Pattern),
        "find should not return a value after the TTL has passed"
    ),

    ok.


add_existing(_) ->
    Me = self(),
    CallerSessionId = bondy_session_id:new(),
    CalleeSessionId = bondy_session_id:new(),
    Caller = bondy_ref:new(client, self(), CallerSessionId),
    Callee = bondy_ref:new(client, self(), CalleeSessionId),


    Promise = bondy_rpc_promise:new_invocation(?REALM, Caller, 1, Callee, 1, #{
        procedure_uri => <<"com.example.test">>,
        timeout => 1000
    }),

    ?assertEqual(ok, bondy_rpc_promise:add(Promise)),

    ?assertError(
        {badarg, {duplicates, [Promise]}},
        bondy_rpc_promise:add(Promise)
    ),

    timer:sleep(3000),

    ok = bondy_rpc_promise:evict_expired(#{
        parallel => false,
        on_evict => fun(P) -> Me ! {evicted, P} end
    }),

    receive
        {evicted, P} when P == Promise ->
            Promise;

        {evicted, Other} ->
            error({wrong_promise, Other})
    after
        0 ->
            error(on_evict_failed)
    end,

    ok.


properties(_) ->
    CallerSessionId = bondy_session_id:new(),
    CalleeSessionId = bondy_session_id:new(),
    Caller = bondy_ref:new(client, self(), CallerSessionId),
    Callee = bondy_ref:new(client, self(), CalleeSessionId),

    Promise = bondy_rpc_promise:new_invocation(?REALM, Caller, 2, Callee, 1, #{
        procedure_uri => <<"com.example.test">>,
        timeout => 1000,
        foo => bar
    }),

    ?assertEqual(
        2,
        bondy_rpc_promise:call_id(Promise)
    ),
    ?assertEqual(
        1,
        bondy_rpc_promise:invocation_id(Promise)
    ),
    ?assertEqual(
        1000,
        bondy_rpc_promise:timeout(Promise)
    ),
    ?assertEqual(
        ?REALM,
        bondy_rpc_promise:realm_uri(Promise)
    ),
    ?assertEqual(
        #{foo => bar},
        bondy_rpc_promise:info(Promise)
    ),
    ?assertEqual(
        bar,
        bondy_rpc_promise:get(foo, Promise)
    ),
    ?assertError(
        {badkey, baz},
        bondy_rpc_promise:get(baz, Promise)
    ),
    ?assertEqual(
        undefined,
        bondy_rpc_promise:get(baz, Promise, undefined)
    ),

    ok.


flush_invocation_with_callback(_) ->
    %% flush/3 must invoke on_callee_flush once per invocation promise whose
    %% callee is the Ref being flushed, then delete the entry.
    Me = self(),
    Caller = bondy_ref:new(client, self(), bondy_session_id:new()),
    Callee = bondy_ref:new(client, self(), bondy_session_id:new()),

    Promise = bondy_rpc_promise:new_invocation(
        ?REALM, Caller, 100, Callee, 100, #{
            procedure_uri => <<"com.example.flush.invocation">>,
            timeout => 60000
        }
    ),
    ?assertEqual(ok, bondy_rpc_promise:add(Promise)),

    ok = bondy_rpc_promise:flush(?REALM, Callee, #{
        on_callee_flush => fun(P) -> Me ! {flushed, P}, ok end
    }),

    receive
        {flushed, P} when P == Promise -> ok;
        {flushed, Other} -> ct:fail({wrong_promise, Other})
    after
        500 -> ct:fail("callback was not invoked")
    end,

    Pattern = bondy_rpc_promise:invocation_key_pattern(
        ?REALM, Caller, 100, Callee, 100
    ),
    ?assertEqual(error, bondy_rpc_promise:find(Pattern)),

    ok.


flush_call_no_callback_trigger(_) ->
    %% When the flushed Ref is the caller, the call promise must be removed
    %% but the on_callee_flush callback must NOT fire (no one to notify).
    Me = self(),
    Caller = bondy_ref:new(client, self(), bondy_session_id:new()),

    Promise = bondy_rpc_promise:new_call(?REALM, Caller, 101, #{
        procedure_uri => <<"com.example.flush.call">>,
        timeout => 60000
    }),
    ?assertEqual(ok, bondy_rpc_promise:add(Promise)),

    ok = bondy_rpc_promise:flush(?REALM, Caller, #{
        on_callee_flush => fun(P) -> Me ! {unexpected, P}, ok end
    }),

    receive
        {unexpected, _} ->
            ct:fail("callback should not fire for call promises")
    after
        200 -> ok
    end,

    Pattern = bondy_rpc_promise:call_key_pattern(?REALM, Caller, 101),
    ?assertEqual(error, bondy_rpc_promise:find(Pattern)),

    ok.


flush_other_ref_untouched(_) ->
    %% Only promises whose callee matches the flushed Ref are affected.
    Me = self(),
    Caller = bondy_ref:new(client, self(), bondy_session_id:new()),
    Callee1 = bondy_ref:new(client, self(), bondy_session_id:new()),
    Callee2 = bondy_ref:new(client, self(), bondy_session_id:new()),

    Promise1 = bondy_rpc_promise:new_invocation(
        ?REALM, Caller, 201, Callee1, 201, #{
            procedure_uri => <<"com.example.flush.p1">>,
            timeout => 60000
        }
    ),
    Promise2 = bondy_rpc_promise:new_invocation(
        ?REALM, Caller, 202, Callee2, 202, #{
            procedure_uri => <<"com.example.flush.p2">>,
            timeout => 60000
        }
    ),
    ok = bondy_rpc_promise:add([Promise1, Promise2]),

    ok = bondy_rpc_promise:flush(?REALM, Callee1, #{
        on_callee_flush => fun(P) -> Me ! {flushed, P}, ok end
    }),

    receive
        {flushed, P1} when P1 == Promise1 -> ok;
        {flushed, Other} -> ct:fail({wrong_promise, Other})
    after
        500 -> ct:fail("callback was not invoked for Callee1")
    end,

    receive
        {flushed, _} ->
            ct:fail("callback should not fire for Callee2")
    after
        200 -> ok
    end,

    Pattern1 = bondy_rpc_promise:invocation_key_pattern(
        ?REALM, Caller, 201, Callee1, 201
    ),
    Pattern2 = bondy_rpc_promise:invocation_key_pattern(
        ?REALM, Caller, 202, Callee2, 202
    ),
    ?assertEqual(error, bondy_rpc_promise:find(Pattern1)),
    ?assertEqual({ok, Promise2}, bondy_rpc_promise:find(Pattern2)),

    ok.


flush_backward_compat(_) ->
    %% flush/2 must still remove promises without requiring a callback.
    Caller = bondy_ref:new(client, self(), bondy_session_id:new()),
    Callee = bondy_ref:new(client, self(), bondy_session_id:new()),

    Promise = bondy_rpc_promise:new_invocation(
        ?REALM, Caller, 300, Callee, 300, #{
            procedure_uri => <<"com.example.flush.compat">>,
            timeout => 60000
        }
    ),
    ok = bondy_rpc_promise:add(Promise),

    ok = bondy_rpc_promise:flush(?REALM, Callee),

    Pattern = bondy_rpc_promise:invocation_key_pattern(
        ?REALM, Caller, 300, Callee, 300
    ),
    ?assertEqual(error, bondy_rpc_promise:find(Pattern)),

    ok.


flush_bad_opts(_) ->
    Caller = bondy_ref:new(client, self(), bondy_session_id:new()),

    ?assertError(
        {badarg, {on_callee_flush, not_a_fun}},
        bondy_rpc_promise:flush(
            ?REALM, Caller, #{on_callee_flush => not_a_fun}
        )
    ),

    ok.


dealer_flush_callee_promises_delivers_error(_) ->
    %% bondy_dealer:flush_callee_promises/2 must deliver a
    %% wamp.error.no_eligible_callee ERROR to the caller of every in-flight
    %% invocation promise whose callee is the flushed Ref, then remove
    %% those promises.
    Caller = bondy_ref:new(client, self(), bondy_session_id:new()),
    Callee = bondy_ref:new(client, self(), bondy_session_id:new()),

    CallId = 400,
    Promise = bondy_rpc_promise:new_invocation(
        ?REALM, Caller, CallId, Callee, CallId, #{
            procedure_uri => <<"com.example.dealer.flush">>,
            timeout => 60000
        }
    ),
    ok = bondy_rpc_promise:add(Promise),

    ok = bondy_dealer:flush_callee_promises(?REALM, Callee),

    ExpectedUri = <<"wamp.error.no_eligible_callee">>,
    receive
        {?BONDY_REQ, _Pid, ?REALM,
            #error{
                request_type = ?CALL,
                request_id = CallId,
                error_uri = ExpectedUri
            }} ->
            ok;
        {?BONDY_REQ, _Pid, ?REALM, Other} ->
            ct:fail({unexpected_message, Other})
    after
        500 ->
            ct:fail("caller did not receive no_eligible_callee error")
    end,

    Pattern = bondy_rpc_promise:invocation_key_pattern(
        ?REALM, Caller, CallId, Callee, CallId
    ),
    ?assertEqual(error, bondy_rpc_promise:find(Pattern)),

    ok.


