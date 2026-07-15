%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_app).

-moduledoc """
The `bondy_connect` application callback module.

Starts the application's top supervisor, `bondy_connect_sup`. The public client
API lives in `bondy_connect`.
""".

-behaviour(application).

-export([start/2]).
-export([stop/1]).

%% =============================================================================
%% APPLICATION CALLBACKS
%% =============================================================================

-spec start(application:start_type(), term()) ->
    {ok, pid()} | {error, term()}.

start(_StartType, _StartArgs) ->
    bondy_connect_sup:start_link().

-spec stop(term()) -> ok.

stop(_State) ->
    ok.
