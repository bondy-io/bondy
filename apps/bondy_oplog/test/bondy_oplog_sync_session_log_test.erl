%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Tests how `bondy_oplog_sync_session` classifies a failed session.
%%
%% The scheduler offers one session per instance per tick against every peer it
%% is given, so a peer that is merely absent must not produce a warning per
%% instance per tick. Anything else must still be loud.
%% =============================================================================
-module(bondy_oplog_sync_session_log_test).

-include_lib("eunit/include/eunit.hrl").

-define(CALL_ARGS, [
    {bondy_oplog_responder, 'node2@127.0.0.1'},
    {sync_protocol, <<"main/4">>, get_root},
    [{timeout, 5000}, {channel, bondy_aae}]
]).

%% The shape Partisan produces for a call to a node that is not there.
nodedown_is_unreachable_test() ->
    Reason =
        {partisan_call_failed, {
            {nodedown, 'node2@127.0.0.1'},
            {partisan_gen_server, call, ?CALL_ARGS}
        }},
    ?assert(bondy_oplog_sync_session:is_peer_unreachable(Reason)).

%% A peer that is up but whose responder has not started — a node still booting.
noproc_is_unreachable_test() ->
    Reason =
        {partisan_call_failed,
            {noproc, {partisan_gen_server, call, ?CALL_ARGS}}},
    ?assert(bondy_oplog_sync_session:is_peer_unreachable(Reason)).

%% A timeout is not unreachability: the peer answered the connection and then
%% did not answer in time, which is worth knowing about.
timeout_is_not_unreachable_test() ->
    Reason =
        {partisan_call_failed,
            {timeout, {partisan_gen_server, call, ?CALL_ARGS}}},
    ?assertNot(bondy_oplog_sync_session:is_peer_unreachable(Reason)).

%% Protocol-level failures stay loud.
protocol_failures_are_not_unreachable_test() ->
    ?assertNot(
        bondy_oplog_sync_session:is_peer_unreachable(
            {peer_pages_unavailable, #{}}
        )
    ),
    ?assertNot(
        bondy_oplog_sync_session:is_peer_unreachable(
            {unexpected_response, garbage}
        )
    ),
    ?assertNot(bondy_oplog_sync_session:is_peer_unreachable(timeout)).

%% The classification is only worth anything if the log site uses it. Captures
%% what actually reaches the logger for each kind of failure. The primary level
%% decides whether the debug line is emitted at all; what matters here is that
%% an absent peer never reaches warning.
levels_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun an_absent_peer_emits_no_warning/0,
        fun a_protocol_failure_emits_a_warning/0
    ]}.

setup() ->
    Tab = ets:new(?MODULE, [public, named_table, duplicate_bag]),
    ok = logger:add_primary_filter(
        ?MODULE,
        {
            fun(Event, _) ->
                _ =
                    (catch ets:insert(?MODULE, {level, maps:get(level, Event)})),
                Event
            end,
            []
        }
    ),
    Tab.

cleanup(_) ->
    _ = logger:remove_primary_filter(?MODULE),
    _ = (catch ets:delete(?MODULE)),
    ok.

an_absent_peer_emits_no_warning() ->
    Reason =
        {partisan_call_failed, {
            {nodedown, 'node2@127.0.0.1'},
            {partisan_gen_server, call, ?CALL_ARGS}
        }},
    ok = bondy_oplog_sync_session:log_failure(<<"main/4">>, peer, Reason),
    ?assertNot(lists:member(warning, levels())).

a_protocol_failure_emits_a_warning() ->
    ok = bondy_oplog_sync_session:log_failure(
        <<"main/4">>, peer, {unexpected_response, garbage}
    ),
    ?assert(lists:member(warning, levels())).

levels() ->
    ets:select(?MODULE, [{{level, '$1'}, [], ['$1']}]).
