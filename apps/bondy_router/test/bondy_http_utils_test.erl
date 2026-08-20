%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_utils_test).
-moduledoc """
`bondy_http_utils:peer/1`, the single source of truth for a request's peer
address.
""".

-include_lib("eunit/include/eunit.hrl").

%% A connection over a Unix domain socket has no network peer, so
%% `cowboy_req:peer/1` answers `{local, <<>>}` for it. `peer/1` maps that to
%% loopback with port 0, and port 0 is what tells it apart from a real
%% loopback client: an accepted TCP connection always carries a bound,
%% non-zero source port.
uds_peer_is_loopback_on_port_zero_test() ->
    ?assertEqual(
        {{127, 0, 0, 1}, 0}, bondy_http_utils:peer(#{peer => {local, <<>>}})
    ),
    ?assertEqual(
        {{127, 0, 0, 1}, 54321},
        bondy_http_utils:peer(#{peer => {{127, 0, 0, 1}, 54321}})
    ).
