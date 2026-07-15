%% Test-only refreshable validator. Caches an `allow_op` value read
%% from a public ETS table; `verify_event/2` accepts events whose
%% `op` matches the cached value and rejects all others; `refresh/1`
%% re-reads the table and updates the cached value. Lets the
%% validator-refresh acceptance test rotate the decision at runtime
%% without restarting the instance.

-module(bondy_oplog_test_refreshable_validator).

-behaviour(bondy_oplog_validator).

-export([init/2]).
-export([sign_event/2]).
-export([verify_event/2]).
-export([detect_equivocation/2]).
-export([refresh/1]).

init(_InstanceId, #{rule_table := Tab}) ->
    {ok, #{rule_table => Tab, allow_op => current_allow(Tab)}}.

sign_event(Event, State) ->
    {Event, State}.

verify_event(Event, #{allow_op := Allow}) ->
    case bondy_oplog_event:op(Event) of
        Allow -> ok;
        _Other -> {error, refused}
    end.

detect_equivocation(_E1, _E2) ->
    ok.

refresh(#{rule_table := Tab} = State) ->
    {ok, State#{allow_op => current_allow(Tab)}}.

current_allow(Tab) ->
    case ets:lookup(Tab, allow_op) of
        [] -> op_a;
        [{allow_op, V}] -> V
    end.
