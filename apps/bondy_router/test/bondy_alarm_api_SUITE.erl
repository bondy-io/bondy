%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% -----------------------------------------------------------------------------
%% The `bondy.alarm.*` read API, exercised through `bondy_wamp_api:handle_call/2`
%% rather than by calling `bondy_alarm_api` directly — a direct call would pass
%% with the dispatch clause unwired, which is the one thing that cannot be
%% checked any other way.
%%
%% Alarms are raised through the raw OTP `alarm_handler:set_alarm/1`, the
%% spelling every producer in the tree actually uses, so what these cases see is
%% what an operator sees.
%%
%% Three properties:
%%
%%   * DISPATCH — the four procedures resolve and answer.
%%   * AUTHORITY — a session in an ordinary realm is refused (D4: alarms are an
%%     operator concern; `realm_uri` on an alarm names the affected tenant, it
%%     does not grant that tenant access).
%%   * ENCODABILITY — a reply carrying a producer's arbitrary Erlang term still
%%     encodes. This is the end-to-end form of the contract
%%     `bondy_alarm_api_test` pins on the rendering functions alone.
%%   * PUBLICATION — the `bondy.alarm.{raised,updated,cleared}` topics, whose
%%     whole path is only observable here: the handler emits into
%%     `bondy_event_manager`, `bondy_event_wamp_publisher` demand-gates and
%%     enqueues, `bondy_jobs` runs the closure and `bondy_broker` routes it.
%%     Four processes, none of which can be checked from a unit test.
%% -----------------------------------------------------------------------------
-module(bondy_alarm_api_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, <<"com.example.alarm_api_suite">>).

%% A catalogued id, so the reply carries the DECLARED class rather than the
%% handler's constant — `integration`, which differs from the `node` default and
%% is therefore evidence the catalogue join ran.
-define(ALARM_ID, {mail_relay_down, <<"ct_alarm_api">>}).

all() ->
    [
        list_returns_the_envelope,
        get_finds_an_alarm_by_its_wire_id,
        get_of_an_unknown_id_returns_an_empty_envelope,
        history_records_the_raise,
        catalogue_lists_every_declared_entry,
        catalogue_entries_carry_their_runbook,
        an_alarm_carries_its_catalogue_join_key,
        every_procedure_requires_the_master_realm,
        replies_encode_with_a_non_encodable_detail,
        no_subscriber_means_no_demand,
        raise_and_clear_reach_a_subscriber,
        only_a_real_change_publishes_an_update
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    R = bondy_realm:create(?REALM),
    ok = bondy_realm:disable_security(R),
    Config.

end_per_suite(Config) ->
    {save_config, Config}.

end_per_testcase(_, Config) ->
    ok = alarm_handler:clear_alarm(?ALARM_ID),
    Config.

%% =============================================================================
%% CASES
%% =============================================================================

%% The reply is an envelope, not a bare array: `nodes.answered` and
%% `nodes.silent` are what let a caller tell "this node has no alarms" from
%% "this node did not answer" once the fan-out lands.
list_returns_the_envelope(_) ->
    ok = raise(<<"relay is down">>),
    #{<<"alarms">> := Alarms, <<"nodes">> := Nodes} = call(
        ?MASTER_REALM_URI, list
    ),

    %% The envelope names its nodes with `atom_to_binary(partisan:node())`
    %% while each alarm is stamped with `partisan:nodestring()`. They must be
    %% the same string or the two halves of the reply cannot be joined.
    ?assertEqual([partisan:nodestring()], maps:get(<<"answered">>, Nodes)),
    ?assertEqual([], maps:get(<<"silent">>, Nodes)),

    [A] = [X || X <- Alarms, maps:get(<<"id">>, X) == wire_id()],
    ?assertEqual(<<"relay is down">>, maps:get(<<"description">>, A)),
    ?assertEqual(partisan:nodestring(), maps:get(<<"node">>, A)),
    %% The catalogue join, end to end: the producer raised through the OTP
    %% 2-tuple and named no class, so `integration` can only have come from
    %% `bondy_alarm_catalogue`.
    ?assertEqual(<<"integration">>, maps:get(<<"class">>, A)),
    ?assertEqual(<<"major">>, maps:get(<<"severity">>, A)),
    ?assertEqual(false, maps:get(<<"affects_ready">>, A)).

