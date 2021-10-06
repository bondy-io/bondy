%% =============================================================================
%%  bondy_migration.erl -
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

-module(bondy_migration).

-include_lib("kernel/include/logger.hrl").

-define(MAX_RETRIES, 3).
-define(NOW, erlang:system_time(millisecond)).

-record(state, {
    mod                         ::  module(),
	direction = forward			::	forward | rollback,
	phases = []			        :: 	[phase()],
	done_phases	= []		    ::	[phase()],
    data						:: 	any() | undefined,
    rollback_retries = 0        ::  pos_integer(),
    events = []                 ::  [event()]
}).

-record(phase, {
    name                        ::  phase_name(),
    forward                     ::  operation(),
    rollback                    ::  operation()
}).


-type event_name()              :: 	started | finished | aborted | failed.
-type event()                   :: 	{
                                        event_name(),
                                        Migration :: module(),
                                        phase_name(),
                                        state()
                                    }.
-type phase_name()              ::  binary() | atom().
-type phase()                   ::  #phase{}.
-type operation()               ::  fun((State :: any()) ->
    {ok, NewData :: any()}
    | {error, Reason :: any(), NewData :: any()}
).
-opaque state() 		        :: 	#state{}.


-export_type([state/0]).


-export([check_dependencies/2]).
-export([dependency_graph/1]).
-export([execute/2]).
-export([get_state/1]).
-export([init/1]).
-export([is_done/1]).
-export([list/0]).
-export([load/0]).
-export([load/1]).
-export([new_phase/3]).
-export([phase_forward_op/1]).
-export([phase_name/1]).
-export([phase_rollback_op/1]).
-export([topsort/1]).
-export([validate/0]).
-export([validate/1]).



%% =============================================================================
%% CALLBACKS
%% =============================================================================



-callback phases() -> [phase()].


-callback dependencies() -> [module()].


-callback init() ->
    {ok, State :: any()} | {error, Reason :: any()}.


-callback terminate(Reason :: any(), State :: any()) -> ok.


-callback manifest_properties() -> map().


