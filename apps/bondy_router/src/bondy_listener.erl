%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_listener).

-moduledoc """
Lifecycle operations on one listener, dispatched to the driver its transport
selects.

The driver is chosen once, by `bondy_listener_config` while it resolves the
inventory, and carried in the resolved listener map under `driver`, so nothing
here branches on transport. `tcp`, `tls` and
`uds` are all ranch stream listeners, which is why there is one driver
(`bondy_listener_ranch`) today; the indirection is the seam for a transport
whose lifecycle primitives are not ranch's — one that spawns its own listen
process and accepts a different option set — since such a transport shares
none of `ranch:suspend_listener/1`, `resume_listener/1` or `procs/2`.
""".

-export([start/1]).
-export([stop/1]).
-export([suspend/1]).
-export([resume/1]).
-export([connections/1]).

%% =============================================================================
%% CALLBACKS
%% =============================================================================

-callback start(bondy_listener_config:t()) -> ok | {error, term()}.
-callback stop(bondy_listener_config:t()) -> ok.
-callback suspend(bondy_listener_config:t()) -> ok.
-callback resume(bondy_listener_config:t()) -> ok.
-callback connections(bondy_listener_config:t()) -> [pid()].

%% =============================================================================
%% API
%% =============================================================================

-spec start(bondy_listener_config:t()) -> ok | {error, term()}.
start(Listener) -> (driver(Listener)):start(Listener).

-spec stop(bondy_listener_config:t()) -> ok.
stop(Listener) -> (driver(Listener)):stop(Listener).

-spec suspend(bondy_listener_config:t()) -> ok.
suspend(Listener) -> (driver(Listener)):suspend(Listener).

-spec resume(bondy_listener_config:t()) -> ok.
resume(Listener) -> (driver(Listener)):resume(Listener).

-spec connections(bondy_listener_config:t()) -> [pid()].
connections(Listener) -> (driver(Listener)):connections(Listener).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
driver(#{driver := Driver}) -> Driver.
