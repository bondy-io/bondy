%% =============================================================================
%%  bondy_event_manager.erl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
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
%% @doc This module is used by Bondy to manage event handlers and notify them of
%% events.
%%
%% It implements both an event manager and a universal event
%% handler (when used with {@link add_callback/1} and
%% {@link add_sup_callback/1}) and the "watched" handler capability i.e.
%% `add_watched_handler/2,3', `swap_watched_handler/2,3'.
%%
%% In addition, this module mirrors most of the gen_event API and adds variants
%% with two arguments were the first argument is the default event manager
%% (`bondy_event_manager').
%%
%% ```
%%      +---------------------------------------+
%%      |                                       |
%%      |          bondy_event_manager          |
%%      |                                       |
%%      +---------------------------------------+
%%                          |
%%                          |
%%                          v
%%      +---------------------------------------+
%%      |                                       |
%%      |    bondy_event_handler_watcher_sup    |
%%      |                                       |
%%      +---------------------------------------+
%%                          |
%%                          +--------------------------------+
%%                          |                                |
%%       +---------------------------------------+       +---+---+
%%       |                                       |       |       |
%%       |     bondy_event_handler_watcher 1     |       |   N   |
%%       |                                       |       |       |
%%       +---------------------------------------+       +-------+
%%
%%                       simple_one_for_one
%% '''
%%
%% @end
%% -----------------------------------------------------------------------------

-module(bondy_event_manager).

-behaviour(gen_event).

-include_lib("kernel/include/logger.hrl").

%% API
-export([add_callback/1]).
-export([add_callback/2]).
-export([add_callback/3]).
-export([add_sup_callback/1]).
-export([add_handler/2]).
-export([add_handler/3]).
-export([add_sup_handler/2]).
-export([add_sup_handler/3]).
-export([add_watched_handler/2]).
-export([add_watched_handler/3]).
-export([swap_handler/2]).
-export([swap_handler/3]).
-export([swap_sup_handler/2]).
-export([swap_sup_handler/3]).
-export([swap_watched_handler/2]).
-export([swap_watched_handler/3]).
-export([notify/1]).
-export([notify/2]).
-export([sync_notify/1]).
-export([sync_notify/2]).
-export([delete_callback/2]).
-export([delete_handler/2]).
-export([delete_watched_handler/1]).


%% GEN_EVENT CALLBACKS
-export([init/1]).
-export([handle_event/2]).
-export([handle_call/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).


%% UNIVERSAL EVENT HANDLER STATE
-record(state, {
    callback    :: function() | {M :: module(), F :: atom(), A :: [term()]}
}).


-type handler()     ::  module() | {module(), Id :: term()}.


%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Adds a callback function.
%% The function needs to have a single argument representing the event that has
%% been fired.
%% @end
%% -----------------------------------------------------------------------------
-spec add_callback(Fun :: fun((any()) -> any())) -> {ok, handler()}.

add_callback(Fun) when is_function(Fun, 1) ->
    Handler = {?MODULE, make_ref()},
    gen_event:add_handler(?MODULE, Handler, [Fun]),
    {ok, Handler}.


%% -----------------------------------------------------------------------------
%% @doc Adds a callback function.
%% The function will be called by prepending the event to the list `Args'.
%% @end
%% -----------------------------------------------------------------------------
-spec add_callback(Fun :: fun((any()) -> any()), Args ::  [term()]) ->
    {ok, reference()}.

add_callback(Fun, []) ->
    add_callback(Fun);

add_callback(Fun, Args) when is_function(Fun, length(Args) + 1) ->
    Handler = {?MODULE, make_ref()},
    gen_event:add_handler(?MODULE, Handler, {Fun, Args}),
    {ok, Handler}.


%% -----------------------------------------------------------------------------
%% @doc Adds a callback MFA
%% The function will be called by prepending the event to the list `Args'.
%% @end
%% -----------------------------------------------------------------------------
-spec add_callback(M :: module(), F :: atom(), Args :: [term()]) ->
    {ok, reference()}.

add_callback(M, F, Args) when is_atom(M), is_atom(F), is_list(Args) ->
    Ref = make_ref(),
    gen_event:add_handler(?MODULE, {?MODULE, Ref}, {M, F, Args}),
    {ok, Ref}.


%% -----------------------------------------------------------------------------
%% @doc Adds a supervised callback function.
%% The function needs to have a single argument representing the event that has
%% been fired.
%% @end
%% -----------------------------------------------------------------------------
-spec add_sup_callback(fun((any()) -> any())) -> {ok, reference()}.

add_sup_callback(Fn) when is_function(Fn, 1) ->
    Ref = make_ref(),
    gen_event:add_sup_handler(?MODULE, {?MODULE, Ref}, Fn),
    {ok, Ref}.


%% -----------------------------------------------------------------------------
%% @doc Adds an event handler.
%% Calls `gen_event:add_handler(?MODULE, Handler, Args)'.
%% @end
%% -----------------------------------------------------------------------------
add_handler(Handler, Args) ->
    add_handler(?MODULE, Handler, Args).


%% -----------------------------------------------------------------------------
%% @doc Adds an event handler.
%% Calls `gen_event:add_handler(Manager, Handler, Args)'.
%% @end
%% -----------------------------------------------------------------------------
add_handler(Manager, Handler, Args) ->
    gen_event:add_handler(Manager, Handler, Args).


%% -----------------------------------------------------------------------------
%% @doc Adds a supervised event handler, but also supervises the connection
%% between the event handler and the calling process.
%% Calls `gen_event:add_sup_handler(?MODULE, Handler, Args)'.
%% Use this call if you want the event manager to remove the handler when the
%% calling process terminates.
%% @end
%% -----------------------------------------------------------------------------
add_sup_handler(Handler, Args) ->
    add_sup_handler(?MODULE, Handler, Args).


%% -----------------------------------------------------------------------------
%% @doc Adds a supervised event handler, but also supervises the connection
%% between the event handler and the calling process.
%% Calls `gen_event:add_sup_handler(?MODULE, Handler, Args)'.
%% Use this call if you want the event manager to remove the handler when the
%% calling process terminates.
%% @end
%% -----------------------------------------------------------------------------
add_sup_handler(Manager, Handler, Args) ->
    gen_event:add_sup_handler(Manager, Handler, Args).


%% -----------------------------------------------------------------------------
%% @doc Adds a watched event handler.
%% As opposed to `add_sup_handler/2' which supervises the calling process,
%% this function calls
%% `bondy_event_handler_watcher_sup:start_watcher(Handler, Args)' which
%% spawns a supervised process (`bondy_event_handler_watcher') which calls
%% `add_sup_handler/2'. If the handler crashes, `bondy_event_handler_watcher'
%% will re-install it in the event manager.
%% @end
%% -----------------------------------------------------------------------------
add_watched_handler(Handler, Args) ->
    add_watched_handler(?MODULE, Handler, Args).


%% -----------------------------------------------------------------------------
%% @doc Adds a supervised event handler.
%% As opposed to `add_sup_handler/2' which monitors the calling process,
%% this function calls
%% `bondy_event_handler_watcher_sup:start_watcher(Handler, Args)' which
%% spawns a supervised process (`bondy_event_handler_watcher') which calls
%% `add_sup_handler/2'. If the handler crashes, `bondy_event_handler_watcher'
%% will re-install it in the event manager.
%% @end
%% -----------------------------------------------------------------------------
add_watched_handler(Manager, Handler, Args) ->
    bondy_event_handler_watcher_sup:start_watcher(Manager, Handler, Args).


%% -----------------------------------------------------------------------------
%% @doc A util function. Equivalent to calling
%% `swap_handler(bondy_event_manager, OldHandler, NewHandler)'
%% @end
%% -----------------------------------------------------------------------------
swap_handler(OldHandler, NewHandler) ->
    swap_handler(?MODULE, OldHandler, NewHandler).


%% -----------------------------------------------------------------------------
%% @doc A util function. Equivalent to calling `gen_event:swap_handler/3'
%% @end
%% -----------------------------------------------------------------------------
swap_handler(Manager, {_, _} = OldHandler, {_, _} = NewHandler) ->
    gen_event:swap_handler(Manager, OldHandler, NewHandler).


%% -----------------------------------------------------------------------------
%% @doc A util function. Equivalent to calling
%% `swap_sup_handler(bondy_event_manager, OldHandler, NewHandler)'
%% @end
%% -----------------------------------------------------------------------------
swap_sup_handler(OldHandler, NewHandler) ->
    swap_sup_handler(?MODULE, OldHandler, NewHandler).


%% -----------------------------------------------------------------------------
%% @doc A util function. Equivalent to calling `gen_event:swap_sup_handler/3'
%% @end
%% -----------------------------------------------------------------------------
swap_sup_handler(Manager, OldHandler, NewHandler) ->
    gen_event:swap_sup_handler(Manager, OldHandler, NewHandler).


%% -----------------------------------------------------------------------------
%% @doc A util function. Equivalent to calling
%% `swap_watched_handler(bondy_event_manager, OldHandler, NewHandler)'
%% @end
%% -----------------------------------------------------------------------------
swap_watched_handler(OldHandler, NewHandler) ->
    swap_watched_handler(?MODULE, OldHandler, NewHandler).


%% -----------------------------------------------------------------------------
%% @doc Replaces an event handler in event manager `Manager' in the same way as
%% `swap_sup_handler/3'. However, this function
%% calls `bondy_event_handler_watcher_sup:start_watcher(Handler, Args)' which
%% spawns a supervised process (`bondy_event_handler_watcher') which is the one
%% calling calls `swap_sup_handler/2'.
%% If the handler crashes or terminates with a reason other than `normal' or
%% `shutdown', `bondy_event_handler_watcher' will re-install it in
%% the event manager.
%% @end
%% -----------------------------------------------------------------------------
swap_watched_handler(Manager, OldHandler, NewHandler) ->
    bondy_event_handler_watcher_sup:start_watcher(
        Manager, {swap, OldHandler, NewHandler}
    ).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec delete_callback(Ref :: reference(), Args :: term()) ->
    term() | {error, module_not_found} | {'EXIT', Reason :: any()}.

delete_callback(Ref, Args) ->
    delete_handler({?MODULE, Ref}, Args).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec delete_handler(
    Handler :: module() | {module(), term()}, Args :: term()) ->
    term() | {error, module_not_found} | {'EXIT', Reason :: any()}.

delete_handler(Handler, Args) ->
    gen_event:delete_handler(?MODULE, Handler, Args).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec delete_watched_handler(Watcher :: pid()) -> ok | {error, not_found}.

delete_watched_handler(Watcher) ->
    bondy_event_handler_watcher_sup:terminate_watcher(Watcher).


%% -----------------------------------------------------------------------------
%% @doc A util function. Equivalent to calling
%% `notify(bondy_event_manager, Event)'
%% @end
%% -----------------------------------------------------------------------------
notify(Event) ->
    notify(?MODULE, Event).


%% -----------------------------------------------------------------------------
%% @doc A util function. Equivalent to calling
%% `gen_event:notify(bondy_event_manager, Event)'
%% @end
%% -----------------------------------------------------------------------------
notify(Manager, Event) ->
    gen_event:notify(Manager, Event).


%% -----------------------------------------------------------------------------
%% @doc A util function. Equivalent to calling
%% `sync_notify(bondy_event_manager, Event)'
%% @end
%% -----------------------------------------------------------------------------
sync_notify(Event) ->
    sync_notify(?MODULE, Event).


%% -----------------------------------------------------------------------------
%% @doc A util function. Equivalent to calling
%% `gen_event:sync_notify(bondy_event_manager, Event)'
%% @end
%% -----------------------------------------------------------------------------
sync_notify(Manager, Event) ->
    gen_event:sync_notify(Manager, Event).




%% =============================================================================
%% GEN_EVENT CALLBACKS
%% =============================================================================



init(CB) ->
    {ok, #state{callback = CB}}.


handle_event(Event, State) ->
    try
        case State#state.callback of
            Fun when is_function(Fun, 1) ->
                Fun(Event);
            {Fun, Args} ->
                erlang:apply(Fun, [Event | Args]);
            {M, F, Args} ->
                erlang:apply(M, F, [Event | Args])
        end
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while applying callback function.",
                class => Class,
                reason => Reason,
                event => Event,
                stacktrace => Stacktrace
            })
    end,
    {ok, State}.


handle_call(_Request, State) ->
    {ok, ok, State}.


handle_info(_Info, State) ->
    {ok, State}.


terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.