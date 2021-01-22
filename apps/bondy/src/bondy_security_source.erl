%% =============================================================================
%%  bondy_security_source.erl -
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
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_security_source).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_security.hrl").

-type source() :: map().


-export([add/2]).
-export([list/1]).
-export([list/2]).
-export([remove/3]).




%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
add(RealmUri, Map0) when is_map(Map0) ->
    try
        Map = maps_utils:validate(Map0, ?SOURCE_SPEC),
        #{
            <<"usernames">> := Usernames,
            <<"cidr">> := CIDR,
            <<"authmethod">> := AuthMethod,
            <<"meta">> := Meta
        } = Map,
        do_add(RealmUri, Usernames, CIDR, AuthMethod, Meta)
    catch
        ?EXCEPTION(error, Reason, _) when is_map(Reason) ->
            {error, Reason}
    end.



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
-spec list(uri(), binary() | all) -> [source()].

list(RealmUri, Username) ->
    case bondy_security:lookup_user_sources(RealmUri, Username) of
        {error, not_found} ->
            [];
        Authmethods ->
            [to_map(S) || S <- Authmethods]
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
-spec do_add(
    RealmUri :: uri(),
    Usernames :: [binary()] | all,
    CIDR :: bondy_security:cidr(),
    Authmethod :: atom(),
    Options :: list()) -> ok.

do_add(RealmUri, Usernames, CIDR, Authmethod, Meta) when is_map(Meta) ->
    do_add(RealmUri, Usernames, CIDR, Authmethod, maps:to_list(Meta));

do_add(RealmUri, Usernames, CIDR, Authmethod, Meta) ->
    bondy_security:add_source(RealmUri, Usernames, CIDR, Authmethod, Meta).


%% @private
to_map({_, _, Authmethod, _} = Obj) when is_atom(Authmethod) ->
    to_map(setelement(3, Obj, list_to_binary(atom_to_list(Authmethod))));

to_map({Username, {Addr, Mask}, Authmethod, Opts} = _Obj) ->
    Map0 = proplists:get_value(<<"meta">>, Opts, #{}),
    CIDRStr = iolist_to_binary(
        io_lib:format("~s/~B", [inet_parse:ntoa(Addr), Mask])),
    Map0#{
        <<"username">> => Username,
        <<"cidr">> => CIDRStr,
        <<"authmethod">> => Authmethod,
        <<"meta">> => maps:from_list(Opts)
    }.




