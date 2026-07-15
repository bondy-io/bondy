%% Test-only validator that rejects every remote event. Exercises the
%% Stage 2 verify_event/2 hook in the instance worker.

-module(bondy_oplog_test_reject_validator).

-behaviour(bondy_oplog_validator).

-export([init/2]).
-export([sign_event/2]).
-export([verify_event/2]).
-export([detect_equivocation/2]).

init(_InstanceId, _Opts) ->
    {ok, undefined}.

sign_event(Event, State) ->
    {Event, State}.

verify_event(_Event, _State) ->
    {error, refused}.

detect_equivocation(_E1, _E2) ->
    ok.