%% `get` answers with the same envelope as `list`, filtered — an alarm id can
%% be raised on several nodes at once, so the question is WHERE the condition
%% holds, not whether one node has it.
get_finds_an_alarm_by_its_wire_id(_) ->
    ok = raise(<<"relay is down">>),
    #{<<"alarms">> := [A], <<"nodes">> := Nodes} =
        call(?MASTER_REALM_URI, get, [wire_id()]),
    ?assertEqual(wire_id(), maps:get(<<"id">>, A)),
    ?assertEqual(<<"integration">>, maps:get(<<"class">>, A)),
    ?assertEqual([], maps:get(<<"silent">>, Nodes)).

%% A miss is an ordinary empty result, NOT an error. Once the answer can be
%% partial, "no active alarm with that id" stops being a fact the router can
%% assert — it is only true of the nodes that answered, and `silent` is what
%% says so. An error would state the opposite, and would put a normal question
%% ("is this still up?") on an agent's exception path.
get_of_an_unknown_id_returns_an_empty_envelope(_) ->
    #{<<"alarms">> := Alarms, <<"nodes">> := Nodes} =
        call(?MASTER_REALM_URI, get, [[<<"no_such_alarm">>, <<"x">>]]),
    ?assertEqual([], Alarms),
    %% Nothing silent, so on this cluster the empty result IS definitive.
    ?assertEqual([], maps:get(<<"silent">>, Nodes)),
    ?assertEqual([partisan:nodestring()], maps:get(<<"answered">>, Nodes)).

history_records_the_raise(_) ->
    ok = raise(<<"relay is down">>),
    #{<<"events">> := Events, <<"node">> := Node} =
        call(?MASTER_REALM_URI, history),
    ?assertEqual(partisan:nodestring(), Node),
    Mine = [E || E <- Events, maps:get(<<"id">>, E) == wire_id()],
    ?assertMatch([_ | _], Mine),
    ?assertEqual(<<"raised">>, maps:get(<<"action">>, hd(Mine))).

%% The catalogue is served whole. An operator writing alert rules needs it
%% BEFORE an alarm has ever fired, which is the point of declaring it.
catalogue_lists_every_declared_entry(_) ->
    #{<<"entries">> := Entries} = call(?MASTER_REALM_URI, catalogue),
    ?assertEqual(length(bondy_alarm_catalogue:list()), length(Entries)),
    [Relay] = [
        E
     || #{<<"id_pattern">> := [<<"mail_relay_down">> | _]} = E <- Entries
    ],
    ?assertEqual(<<"integration">>, maps:get(<<"class">>, Relay)),
    ?assertMatch([_ | _], maps:get(<<"config_keys">>, Relay)).

%% The runbook join (design §9): the entry names what to look at and what may
%% be done. Asserted on the WIRE because the fields are only useful if they
%% survive rendering — `observe_with` is a list of maps mixing binary and atom refs,
%% which is exactly the shape a renderer flattens by accident.
catalogue_entries_carry_their_runbook(_) ->
    #{<<"entries">> := Entries} = call(?MASTER_REALM_URI, catalogue),
    [Relay] = [
        E
     || #{<<"id_pattern">> := [<<"mail_relay_down">> | _]} = E <- Entries
    ],
    ?assertEqual([<<"bondy.mail.test">>], maps:get(<<"tasks">>, Relay)),
    Signals = maps:get(<<"observe_with">>, Relay),
    ?assert(
        lists:member(
            #{
                <<"kind">> => <<"metric">>,
                <<"ref">> => <<"bondy_mail_relay_up">>
            },
            Signals
        )
    ),
    ?assert(
        lists:member(
            #{
                <<"kind">> => <<"procedure">>,
                <<"ref">> => <<"bondy.mail.status.get">>
            },
            Signals
        )
    ).

