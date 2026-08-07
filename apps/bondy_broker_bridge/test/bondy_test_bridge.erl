%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_test_bridge).

-moduledoc """
A `bondy_broker_bridge` implementation that records what it was asked to do,
for use in Common Test suites.

It reaches no external system, so a suite can exercise the manager's own
machinery -- specification loading, subscription creation, `mops` evaluation,
action validation and shutdown -- without a broker, an SMTP relay or a network.

Recorded state lives in a public named ETS table owned by a keeper process, so
it survives the transient process that runs `init_per_suite/1`.

    init_per_suite(Config) ->
        ok = bondy_test_bridge:start(),
        Config.

    my_test(_) ->
        ok = bondy_test_bridge:reset(),
        %% ... publish something ...
        [Action] = bondy_test_bridge:actions(),
        ?assertEqual(~"hello", maps:get(~"body", Action)).

`set_result/1` makes the next `apply_action/1` answer something other than `ok`,
which is how a suite drives the manager's failure paths.
""".

-include_lib("kernel/include/logger.hrl").

-behaviour(bondy_broker_bridge).

-define(TAB, ?MODULE).
-define(KEEPER, bondy_test_bridge_keeper).

%% The action shape this bridge accepts. Deliberately small: the point is to
%% observe what `mops` produced, not to model a real sink.
-define(ACTION_SPEC, #{
    <<"tag">> => #{
        alias => tag,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => binary
    },
    <<"body">> => #{
        alias => body,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => binary
    },
    <<"meta">> => #{
        alias => meta,
        required => true,
        default => #{},
        allow_null => false,
        allow_undefined => false,
        datatype => map
    }
}).

%% API
-export([actions/0]).
-export([reset/0]).
-export([set_result/1]).
-export([start/0]).
-export([stop/0]).
-export([terminations/0]).

%% BONDY_BROKER_BRIDGE CALLBACKS
-export([apply_action/1]).
-export([init/1]).
-export([terminate/2]).
-export([validate_action/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Create the recording table, owned by a process that outlives the caller.

Idempotent: calling it again while the keeper is alive is a no-op.
""".
-spec start() -> ok.

start() ->
    case whereis(?KEEPER) of
        undefined ->
            Self = self(),
            Pid = spawn(fun() -> keeper(Self) end),
            receive
                {?KEEPER, ready} ->
                    true = is_process_alive(Pid),
                    ok
            after 5000 ->
                error(bondy_test_bridge_keeper_timeout)
            end;
        _ ->
            ok
    end.

-doc "Stop the keeper and discard everything it recorded.".
-spec stop() -> ok.

stop() ->
    case whereis(?KEEPER) of
        undefined ->
            ok;
        Pid ->
            Ref = monitor(process, Pid),
            Pid ! stop,
            receive
                {'DOWN', Ref, process, Pid, _} -> ok
            after 5000 -> ok
            end
    end.

-doc "Discard recorded actions and terminations, and clear any forced result.".
-spec reset() -> ok.

reset() ->
    true = ets:delete_all_objects(?TAB),
    ok.

-doc """
Return every action `apply_action/1` accepted, oldest first.

Each is the validated action map, i.e. what `mops` produced.
""".
-spec actions() -> [map()].

actions() ->
    in_seq_order(select_tagged(action)).

-doc "Return every `{Reason, Ctxt}` pair `terminate/2` was called with.".
-spec terminations() -> [{Reason :: any(), Ctxt :: any()}].

terminations() ->
    in_seq_order(select_tagged(termination)).

-doc """
Force what `apply_action/1` returns.

Set to `ok` to restore normal behaviour. Any other term is returned verbatim,
so a suite can drive the `{error, _}` and `{retry, _}` paths.
""".
-spec set_result(Result :: any()) -> ok.

set_result(Result) ->
    true = ets:insert(?TAB, {result, Result}),
    ok.

%% =============================================================================
%% BONDY_BROKER_BRIDGE CALLBACKS
%% =============================================================================

-doc """
Return a `mops` base context naming this bridge.

The `tag` is asserted by suites to prove the base context reached the template.
""".
-spec init(Config :: any()) -> {ok, map()}.

init(_Config) ->
    ok = start(),
    {ok, #{<<"test">> => #{<<"tag">> => <<"from_init">>}}}.

-doc "Validate the evaluated action against this bridge's small spec.".
-spec validate_action(Action :: map()) -> {ok, map()} | {error, any()}.

validate_action(Action0) ->
    try maps_utils:validate(Action0, ?ACTION_SPEC) of
        Action1 ->
            {ok, Action1}
    catch
        _:Reason ->
            {error, Reason}
    end.

-doc "Record the action and return `ok`, or whatever `set_result/1` forced.".
-spec apply_action(Action :: map()) -> ok | {retry, any()} | {error, any()}.

apply_action(Action) ->
    N = ets:update_counter(?TAB, action_seq, {2, 1}, {action_seq, 0}),
    true = ets:insert(?TAB, {{action, N}, Action}),
    case ets:lookup(?TAB, result) of
        [{result, Result}] -> Result;
        [] -> ok
    end.

-doc "Record that the manager terminated this bridge, and with what context.".
-spec terminate(Reason :: any(), Ctxt :: any()) -> ok.

terminate(Reason, Ctxt) ->
    %% The manager may be shutting down after `stop/0`, so tolerate a table
    %% that is already gone rather than failing a suite during teardown.
    try
        N = ets:update_counter(?TAB, termination_seq, {2, 1}, {termination_seq, 0}),
        true = ets:insert(?TAB, {{termination, N}, {Reason, Ctxt}}),
        ok
    catch
        error:badarg ->
            ok
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% The table is a `set` and also holds bookkeeping keys, so entries are selected
%% by tag with a match specification and ordered by their recorded sequence.
select_tagged(Tag) ->
    MS = [{{{Tag, '$1'}, '$2'}, [], [{{'$1', '$2'}}]}],
    ets:select(?TAB, MS).

%% @private
in_seq_order(Pairs) ->
    [Value || {_Seq, Value} <- lists:keysort(1, Pairs)].

%% @private
%% Owns the table so it outlives whichever transient process called `start/0`.
keeper(Parent) ->
    true = register(?KEEPER, self()),
    _ = ets:new(?TAB, [named_table, public, set]),
    Parent ! {?KEEPER, ready},
    receive
        stop -> ok
    end.
