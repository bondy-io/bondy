%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Stateful PropEr model of what `bondy_oplog_instance_keeper` reports about
%% the instances it keeps.
%%
%% The model holds each of three instances as absent, running or down. The
%% commands start one, kill its subtree, start a down one again with
%% `start_now/1`, stop one, and restart the keeper. Every restart the keeper
%% schedules on its own fails (`restart_instance/2` is mocked to refuse unless
%% the command is `heal`), so a killed instance stays down until the model
%% heals it. After each command, `not_running/0` and the raised
%% `{bondy_oplog_instance_down, Id}` alarms must both equal the model's down
%% set. The alarms are read from a handler that, like `bondy_alarm_handler`
%% in a release, keys them by id; SASL's default handler keeps a re-raise as a
%% duplicate. Not covered: a timed restart that succeeds (the keeper's backoff is
%% measured by `bondy_oplog_instance_keeper_test`), and a subtree that stops by
%% exhausting its restart intensity rather than being killed.
-module(bondy_oplog_instance_keeper_statem_test).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(KEEPER, bondy_oplog_instance_keeper).
-define(SLOTS, [1, 2, 3]).

-export([prop_keeper_reports_down_instances/0]).

-export([initial_state/0]).
-export([command/1]).
-export([precondition/2]).
-export([postcondition/3]).
-export([next_state/3]).

-export([start/1]).
-export([kill/1]).
-export([heal/1]).
-export([stop/1]).
-export([restart_keeper/0]).

-export([init/1]).
-export([handle_event/2]).
-export([handle_call/2]).

%% =============================================================================
%% EUNIT
%% =============================================================================

statem_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 300,
            ?_assert(
                proper:quickcheck(
                    prop_keeper_reports_down_instances(),
                    [{numtests, 100}, {to_file, user}]
                )
            )}
    ]}.

setup() ->
    {ok, _} = application:ensure_all_started(sasl),
    {ok, _} = application:ensure_all_started(bondy_db),
    ok = gen_event:add_handler(alarm_handler, ?MODULE, []),
    Allowed = atomics:new(1, []),
    persistent_term:put({?MODULE, allowed}, Allowed),
    ok = meck:new(bondy_oplog_instance_dyn_sup, [passthrough, no_link]),
    ok = meck:expect(
        bondy_oplog_instance_dyn_sup, restart_instance, fun(Id, Opts) ->
            case atomics:get(Allowed, 1) of
                1 -> meck:passthrough([Id, Opts]);
                0 -> {error, held_by_test}
            end
        end
    ),
    ok.

cleanup(_) ->
    _ = meck:unload(),
    _ = gen_event:delete_handler(alarm_handler, ?MODULE, []),
    _ = persistent_term:erase({?MODULE, allowed}),
    ok.

%% =============================================================================
%% PROPERTY
%% =============================================================================

prop_keeper_reports_down_instances() ->
    ?FORALL(
        Cmds,
        commands(?MODULE),
        begin
            Prefix = iolist_to_binary([
                "keeper_statem_",
                integer_to_list(erlang:unique_integer([positive])),
                "_"
            ]),
            put(prefix, Prefix),
            try
                {History, State, Result} = run_commands(?MODULE, Cmds),
                ?WHENFAIL(
                    io:format(
                        user,
                        "History: ~p~nState: ~p~nResult: ~p~n",
                        [History, State, Result]
                    ),
                    aggregate(command_names(Cmds), Result =:= ok)
                )
            after
                _ = [bondy_oplog:stop_instance(id(S)) || S <- ?SLOTS]
            end
        end
    ).

%% =============================================================================
%% MODEL
%% =============================================================================

initial_state() ->
    maps:from_keys(?SLOTS, absent).

