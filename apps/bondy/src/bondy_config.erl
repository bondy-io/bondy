%% =============================================================================
%%  bondy_config.erl -
%%
%%  Copyright (c) 2016-2019 Ngineo Limited t/a Leapsight. All rights reserved.
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
-module(bondy_config).

-define(ERROR, '$error_badarg').
-define(APP, bondy).

-export([get/1]).
-export([get/2]).
-export([init/0]).
-export([set/2]).

-compile({no_auto_import, [get/1]}).



%% =============================================================================
%% API
%% =============================================================================



init() ->
    %% Init from environment
    Config0 = application:get_all_env(bondy),
    Config1 = [{priv_dir, priv_dir()} | Config0],
    %% We initialise the config, caching all values as code
    %% We set configs at first level only
    _ = [set(Key, Value) || {Key, Value} <- Config1],
    _ = lager:info("Bondy configuration initialised"),
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get(Key :: list() | atom() | tuple()) -> term().

get([H|T]) ->
    case get(H) of
        Term when is_map(Term) ->
            case maps_utils:get_path(T, Term, ?ERROR) of
                ?ERROR -> error(badarg);
                Value -> Value
            end;
        Term when is_list(Term) ->
            get_path(T, Term, ?ERROR);
        _ ->
            %% We cannot get(T) from a term which is neither a map nor a list
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
-spec get(Key :: list() | atom() | tuple(), Default :: term()) -> term().

get([H|T], Default) ->
    case get(H, Default) of
        Term when is_map(Term) ->
            maps_utils:get_path(T, Term, Default);
        Term when is_list(Term) ->
            get_path(T, Term, Default);
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




%% =============================================================================
%% PRIVATE
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @private
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
