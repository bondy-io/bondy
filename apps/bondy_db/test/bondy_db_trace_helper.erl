%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Records the calls a process makes to given functions while a fun runs.
-module(bondy_db_trace_helper).

-export([calls/3]).

%% The calls `Pid` makes to `MFAs` while `Fun` runs in the caller, in order.
%% The tracer is a separate process: trace messages a process would send
%% itself are dropped. A pattern set on a module that is not loaded matches
%% nothing, so each module is loaded first.
calls(Pid, MFAs, Fun) ->
    Collector = spawn_link(fun() -> collect([]) end),
    _ = [code:ensure_loaded(M) || {M, _, _} <- MFAs],
    _ = [erlang:trace_pattern(MFA, true, [local]) || MFA <- MFAs],
    _ = erlang:trace(Pid, true, [call, {tracer, Collector}]),
    try
        Fun()
    after
        _ = erlang:trace(Pid, false, [call]),
        _ = [erlang:trace_pattern(MFA, false, [local]) || MFA <- MFAs]
    end,
    Ref = erlang:trace_delivered(Pid),
    receive
        {trace_delivered, _, Ref} -> ok
    end,
    Collector ! {dump, self()},
    receive
        {calls, Calls} -> Calls
    end.

collect(Acc) ->
    receive
        {trace, _, call, MFA} -> collect([MFA | Acc]);
        {dump, From} -> From ! {calls, lists:reverse(Acc)}
    end.
