%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_gproc).

-export([local_name/1]).
-export([lookup_pid/1]).
-export([lookup_pid/2]).
-export([register/1]).
-export([register/2]).
-export([register/4]).
-export([select/1]).
-export([select/2]).
-export([unregister/1]).
-export([unregister/2]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec local_name(Name :: any()) -> true.

local_name(Name) ->
    {n, l, Name}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec register(Name :: any()) -> true.

register(Name) ->
    gproc:reg({n, l, Name}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec register(Name :: any(), Pid :: pid()) -> true.

register(Name, Pid) ->
    gproc:reg_other({n, l, Name}, Pid).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec register(Name :: any(), Pid :: pid(), Type :: atom(), Attr :: any()) ->
    true.

register(Name, Pid, Type, Attr) ->
    GType = case Type of
        aggregated_counter -> a;
        counter -> c;
        name -> n;
        property -> p;
        resource_counter -> rc;
        resource_property -> r
    end,
    gproc:reg_other({GType, l, Name}, Pid, Attr).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unregister(Name :: any()) -> true.

unregister(Name) ->
    gproc:unreg({n, l, Name}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unregister(Name :: any(), Type :: atom()) -> true.

unregister(Name, Type) ->
    GType = case Type of
        aggregated_counter -> a;
        counter -> c;
        name -> n;
        property -> p;
        resource_counter -> rc;
        resource_property -> r
    end,
    gproc:unreg({GType, l, Name}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup_pid(Name :: any()) -> pid() | no_return().

lookup_pid(Name) ->
    gproc:lookup_pid({n, l, Name}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup_pid(Type :: atom(), Id :: any()) -> pid() | no_return().

lookup_pid(Type, Id) ->
    lookup_pid({Type, Id}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec select(Term :: ets:match_spec() | ets:continuation()) -> [any()].

select(Term) when is_list(Term) ->
    gproc:select({l, resources}, Term).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec select(MatchSpec :: ets:match_spec(), Limit :: integer()) ->
    {[any()], Continuation :: ets:continuation()} | '$end_of_table'.


select(MatchSpec, Limit) ->
    gproc:select({l, resources}, MatchSpec, Limit).

