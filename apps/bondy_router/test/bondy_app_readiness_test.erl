%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% EUnit coverage for `bondy_app:is_ready/0`, the single oracle behind the
%% `/ready` probe and the `bondy_node_ready` Prometheus gauge.
%%
%% The three conditions are independent and each is read from exactly one
%% source, so the tests below drive them one at a time and then together. What
%% they are aimed at falsifying is the two ways a readiness probe goes wrong:
%%
%%   - answering READY while the node cannot serve (traffic is routed at a node
%%     that will raise `*_not_provisioned` on every durable operation), and
%%   - answering NOT READY for a condition that does not stop it serving
%%     (an alarm about an unreachable upstream drains the whole node).
%%
%% This module owns the interaction with the globally-registered `alarm_handler`
%% name: it installs `bondy_alarm_handler` for the duration of each test and
%% removes it afterwards, starting the manager itself only if none is running.
-module(bondy_app_readiness_test).

-include_lib("eunit/include/eunit.hrl").

%% `bondy_config:set(status, V)` writes `persistent_term:put({?BONDY, status})`
%% with `?BONDY = bondy_router` (`bondy_config.erl:224`), and
%% `bondy_config:get/2` reads it through `app_config:get/3`, itself a
%% `persistent_term:get/2`. Erasing the key is how a test restores "not set".
-define(PT_STATUS, {bondy_router, status}).
-define(PT_MAIN_FAILED, {bondy_namespace_catalog, main_failed}).

-define(BLOCKING, {test_blocking_alarm, <<"drain this node">>}).
-define(NOISY, {test_noisy_alarm, <<"an upstream is unreachable">>}).

is_ready_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun not_ready_before_boot_completes/0,
        fun ready_once_booted_with_nothing_wrong/0,
        fun idle_main_db_is_ready/0,
        fun failed_main_db_is_not_ready/0,
        fun a_blocking_alarm_makes_the_node_not_ready/0,
        fun clearing_the_blocking_alarm_restores_readiness/0,
        fun a_plain_alarm_does_not_affect_readiness/0,
        fun an_uninstalled_alarm_handler_reads_as_not_blocking/0
    ]}.

setup() ->
    _ = persistent_term:erase(?PT_STATUS),
    _ = persistent_term:erase(?PT_MAIN_FAILED),
    Owned =
        case whereis(alarm_handler) of
            undefined ->
                {ok, _} = gen_event:start({local, alarm_handler}),
                true;
            _ ->
                false
        end,
    ok = gen_event:add_handler(alarm_handler, bondy_alarm_handler, []),
    Owned.

cleanup(Owned) ->
    %% Tolerant: `an_uninstalled_alarm_handler_reads_as_not_blocking/0` removes
    %% the handler itself.
    _ = gen_event:delete_handler(alarm_handler, bondy_alarm_handler, []),
    Owned andalso gen_event:stop(alarm_handler),
    _ = persistent_term:erase(?PT_STATUS),
    _ = persistent_term:erase(?PT_MAIN_FAILED),
    ok.

%% `bondy_app:start/2` sets the status only once the listeners are up. Until
%% then the node answers 503 whatever else is true.
not_ready_before_boot_completes() ->
    ?assertEqual(undefined, bondy_config:get(status, undefined)),
    ?assertNot(bondy_app:is_ready()),
    ok = bondy_config:set(status, initialising),
    ?assertNot(bondy_app:is_ready()).

ready_once_booted_with_nothing_wrong() ->
    ok = bondy_config:set(status, ready),
    ?assert(bondy_app:is_ready()).

%% Only `failed` disqualifies. In a bare eunit VM nothing is provisioned, so
%% `main_status/0` is `idle` — the legitimate "nothing to open" case, and this
%% test is what keeps a node with no durable tables in the load balancer.
idle_main_db_is_ready() ->
    ok = bondy_config:set(status, ready),
    ?assertEqual(idle, bondy_namespace_catalog:main_status()),
    ?assert(bondy_app:is_ready()).

