%% =============================================================================
%%  bondy_event_manager.erl -
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

%% -----------------------------------------------------------------------------
%% @doc This module is used by Bondy to manage event handlers and notify them of
%% events. It implements the "watched" handler capability i.e.
%% `add_watched_handler/2,3', `swap_watched_handler/2,3'.
%% In addition, this module mirrors most of the gen_event API and adds variants
%% with two arguments were the first argument is the defaul event manager
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

-include_lib("kernel/include/logger.hrl").

%% API
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



%% =============================================================================
%% API
%% =============================================================================



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
%% %% Use this call if you want the event manager to remove the handler when the
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
        Manager, {swap, OldHandler, NewHandler}).


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
