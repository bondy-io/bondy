%% =============================================================================
%% EUnit suite for `bondy_alarm_handler` — Bondy's replacement for OTP's
%% default `alarm_handler`.
%%
%% The contract under test is that an alarm is identified by its ID: raising
%% one that is already raised is a restatement, not a second alarm. Callers do
%% restate freely (`bondy_oplog_responder` and `bondy_oplog_applier` set theirs
%% once per offending item), so the handler must be idempotent in the ID —
%% otherwise the alarm list grows per event and, because `clear_alarm/1`
%% removes only the first match, the alarm can never be cleared again.
%%
%% Driven through `gen_event` callbacks directly: no running Bondy needed.
%% =============================================================================

-module(bondy_alarm_handler_test).

-include_lib("eunit/include/eunit.hrl").

%% The `logger` handler callback `logged/1` installs.
-export([log/2]).

-define(ID, test_alarm).
-define(OTHER, other_alarm).

%% A raise this handler cannot key: neither `{Id, Desc}` nor `{Id, Desc, Opts}`.
-define(UNKEYABLE, {?ID, <<"desc">>, not_a_map}).

%% =============================================================================
%% TESTS
%% =============================================================================

repeated_set_of_the_same_alarm_does_not_accumulate_test() ->
    S = set_n({?ID, <<"desc">>}, 1000, state()),
    ?assertEqual([{?ID, <<"desc">>}], alarms(S)).

%% The consequence that made the leak more than cosmetic: `clear_alarm/1` uses
%% `lists:keydelete/3`, which removes ONE entry, so N accumulated duplicates
%% would leave N-1 stale alarms behind and the alarm would look permanently
%% raised.
one_clear_clears_a_repeatedly_set_alarm_test() ->
    S0 = set_n({?ID, <<"desc">>}, 100, state()),
    S1 = clear(?ID, S0),
    ?assertEqual([], alarms(S1)).

%% Restating with a new description must update in place, not append.
resetting_with_a_new_description_replaces_test() ->
    S0 = set({?ID, <<"first">>}, state()),
    S1 = set({?ID, <<"second">>}, S0),
    ?assertEqual([{?ID, <<"second">>}], alarms(S1)).

distinct_alarms_coexist_test() ->
    S0 = set({?ID, <<"a">>}, state()),
    S1 = set({?OTHER, <<"b">>}, S0),
    ?assertEqual(
        lists:sort([{?ID, <<"a">>}, {?OTHER, <<"b">>}]), lists:sort(alarms(S1))
    ),
    ?assertEqual([{?OTHER, <<"b">>}], alarms(clear(?ID, S1))).

%% A memory alarm is recorded like any other. Special-casing
%% `system_memory_high_watermark` with `lists:keyreplace/4` would drop it: that
%% function returns the list UNCHANGED when the key is absent, so the first
%% memory alarm raised while any other alarm is up would be logged and then
%% silently discarded.
first_memory_alarm_on_a_non_empty_list_is_recorded_test() ->
    S0 = set({?OTHER, <<"b">>}, state()),
    S1 = set({system_memory_high_watermark, <<"high">>}, S0),
    ?assertEqual(
        [{system_memory_high_watermark, <<"high">>}],
        [A || {Id, _} = A <- alarms(S1), Id == system_memory_high_watermark]
    ).

clearing_an_alarm_that_was_never_raised_is_a_no_op_test() ->
    S0 = set({?ID, <<"a">>}, state()),
    ?assertEqual(alarms(S0), alarms(clear(?OTHER, S0))).

%% Alarm ids are not always atoms — `bondy_http_connector_http_pool` uses
%% `{http_connector_service_down, ServiceName}`.
tuple_alarm_ids_dedupe_per_service_test() ->
    A = {{http_connector_service_down, <<"svc_a">>}, <<"down">>},
    B = {{http_connector_service_down, <<"svc_b">>}, <<"down">>},
    S0 = set_n(A, 10, state()),
    S1 = set_n(B, 10, S0),
    ?assertEqual(2, length(alarms(S1))),
    ?assertEqual([B], alarms(clear(element(1, A), S1))).

%% =============================================================================
%% TESTS — the record (increment 1)
%% =============================================================================

