%% Test-only validator that blocks `verify_event/2` until the test
%% releases it. Carries a `verdict` field (`ok` or `refused`); on
%% release, the worker returns that verdict to the applier.
%%
%% Used by the validator-refresh in-flight test to prove the
%% in-flight contract: a worker that captured snapshot-1 returns
%% snapshot-1's verdict even after the applier has been refreshed to
%% snapshot-2.
%%
%% Coordination protocol:
%%
%% - `verify_event(Event, State)` sends `{verifying, Verdict, self()}`
%%   to `State#{coordinator}` and blocks on `{release, self()}`.
%% - `refresh/1` reads the next state from
%%   `ets:lookup(?MODULE, coordinator_pid)` and merges it into the
%%   current state.

-module(bondy_oplog_test_blocking_validator).

-behaviour(bondy_oplog_validator).

-export([init/2]).
-export([sign_event/2]).
-export([verify_event/2]).
-export([detect_equivocation/2]).
-export([refresh/1]).

init(_InstanceId, #{coordinator := Pid, verdict := Verdict}) ->
    {ok, #{coordinator => Pid, verdict => Verdict}}.

sign_event(Event, State) ->
    {Event, State}.

verify_event(_Event, #{coordinator := Pid, verdict := Verdict}) ->
    Pid ! {verifying, Verdict, self()},
    receive
        {release, Self} when Self =:= self() -> ok
    after 5000 ->
        ok
    end,
    case Verdict of
        ok -> ok;
        refused -> {error, refused}
    end.

detect_equivocation(_E1, _E2) ->
    ok.

%% Refresh looks up the next state in a public ETS table keyed by
%% the coordinator pid, and merges it into the current state. The
%% table is owned by the test process.
refresh(#{coordinator := Pid} = State) ->
    case ets:lookup(bondy_oplog_test_blocking_validator, Pid) of
        [{Pid, NextState}] ->
            {ok, maps:merge(State, NextState)};
        [] ->
            {error, no_next_state}
    end.
