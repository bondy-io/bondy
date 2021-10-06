%% =============================================================================
%%  bondy_migration_manager.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================

-module(bondy_migration_manager).
-behaviour(gen_statem).

-include_lib("kernel/include/logger.hrl").

-define(MANIFEST_NAME, bondy_migration_manager_manifest).
-define(LOG_NAME, bondy_migration_manager_log).
-define(LOG_FILE_NAME, "current.log").
-define(MANIFEST_FILE_NAME, "manifest.dets").
-define(NOW, erlang:system_time(millisecond)).

-record(state, {
	from 								:: 	pid(),
	data_root                           :: 	file:filename(),
	manifest_filename                 	:: 	file:filename(),
	log_filename						:: 	file:filename(),
	log                                 :: 	disk_log:log(),
	remaining = []           			:: 	[module()],
	migration_states = #{}	    		:: 	#{module() =>
												bondy_migration:state()
											},
    timestamp  							:: 	integer()
}).

-record(log_header, {
	log_version = 1             ::  integer(),
	timestamp                   ::  integer()
}).


%% API
-export([start_link/0]).
-export([execute/0]).

%% GEN_STATEM CALLBACKS
-export([init/1]).
-export([callback_mode/0]).
-export([terminate/3]).
-export([code_change/4]).

%% STATES
-export([preparing/3]).
-export([executing/3]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start_link() ->
    {ok, Root} = application:get_env(bondy, platform_data_dir),
    DataRoot = filename:join([Root, "migration"]),
    gen_statem:start_link(?MODULE, [DataRoot, self()], []).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
execute() ->
	case bondy_migration_manager:start_link() of
		{ok, Pid} ->
			receive
				{migration_result, Pid, Result} ->
					Result
			end;
		Error ->
			Error
	end.



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



callback_mode() ->
    state_functions.


init([DataRoot, From]) ->
	dbg:tracer(), dbg:p(all,c), dbg:tpl(?MODULE, '_', x),
	process_flag(trap_exit, true),
	State = #state{
		from = From,
		log_filename = filename:join([DataRoot, ?LOG_FILE_NAME]),
		manifest_filename = filename:join([DataRoot, ?MANIFEST_FILE_NAME]),
		data_root = DataRoot,
		timestamp = ?NOW
	},
    {ok, preparing, State, 0}.



terminate(normal, _StateName, State) ->
	close_files(State);

terminate(Reason, _, State) ->
	State#state.from ! {migration_result, self(), {error, Reason}},
	close_files(State).


code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.



%% =============================================================================
%% STATE FUNCTIONS
%% =============================================================================



