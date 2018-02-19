%% =============================================================================
%%  bondy_cache.erl -
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


-module(bondy_cache).


-export([get/2]).
-export([put/3]).
-export([put/4]).
-export([remove/2]).


-spec get(RealmUri :: binary(), any()) -> {ok, any()} | {error, not_found}.
get(_, _) ->
    %%TODO
    {error, not_found}.

put(RealmUri, K, V) ->
    bondy_cache:put(RealmUri, K, V, #{}).


put(_RealmUri, _, _, _Opts) ->
    %%TODO
    ok.

remove(_RealmUri, _) ->
    %%TODO
    ok.

%%TODO factor out all TTL related functionality from tuplespace_queue into a tuplespace_ttl module to be reused