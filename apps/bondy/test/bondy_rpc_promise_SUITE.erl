%% =============================================================================
%%  bondy_realm_SUITE.erl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
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

-module(bondy_rpc_promise_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("bondy.hrl").
-include("bondy_plum_db.hrl").
-include("bondy_security.hrl").

-define(REALM, <<"com.leapsight.test.bondy_rpc_promise">>).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        add_new,
        add_existing,
        properties
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


