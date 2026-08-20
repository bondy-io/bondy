%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_app).

-moduledoc """
The `bondy_connect_sdk` application callback module.

Starts the application's top supervisor, `bondy_connect_sup`. The public client
API lives in `bondy_connect_client`.
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
    ok = ensure_wamp_extensions(),
    bondy_connect_sup:start_link().

-spec stop(term()) -> ok.

stop(_State) ->
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% The client sends the `_deadline` CALL extension option (the absolute
%% cap for a progressive call). Extension options are validated against
%% the `wamp` application's `extended_options`, which in a router node is
%% populated by `bondy_config` — but a standalone client deployment has no
%% router, and an undeclared extension is silently stripped by the
%% client's own encoder. Merge (never replace) so this is safe in either
%% start order when co-located with `bondy_router`.
ensure_wamp_extensions() ->
    ok = bondy_wamp_config:init(),
    Current = bondy_wamp_config:get([extended_options, call], []),

    case lists:member('_deadline', Current) of
        true ->
            ok;
        false ->
            bondy_wamp_config:set(
                [extended_options, call], ['_deadline' | Current]
            )
    end.
