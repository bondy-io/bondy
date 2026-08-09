%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_gproc).
-moduledoc """
Thin wrapper around `m:gproc` for registering, unregistering and looking up
local names and resources.
""".

%% `ets` exports no continuation type — verified against OTP 28's own
%% `export_type` list — so naming `ets:continuation()` in a spec resolves to
%% `any()`. A select continuation is genuinely opaque.
-type ets_continuation() :: term().

-export([local_name/1]).
-export([lookup_pid/1]).
-export([lookup_pid/2]).
-export([register/1]).
-export([register/2]).
-export([register/4]).
-export([select/1]).
-export([select/2]).
-export([unregister/1]).
-export([unregister/2]).

%% =============================================================================
%% API
%% =============================================================================

-spec local_name(Name :: any()) -> true.

local_name(Name) ->
    {n, l, Name}.

-spec register(Name :: any()) -> true.

register(Name) ->
    gproc:reg({n, l, Name}).

-spec register(Name :: any(), Pid :: pid()) -> true.

register(Name, Pid) ->
    gproc:reg_other({n, l, Name}, Pid).

-spec register(Name :: any(), Pid :: pid(), Type :: atom(), Attr :: any()) ->
    true.

register(Name, Pid, Type, Attr) ->
    GType =
        case Type of
            aggregated_counter -> a;
            counter -> c;
            name -> n;
            property -> p;
            resource_counter -> rc;
            resource_property -> r
        end,
    gproc:reg_other({GType, l, Name}, Pid, Attr).

-spec unregister(Name :: any()) -> true.

unregister(Name) ->
    gproc:unreg({n, l, Name}).

-spec unregister(Name :: any(), Type :: atom()) -> true.

unregister(Name, Type) ->
    GType =
        case Type of
            aggregated_counter -> a;
            counter -> c;
            name -> n;
            property -> p;
            resource_counter -> rc;
            resource_property -> r
        end,
    gproc:unreg({GType, l, Name}).

-spec lookup_pid(Name :: any()) -> pid() | no_return().

lookup_pid(Name) ->
    gproc:lookup_pid({n, l, Name}).

-spec lookup_pid(Type :: atom(), Id :: any()) -> pid() | no_return().

lookup_pid(Type, Id) ->
    lookup_pid({Type, Id}).

-spec select(Term :: ets:match_spec() | ets_continuation()) -> [any()].

select(Term) when is_list(Term) ->
    gproc:select({l, resources}, Term).

-spec select(MatchSpec :: ets:match_spec(), Limit :: integer()) ->
    {[any()], Continuation :: ets_continuation()} | '$end_of_table'.

select(MatchSpec, Limit) ->
    gproc:select({l, resources}, MatchSpec, Limit).
