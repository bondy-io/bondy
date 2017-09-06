%% =============================================================================
%%  bondy_security_source.erl -
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


-module(bondy_security_source).
-include_lib("wamp/include/wamp.hrl").

-type source() :: map().


-export([add/5]).
-export([list/1]).
-export([list/2]).
-export([remove/3]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add(
    RealmUri :: uri(),
    Usernames :: [binary()] | all,
    CIDR :: bondy_security:cidr(),
    Source :: atom(),
    Options :: list()) -> ok.

add(RealmUri, Usernames, CIDR, Source, Opts) ->
    bondy_security:add_source(RealmUri, Usernames, CIDR, Source, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(
    RealmUri :: uri(),
    Usernames :: [binary()] | binary() | all,
    CIDR :: bondy_security:cidr()) -> ok.

remove(RealmUri, <<"all">>, CIDR) ->
    remove(RealmUri, all, CIDR);

remove(RealmUri, Usernames, CIDR) ->
    bondy_security:del_source(RealmUri, Usernames, CIDR).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec list(uri(), binary()) -> source() | {error, not_found}.

list(RealmUri, Username) ->
    case bondy_security:lookup_user_sources(RealmUri, Username) of
        {error, _} = Error ->
            Error;
        Sources ->
            [to_map(S) || S <- Sources]
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec list(uri()) -> list(source()).

list(RealmUri) ->
    [to_map(Obj) || Obj <- bondy_security:list(RealmUri, source)].




%% =============================================================================
%% PRIVATE
%% =============================================================================




%% @private
to_map({Username, CIDR, Source, Opts} = _Obj) ->
    Map0 = proplists:get_value(<<"meta">>, Opts, #{}),
    {Addr, Mask} = CIDR,
    CIDRStr = list_to_binary(
        io_lib:format("~s/~B", [inet_parse:ntoa(Addr), Mask])),
    Map0#{
        username => Username,
        cidr => CIDRStr,
        source => list_to_binary(atom_to_list(Source)),
        options => maps:from_list(Opts)
    }.




