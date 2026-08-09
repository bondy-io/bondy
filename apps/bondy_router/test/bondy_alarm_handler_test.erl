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

-define(ID, test_alarm).
-define(OTHER, other_alarm).

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
%% PRIVATE
%% =============================================================================

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
alarms(S) ->
    {ok, Alarms, S} = bondy_alarm_handler:handle_call(get_alarms, S),
    Alarms.
