%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_session_transport_test).

-include_lib("eunit/include/eunit.hrl").

%% An `internal` session has no socket and therefore no peer: it is opened
%% by an in-VM component (the HTTP Connector callee, for one) purely so the
%% session manager monitors the process. `to_external/1` is called on the
%% `session opened` event, so a session with no peer must not raise.
internal_session_has_no_peername_test() ->
    ?assertEqual(
        #{}, bondy_session:transport_external_for_test(undefined)
    ).

connected_session_carries_its_peername_test() ->
    ?assertEqual(
        #{peername => <<"127.0.0.1:18080">>},
        bondy_session:transport_external_for_test({{127, 0, 0, 1}, 18080})
    ).