%% A raw OTP `{Id, Desc}` set — the spelling five producers use today
%% (`bondy_http_connector_http_pool`, `bondy_mail_relay`, `bondy_oplog_applier`,
%% `bondy_oplog_origin_bans`, `bondy_oplog_responder`) — must still land, with
%% the documented defaults rather than a crash or an absent field.
otp_two_tuple_set_defaults_to_major_node_test() ->
    [A] = list_(set({?ID, <<"desc">>}, state())),
    ?assertEqual(major, maps:get(severity, A)),
    ?assertEqual(node, maps:get(class, A)),
    ?assertEqual(#{}, maps:get(details, A)),
    ?assertEqual(?ID, maps:get(id, A)),
    ?assertEqual(<<"desc">>, maps:get(description, A)).

opts_carry_severity_class_and_details_test() ->
    Opts = #{
        severity => critical,
        class => integration,
        details => #{service_name => <<"svc">>},
        realm_uri => <<"com.example">>,
        onset_trace_id => <<"abc">>
    },
    [A] = list_(set_opts({?ID, <<"desc">>}, Opts, state())),
    ?assertEqual(critical, maps:get(severity, A)),
    ?assertEqual(integration, maps:get(class, A)),
    ?assertEqual(#{service_name => <<"svc">>}, maps:get(details, A)),
    ?assertEqual(<<"com.example">>, maps:get(realm_uri, A)),
    ?assertEqual(<<"abc">>, maps:get(onset_trace_id, A)).

%% A producer reporting a problem must never be turned into a second problem:
%% a bad severity/class falls back rather than crashing the handler, which
%% would leave the node with no alarm handler at all.
unknown_severity_and_class_fall_back_test() ->
    Opts = #{severity => catastrophic, class => galaxy},
    [A] = list_(set_opts({?ID, <<"d">>}, Opts, state())),
    ?assertEqual(major, maps:get(severity, A)),
    ?assertEqual(node, maps:get(class, A)).

%% Absent, not `undefined` — so `content/1` equality cannot depend on which
%% spelling a producer used. A non-binary value is dropped for the same reason.
optional_fields_are_absent_unless_binary_test() ->
    [A] = list_(set({?ID, <<"d">>}, state())),
    ?assertNot(maps:is_key(realm_uri, A)),
    ?assertNot(maps:is_key(trace_id, A)),
    Opts = #{realm_uri => not_a_binary, trace_id => 42},
    [B] = list_(set_opts({?OTHER, <<"d">>}, Opts, state())),
    ?assertNot(maps:is_key(realm_uri, B)),
    ?assertNot(maps:is_key(trace_id, B)).

%% Pins the contract the five `get_alarms/0` callers depend on
%% (`bondy_cluster_topology`, `bondy_prometheus_db`, `bondy_mcp_gateway`, and
%% two CT suites). `bondy_prometheus_db` filters on `{_, _}` and
%% `bondy_mcp_gateway` pattern-matches a 2-tuple, so a richer return here
%% would silently produce an empty alarm list rather than an error.
get_alarms_projection_is_two_tuples_test() ->
    S = set({?OTHER, <<"b">>}, set({?ID, <<"a">>}, state())),
    Got = alarms(S),
    ?assertEqual(2, length(Got)),
    [?assertMatch({_, _}, A) || A <- Got],
    ?assertEqual(
        lists:sort([{?ID, <<"a">>}, {?OTHER, <<"b">>}]), lists:sort(Got)
    ).

%% `raised_at` belongs to the CONDITION, not to the last report of it —
%% otherwise "how long has this been up" is unanswerable and every restatement
%% resets the clock. The sleep is what makes this non-vacuous: without a
%% measurable gap a mutant that assigns `raised_at => Now` on update produces
%% the same millisecond and the assertion passes for the wrong reason.
restatement_with_new_content_preserves_raised_at_test() ->
    S0 = set({?ID, <<"first">>}, state()),
    [Before] = list_(S0),
    ok = timer:sleep(2),
    S1 = set({?ID, <<"second">>}, S0),
    [After] = list_(S1),
    ?assertEqual(maps:get(raised_at, Before), maps:get(raised_at, After)),
    ?assert(maps:get(updated_at, After) > maps:get(raised_at, After)).

%% A map has no insertion order, so the projection must impose one or the
%% output differs between calls on the same state.
list_is_newest_raise_first_test() ->
    S0 = set({?ID, <<"a">>}, state()),
    ok = timer:sleep(2),
    S1 = set({?OTHER, <<"b">>}, S0),
    ?assertEqual([?OTHER, ?ID], [maps:get(id, A) || A <- list_(S1)]).

%% =============================================================================
%% TESTS — the history ring (increment 1)
%% =============================================================================

%% THE load-bearing case. `bondy_oplog_responder` and `bondy_oplog_applier`
%% set their alarms once per offending item, so if an identical restatement
%% entered the ring one busy alarm would evict every other transition and the
%% ring would answer "what changed" with a single id repeated 100 times.
identical_restatement_records_no_history_test() ->
    S = set_n({?ID, <<"desc">>}, 1000, state()),
    ?assertEqual(1, length(history_(S))),
    ?assertMatch([#{action := raised, id := ?ID}], history_(S)).

%% The mirror: a change that is NOT visible in the description is still a
%% transition. A mutant comparing only descriptions passes every other test.
details_change_alone_is_a_transition_test() ->
    S0 = set_opts({?ID, <<"d">>}, #{details => #{n => 1}}, state()),
    S1 = set_opts({?ID, <<"d">>}, #{details => #{n => 2}}, S0),
    ?assertEqual(
        [updated, raised], [maps:get(action, E) || E <- history_(S1)]
    ),
    ?assertEqual(#{n => 2}, maps:get(details, hd(list_(S1)))).

history_records_all_three_actions_test() ->
    S0 = set({?ID, <<"first">>}, state()),
    S1 = set({?ID, <<"second">>}, S0),
    S2 = clear(?ID, S1),
    ?assertEqual(
        [cleared, updated, raised], [maps:get(action, E) || E <- history_(S2)]
    ).

%% Clearing an alarm that was never raised is a no-op for several callers on
%% recovery; it must not manufacture a transition either.
clearing_an_unraised_alarm_records_no_history_test() ->
    S0 = set({?ID, <<"a">>}, state()),
    ?assertEqual(history_(S0), history_(clear(?OTHER, S0))).

%% The ring keeps the NEWEST 100, not the first 100. Ids are distinct and
%% ascending so the retained window is identifiable: a mutant that appends
%% instead of prepending, or trims the wrong end, changes both endpoints.
ring_is_bounded_and_keeps_the_newest_test() ->
    S = lists:foldl(
        fun(N, Acc) -> set({{seq, N}, <<"d">>}, Acc) end,
        state(),
        lists:seq(1, 200)
    ),
    H = history_(S),
    ?assertEqual(100, length(H)),
    ?assertEqual({seq, 200}, maps:get(id, hd(H))),
    ?assertEqual({seq, 101}, maps:get(id, lists:last(H))).

cleared_event_carries_the_alarms_severity_test() ->
    S0 = set_opts({?ID, <<"d">>}, #{severity => critical}, state()),
    [E | _] = history_(clear(?ID, S0)),
    ?assertEqual(
        #{action => cleared, id => ?ID, severity => critical},
        maps:with([action, id, severity], E)
    ).

%% =============================================================================
%% TESTS — swap adoption (increment 1)
%% =============================================================================

%% `bondy_degraded_boot_SUITE` asserts alarms raised BEFORE the swap survive
%% into `get_alarms/0`. They must arrive as full records, not as the raw OTP
%% pairs — otherwise `list/0` returns two different shapes depending on when
%% the alarm was raised.
swap_adoption_lifts_otp_pairs_to_records_test() ->
    {ok, S} = bondy_alarm_handler:init(
        {[], {alarm_handler, [{?ID, <<"a">>}, {?OTHER, <<"b">>}]}}
    ),
    ?assertEqual(2, length(list_(S))),
    [?assertEqual(major, maps:get(severity, A)) || A <- list_(S)],
    ?assertEqual(
        lists:sort([{?ID, <<"a">>}, {?OTHER, <<"b">>}]), lists:sort(alarms(S))
    ).

%% Producers that start BEFORE `bondy_app` swaps this handler in — the
%% namespace catalogue, the oplog applier — raise into OTP's default handler,
%% whose list holds whatever term was passed. A rich alarm adopted through the
%% pair clause alone would silently lose its details on exactly the boots where
%% it fired early, which are the boots an operator is reading the alarm on.
swap_adoption_lifts_rich_alarms_test() ->
    Details = #{instance_id => <<"i1">>, stalled_for_ms => 900},
    {ok, S} = bondy_alarm_handler:init(
        {[], {alarm_handler, [{?ID, <<"a">>, #{details => Details}}]}}
    ),
    [A] = list_(S),
    ?assertEqual(Details, maps:get(details, A)).

%% The falsifier for the clause above: a 3-tuple whose third element is not an
%% options map is still unkeyable and must not be adopted as one.
swap_adoption_drops_a_non_map_third_element_test() ->
    {ok, S} = bondy_alarm_handler:init(
        {[], {alarm_handler, [{?ID, <<"a">>}, {?OTHER, <<"b">>, not_a_map}]}}
    ),
    ?assertEqual([?ID], [maps:get(id, A) || A <- list_(S)]).

%% A swap that crashes leaves the node with NO alarm handler, so an entry that
%% cannot be keyed is dropped rather than raised.
swap_adoption_drops_unkeyable_entries_test() ->
    {ok, S} = bondy_alarm_handler:init(
        {[], {alarm_handler, [{?ID, <<"a">>}, not_a_pair]}}
    ),
    ?assertEqual([?ID], [maps:get(id, A) || A <- list_(S)]).

%% =============================================================================
%% TESTS — catalogue-declared classification (increment 4)
%% =============================================================================

%% Every producer in the tree raises through the OTP 2-tuple, so without this
%% join an `integration` alarm would report `class = node` and a `warning` one
%% would report `major`. Both entries below differ from the constants in
%% EXACTLY the field asserted, so a handler that ignored the catalogue would
%% fail here rather than pass by coincidence.
catalogued_id_takes_its_class_from_the_catalogue_test() ->
    S = set(
        {{http_connector_service_down, <<"billing">>}, <<"down">>}, state()
    ),
    [A] = list_(S),
    ?assertEqual(integration, maps:get(class, A)),
    ?assertEqual(major, maps:get(severity, A)).

%% `warning` is the assertion that carries this case: it is not reachable from
%% `?DEFAULT_SEVERITY`, so a handler ignoring the catalogue answers `major` and
%% fails. The id has to be the full tuple — `set/2` sends the OTP
%% `{Id, Description}` pair, so `{retained_messages_count_limit, <<"full">>}`
%% is the BARE ATOM with a description, not a parameterised id.
catalogued_id_takes_its_severity_from_the_catalogue_test() ->
    S = set(
        {{retained_messages_count_limit, <<"com.example">>}, <<"full">>},
        state()
    ),
    [A] = list_(S),
    ?assertEqual(warning, maps:get(severity, A)),
    ?assertEqual(realm, maps:get(class, A)).

%% An id the catalogue does not declare must still land — the handler is not a
%% gate. `?ID` is a test-only id and deliberately absent from the catalogue.
uncatalogued_id_falls_back_to_the_constants_test() ->
    S = set({?ID, <<"desc">>}, state()),
    [A] = list_(S),
    ?assertEqual(major, maps:get(severity, A)),
    ?assertEqual(node, maps:get(class, A)),
    ?assertEqual(false, maps:get(affects_ready, A)).

%% The option is an override at the raise site, not a second source of truth.
explicit_opts_override_the_catalogue_test() ->
    S = set_opts(
        {{retained_messages_count_limit, <<"com.example">>}, <<"full">>},
        #{severity => critical, class => cluster},
        state()
    ),
    [A] = list_(S),
    ?assertEqual(critical, maps:get(severity, A)),
    ?assertEqual(cluster, maps:get(class, A)).

%% A misspelled severity must reach the CATALOGUE, not the constant. Without
%% the ordering this pins, a typo at the raise site would silently promote a
%% `warning` alarm to `major`.
invalid_opt_falls_through_to_the_catalogue_test() ->
    S = set_opts(
        {{retained_messages_count_limit, <<"com.example">>}, <<"full">>},
        #{severity => wrning, class => nodes},
        state()
    ),
    [A] = list_(S),
    ?assertEqual(warning, maps:get(severity, A)),
    ?assertEqual(realm, maps:get(class, A)).

%% =============================================================================
%% TESTS — readiness (increment 2)
%% =============================================================================

%% An alarm takes the node out of rotation only by asking to. Every producer in
%% the tree today raises through the OTP 2-tuple, so this is the answer for all
%% of them until the catalogue assigns the flag per alarm.
default_alarm_does_not_affect_readiness_test() ->
    S = set({?ID, <<"desc">>}, state()),
    [A] = list_(S),
    ?assertEqual(false, maps:get(affects_ready, A)),
    ?assertEqual(false, blocking_(S)).

opts_can_declare_affects_ready_test() ->
    S = set_opts({?ID, <<"d">>}, #{affects_ready => true}, state()),
    [A] = list_(S),
    ?assertEqual(true, maps:get(affects_ready, A)),
    ?assertEqual(true, blocking_(S)).

%% Normalisation is total, like `severity` and `class`: a producer that is
%% already reporting a problem must not be turned into a second one.
non_boolean_affects_ready_falls_back_to_false_test() ->
    S = set_opts({?ID, <<"d">>}, #{affects_ready => yes}, state()),
    [A] = list_(S),
    ?assertEqual(false, maps:get(affects_ready, A)),
    ?assertEqual(false, blocking_(S)).

%% The falsifier for reading readiness off a severity threshold. A `critical`
%% alarm that has not asked to drain the node must not drain it —
%% `{http_connector_service_down, _}` is the live example: severe, and no
%% reason to pull the node out of the load balancer.
severity_does_not_decide_readiness_test() ->
    S = set_opts({?ID, <<"d">>}, #{severity => critical}, state()),
    ?assertEqual(critical, maps:get(severity, hd(list_(S)))),
    ?assertEqual(false, blocking_(S)).

%% Kills a fold that inspects only the first or the last alarm.
one_blocking_alarm_among_many_blocks_test() ->
    S0 = set({?OTHER, <<"a">>}, state()),
    S1 = set_opts({?ID, <<"b">>}, #{affects_ready => true}, S0),
    S2 = set({third_alarm, <<"c">>}, S1),
    ?assertEqual(3, length(list_(S2))),
    ?assertEqual(true, blocking_(S2)).

%% Kills "any active alarm blocks readiness": clearing the one blocking alarm
%% must restore readiness even though two alarms are still up.
clearing_the_blocking_alarm_restores_readiness_test() ->
    S0 = set({?OTHER, <<"a">>}, state()),
    S1 = set_opts({?ID, <<"b">>}, #{affects_ready => true}, S0),
    S2 = set({third_alarm, <<"c">>}, S1),
    S3 = clear(?ID, S2),
    ?assertEqual(2, length(list_(S3))),
    ?assertEqual(false, blocking_(S3)).

%% `affects_ready` is part of the alarm's content, so flipping it is a
%% restatement that CHANGED something and belongs in the ring — an operator
%% reading the history must see the moment the node was drained.
flipping_affects_ready_alone_is_a_transition_test() ->
    S0 = set({?ID, <<"d">>}, state()),
    S1 = set_opts({?ID, <<"d">>}, #{affects_ready => true}, S0),
    ?assertEqual(true, blocking_(S1)),
    ?assertEqual([updated, raised], [maps:get(action, E) || E <- history_(S1)]).

%% `affects_ready/0` reads a PUBLISHED boolean rather than calling the handler,
%% so it can lag the alarm map. This is the falsifier for that: after every
%% transition shape — first raise, a second non-blocking alarm, clearing the
%% blocking one, and a restatement that flips the flag — the published value
%% must equal the oracle `handle_call(affects_ready, _)` recomputes.
%%
%% Kills the two ways a cache goes wrong: a transition that forgets to publish
%% (the raise and the clear are separate code paths), and a publication that
%% inspects the alarm being written instead of the whole map.
published_readiness_matches_the_handler_test() ->
    Check = fun(S) ->
        ?assertEqual(blocking_(S), bondy_alarm_handler:affects_ready()),
        S
    end,
    S0 = Check(set({?OTHER, <<"a">>}, state())),
    ?assertEqual(false, bondy_alarm_handler:affects_ready()),
    S1 = Check(set_opts({?ID, <<"b">>}, #{affects_ready => true}, S0)),
    ?assertEqual(true, bondy_alarm_handler:affects_ready()),
    %% A second, non-blocking alarm must not clear it.
    S2 = Check(set({third_alarm, <<"c">>}, S1)),
    ?assertEqual(true, bondy_alarm_handler:affects_ready()),
    %% Clearing the blocking one restores readiness with two alarms still up.
    S3 = Check(clear(?ID, S2)),
    ?assertEqual(false, bondy_alarm_handler:affects_ready()),
    %% A restatement that flips the flag republishes.
    S4 = Check(set_opts({?OTHER, <<"a">>}, #{affects_ready => true}, S3)),
    ?assertEqual(true, bondy_alarm_handler:affects_ready()),
    %% Leave the node-global cell not-blocking: it outlives this test.
    _ = Check(clear(?OTHER, S4)),
    ?assertEqual(false, bondy_alarm_handler:affects_ready()).

%% `terminate/2` publishes NOT blocking, so a crashed or removed handler reads
%% as it always has. Without this a handler that crashed while blocking would
%% leave the node out of rotation with nothing left to clear it.
terminate_publishes_not_blocking_test() ->
    S = set_opts({?ID, <<"d">>}, #{affects_ready => true}, state()),
    ?assertEqual(true, bondy_alarm_handler:affects_ready()),
    ok = bondy_alarm_handler:terminate({error, boom}, S),
    ?assertEqual(false, bondy_alarm_handler:affects_ready()).

%% The totality of the public `affects_ready/0` wrapper — an absent handler
%% must read as `false` rather than exit — is pinned in
%% `bondy_app_readiness_test`, which owns the interaction with the globally
%% registered `alarm_handler` name.

%% =============================================================================
%% TESTS — the onset correlation handle
%% =============================================================================

-define(TRACE, <<"0af7651916cd43dd8448eb211c80319c">>).
-define(OTHER_TRACE, <<"4bf92f3577b34da6a3ce929d0e0e4736">>).

onset_trace_id_is_carried_test() ->
    S = set_opts({?ID, <<"desc">>}, #{onset_trace_id => ?TRACE}, state()),
    ?assertEqual(?TRACE, maps:get(onset_trace_id, hd(list_(S)))).

%% ONSET, not most-recent: it names the occurrence that RAISED the condition,
%% which is what the field's name promises a consumer. It therefore survives a
%% content-changing restatement exactly as `raised_at` does.
onset_trace_survives_a_content_change_test() ->
    S0 = set_opts({?ID, <<"first">>}, #{onset_trace_id => ?TRACE}, state()),
    S1 = set_opts({?ID, <<"second">>}, #{onset_trace_id => ?OTHER_TRACE}, S0),
    A = hd(list_(S1)),
    ?assertEqual(<<"second">>, maps:get(description, A)),
    ?assertEqual(?TRACE, maps:get(onset_trace_id, A)).

%% A condition whose onset carried no trace does not acquire one later. The
%% alternative would label a later occurrence's trace as the onset, which is
%% the precise thing the name rules out.
onset_absent_at_raise_stays_absent_test() ->
    S0 = set({?ID, <<"first">>}, state()),
    S1 = set_opts({?ID, <<"second">>}, #{onset_trace_id => ?TRACE}, S0),
    ?assertNot(maps:is_key(onset_trace_id, hd(list_(S1)))).

%% THE one that constrains the implementation. `content/1` must ignore the
%% onset trace: were it compared, a producer restating with a fresh trace would
%% make every restatement a transition, flooding the ring and the
%% `bondy.alarm.*` topics. `bondy_oplog_responder` restates once per offending
%% item, so that is a real flood, not a hypothetical one.
a_new_trace_alone_is_not_a_transition_test() ->
    S0 = set_opts({?ID, <<"desc">>}, #{onset_trace_id => ?TRACE}, state()),
    S1 = set_opts({?ID, <<"desc">>}, #{onset_trace_id => ?OTHER_TRACE}, S0),
    ?assertEqual(1, length(history_(S1))),
    ?assertEqual(?TRACE, maps:get(onset_trace_id, hd(list_(S1)))).

%% Absent rather than `undefined` when unsupplied, so a consumer tests one
%% thing and `content/1` does not depend on which spelling a producer used.
no_trace_means_no_field_test() ->
    S = set({?ID, <<"desc">>}, state()),
    ?assertNot(maps:is_key(onset_trace_id, hd(list_(S)))).

non_binary_trace_is_dropped_test() ->
    S = set_opts({?ID, <<"desc">>}, #{onset_trace_id => not_a_binary}, state()),
    ?assertNot(maps:is_key(onset_trace_id, hd(list_(S)))).

%% =============================================================================
%% TESTS — emission to the event manager
%% =============================================================================

%% THE load-bearing one. `gen_event:notify/2` on an unregistered atom raises
%% `badarg`, and a raise inside this handler makes the watcher re-install it
%% with `[]`, discarding every active alarm while reporting one. So the
%% manager is addressed by pid, and this is the case that fails if that ever
%% becomes a name again — every alarm here is raised with no manager running.
transitions_do_not_need_an_event_manager_test() ->
    ?assertEqual(undefined, erlang:whereis(bondy_event_manager)),
    S0 = set({?ID, <<"a">>}, state()),
    S1 = set({?ID, <<"b">>}, S0),
    S2 = clear(?ID, S1),
    ?assertEqual([{?ID, <<"b">>}], alarms(S1)),
    ?assertEqual([], alarms(S2)).

raise_emits_the_whole_alarm_test() ->
    with_manager(fun() ->
        _ = set({?ID, <<"desc">>}, state()),
        {[bondy, alarm, raised], Alarm} = captured(),
        %% The payload is the alarm record, not an id: a subscriber must be
        %% able to route on severity without a follow-up call.
        ?assertEqual(?ID, maps:get(id, Alarm)),
        ?assertEqual(<<"desc">>, maps:get(description, Alarm)),
        ?assertEqual(major, maps:get(severity, Alarm))
    end).

content_change_emits_updated_test() ->
    with_manager(fun() ->
        S0 = set({?ID, <<"first">>}, state()),
        {[bondy, alarm, raised], _} = captured(),
        _ = set({?ID, <<"second">>}, S0),
        {[bondy, alarm, updated], Alarm} = captured(),
        ?assertEqual(<<"second">>, maps:get(description, Alarm))
    end).

%% The topics and the history ring must agree on what a transition IS.
%% `bondy_oplog_responder` restates its alarm once per offending item, so a
%% handler that emitted per restatement would publish thousands of identical
%% events for one condition.
identical_restatement_emits_nothing_test() ->
    with_manager(fun() ->
        S0 = set({?ID, <<"desc">>}, state()),
        {[bondy, alarm, raised], _} = captured(),
        _ = set_n({?ID, <<"desc">>}, 50, S0),
        ?assertEqual(timeout, captured())
    end).

%% A bare id would say something resolved without saying how urgent it had
%% been, which is what decides whether the notice is worth acting on.
clear_emits_the_alarm_as_it_was_test() ->
    with_manager(fun() ->
        S0 = set({?ID, <<"desc">>}, state()),
        {[bondy, alarm, raised], _} = captured(),
        _ = clear(?ID, S0),
        {[bondy, alarm, cleared], Alarm} = captured(),
        ?assertEqual(?ID, maps:get(id, Alarm)),
        ?assertEqual(major, maps:get(severity, Alarm))
    end).

clearing_an_unraised_alarm_emits_nothing_test() ->
    with_manager(fun() ->
        _ = clear(?ID, state()),
        ?assertEqual(timeout, captured())
    end).

%% =============================================================================
%% TESTS — a raise this handler cannot key
%% =============================================================================

%% Dropping it is right: a `function_clause` in `handle_event/2` takes the
%% gen_event handler down and the node loses EVERY alarm it holds, so a
%% misspelled raise must not be able to end the alarm subsystem.
%%
%% Dropping it SILENTLY is not. A producer would be reporting a fault that
%% appears nowhere at all, with nothing to say it tried — the failure this
%% whole subsystem exists to prevent, one level down. So the falsifier is the
%% LOG RECORD and not the surviving state: the state survives either way, and a
%% case that only checked it would pass against the catch-all this replaced.
an_unkeyable_raise_is_logged_test() ->
    ?assertMatch(
        #{level := warning, alarm := ?UNKEYABLE},
        logged(fun() ->
            bondy_alarm_handler:handle_event({set_alarm, ?UNKEYABLE}, state())
        end)
    ).

%% ...and the handler is still standing with nothing recorded on either side.
%% A dropped raise that left a half-written alarm behind would be worse than a
%% crash, because nothing would ever report it.
an_unkeyable_raise_records_nothing_test() ->
    S0 = set({?ID, <<"desc">>}, state()),
    {ok, S} = bondy_alarm_handler:handle_event({set_alarm, ?UNKEYABLE}, S0),
    ?assertEqual(alarms(S0), alarms(S)),
    ?assertEqual(history_(S0), history_(S)).

%% The same shape arriving through the SWAP rather than through a raise. It
%% matters more here: an alarm raised before `bondy_app` swaps this handler in,
%% and dropped at the swap, is lost on every boot where the condition fires
%% early — which is exactly when a boot-time fault would be raising one.
an_unkeyable_alarm_dropped_while_adopting_is_logged_test() ->
    ?assertMatch(
        #{level := warning, alarm := ?UNKEYABLE},
        logged(fun() ->
            bondy_alarm_handler:init({[], {alarm_handler, [?UNKEYABLE]}})
        end)
    ).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Runs `Fun` with a `logger` handler attached and answers the first report it
%% logged, or `no_log_record`.
%%
%% The primary level is FORCED: a `warning` is filtered before any handler runs
%% on a node configured at `error`, so without this the cases above would pass
%% or fail on how the harness happened to configure logging.
logged(Fun) ->
    #{level := Primary} = logger:get_primary_config(),
    ok = logger:set_primary_config(level, all),
    ok = logger:add_handler(?MODULE, ?MODULE, #{config => #{pid => self()}}),
    try
        _ = Fun(),
        receive
            {log_record, Record} -> Record
        after 1000 ->
            no_log_record
        end
    after
        ok = logger:remove_handler(?MODULE),
        ok = logger:set_primary_config(level, Primary)
    end.

%% @private
%% `logger` handler callback. Matches on the `alarm` key rather than taking
%% every report, because this handler is attached while the code under test is
%% also logging ordinary "Alarm set" records.
log(#{level := Level, msg := {report, #{alarm := Alarm}}}, Config) ->
    #{config := #{pid := Pid}} = Config,
    Pid ! {log_record, #{level => Level, alarm => Alarm}},
    ok;
log(_Event, _Config) ->
    ok.

%% @private
%% Runs `Fun` with a real `bondy_event_manager` registered, whose universal
%% callback handler forwards every event to the calling process.
%%
%% The name is asserted free rather than reused: this module would otherwise
%% pass against someone else's manager and stop testing anything. `after`
%% rather than a fixture cleanup, so a failing assertion still unregisters the
%% name — an orphaned registration would fail every later test in the run.
with_manager(Fun) ->
    ?assertEqual(undefined, erlang:whereis(bondy_event_manager)),
    {ok, Pid} = gen_event:start_link({local, bondy_event_manager}),
    Self = self(),
    ok = gen_event:add_handler(
        Pid,
        {bondy_event_manager, make_ref()},
        fun(E) -> Self ! {captured, E} end
    ),
    %% eunit runs the `*_test/0` functions of a module in ONE process, so a
    %% case that leaves an event queued would be read by the next one.
    _ = drain(),
    try
        Fun()
    after
        gen_event:stop(Pid)
    end.

%% @private
drain() ->
    case captured(0) of
        timeout -> ok;
        _ -> drain()
    end.

%% @private
%% `emit/2` is an async notify, so the event arrives after `handle_event/2`
%% has already returned. `timeout` is a value rather than a failure because
%% two cases assert that NOTHING is emitted.
captured() ->
    captured(1000).

%% @private
captured(Timeout) ->
    receive
        {captured, E} -> E
    after Timeout -> timeout
    end.

%% @private
state() ->
    {ok, S} = bondy_alarm_handler:init([]),
    S.

%% @private
set(Alarm, S0) ->
    {ok, S} = bondy_alarm_handler:handle_event({set_alarm, Alarm}, S0),
    S.

%% @private
set_n(_Alarm, 0, S) ->
    S;
set_n(Alarm, N, S) ->
    set_n(Alarm, N - 1, set(Alarm, S)).

%% @private
clear(Id, S0) ->
    {ok, S} = bondy_alarm_handler:handle_event({clear_alarm, Id}, S0),
    S.

%% @private
set_opts(Alarm, Opts, S0) ->
    {ok, S} = bondy_alarm_handler:handle_event(
        {set_alarm, erlang:append_element(Alarm, Opts)}, S0
    ),
    S.

%% @private
alarms(S) ->
    {ok, Alarms, S} = bondy_alarm_handler:handle_call(get_alarms, S),
    Alarms.

%% @private
list_(S) ->
    {ok, Alarms, S} = bondy_alarm_handler:handle_call(list, S),
    Alarms.

%% @private
history_(S) ->
    {ok, Events, S} = bondy_alarm_handler:handle_call(history, S),
    Events.

%% @private
blocking_(S) ->
    {ok, Bool, S} = bondy_alarm_handler:handle_call(affects_ready, S),
    Bool.