%% The condition read from `persistent_term` rather than from the alarm that
%% mirrors it: this must hold after an `alarm_handler` crash, which
%% `bondy_event_handler_watcher` repairs by re-installing with `[]` — an empty
%% alarm set.
failed_main_db_is_not_ready() ->
    ok = bondy_config:set(status, ready),
    _ = persistent_term:put(?PT_MAIN_FAILED, {shutdown, some_reason}),
    ?assertEqual(failed, bondy_namespace_catalog:main_status()),
    ?assertNot(bondy_app:is_ready()),
    %% Still not ready with the handler gone — the signal does not depend on it.
    ok = gen_event:delete_handler(alarm_handler, bondy_alarm_handler, []),
    ?assertNot(bondy_app:is_ready()).

a_blocking_alarm_makes_the_node_not_ready() ->
    ok = bondy_config:set(status, ready),
    ?assert(bondy_app:is_ready()),
    ok = bondy_alarm_handler:set_alarm(?BLOCKING, #{affects_ready => true}),
    ok = sync(),
    ?assertNot(bondy_app:is_ready()).

clearing_the_blocking_alarm_restores_readiness() ->
    ok = bondy_config:set(status, ready),
    ok = bondy_alarm_handler:set_alarm(?BLOCKING, #{affects_ready => true}),
    ok = sync(),
    ?assertNot(bondy_app:is_ready()),
    ok = alarm_handler:clear_alarm(element(1, ?BLOCKING)),
    ok = sync(),
    ?assert(bondy_app:is_ready()).

%% The falsifier for "any active alarm makes the node not ready". Every
%% producer in the tree today raises through the OTP 2-tuple, so this is the
%% shape that must NOT drain the node.
a_plain_alarm_does_not_affect_readiness() ->
    ok = bondy_config:set(status, ready),
    ok = alarm_handler:set_alarm(?NOISY),
    ?assertMatch([_ | _], bondy_alarm_handler:get_alarms()),
    ?assert(bondy_app:is_ready()).

%% The window between a handler crash and the watcher's re-install: the manager
%% is alive, this handler is not installed. `affects_ready/0` reads a published
%% boolean, so what makes this hold is `terminate/2` publishing NOT blocking on
%% the way out — a handler that crashed while blocking would otherwise leave
%% the node out of rotation with nothing left to clear it. The other absence
%% (no manager at all) is NOT covered here, because a running eunit VM may have
%% sasl's `alarm_handler` registered and this module must not stop a manager it
%% did not start.
an_uninstalled_alarm_handler_reads_as_not_blocking() ->
    ok = bondy_config:set(status, ready),
    ok = bondy_alarm_handler:set_alarm(?BLOCKING, #{affects_ready => true}),
    ok = sync(),
    ?assertNot(bondy_app:is_ready()),
    ok = gen_event:delete_handler(alarm_handler, bondy_alarm_handler, []),
    ?assertEqual(false, bondy_alarm_handler:affects_ready()),
    ?assert(bondy_app:is_ready()).

%% @private
%% Raising an alarm is a CAST (`gen_event:notify/2`, as OTP's own
%% `alarm_handler:set_alarm/1` is), and `affects_ready/0` no longer calls the
%% handler — it reads a boolean the handler publishes. So a raise and a
%% readiness read are not ordered, and a test that asserts immediately after
%% raising is racing. Any `gen_event:call` to the handler is the barrier;
%% `list/0` is the cheapest.
%%
%% This is a real property, not a test artifact: `/ready` can answer READY for
%% as long as the raise sits in the handler's mailbox. It is bounded by the
%% mailbox, polled once a second or so, and only observable by a caller that
%% just raised — see the `bondy_alarm_handler` moduledoc.
sync() ->
    _ = bondy_alarm_handler:list(),
    ok.
