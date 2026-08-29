%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rate_limit_SUITE).
-moduledoc """
The REALM scope of the rate-limit chain (design:
`_plans/2026-08-29-rate-limit-scopes-design.md`), end to end through a
real realm: the `rate_limit` realm property (validator, update,
migration, external projection) and its enforcement — per-caller
budgets, the shared `total` quota, consumption order, and the
session-limiter chain. The node/listener mechanics are pinned in
`bondy_rate_limit_test` (eunit); this suite owns what needs the realm
store. Buckets refill at 1 token/second, negligible within a case.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("bondy_db_tables.hrl").

-compile([nowarn_export_all, export_all]).

all() ->
    [
        realm_budgets_enforce_in_order,
        parked_realm_class_is_inert,
        update_clears_realm_budgets,
        session_chain_shares_the_realm_total,
        invalid_budget_is_refused,
        pre_rate_limit_realm_migrates,
        property_is_projected_externally,
        longpoll_session_draws_from_the_listener_message_budget,
        sse_session_draws_from_the_listener_message_budget
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Config.

end_per_suite(Config) ->
    {save_config, Config}.

init_per_testcase(_, Config) ->
    %% The realm scope must bind with the node scope entirely off —
    %% every case here isolates the realm link of the chain.
    Saved = bondy_config:get([security, rate_limit], undefined),
    ok = bondy_config:set([security, rate_limit], #{enabled => false}),
    [{saved_node_rate_limit, Saved} | Config].

end_per_testcase(_, Config) ->
    ok = bondy_config:set(
        [security, rate_limit], ?config(saved_node_rate_limit, Config)
    ),
    ok.

gen_uri() ->
    string:casefold(bondy_utils:generate_fragment(6)).

key() ->
    {test_ip, erlang:unique_integer([positive])}.

%% One sequence pins three properties at once. With `auth` per_caller
%% capacity 1 and total capacity 2:
%%   A ok            — consumes A's per-caller token AND one total token
%%   A {throttled, realm}
%%                   — A's per-caller bucket refuses BEFORE the total is
%%                     consulted, so the total keeps its second token...
%%   B ok            — ...which B (a fresh caller) receives
%%   C {throttled, realm_total}
%%                   — C's own per-caller bucket is fresh, so only the
%%                     exhausted SHARED total can refuse it
%% Were the total consumed before per_caller, A's refusal would have
%% drained it and B would see `{throttled, realm_total}` instead of
%% `ok` — B's admission is the order falsifier.
realm_budgets_enforce_in_order(_) ->
    Uri = gen_uri(),
    _ = bondy_realm:create(#{
        uri => Uri,
        rate_limit => #{
            auth => #{
                per_caller => #{rate => 1, capacity => 1},
                total => #{rate => 1, capacity => 2}
            }
        }
    }),
    Dims = #{realm => Uri},
    A = key(),
    B = key(),
    C = key(),
    ?assertEqual(ok, bondy_rate_limit:do_throttle(auth, A, Dims)),
    ?assertEqual(
        {throttled, realm}, bondy_rate_limit:do_throttle(auth, A, Dims)
    ),
    ?assertEqual(ok, bondy_rate_limit:do_throttle(auth, B, Dims)),
    ?assertEqual(
        {throttled, realm_total}, bondy_rate_limit:do_throttle(auth, C, Dims)
    ).

%% `enabled: false` inside a class block parks it — the numbers stay,
%% nothing is enforced.
parked_realm_class_is_inert(_) ->
    Uri = gen_uri(),
    _ = bondy_realm:create(#{
        uri => Uri,
        rate_limit => #{
            http => #{
                enabled => false,
                per_caller => #{rate => 1, capacity => 1}
            }
        }
    }),
    Dims = #{realm => Uri},
    K = key(),
    ?assertEqual(ok, bondy_rate_limit:do_throttle(http, K, Dims)),
    ?assertEqual(ok, bondy_rate_limit:do_throttle(http, K, Dims)),
    ?assertEqual(ok, bondy_rate_limit:do_throttle(http, K, Dims)).

%% Updating `rate_limit` to `undefined` clears the property: a caller
%% the old budget already refused is admitted again, because the chain
%% no longer consults the (still-existing) buckets.
update_clears_realm_budgets(_) ->
    Uri = gen_uri(),
    _ = bondy_realm:create(#{
        uri => Uri,
        rate_limit => #{
            http => #{per_caller => #{rate => 1, capacity => 1}}
        }
    }),
    Dims = #{realm => Uri},
    K = key(),
    ?assertEqual(ok, bondy_rate_limit:do_throttle(http, K, Dims)),
    ?assertEqual(
        {throttled, realm}, bondy_rate_limit:do_throttle(http, K, Dims)
    ),
    _ = bondy_realm:update(Uri, #{rate_limit => undefined}),
    ?assertEqual(undefined, bondy_realm:rate_limit(Uri)),
    ?assertEqual(ok, bondy_rate_limit:do_throttle(http, K, Dims)).

%% Two sessions on the same realm: each gets its OWN per-caller message
%% bucket (capacity 5 here — never the binding constraint) but SHARE the
%% realm's total bucket (capacity 2), so the second session's second
%% message is refused by the quota, not by its own budget. Closing the
%% other session must not free the shared bucket.
session_chain_shares_the_realm_total(_) ->
    Uri = gen_uri(),
    _ = bondy_realm:create(#{
        uri => Uri,
        rate_limit => #{
            message => #{
                per_caller => #{rate => 1, capacity => 5},
                total => #{rate => 1, capacity => 2}
            }
        }
    }),
    Dims = #{realm => Uri},
    L1 = bondy_rate_limit:new_session_limiter(Dims),
    L2 = bondy_rate_limit:new_session_limiter(Dims),
    ?assertNotEqual(undefined, L1),
    ?assertNotEqual(undefined, L2),
    ?assertEqual(ok, bondy_rate_limit:allow_session(L1)),
    ?assertEqual(ok, bondy_rate_limit:allow_session(L2)),
    ?assertEqual(throttled, bondy_rate_limit:allow_session(L2)),
    %% deleting a session's chain must leave the SHARED bucket alone
    ok = bondy_rate_limit:delete_session_limiter(L1),
    ?assertEqual(throttled, bondy_rate_limit:allow_session(L2)),
    ok = bondy_rate_limit:delete_session_limiter(L2).

%% The validator refuses malformed budgets at the API boundary.
invalid_budget_is_refused(_) ->
    ?assertError(
        _,
        bondy_realm:create(#{
            uri => gen_uri(),
            rate_limit => #{
                http => #{per_caller => #{rate => 0, capacity => 1}}
            }
        })
    ),
    ?assertError(
        _,
        bondy_realm:create(#{
            uri => gen_uri(),
            rate_limit => #{
                http => #{per_caller => #{rate => <<"fast">>, capacity => 1}}
            }
        })
    ),
    %% a budget must name BOTH numbers
    ?assertError(
        _,
        bondy_realm:create(#{
            uri => gen_uri(),
            rate_limit => #{http => #{per_caller => #{rate => 1}}}
        })
    ).

%% A realm persisted before the `rate_limit` record field existed (the
%% 15-element record tuple) must read back with the property undefined —
%% and stay fully usable.
pre_rate_limit_realm_migrates(_) ->
    Uri = gen_uri(),
    Old =
        {realm, Uri, <<"pre rate_limit">>, false, undefined, false, undefined,
            true, [<<"anonymous">>], true, undefined, #{}, #{}, #{}, #{}},
    ?assertEqual(15, tuple_size(Old)),
    Table = bondy_namespace_catalog:table(?BONDY_DB_REALM_TAB),
    ok = bondy_db:apply(Table, <<>>, Uri, {set, Old}),

    Realm = bondy_realm:fetch(Uri),
    ?assertEqual(Uri, bondy_realm:uri(Realm)),
    ?assertEqual(undefined, bondy_realm:rate_limit(Realm)),
    ?assertEqual(
        ok, bondy_rate_limit:throttle(auth, key(), #{realm => Uri})
    ).

%% `to_external/1` exposes the property when set and omits the key when
%% not — the shape the admin APIs project.
property_is_projected_externally(_) ->
    Uri1 = gen_uri(),
    RateLimit = #{auth => #{per_caller => #{rate => 3, capacity => 9}}},
    _ = bondy_realm:create(#{uri => Uri1, rate_limit => RateLimit}),
    ?assertEqual(RateLimit, bondy_realm:rate_limit(Uri1)),
    ?assertMatch(#{rate_limit := RateLimit}, bondy_realm:to_external(Uri1)),

    Uri2 = gen_uri(),
    _ = bondy_realm:create(#{uri => Uri2}),
    ?assertNot(maps:is_key(rate_limit, bondy_realm:to_external(Uri2))).

%% =============================================================================
%% LISTENER scope for HTTP-era WAMP sessions (longpoll / SSE)
%%
%% These two are the wire falsifiers for the listener dimension of the
%% per-session MESSAGE chain on HTTP transports: a session opened through
%% the longpoll (resp. SSE) handler on `api_gateway_http' must draw from
%% that listener's `message' budget. Node scope is off (per-testcase),
%% and no realm budget is set, so the ONLY link that can refuse the third
%% throttled verb is the listener's. Before the listener name was
%% threaded through `init_protocol', the chain resolved empty and the
%% third SUBSCRIBE was admitted — the exact assertion below.
%% =============================================================================

longpoll_session_draws_from_the_listener_message_budget(_) ->
    with_listener_message_budget(fun(RealmUri) ->
        Base = "http://127.0.0.1:18080/wamp/longpoll",
        %% open
        {ok, 200, _, OpenRef} = hackney:request(
            post,
            Base ++ "/open",
            [{<<"content-type">>, <<"application/json">>}],
            json:encode(#{<<"protocols">> => [<<"wamp.2.json">>]}),
            []
        ),
        {ok, OpenBody} = hackney:body(OpenRef),
        #{<<"transport">> := TransportId} = json:decode(OpenBody),
        Send = fun(Msg) ->
            {ok, 202, _, SRef} = hackney:request(
                post,
                Base ++ "/" ++ binary_to_list(TransportId) ++ "/send",
                [{<<"content-type">>, <<"application/json">>}],
                json:encode(Msg),
                []
            ),
            {ok, _} = hackney:body(SRef),
            ok
        end,
        Recv = fun() ->
            {ok, 200, _, RRef} = hackney:request(
                post,
                Base ++ "/" ++ binary_to_list(TransportId) ++ "/receive",
                [{<<"content-type">>, <<"application/json">>}],
                <<>>,
                []
            ),
            {ok, RBody} = hackney:body(RRef),
            json:decode(RBody)
        end,
        %% HELLO -> WELCOME
        ok = Send([1, RealmUri, #{<<"roles">> => #{<<"subscriber">> => #{}}}]),
        ?assertMatch([2 | _], Recv()),
        exhaust_message_budget(Send, Recv)
    end).

sse_session_draws_from_the_listener_message_budget(_) ->
    with_listener_message_budget(fun(RealmUri) ->
        Base = "http://127.0.0.1:18080/wamp/sse",
        {ok, 200, _, OpenRef} = hackney:request(
            post,
            Base ++ "/open",
            [{<<"content-type">>, <<"application/json">>}],
            json:encode(#{<<"protocols">> => [<<"wamp.2.json.sse">>]}),
            []
        ),
        {ok, OpenBody} = hackney:body(OpenRef),
        #{<<"transport">> := TransportId} = json:decode(OpenBody),
        Send = fun(Msg) ->
            {ok, 202, _, SRef} = hackney:request(
                post,
                Base ++ "/" ++ binary_to_list(TransportId) ++ "/send",
                [{<<"content-type">>, <<"application/json">>}],
                json:encode(Msg),
                []
            ),
            {ok, _} = hackney:body(SRef),
            ok
        end,
        %% SSE replies stream over the held GET; reading them through the
        %% shared transport session instead keeps the case focused on the
        %% SSE handler's OPEN seat (the one that threads the listener).
        Pid = bondy_http_transport_session:whereis(TransportId),
        ?assert(is_pid(Pid)),
        Recv = fun() ->
            {ok, {replies, [Bin | _]}} =
                bondy_http_transport_session:poll_receive(Pid, 5000),
            json:decode(Bin)
        end,
        ok = Send([1, RealmUri, #{<<"roles">> => #{<<"subscriber">> => #{}}}]),
        ?assertMatch([2 | _], Recv()),
        exhaust_message_budget(Send, Recv)
    end).

%% @private
%% Configures `message' rate 1/capacity 2 on the `api_gateway_http'
%% listener (the CT node's longpoll/SSE listener), creates a
%% security-disabled realm, runs `Fun(RealmUri)', and restores the
%% listener config whatever happens.
with_listener_message_budget(Fun) ->
    Saved = bondy_config:get([api_gateway_http, rate_limit], undefined),
    ok = bondy_config:set(
        [api_gateway_http, rate_limit],
        #{message => #{rate => 1, capacity => 2}}
    ),
    Uri = <<"com.test.", (gen_uri())/binary>>,
    _ = bondy_realm:create(Uri),
    ok = bondy_realm:disable_security(Uri),
    try
        Fun(Uri)
    after
        ok = bondy_config:set([api_gateway_http, rate_limit], Saved)
    end.

%% @private
%% With capacity 2, the first two SUBSCRIBEs are admitted and the third
%% must come back as a WAMP ERROR for SUBSCRIBE (code 8/32) with
%% `wamp.error.unavailable' — refused by the listener link, the only
%% enabled one.
exhaust_message_budget(Send, Recv) ->
    ok = Send([32, 1, #{}, <<"com.test.topic.a">>]),
    ?assertMatch([33, 1 | _], Recv()),
    ok = Send([32, 2, #{}, <<"com.test.topic.b">>]),
    ?assertMatch([33, 2 | _], Recv()),
    ok = Send([32, 3, #{}, <<"com.test.topic.c">>]),
    ?assertMatch(
        [8, 32, 3, _, <<"wamp.error.unavailable">> | _], Recv()
    ).