-optional_callbacks([manifest_properties/0]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Lists the filenames of all migration modules found in the priv directory
%% @end
%% -----------------------------------------------------------------------------
list() ->
    PrivDir = bondy_config:priv_dir(),
    Dir = filename:join(PrivDir, "migrations"),
    case filelib:is_dir(Dir) of
        true ->
            filelib:wildcard(filename:join(Dir, "*.{erl}"));
        false ->
            []
    end.


%% -----------------------------------------------------------------------------
%% @doc Creates a new phase.
%% This is a util function to be used by modules implementing the
%% bondy_migration behaviour callback `phases/0'.
%% @end
%% -----------------------------------------------------------------------------
-spec new_phase(
    Name :: binary(), Forward :: operation(), Rollback :: operation()) ->
    phase() | no_return().

new_phase(Name, Forward, Rollback)
when (is_binary(Name) orelse is_atom(Name))
andalso is_function(Forward, 1)
andalso is_function(Rollback, 1) ->
    #phase{name = Name, forward = Forward, rollback = Rollback}.


%% -----------------------------------------------------------------------------
%% @doc Returns the name of a phase().
%% @end
%% -----------------------------------------------------------------------------
phase_name(#phase{name = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc Returns the forward operation (erlang function) of a `phase()'
%% @end
%% -----------------------------------------------------------------------------
phase_forward_op(#phase{forward = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc Returns the rollback operation (erlang function) of a `phase()'
%% @end
%% -----------------------------------------------------------------------------
phase_rollback_op(#phase{rollback = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc Validates all the migration modules found in the system's priv
%% directory.
%% This function is equivalent to `[validate(FN) || FN <- list()]'.
%% @end
%% -----------------------------------------------------------------------------
validate() ->
    [validate(FN) || FN <- list()].


%% -----------------------------------------------------------------------------
%% @doc Validates the migration module found at path Filename.
%% @end
%% -----------------------------------------------------------------------------
validate(Filename) ->
    case compile(Filename) of
        {error, _} = Error -> Error;
        _ -> ok
    end.


%% -----------------------------------------------------------------------------
%% @doc Compiles and loads all the migration modules found in the systems's priv
%% directory.
%% This function is equivalent to calling `load(list()).'.
%% @end
%% -----------------------------------------------------------------------------
load() ->
    load(list()).


%% -----------------------------------------------------------------------------
%% @doc Compiles and loads the migrations found at the Filename or list of
%% filnames provided.
%% @end
%% -----------------------------------------------------------------------------
load(L) when is_list(L) ->
    [load(FN) || FN <- L];

load(Filename) ->
    case compile(Filename) of
        {ok, Mod, Bin} ->
            case code:load_binary(Mod, Mod, Bin) of
                {module, Mod} ->
                    Mod;
                {error, _} = Err ->
                    _ = lager:error(
                        "Error when loading migration module; "
                        "filename=~p, module=~p",
                        [Filename, Mod]
                    ),
                    throw(Err)
            end;
        {error, Reason} ->
            error(Reason)
    end.


%% -----------------------------------------------------------------------------
%% @doc Returns a digraph:graph().
%% Let each module Mi be a node in the graph; there is an arc Mj -> Mi if Mi
%% depends on Mj.
%%
%% The resulting digraph:graph() can be used with the topsort/1 function.
%% @end
%% -----------------------------------------------------------------------------
dependency_graph(Mods) ->
    %% Let each module Mi be a node in the graph;
    %% put an arc Mj => Mi if Mi depends on Mj
    Relations = [{I, J} || I <- Mods, J <- I:dependencies()],
    Fun = fun({I, J}, Graph) ->
        digraph:add_vertex(Graph, I),
        digraph:add_vertex(Graph, J),
        digraph:add_edge(Graph, J, I),
        Graph
	end,
    Graph = lists:foldl(Fun, digraph:new(), Relations),
    case digraph_utils:is_acyclic(Graph) of
        true ->
            Graph;
        false ->
            error({dependency_cycles, digraph_utils:loop_vertices(Graph)})
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
topsort(Mods) when is_list(Mods) ->
    digraph_utils:topsort(dependency_graph(Mods));

topsort(Graph) ->
    digraph_utils:topsort(Graph).


%% -----------------------------------------------------------------------------
%% @doc Returns true if all transition dependencies for transition implemented
%% in Mod are satisfied by the list L.
%% @end
%% -----------------------------------------------------------------------------
check_dependencies(Mod, L) ->
    Deps = sets:from_list(Mod:dependencies()),
    sets:is_subset(Deps, sets:from_list(L)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
init(Mod) ->
    try Mod:init() of
        {ok, Data0} ->
            Phases = Mod:phases(),
            State = #state{
                mod = Mod,
                phases = Phases,
                data = Data0
            },
            {ok, State};
        Error ->
            Error
    catch
		_Class:Reason ->
            {error, Reason}
	end.



%% -----------------------------------------------------------------------------
%% @doc Executes, in order, the `forward_op' function of each of the phases of
%% a migration represented by the module Mod.
%% In case a phase fails, it rollbacks that phase and all the previously
%% succesfull phases.
%% At each step logs an entry into the provided Log.
%% @end
%% -----------------------------------------------------------------------------
-spec execute(ModOrState :: module(), Log :: disk_log:log()) ->
    {ok, state()} | {error, Reason :: aborted | any(), state() | undefined}.


execute(Mod, Log) ->
	try Mod:init() of
		{ok, Data0} ->
			Phases = Mod:phases(),
			State0 = #state{
                mod = Mod,
				phases = Phases,
				data = Data0
			},
			case execute_phases(State0, Log) of
                {ok, #state{direction = forward} = State1} = OK ->
                    _ = Mod:terminate(normal, State1),
                    OK;
                {ok, #state{direction = rollback} = State1} ->
                    _ = Mod:terminate(aborted, State1),
					{error, aborted, State1};
                {error, Reason, State1} = Error ->
                    _ = Mod:terminate(Reason, State1),
                    Error
			end
	catch
		_Class:Reason ->
            {error, Reason, undefined}
	end.


%% -----------------------------------------------------------------------------
%% @doc Returns the logged state from a log event
%% @end
%% -----------------------------------------------------------------------------
get_state({phase_started, _, _, Data, _}) -> Data;
get_state({phase_finished, _, _, Data, _}) -> Data;
get_state({phase_aborted, _, _, Data, _}) -> Data;
get_state({phase_failed, _, _, _, Data, _}) -> Data.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
is_done(#state{direction = forward, phases = []}) -> true;
is_done(#state{direction = rollback, done_phases = []}) -> true;
is_done(#state{}) -> false.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
log(Event, Log) ->
    disk_log:log(Log, Event).


%% @private
execute_phases(#state{direction = forward, phases = [H|T]} = State0, Log) ->
    Mod = State0#state.mod,
    Phase = H#phase.name,
    Data0 = State0#state.data,
    Done = State0#state.done_phases,
    Forward = H#phase.forward,

    ok = log({phase_started, Mod, Phase, Data0, ?NOW}, Log),

    try Mod:Forward(Data0) of
        {ok, Data1} ->
            State1 = State0#state{
                data = Data1,
                phases = T,
                done_phases = [H|Done]
            },
            ok = log({phase_finished, Mod, Phase, State1, ?NOW}, Log),
            execute_phases(State1, Log);
        {error, Data1} ->
            %% We rollback this and all previous phases
            State1 = State0#state{
                direction = rollback,
                data = Data1,
                phases = T,
                done_phases = [H|Done]
            },
            execute_phases(State1, Log)
    catch
        _Class:Reason ->
            _ = lager:error(
                "Error while executing migration phase; "
                "migration=~p, phase=~p, reason=~p",
                [Mod, Phase, Reason]
            ),
            ok = log({phase_failed, Mod, Phase, Reason, State0, ?NOW}, Log),
            {error, Reason, Data0}
    end;

execute_phases(
    #state{direction = rollback, done_phases = [H|T]} = State0, Log) ->
    Mod = State0#state.mod,
    Phase = H#phase.name,
    Data0 = State0#state.data,
    Rollback = H#phase.rollback,
    Retries = State0#state.rollback_retries,

    try Mod:Rollback(Data0) of
        {ok, Data1} ->
            State1 = State0#state{
                data = Data1,
                done_phases = T
            },
            ok = log({phase_aborted, Mod, Phase, Data1, ?NOW}, Log),
            execute_phases(State1, Log);
        {error, Reason, Data1} when Retries =< ?MAX_RETRIES ->
            %% We retry
            %% TODO use exponential backoff
            timer:sleep(3000),
            State1 = State0#state{data = Data1, rollback_retries = Retries + 1},
            _ = lager:error(
                "Error while rolling back migration phase; "
                "migration=~p, phase=~p, reason=~p, retries_left=~p",
                [Mod, Phase, Reason, ?MAX_RETRIES - Retries]
            ),
            execute_phases(State1, Log);
        {error, Reason, Data1} ->
            _ = lager:error(
                "Error while rolling back migration phase; "
                "migration=~p, phase=~p, reason=~p, retries_left=~p",
                [Mod, Phase, Reason, 0]
            ),
            ok = log({phase_failed, Mod, Phase, Reason, Data1, ?NOW}, Log),
            {error, failed, State0}
    catch
        _Class:Reason ->
            _ = lager:error(
                "Error while rolling back migration phase; "
                "migration=~p, phase=~p, reason=~p",
                [Mod, Phase, Reason, 0]
            ),
            ok = log({phase_failed, Mod, Phase, Reason, Data0, ?NOW}, Log),
            {error, Reason}
    end;

execute_phases(#state{direction = forward, phases = []} = State0, _) ->
    %% No more phases to execute
    {ok, State0};

execute_phases(#state{direction = rollback, done_phases = []} = State0, _) ->
    %% No more phases to rollback
    {ok, State0}.



%% @private
compile(Filename) ->
    _ = lager:debug("Compiling migration module; filename=~p", [Filename]),
    case compile:file(Filename, [verbose, binary, report]) of
        {ok, _, _} = OK ->
            OK;
        {ok, Mod, Bin, Warnings} ->
            _ = lager:info(
                "Warnings while compiling migration module; "
                "filename=~p, warnings=~p",
                [Filename, Warnings]
            ),
            {ok, Mod, Bin};
        {error, Errors, Warnings} ->
            _ = lager:error(
                "Errors while compiling migration module; "
                "filename=~p, errors=~p, warnings=~p",
                [Filename, Errors, Warnings]
            ),
            {error, compile_errors};
        error ->
            _ = lager:error(
                "Errors while compiling migration module; filename=~p",
                [Filename]
            ),
            {error, compile_errors}
    end.
