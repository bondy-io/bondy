%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_instance_keeper).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Starts an instance again when its subtree stops without `stop_instance/1`.

`bondy_oplog_instance_dyn_sup` never restarts a subtree, because a
subtree restarted there would come back without children, and a subtree
whose children exhaust its restart intensity stops with reason
`shutdown`. This process monitors every subtree that
`bondy_oplog_instance_dyn_sup:start_instance/2` starts. When one stops,
it starts the instance again with the options it was first started with,
after a backoff of 1 s that doubles with each consecutive failure up to
60 s. A subtree that ran for 60 s resets the count.

Restarts run in this process, so `forget/1` (called by `stop_instance/1`)
is ordered against them and a stopped instance is never started again.
A `start_instance/2` of a kept instance that is not running is handed to
`start_now/1` for the same reason: started beside a pending restart, the
instance would get two subtrees writing one WAL.
What a restart needs, each instance's start options and subtree
supervisor, is in a table this process borrows from
`bondy_connect_table_manager`, so the table survives a crash here and a restarted
keeper monitors every subtree recorded in it. Each of these is exercised by
`bondy_oplog_instance_keeper_test`.

From the moment a kept instance's subtree stops until a start succeeds or
`forget/1` drops it, `not_running/0` lists the instance; the alarm
`{bondy_oplog_instance_down, InstanceId}` is raised once this process has
handled the stop, and cleared with it. `bondy_router_app:is_ready/0` reads
`not_running/0` (`bondy_oplog_instance_keeper_statem_test`). Because
restarts run here one at a time, subtrees that stop together come back one
after another, and `watch/3`, `forget/1`, `start_now/1` and
`release_drain_gate/1` wait behind a restart in progress.

It is started after `bondy_oplog_instance_dyn_sup`, so during shutdown it
stops first and restarts nothing.