preparing(timeout, _, State0) ->
	_ = lager:info("Analysing required migrations"),
	Log = ?LOG_NAME,
	DetsOpts = [
		{file, State0#state.manifest_filename},
		{keypos, 1},
		{type, set}
	],
	{ok, ?MANIFEST_NAME} = dets:open(?MANIFEST_NAME, DetsOpts),

	{ok, Log} = open(State0#state.log_filename),

	State1 = State0#state{log = Log},

	%% Restore state from existing log in case we crashed
	{_, State2} = fold_log(Log, fun restore_state/2, {undefined, State1}),

	%% Compile and load all migration modules from priv/migrations dir
	try bondy_migration:load(State2#state.remaining) of
        [] ->
			%% Nothing to be done
			_ = lager:info("No required migrations found"),
			State3 = close_and_rename_log(State2),
			State3#state.from ! {migration_result, self(), ok},
            {stop, normal, State3};
		Mods ->
			%% We sort the migration modules based on their dependency graph
			Sorted = bondy_migration:topsort(Mods),
			State3 = State2#state{
				remaining = Sorted
			},
			_ = lager:info(
				"Found ~p migrations; migrations = ~p",
				[length(Sorted), Sorted]
			),
            {next_state, executing, State3, 0}
    catch
		error:Reason ->
			State2#state.from ! {migration_result, self(), {error, Reason}},
            {stop, Reason, State2}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
executing(timeout, _, #state{remaining = [H|T]} = State0) ->
	case execute_migration(H, State0) of
		{ok, State1} ->
			State2 = State1#state{remaining = T},
			{next_state, executing, State2, 0};
		{error, Reason, State1} ->
			State1#state.from ! {migration_result, self(), {error, Reason}},
			{stop, Reason, State1}
	end;

executing(timeout, _, #state{remaining = []} = State0) ->
	_ = lager:info("Finished executing available migrations"),
	State1 = close_and_rename_log(State0),
	State1#state.from ! {migration_result, self(), ok},
	{stop, normal, State1}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
execute_migration(Mod, State0) ->
	_ = lager:info("Executing migration; migration= ~p", [Mod]),

	Log = State0#state.log,

	case bondy_migration:init(Mod) of
		{ok, MState0} ->
			ok = disk_log:log(Log, {started, Mod, MState0, ?NOW}),

			case bondy_migration:execute(Mod, Log) of
				{ok, MState} ->
					State1 = set_migration_state(Mod, MState, State0),
					ok = disk_log:log(Log, {finished, Mod, MState, ?NOW}),
					_ = lager:info("Migration finished; migration= ~p", [Mod]),
					{ok, State1};
				{error, aborted, MState} ->
					State1 = set_migration_state(Mod, MState, State0),
					ok = disk_log:log(Log, {aborted, Mod, MState, ?NOW}),
					_ = lager:info("Migration aborted; migration= ~p", [Mod]),
					{error, aborted, State1};
				{error, Reason, MState} ->
					State1 = set_migration_state(Mod, MState, State0),
					_ = lager:info(
						"Migration failed; migration= ~p, reason=~p", [Mod, Reason]),
					ok = disk_log:log(Log, {failed, Mod, MState, ?NOW}),
					{error, Reason, State1}
			end;
		{error, Reason} ->
			disk_log:log(Log, {failed, Mod, Reason, undefined, ?NOW}),
			_ = lager:info(
				"Migration failed; migration=~p, reason=~p", [Mod, Reason]),
			{error, Reason, State0}
	end.


%% @private
restore_state({started, Mod, MState}, {_, State}) ->
	{Mod, set_migration_state(Mod, MState, State)};

restore_state({finished, Mod, MState}, {Mod, State}) ->
	{undefined, set_migration_state(Mod, MState, State)};

restore_state({aborted, Mod, MState}, {Mod, State}) ->
	{undefined, set_migration_state(Mod, MState, State)};

restore_state({failed, Mod, MState}, {Mod, State}) ->
	{undefined, set_migration_state(Mod, MState, State)};

restore_state(Event, {Mod, State}) ->
	MState = bondy_migration:get_state(Event),
	{Mod, set_migration_state(Mod, MState, State)}.





%% @private
-spec open(file:filename()) -> {ok, atom()} | {error, any()}.

open(Filename) ->
    Head = #log_header{
        timestamp = erlang:system_time(millisecond)
    },

    case open_log(Filename) of
        {ok, ?LOG_NAME} = OK ->
            ok = maybe_set_header(?LOG_NAME, Head),
            OK;
        Error ->
            Error
    end.


%% @private
fold_log(Log, Fun, Acc) ->
    do_fold_log(disk_log:chunk(Log, start), Fun, Acc).


%% @private
do_fold_log(eof, _, Acc) ->
    Acc;

do_fold_log({corrupt_log_filename, _}, _, Acc) ->
    error({corrupt_log_filename, Acc});

do_fold_log({error, Reason}, _, _) ->
    error(Reason);

do_fold_log({Cont, Terms}, Fun, Acc0) ->
    Acc1 = lists:do_foldl(Fun, Acc0, Terms),
    do_fold_log(Cont, Fun, Acc1);

do_fold_log(Cont, Fun, Acc) ->
    do_fold_log(disk_log:chunk(Cont), Fun, Acc).


%% @private
open_log(Filename) when is_list(Filename) ->
	case filelib:ensure_dir(Filename) of
        ok ->
			Opts = [
				{name, ?LOG_NAME},
				{file, Filename},
				{linkto, self()},
				{size, infinity},
				{type, halt}
			],
			case disk_log:open(Opts) of
				{ok, ?LOG_NAME} ->
					{ok, ?LOG_NAME};
				{repaired, ?LOG_NAME, Recovered, Bad} ->
					_ = lager:warning(
                        "Log ~p repaired; "
                        "recovered=~p, bad_bytes=~p.",
                        [Filename, Recovered, Bad]
                    ),
					{ok, ?LOG_NAME};
				{error, _} = Error ->
					Error
			end;
    	{error, _} = Error ->
    		Error
    end.


%% @private
maybe_set_header(Log, Head) ->
    case lists:keyfind(head, 1, disk_log:info(Log)) of
        {head, Head} ->
            ok;
		{head, none} ->
            disk_log:change_header(Log, {head, Head});
        false ->
            disk_log:change_header(Log, {head, Head})
    end.


%% @private
close_files(State) ->
	ok = dets:close(State#state.manifest_filename),
	close_log(State#state.log).


%% @private
close_log(undefined) ->
	ok;

close_log(Log) ->
	disk_log:sync(Log),
	case disk_log:close(Log) of
		ok ->
			ok;
		{error, Reason} ->
			_ = lager:error(
                "Failed syncing log to disk; "
                "log=~p, reason=~p",
                [Log, Reason]
            ),
			{error, Reason}
	end.


%% @private
close_and_rename_log(State0) ->
	ok = close_log(State0#state.log),
	State1 = State0#state{log = undefined},
	CurrentName = State1#state.log_filename,
	NewName = filename:join([
		State1#state.data_root,
		integer_to_list(State1#state.timestamp),
		".log"
	]),
	_ = file:rename(CurrentName, NewName),
	State1.



%% @private
%% get_migration_state(Mod, #state{migration_states = Map}) ->
%% 	maps:get(Mod, Map, undefined).


%% @private
set_migration_state(Mod, MState, State) ->
	Map = State#state.migration_states,
	State#state{migration_states = maps:put(Mod, MState, Map)}.