command(_M) ->
    oneof(
        [{call, ?MODULE, start, [Slot]} || Slot <- ?SLOTS] ++
            [{call, ?MODULE, kill, [Slot]} || Slot <- ?SLOTS] ++
            [{call, ?MODULE, heal, [Slot]} || Slot <- ?SLOTS] ++
            [{call, ?MODULE, stop, [Slot]} || Slot <- ?SLOTS] ++
            [{call, ?MODULE, restart_keeper, []}]
    ).

precondition(M, {call, _, start, [S]}) -> maps:get(S, M) =:= absent;
precondition(M, {call, _, kill, [S]}) -> maps:get(S, M) =:= running;
precondition(M, {call, _, heal, [S]}) -> maps:get(S, M) =:= down;
precondition(M, {call, _, stop, [S]}) -> maps:get(S, M) =/= absent;
precondition(_, {call, _, restart_keeper, []}) -> true.

next_state(M, _, {call, _, start, [S]}) -> M#{S := running};
next_state(M, _, {call, _, kill, [S]}) -> M#{S := down};
next_state(M, _, {call, _, heal, [S]}) -> M#{S := running};
next_state(M, _, {call, _, stop, [S]}) -> M#{S := absent};
next_state(M, _, {call, _, restart_keeper, []}) -> M.

postcondition(M0, Call, {NotRunning, Alarmed}) ->
    M = next_state(M0, undefined, Call),
    Down = lists:sort([id(S) || S := down <- M]),
    NotRunning =:= Down andalso Alarmed =:= Down.

%% =============================================================================
%% COMMANDS
%% =============================================================================

start(S) ->
    {ok, _} = bondy_oplog:start_instance(id(S)),
    observe().

kill(S) ->
    Sup = bondy_oplog_registry:sup_pid(id(S)),
    Ref = monitor(process, Sup),
    exit(Sup, kill),
    receive
        {'DOWN', Ref, _, _, _} -> ok
    end,
    observe().

heal(S) ->
    Allowed = persistent_term:get({?MODULE, allowed}),
    ok = atomics:put(Allowed, 1, 1),
    try
        {ok, _} = ?KEEPER:start_now(id(S))
    after
        ok = atomics:put(Allowed, 1, 0)
    end,
    observe().

stop(S) ->
    _ = bondy_oplog:stop_instance(id(S)),
    observe().

%% A manual restart through the supervisor, which unlike a kill does not count
%% against `bondy_oplog_sup`'s restart intensity across a hundred runs.
restart_keeper() ->
    ok = supervisor:terminate_child(bondy_oplog_sup, ?KEEPER),
    {ok, _} = supervisor:restart_child(bondy_oplog_sup, ?KEEPER),
    observe().

%% =============================================================================
%% HELPERS
%% =============================================================================

%% The keeper handles a subtree's `'DOWN'` before this call, and raises its
%% alarm before replying, so the call to the manager below sees it.
observe() ->
    _ = sys:get_state(?KEEPER),
    Mine = [id(S) || S <- ?SLOTS],
    NotRunning = lists:sort([
        Id
     || Id <- ?KEEPER:not_running(), lists:member(Id, Mine)
    ]),
    Alarmed = lists:sort([
        Id
     || {bondy_oplog_instance_down, Id} <- gen_event:call(
            alarm_handler, ?MODULE, ids
        ),
        lists:member(Id, Mine)
    ]),
    {NotRunning, Alarmed}.

id(Slot) ->
    <<(get(prefix))/binary, (integer_to_binary(Slot))/binary>>.

%% =============================================================================
%% ALARM HANDLER
%% =============================================================================

init([]) ->
    {ok, #{}}.

handle_event({set_alarm, Alarm}, Ids) ->
    {ok, Ids#{element(1, Alarm) => true}};
handle_event({clear_alarm, Id}, Ids) ->
    {ok, maps:remove(Id, Ids)};
handle_event(_, Ids) ->
    {ok, Ids}.

handle_call(ids, Ids) ->
    {ok, maps:keys(Ids), Ids}.
