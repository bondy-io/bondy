%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_relay_sup).

-moduledoc """
Supervises every configured relay: one `bondy_mail_relay` and one worker pool
each.

`one_for_one`: relays are independent, and one unreachable relay must not
disturb another. The relay process and its pool are siblings rather than nested
because neither needs the other to start -- the relay holds configuration and
health, the pool holds delivery slots.

A relay that keeps failing to start is restarted within the usual intensity
budget; past that the whole mail subsystem gives up, which is the right
escalation for what is a configuration error rather than a transient fault.
""".

-behaviour(supervisor).

-include("bondy_mail.hrl").

%% API
-export([start_link/0]).

%% SUPERVISOR CALLBACKS
-export([init/1]).

-define(SERVER, ?MODULE).

%% =============================================================================
%% API
%% =============================================================================

-doc "Start the supervisor, registered as `bondy_mail_relay_sup`.".
-spec start_link() -> {ok, pid()} | {error, any()}.

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================

-doc false.
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },
    Children = lists:flatmap(
        fun child_specs/1,
        maps:values(bondy_mail_config:relays())
    ),
    {ok, {SupFlags, Children}}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
child_specs(#bondy_mail_relay{name = Name} = Relay) ->
    [
        #{
            id => {bondy_mail_relay, Name},
            start => {bondy_mail_relay, start_link, [Relay]},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [bondy_mail_relay]
        },
        #{
            id => {bondy_mail_worker_sup, Name},
            start => {bondy_mail_worker_sup, start_link, [Relay]},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [bondy_mail_worker_sup]
        }
    ].