Once `bondy_oplog_instance:open_drain_gate/1` releases an instance's WAL
drain, its recorded options no longer gate it, so an applier that starts
again within this boot, restarted here or by its own supervisor, starts
with the drain open (`bondy_db_bookie_restart_test`).
""").

-define(TAB, ?MODULE).
-define(BASE_DELAY_MS, 1000).
-define(MAX_DELAY_MS, 60000).
-define(STABLE_MS, 60000).

-record(state, {
    %% `{watching, SupPid, MonitorRef, StartedAtMs, Failures}` or
    %% `{retrying, Token, Failures}` per instance.
    instances = #{} :: #{instance_id() => tuple()},
    monitors = #{} :: #{reference() => instance_id()}
}).

-export([start_link/0]).
-export([child_spec/0]).
-export([watch/3]).
-export([forget/1]).
-export([is_kept/1]).
-export([not_running/0]).
-export([start_now/1]).
-export([release_drain_gate/1]).
-export([drain_released/1]).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec child_spec() -> supervisor:child_spec().

child_spec() ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

?DOC("""
Keeps `InstanceId`, running under `SupPid`, started with `Opts`. Called
by `bondy_oplog_instance_dyn_sup:start_instance/2` after a start.
""").
-spec watch(instance_id(), pid(), bondy_oplog_instance:opts()) -> ok.

watch(InstanceId, SupPid, Opts) ->
    gen_server:call(?MODULE, {watch, InstanceId, SupPid, Opts}, infinity).

?DOC("""
Stops keeping the instance named by its id or its subtree supervisor.
Called by `bondy_oplog_instance_dyn_sup:stop_instance/1` before it stops
the subtree.
""").
-spec forget(instance_id() | pid()) -> ok.

forget(InstanceIdOrSupPid) ->
    gen_server:call(?MODULE, {forget, InstanceIdOrSupPid}, infinity).

?DOC("""
Whether `InstanceId` is kept here: started and not since stopped.
""").
-spec is_kept(instance_id()) -> boolean().

is_kept(InstanceId) ->
    ets:member(?TAB, InstanceId).

?DOC("""
The kept instances with no running subtree: stopped and not yet started
again, including those whose restarts keep failing. `[]` before this
process first starts. Reads this process's table, not its state, so it
answers while this process is restarting.
""").
-spec not_running() -> [instance_id()].

not_running() ->
    case ets:whereis(?TAB) of
        undefined ->
            [];
        _ ->
            [
                Id
             || [Id, SupPid] <- ets:match(?TAB, {'$1', '$2', '_'}),
                not is_process_alive(SupPid)
            ]
    end.

?DOC("""
Starts kept `InstanceId` now, with its recorded options, unless a subtree
for it is running; a pending restart is cancelled. `{error, not_kept}` if
it has been forgotten meanwhile.
""").
-spec start_now(instance_id()) -> {ok, pid()} | {error, term()}.

start_now(InstanceId) ->
    gen_server:call(?MODULE, {start_now, InstanceId}, infinity).

?DOC("""
Records that `InstanceId`'s WAL drain has been released, so its recorded
start options no longer gate it. Called by
`bondy_oplog_instance:open_drain_gate/1`.
""").
-spec release_drain_gate(instance_id()) -> ok.

release_drain_gate(InstanceId) ->
    gen_server:call(?MODULE, {release_drain_gate, InstanceId}, infinity).

?DOC("""
Whether `InstanceId` is kept here with options that no longer gate its WAL
drain. `false` for an instance that is not kept, which is the case during
its first start: `watch/3` follows the start.
""").
-spec drain_released(instance_id()) -> boolean().

drain_released(InstanceId) ->
    case ets:lookup(?TAB, InstanceId) of
        [{_, _, Opts}] -> not maps:get(drain_gated, applier_opts(Opts), false);
        [] -> false
    end.

%% =============================================================================
%% gen_server CALLBACKS
%% =============================================================================

init([]) ->
    {ok, ?TAB} = bondy_connect_table_manager:add_or_claim(
        ?TAB, [named_table, set, protected]
    ),
    State = ets:foldl(
        fun({Id, SupPid, _Opts}, S) -> monitor_sup(Id, SupPid, 0, S) end,
        #state{},
        ?TAB
    ),
    {ok, State}.

handle_call({watch, Id, SupPid, Opts}, _From, State) ->
    true = ets:insert(?TAB, {Id, SupPid, Opts}),
    {reply, ok, monitor_sup(Id, SupPid, 0, drop(Id, State))};
handle_call({forget, SupPid}, From, State) when is_pid(SupPid) ->
    case ets:select(?TAB, [{{'$1', SupPid, '_'}, [], ['$1']}]) of
        [Id] -> handle_call({forget, Id}, From, State);
        [] -> {reply, ok, State}
    end;
handle_call({start_now, Id}, _From, State0) ->
    Failures =
        case maps:get(Id, State0#state.instances, undefined) of
            {watching, _, _, _, F} -> F;
            {retrying, _, F} -> F;
            undefined -> 0
        end,
    {Reply, State} = restart(Id, Failures, drop(Id, State0)),
    {reply, Reply, State};
handle_call({release_drain_gate, Id}, _From, State) ->
    _ =
        case ets:lookup(?TAB, Id) of
            [{Id, SupPid, Opts}] ->
                Applier = maps:put(drain_gated, false, applier_opts(Opts)),
                ets:insert(
                    ?TAB, {Id, SupPid, maps:put(applier, Applier, Opts)}
                );
            [] ->
                true
        end,
    {reply, ok, State};
handle_call({forget, Id}, _From, State) ->
    true = ets:delete(?TAB, Id),
    ok = clear_down_alarm(Id),
    {reply, ok, drop(Id, State)};
handle_call(_Request, _From, State) ->
    {reply, {error, badcall}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', Ref, process, _, Reason}, State0) ->
    case maps:take(Ref, State0#state.monitors) of
        {Id, Monitors} ->
            State = State0#state{monitors = Monitors},
            {noreply, stopped(Id, Reason, State)};
        error ->
            {noreply, State0}
    end;
handle_info({restart, Id, Token}, State) ->
    case maps:find(Id, State#state.instances) of
        {ok, {retrying, Token, Failures}} ->
            {_, State1} = restart(Id, Failures, State),
            {noreply, State1};
        _ ->
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
stopped(Id, Reason, State) ->
    {watching, _, _, StartedAt, Failures0} = maps:get(
        Id, State#state.instances
    ),
    Failures =
        case now_ms() - StartedAt >= ?STABLE_MS of
            true -> 0;
            false -> Failures0 + 1
        end,
    ?LOG_WARNING(#{
        description => "Oplog instance stopped; it will be started again",
        instance_id => Id,
        reason => Reason,
        restart_in_ms => delay(Failures)
    }),
    ok = set_down_alarm(Id),
    retry(Id, Failures, State).

%% @private
restart(Id, Failures, State) ->
    case ets:lookup(?TAB, Id) of
        [{Id, _, Opts}] ->
            case start(Id, Opts) of
                {ok, SupPid} = Ok ->
                    %% Cleared first: a crash here leaves the row naming the
                    %% dead subtree, which the next keeper sees stop again.
                    ok = clear_down_alarm(Id),
                    true = ets:insert(?TAB, {Id, SupPid, Opts}),
                    ?LOG_NOTICE(#{
                        description => "Oplog instance started again",
                        instance_id => Id
                    }),
                    {Ok, monitor_sup(Id, SupPid, Failures, drop(Id, State))};
                {error, Reason} ->
                    ?LOG_ERROR(#{
                        description => "Oplog instance failed to start again",
                        instance_id => Id,
                        reason => Reason,
                        restart_in_ms => delay(Failures + 1)
                    }),
                    {{error, Reason}, retry(Id, Failures + 1, State)}
            end;
        [] ->
            {{error, not_kept}, drop(Id, State)}
    end.

%% @private
%% A start that raises must not stop this process: its restart would find
%% the same dead subtrees at once and retry them without backoff until
%% `bondy_oplog_sup` gives up and takes every instance with it.
start(Id, Opts) ->
    try
        bondy_oplog_instance_dyn_sup:restart_instance(Id, Opts)
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

%% @private
retry(Id, Failures, State) ->
    Token = make_ref(),
    _ = erlang:send_after(delay(Failures), self(), {restart, Id, Token}),
    Instances = maps:put(
        Id, {retrying, Token, Failures}, State#state.instances
    ),
    State#state{instances = Instances}.

%% @private
monitor_sup(Id, SupPid, Failures, State) ->
    Ref = monitor(process, SupPid),
    Entry = {watching, SupPid, Ref, now_ms(), Failures},
    State#state{
        instances = maps:put(Id, Entry, State#state.instances),
        monitors = maps:put(Ref, Id, State#state.monitors)
    }.

%% @private
drop(Id, State) ->
    case maps:take(Id, State#state.instances) of
        {{watching, _, Ref, _, _}, Instances} ->
            true = demonitor(Ref, [flush]),
            State#state{
                instances = Instances,
                monitors = maps:remove(Ref, State#state.monitors)
            };
        {{retrying, _, _}, Instances} ->
            State#state{instances = Instances};
        error ->
            State
    end.

%% @private
%% The 3-tuple carries `details` through OTP's `alarm_handler:set_alarm/1`;
%% see `bondy_alarm_handler:set_alarm/2`.
set_down_alarm(Id) ->
    alarm_handler:set_alarm(
        {
            {bondy_oplog_instance_down, Id},
            <<"Oplog instance is not running; its tables are unavailable">>,
            #{details => #{instance_id => Id}}
        }
    ).

%% @private
clear_down_alarm(Id) ->
    alarm_handler:clear_alarm({bondy_oplog_instance_down, Id}).

%% @private
applier_opts(Opts) ->
    maps:get(applier, Opts, #{}).

%% @private
delay(Failures) ->
    min(?BASE_DELAY_MS bsl min(Failures, 6), ?MAX_DELAY_MS).

%% @private
now_ms() ->
    erlang:monotonic_time(millisecond).
