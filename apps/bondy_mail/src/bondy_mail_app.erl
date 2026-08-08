%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_app).

-moduledoc """
Application callback for `bondy_mail`.

Configuration is read before the supervisor starts, so the supervisor can see
whether there is anything to supervise. With no relay configured the tree comes
up empty and the application still starts -- a node that does not send email
must not be a node that fails to boot.
""".

-behaviour(application).

-export([start/2]).
-export([stop/1]).

%% =============================================================================
%% APPLICATION CALLBACKS
%% =============================================================================

-doc false.
start(_StartType, _StartArgs) ->
    ok = bondy_mail_config:init(),
    %% Before the supervisor, so the families exist before any relay can write
    %% to one. Best effort: see bondy_mail_telemetry:declare_families/0.
    ok = bondy_mail_telemetry:init(),
    bondy_mail_sup:start_link().

-doc false.
stop(_State) ->
    ok.
