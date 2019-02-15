%% =============================================================================
%%  bondy_config.erl -
%%
%%  Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
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


%% =============================================================================
%% @doc
%%
%% @end
%% =============================================================================
-module(bondy_config).

-define(ERROR, '$error_badarg').
-define(APP, bondy).
-define(DEFAULT_RESOURCE_SIZE, erlang:system_info(schedulers)).
-define(DEFAULT_RESOURCE_CAPACITY, 10000). % max messages in process queue
-define(DEFAULT_POOL_TYPE, transient).

-export([priv_dir/0]).
-export([get/1]).
-export([get/2]).
%% -export([set/2]).
-export([automatically_create_realms/0]).
-export([connection_lifetime/0]).
-export([coordinator_timeout/0]).
-export([is_router/0]).
-export([load_regulation_enabled/0]).
-export([router_pool/0]).
-export([request_timeout/0]).
-export([ws_compress_enabled/0]).
-export([init/0]).

-compile({no_auto_import, [get/1]}).




%% =============================================================================
%% API
%% =============================================================================


init() ->
    Config = application:get_all_env(bondy),
    %% We set configs at first level only
    _ = [set(Key, Value) || {Key, Value} <- Config],
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get(Key :: atom() | tuple()) -> term().
get([H|T]) ->
    case get(H) of
        Term when is_map(Term) ->
            case maps_utils:get_path(T, Term, ?ERROR) of
                ?ERROR -> error(badarg);
                Value -> Value
            end;
        Term when is_list(Term) ->
            get_path(Term, T, ?ERROR);
        _ ->
            undefined
    end;

get(Key) when is_tuple(Key) ->
    get(tuple_to_list(Key));

get(Key) ->
    bondy_mochiglobal:get(Key).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get(Key :: atom() | tuple(), Default :: term()) -> term().
get([H|T], Default) ->
    case get(H, Default) of
        Term when is_map(Term) ->
            maps_utils:get_path(T, Term, Default);
        Term when is_list(Term) ->
            get_path(Term, T, Default);
        _ ->
            Default
    end;

get(Key, Default) when is_tuple(Key) ->
    get(tuple_to_list(Key), Default);

get(Key, Default) ->
    bondy_mochiglobal:get(Key, Default).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec set(Key :: atom() | tuple(), Default :: term()) -> ok.
set(Key, Value) ->
    application:set_env(?APP, Key, Value),
    bondy_mochiglobal:put(Key, Value).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_router() -> boolean().
is_router() ->
    true.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the app's priv dir
%% @end
%% -----------------------------------------------------------------------------
priv_dir() ->
    case code:priv_dir(bondy) of
        {error, bad_name} ->
            filename:join(
                [filename:dirname(code:which(?MODULE)), "..", "priv"]);
        Val ->
            Val
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% x-webkit-deflate-frame compression draft which is being used by some
%% browsers to reduce the size of data being transmitted supported by Cowboy.
%% @end
%% -----------------------------------------------------------------------------
ws_compress_enabled() -> true.



%% =============================================================================
%% REALMS
%% =============================================================================


automatically_create_realms() ->
    get(automatically_create_realms).


%% =============================================================================
%% SESSION
%% =============================================================================

-spec connection_lifetime() -> session | connection.
connection_lifetime() ->
    get(connection_lifetime).


%% =============================================================================
%% API : LOAD REGULATION
%% =============================================================================

-spec load_regulation_enabled() -> boolean().
load_regulation_enabled() ->
    get(load_regulation_enabled).


-spec coordinator_timeout() -> pos_integer().
coordinator_timeout() ->
    get(coordinator_timeout).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns a proplist containing the following keys:
%%
%% * type - can be one of the following:
%%     * permanent - the pool contains a (size) number of permanent workers
%% under a supervision tree. This is the "events as messages" design pattern.
%%      * transient - the pool contains a (size) number of supervisors each one
%% supervision a transient process. This is the "events as messages" design
%% pattern.
%% * size - The number of workers used by the load regulation system
%% for the provided pool
%%% * capacity - The usage limit enforced by the load regulation system for the provided pool
%% @end
%% -----------------------------------------------------------------------------
-spec router_pool() -> list().
router_pool() ->
    get(router_pool).


%% CALL

request_timeout() ->
    get(request_timeout).




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
get_path([H|T], Term, Default) when is_list(Term) ->
    case lists:keyfind(H, 1, Term) of
        false when Default == ?ERROR ->
            error(badarg);
        false ->
            Default;
        {H, Child} ->
            get_path(T, Child, Default)
    end;

get_path([], Term, _) ->
    Term;

get_path(_, _, ?ERROR) ->
    error(badarg);

get_path(_, _, Default) ->
    Default.
