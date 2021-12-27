%% =============================================================================
%%  bondy_sensitive.erl -
%%
%%  Copyright (c) 2021 Leapsight. All rights reserved.
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
%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_sensitive).

-type sensitive()   ::  {sensitive, fun()}.

-export_type([sensitive/0]).


-export([format_status/3]).
-export([conforms/1]).
-export([wrap/1]).
-export([unwrap/1]).
-export([raise/3]).



%% =============================================================================
%% CALLBACKS
%% =============================================================================



-callback format_status(Opts :: normal | terminate, State :: term()) -> term().



%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc Returns true is module `Mod' conforms with this behaviour.
%% @end
%% -----------------------------------------------------------------------------
-spec conforms(Mod :: module()) -> boolean().

conforms(Mod) ->
    erlang:function_exported(Mod, format_status, 2).


%% -----------------------------------------------------------------------------
%% @doc Formalises and extends the use of the callback `format_status/2'
%% gen_server callback ([See documentation here](https://erlang.org/doc/man/gen_server.html#Module:format_status-2)) to modules.
%%
%% {@link gen_server:format_status/2} is called by a gen_server process in the
%% following situations:
%%
%% * One of sys:get_status/1,2 is invoked to get the gen_server status. Opt is
%% set to the atom normal.
%% * The gen_server process terminates abnormally and
%% logs an error. Opt is set to the atom terminate.
%%
%% A callback module managing the status for or on-behalf of a gen_server
%% porocess can use this function to change the return value. `State' is the
%% internal state of the gen_server process.
%%
%% The function is to return Status, a term that changes the details of the
%% current state `State' and status of the gen_server process. There are no
%% restrictions on the form Status can take.
%% @end
%% -----------------------------------------------------------------------------
-spec format_status(
    Opt :: normal | terminate, Mod :: module(), State :: term()) -> term().

format_status(Opt, Mod, State) ->
     case conforms(Mod) of
        true ->
            case catch Mod:format_status(Opt, State) of
                {'EXIT', _} ->
                    State;
                Formatted ->
                    Formatted
            end;
        false ->
            State
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec wrap(Term :: term() | fun(() -> term())) -> sensitive().

wrap(Fun) when is_function(Fun, 0) ->
    {sensitive, fun() -> Fun() end};

wrap(Term) ->
    {sensitive, fun() -> Term end}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unwrap(sensitive()) -> term().

unwrap({sensitive, Fun}) when is_function(Fun, 0) ->
    Fun().



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec raise(
    Class :: error | exit | throw,
    Reason :: term(),
    Stacktrace :: erlang:raise_stacktrace()) -> badarg.


raise(Class, Reason, Stacktrace0) ->
    Stacktrace = prune_stacktrace(Stacktrace0),
    erlang:raise(Class, Reason, Stacktrace).




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
prune_stacktrace([{M, F, [_ | _] = A, Info} | Rest]) ->
    %% We strip the function arguments and replaced them by the arity
    [{M, F, length(A), Info} | Rest];

prune_stacktrace(Stacktrace) ->
    Stacktrace.


