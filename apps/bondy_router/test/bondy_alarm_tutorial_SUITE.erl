%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_alarm_tutorial_SUITE).

-moduledoc """
Walks the published tutorial "Watching an Alarm from Raise to Clear" and
asserts what it tells the reader they will see.

A tutorial is a promise: follow these steps and get this result. Nothing else
in the tree keeps that promise true — the alarm API suites assert the API's
contract, and none of them runs the SEQUENCE a reader runs or checks the
payloads the tutorial prints. So a `detail_keys` change, a severity change or
a renamed field breaks the tutorial silently while every other suite stays
green.

The one substitution is the SMTP server: the tutorial says
`python3 -m aiosmtpd -l 127.0.0.1:2525`, and this uses `mock_smtp_server` on an
ephemeral port instead. Everything else is the reader's own sequence — the same
procedures, in the same order, against a real relay that really fails and then
really works.

WHAT THIS DOES NOT COVER: the tutorial's `bondy.conf` step and the node
restart. Configuration is applied here through `application:set_env/3`, so a
`mail.relay.$name.*` key that stopped reaching `bondy_mail`'s `relays`
environment would not fail this suite — `bondy_mail_config_SUITE` is what
covers that mapping. Nor the `/metrics` scrape in step 4, nor the event topics
in "What to try next" (`bondy_alarm_api_SUITE` covers those).
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").

-compile([nowarn_export_all, export_all]).

-define(RELAY, ~"demo").
-define(TO, ~"you@example.com").

all() ->
    [
        step_2_and_3_the_failing_relay_raises_one_alarm,
        step_3_further_failures_neither_add_nor_restate_an_alarm,
        step_4_the_catalogue_entry_carries_the_runbook,
        step_4_the_task_describe_reply_grades_the_remedy,
        step_5_fixing_the_condition_clears_the_alarm,
        step_6_the_history_holds_the_transitions
    ].

suite() ->
    [{timetrap, {minutes, 5}}].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    %% The tutorial's "a port with nothing behind it". Taken by starting the
    %% mock and stopping it, so the port is known to be free AND known to be
    %% one the mock can bind again in step 5.
    {ok, Port} = mock_smtp_server:start(),
    ok = mock_smtp_server:stop(),
    [{port, Port} | Config].

end_per_suite(Config) ->
    _ = application:stop(bondy_mail),
    ok = stop_mock(),
    {save_config, Config}.

%% Each case starts from the tutorial's step 1 — the relay configured to fail,
%% no alarm raised yet — because the tutorial's own steps are ordered and a
%% case that inherited a previous case's alarm would be asserting a
%% restatement while claiming to assert a raise.
init_per_testcase(_Case, Config) ->
    ok = configure_broken_relay(?config(port, Config)),
    ok = alarm_handler:clear_alarm({mail_relay_down, ?RELAY}),
    Config.

end_per_testcase(_Case, _Config) ->
    _ = application:stop(bondy_mail),
    ok = stop_mock(),
    ok = alarm_handler:clear_alarm({mail_relay_down, ?RELAY}),
    ok.

%% =============================================================================
%% THE TUTORIAL'S STEPS
%% =============================================================================

%% Steps 2 and 3. "It fails. Nothing is listening on port 2525, which is the
%% point." Then `bondy.alarm.list` shows ONE alarm, and the tutorial prints its
%% every field.
step_2_and_3_the_failing_relay_raises_one_alarm(_) ->
    ?assertMatch(#error{}, mail_test()),
    ok = await_alarm(),

    #{~"alarms" := Alarms, ~"nodes" := Nodes} = call(?BONDY_ALARM_LIST, []),
    [A] = [X || X <- Alarms, id_of(X) == [~"mail_relay_down", ?RELAY]],

    %% Every field the tutorial's step-3 payload shows, and the three it then
    %% tells the reader to notice.
    ?assertEqual([~"mail_relay_down", ~"_"], maps:get(~"catalogue_id", A)),
    ?assertEqual(~"major", maps:get(~"severity", A)),
    ?assertEqual(~"integration", maps:get(~"class", A)),
    ?assertEqual(false, maps:get(~"affects_ready", A)),
    ?assertEqual(
        atom_to_binary(partisan:node(), utf8), maps:get(~"node", A)
    ),
    ?assert(is_integer(maps:get(~"raised_at", A))),
    ?assert(is_integer(maps:get(~"updated_at", A))),

    Details = maps:get(~"details", A),
    ?assertEqual(?RELAY, maps:get(~"relay", Details)),
    ?assert(maps:get(~"consecutive_failures", Details) >= 1),

    %% "`silent` is empty, so this answer covers the whole cluster."
    ?assertEqual([], maps:get(~"silent", Nodes)),
    ?assertEqual(
        [atom_to_binary(partisan:node(), utf8)], maps:get(~"answered", Nodes)
    ).

%% Step 3's second half: "Now call `bondy.mail.test` again, twice. Call
%% `bondy.alarm.list` once more — still ONE alarm."
%%
%% MEASURED 2026-08-31, and the tutorial was wrong about the reason. It said
%% `consecutive_failures` would have grown, teaching restatement. This producer
%% does not restate: `bondy_mail_relay:fail/1` gates on
%% `status =/= down andalso Failures >= Threshold`, so the alarm is raised ONCE
%% on the transition to down and further failures only move the relay's own
%% counter. The alarm's `details` therefore hold the count AT THE RAISE
%% forever.
%%
%% Asserting the count is UNCHANGED is the sharper property anyway: it is the
%% falsifier for a producer that restated on every failure, which is what would
%% flood `bondy.alarm.updated` and evict the history ring.
step_3_further_failures_neither_add_nor_restate_an_alarm(_) ->
    ?assertMatch(#error{}, mail_test()),
    ok = await_alarm(),
    First = failures(),

    ?assertMatch(#error{}, mail_test()),
    ?assertMatch(#error{}, mail_test()),
    %% No barrier to wait on here — the point is that NOTHING further is
    %% published — so the two sends are given the same window the raise needed.
    timer:sleep(500),

    ?assertEqual(
        1,
        length(relay_alarms()),
        "a further failure created a second alarm"
    ),
    ?assertEqual(
        First,
        failures(),
        "the producer restated the alarm instead of gating on its own flag"
    ).

%% Step 4. The reader takes `catalogue_id` from step 3 and looks it up. The
%% entry is what carries "the part the alarm itself does not", and the tutorial
%% prints it in full.
step_4_the_catalogue_entry_carries_the_runbook(_) ->
    #{~"entries" := Entries} = call(?BONDY_ALARM_CATALOGUE, []),
    [E] = [
        X
     || X <- Entries,
        maps:get(~"id_pattern", X) == [~"mail_relay_down", ~"_"]
    ],

    ?assertEqual(~"major", maps:get(~"severity", E)),
    ?assertEqual(~"integration", maps:get(~"class", E)),
    ?assertEqual(false, maps:get(~"affects_ready", E)),
    ?assertEqual(
        [~"relay", ~"consecutive_failures"], maps:get(~"detail_keys", E)
    ),
    ?assertEqual(
        [
            ~"mail.relay.$name.health.failure_threshold",
            ~"mail.relay.$name.health.success_threshold"
        ],
        maps:get(~"config_keys", E)
    ),

    %% The tutorial tells the reader to RUN the two `procedure` references and
    %% says each "is read-only by construction, so this is always safe". Both
    %% halves are checked: the refs are the ones printed, and the procedures
    %% answer.
    Obs = maps:get(~"observe_with", E),
    ?assertEqual(
        [~"bondy.mail.status.get", ~"bondy.mail.relay.list"],
        [maps:get(~"ref", O) || O <- Obs, maps:get(~"kind", O) == ~"procedure"]
    ),
    ?assertEqual(
        [~"bondy_mail_relay_up", ~"bondy_mail_failed_total"],
        [maps:get(~"ref", O) || O <- Obs, maps:get(~"kind", O) == ~"metric"]
    ),
    ?assertMatch(
        {reply, #result{}},
        dispatch(?BONDY_MAIL_RELAY_LIST, [?MASTER_REALM_URI])
    ),

    %% "Finally, look at `tasks`. It names `bondy.mail.test`."
    ?assertEqual([~"bondy.mail.test"], maps:get(~"tasks", E)).

%% Step 4's last move: `bondy.task.describe("bondy.mail.test")`, and the
%% tutorial's conclusion from it — "`benign` and `idempotent` — safe to run,
%% safe to retry".
step_4_the_task_describe_reply_grades_the_remedy(_) ->
    #{~"tasks" := [T]} = call(?BONDY_TASK_DESCRIBE, [~"bondy.mail.test"]),
    ?assertEqual(~"bondy.mail.test", maps:get(~"id", T)),
    ?assertEqual(~"benign", maps:get(~"impact", T)),
    ?assertEqual(~"node", maps:get(~"blast_radius", T)),
    ?assertEqual(true, maps:get(~"idempotent", T)),
    ?assertEqual(
        [~"bondy.mail.status.get", ~"bondy.mail.relay.list"],
        [
            maps:get(~"ref", O)
         || O <- maps:get(~"observe_with", T),
            maps:get(~"kind", O) == ~"procedure"
        ]
    ),
    %% The tutorial builds this call from `args`, so the count has to be the
    %% count `bondy.mail.test` takes.
    ?assertEqual(2, length(maps:get(~"args", T))).

%% Step 5. "It succeeds... The alarm is gone. You did not clear it — there is
%% no procedure that can. It cleared because the condition stopped being true."
step_5_fixing_the_condition_clears_the_alarm(Config) ->
    ?assertMatch(#error{}, mail_test()),
    ok = await_alarm(),
    ?assertEqual(1, length(relay_alarms())),

    {ok, _} = mock_smtp_server:start(?config(port, Config)),
    ?assertMatch({reply, #result{}}, mail_test_raw()),

    %% `success_threshold` is 1, so one success is the whole recovery.
    ok = await_no_alarm(),
    ?assertEqual(
        [],
        relay_alarms(),
        "the alarm outlived the condition the tutorial says clears it"
    ),
    ?assertEqual(
        [],
        maps:get(~"silent", maps:get(~"nodes", call(?BONDY_ALARM_LIST, [])))
    ).

%% Step 6. "Newest first. Notice what is NOT there: ... the history holds one
%% `raised` and one `updated`, not three entries."
step_6_the_history_holds_the_transitions(Config) ->
    ?assertMatch(#error{}, mail_test()),
    ok = await_alarm(),
    ?assertMatch(#error{}, mail_test()),
    {ok, _} = mock_smtp_server:start(?config(port, Config)),
    ?assertMatch({reply, #result{}}, mail_test_raw()),
    ok = await_no_alarm(),

    #{~"node" := Node, ~"events" := Events} = call(?BONDY_ALARM_HISTORY, []),
    ?assertEqual(atom_to_binary(partisan:node(), utf8), Node),

    %% The ring is per NODE and survives every case in this suite, so only
    %% THIS case's transitions are examined — the two newest for our id.
    %% Asserting over the whole ring would be asserting about the suite's
    %% running order.
    Ours = [
        E
     || E <- Events, maps:get(~"id", E) == [~"mail_relay_down", ?RELAY]
    ],
    [Newest, Previous | _] = Ours,

    %% Newest first: the clear precedes the raise in the list.
    ?assertEqual(~"cleared", maps:get(~"action", Newest)),
    ?assertEqual(~"raised", maps:get(~"action", Previous)),
    ?assert(maps:get(~"at", Newest) >= maps:get(~"at", Previous)),

    %% MEASURED 2026-08-31: no `updated` between them. The tutorial said the
    %% two extra failures would each be weighed as a possible transition and
    %% one would show as `updated`; they are not reported at all, because
    %% `bondy_mail_relay:fail/1` stops at the down transition. The three sends
    %% in this case produce exactly two transitions.
    ?assertEqual(
        [~"cleared", ~"raised"],
        [maps:get(~"action", E) || E <- [Newest, Previous]]
    ),
    lists:foreach(
        fun(E) ->
            ?assertEqual(~"major", maps:get(~"severity", E)),
            ?assert(is_integer(maps:get(~"at", E)))
        end,
        [Newest, Previous]
    ).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
%% The tutorial's step 1, as configuration rather than as `bondy.conf`: a relay
%% pointing at a port with nothing behind it, with both thresholds at 1 so the
%% alarm raises on the first failure and clears on the first success.
configure_broken_relay(Port) ->
    _ = application:stop(bondy_mail),
    ok = application:set_env(bondy_mail, relays, [
        #{
            name => ?RELAY,
            host => ~"127.0.0.1",
            port => Port,
            transport => plain,
            auth => never,
            from => ~"no-reply@example.com",
            realms => any,
            retry_max_attempts => 1,
            retry_backoff_min => 10,
            retry_backoff_max => 20,
            health_failure_threshold => 1,
            health_success_threshold => 1
        }
    ]),
    ok = application:set_env(bondy_mail, default_relay, ?RELAY),
    {ok, _} = application:ensure_all_started(bondy_mail),
    ok.

%% @private
%% Stopping a server that was never started is a normal outcome here — most
%% cases never reach step 5 — so it is not an error.
stop_mock() ->
    try
        mock_smtp_server:stop()
    catch
        _:_ -> ok
    end,
    ok.

%% @private
mail_test() ->
    case mail_test_raw() of
        {reply, R} -> R;
        Other -> Other
    end.

%% @private
mail_test_raw() ->
    dispatch(?BONDY_MAIL_TEST, [?MASTER_REALM_URI, ?TO]).

%% @private
%% Through the dispatcher, which is what a reader's WAMP client reaches.
dispatch(Proc, Args) ->
    Ctxt = bondy_context:local_context(?MASTER_REALM_URI),
    M = bondy_wamp_message:call(1, #{}, Proc, Args),
    bondy_wamp_api:handle_call(M, Ctxt).

%% @private
call(Proc, Args) ->
    case dispatch(Proc, Args) of
        {reply, #result{args = [Reply]}} -> Reply;
        Other -> ct:fail({expected_result, Proc, Other})
    end.

%% @private
%% A reader types the next command a second later; a suite does not.
%%
%% `bondy_mail:send/3` replies when the SEND fails, and the relay process
%% raises the alarm after that — `alarm_handler:set_alarm/1` is a
%% `gen_event:notify/2`, a cast. So a read taken the instant the call returns
%% can legitimately precede the raise. Measured: without this,
%% `step_3_...` read an empty alarm list while `step_2_and_3_...` did not, in
%% the same run.
%%
%% This is a REAL property of the alarm subsystem, not a test artefact — see
%% `bondy_alarm_handler`'s moduledoc — so the barrier is here rather than the
%% raise being made synchronous, which would put a producer reporting a
%% problem in a queue behind the alarm subsystem.
await_alarm() ->
    await(fun() -> relay_alarms() =/= [] end, alarm_not_raised).

%% @private
await_no_alarm() ->
    await(fun() -> relay_alarms() == [] end, alarm_not_cleared).

%% @private
await(Fun, Tag) ->
    await(Fun, Tag, erlang:monotonic_time(millisecond) + 5000).

%% @private
await(Fun, Tag, Deadline) ->
    case Fun() of
        true ->
            ok;
        false ->
            erlang:monotonic_time(millisecond) < Deadline orelse
                ct:fail(Tag),
            timer:sleep(50),
            await(Fun, Tag, Deadline)
    end.

%% @private
relay_alarms() ->
    #{~"alarms" := Alarms} = call(?BONDY_ALARM_LIST, []),
    [A || A <- Alarms, id_of(A) == [~"mail_relay_down", ?RELAY]].

%% @private
failures() ->
    [A] = relay_alarms(),
    maps:get(~"consecutive_failures", maps:get(~"details", A)).

%% @private
id_of(A) ->
    maps:get(~"id", A).