%% The join KEY. A raised alarm's id is concrete and its catalogue entry is a
%% pattern, so an agent holding an alarm needs something to look the entry up
%% by. Without this it would have to re-implement the catalogue's own matching,
%% which is what the runbook exists to spare it.
an_alarm_carries_its_catalogue_join_key(_) ->
    ok = raise(<<"relay is down">>),
    #{<<"alarms">> := [A]} = call(?MASTER_REALM_URI, get, [wire_id()]),
    Key = maps:get(<<"catalogue_id">>, A),
    #{<<"entries">> := Entries} = call(?MASTER_REALM_URI, catalogue),
    [Entry] = [E || #{<<"id_pattern">> := P} = E <- Entries, P == Key],
    %% End to end: alarm -> its entry -> the task -> that task's own record.
    [Task] = maps:get(<<"tasks">>, Entry),
    ?assertMatch({ok, #{}}, bondy_task_catalogue:lookup(Task)).

%% D4. Every one of the four, because an authority check that covers three
%% procedures and misses the fourth is the usual shape of this bug.
every_procedure_requires_the_master_realm(_) ->
    ok = raise(<<"relay is down">>),
    lists:foreach(
        fun({Proc, Args}) ->
            E = call_error(?REALM, Proc, Args),
            ?assertEqual(
                ?WAMP_NOT_AUTHORIZED, E#error.error_uri, {not_refused, Proc}
            )
        end,
        [
            {list, []},
            {get, [wire_id()]},
            {history, []},
            {catalogue, []}
        ]
    ).

%% The producers put arbitrary terms in a description. `{tcp, closed}` cannot
%% be encoded, and an encoder raising here would kill the session of whoever
%% asked what was wrong.
replies_encode_with_a_non_encodable_detail(_) ->
    ok = alarm_handler:set_alarm(
        {?ALARM_ID, #{relay => <<"ct_alarm_api">>, reason => {tcp, closed}}}
    ),
    Envelope = call(?MASTER_REALM_URI, list),
    [A] = [
        X
     || X <- maps:get(<<"alarms">>, Envelope),
        maps:get(<<"id">>, X) == wire_id()
    ],
    ?assertEqual(
        <<"{tcp,closed}">>,
        maps:get(<<"reason">>, maps:get(<<"description">>, A))
    ),
    ?assert(is_binary(iolist_to_binary(json:encode(Envelope)))).

%% The predicate the gate reads, in both directions. With nothing subscribed
%% an alarm transition costs one registry probe and stops.
%%
%% WHAT THIS DOES NOT COVER: that the publisher actually consults it. A gate
%% removed from `bondy_event_wamp_publisher` publishes into a realm where
%% nobody is listening, which no observer can distinguish from not publishing
%% — the gate buys cost, not behaviour, and cost is not assertable here.
no_subscriber_means_no_demand(_) ->
    Probe = fun(Topic) ->
        bondy_registry:has_matches(subscription, ?MASTER_REALM_URI, Topic)
    end,
    ?assertNot(Probe(?BONDY_ALARM_RAISED)),
    ?assertNot(Probe(?BONDY_ALARM_CLEARED)),

    {ok, SubId} = subscribe(?BONDY_ALARM_RAISED),
    ?assert(Probe(?BONDY_ALARM_RAISED)),
    %% Per topic, not per prefix: a subscriber to `raised` does not make
    %% `cleared` demanded.
    ?assertNot(Probe(?BONDY_ALARM_CLEARED)),

    ok = unsubscribe([SubId]),
    ?assertNot(Probe(?BONDY_ALARM_RAISED)).

%% The payload is the same map `bondy.alarm.get` returns — an agent that
%% reacts to the event acts on it without a second call.
raise_and_clear_reach_a_subscriber(_) ->
    {ok, Raised} = subscribe(?BONDY_ALARM_RAISED),
    {ok, Cleared} = subscribe(?BONDY_ALARM_CLEARED),

    ok = raise(<<"relay is down">>),
    [Alarm] = (await_event(Raised))#event.args,
    ?assertEqual(wire_id(), maps:get(<<"id">>, Alarm)),
    ?assertEqual(<<"relay is down">>, maps:get(<<"description">>, Alarm)),
    %% The catalogue join reaches the topic too, not just the read API.
    ?assertEqual(<<"integration">>, maps:get(<<"class">>, Alarm)),
    ?assertEqual(partisan:nodestring(), maps:get(<<"node">>, Alarm)),

    ok = alarm_handler:clear_alarm(?ALARM_ID),
    [Gone] = (await_event(Cleared))#event.args,
    ?assertEqual(wire_id(), maps:get(<<"id">>, Gone)),
    %% Carried, so a subscriber can tell a resolved page from a resolved
    %% in-hours warning.
    ?assertEqual(<<"major">>, maps:get(<<"severity">>, Gone)),

    ok = unsubscribe([Raised, Cleared]).

%% `bondy_oplog_responder` restates its alarm once per offending item. If a
%% restatement published, one bad sync would emit thousands of identical
%% events — so the topics fire on exactly the transitions the history ring
%% records, and this walks all three.
only_a_real_change_publishes_an_update(_) ->
    {ok, Raised} = subscribe(?BONDY_ALARM_RAISED),
    {ok, Updated} = subscribe(?BONDY_ALARM_UPDATED),

    ok = raise(<<"first">>),
    _ = await_event(Raised),

    ok = raise(<<"first">>),
    ok = raise(<<"first">>),
    ?assertEqual(timeout, next_event(1000)),

    ok = raise(<<"second">>),
    [Alarm] = (await_event(Updated))#event.args,
    ?assertEqual(<<"second">>, maps:get(<<"description">>, Alarm)),

    ok = unsubscribe([Raised, Updated]).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
%% An internal (pid) subscription in the master realm: events arrive as Bondy
%% requests in this process's mailbox.
subscribe(Topic) ->
    Ref = bondy_ref:new(internal, self(), bondy_session_id:new()),
    bondy_broker:subscribe(?MASTER_REALM_URI, #{}, Topic, Ref).

%% @private
unsubscribe(Ids) ->
    lists:foreach(
        fun(Id) -> ok = bondy_broker:unsubscribe(Id, ?MASTER_REALM_URI) end, Ids
    ),
    %% Drop anything still in flight, so the next case starts clean.
    _ = next_event(0),
    ok.

%% @private
%% The publish runs in a `bondy_jobs` worker, so it is asynchronous with
%% respect to the `set_alarm` cast that caused it.
await_event(SubId) ->
    case next_event(5000) of
        #event{subscription_id = SubId} = E -> E;
        Other -> ct:fail({unexpected_event, SubId, Other})
    end.

%% @private
next_event(Timeout) ->
    receive
        {?BONDY_REQ, _, ?MASTER_REALM_URI, #event{} = E} -> E
    after Timeout -> timeout
    end.

%% @private
%% `alarm_handler:set_alarm/1` is a cast, but `bondy_alarm_handler:list/0` is a
%% `gen_event:call` to the same manager from the same process, so the raise is
%% already applied when the API reads. No sleep, and nothing to flake on.
raise(Desc) ->
    alarm_handler:set_alarm({?ALARM_ID, Desc}).

%% @private
wire_id() ->
    bondy_alarm_api:wire_id(?ALARM_ID).

%% @private
uri(list) -> <<"bondy.alarm.list">>;
uri(get) -> <<"bondy.alarm.get">>;
uri(history) -> <<"bondy.alarm.history">>;
uri(catalogue) -> <<"bondy.alarm.catalogue">>.

%% @private
%% Through the dispatcher, so the `bondy.alarm.` clause in
%% `bondy_wamp_api:do_handle_call/3` is exercised by every call.
handle(RealmUri, Proc, Args) ->
    Ctxt = bondy_context:local_context(RealmUri),
    M = bondy_wamp_message:call(1, #{}, uri(Proc), Args),
    bondy_wamp_api:handle_call(M, Ctxt).

%% @private
call(RealmUri, Proc) ->
    call(RealmUri, Proc, []).

%% @private
call(RealmUri, Proc, Args) ->
    case handle(RealmUri, Proc, Args) of
        {reply, #result{args = [Reply]}} -> Reply;
        Other -> ct:fail({expected_result, Proc, Other})
    end.

%% @private
%% The unauthorized path THROWS the error rather than returning it, which is
%% how `bondy_wamp_api_utils:validate_admin_call_args/3` reports refusal.
call_error(RealmUri, Proc, Args) ->
    try handle(RealmUri, Proc, Args) of
        {reply, #error{} = E} -> E;
        Other -> ct:fail({expected_error, Proc, Other})
    catch
        error:#error{} = E -> E
    end.
