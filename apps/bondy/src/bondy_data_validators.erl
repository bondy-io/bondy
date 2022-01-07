%% =============================================================================
%%  bondy_data_validators.erl - a collection of utils functions for data
%% validation
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
-module(bondy_data_validators).
-include_lib("wamp/include/wamp.hrl").

-export([authorized_key/1]).
-export([cidr/1]).
-export([existing_atom/1]).
-export([groupname/1]).
-export([groupnames/1]).
-export([ip_address/1]).
-export([password/1]).
-export([peer/1]).
-export([port_number/1]).
-export([realm_uri/1]).
-export([rolename/1]).
-export([rolenames/1]).
-export([strict_groupname/1]).
-export([strict_username/1]).
-export([username/1]).
-export([usernames/1]).

-on_load(on_load/0).


%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec cidr(Term :: binary() | tuple()) ->
    {ok, bondy_cidr:t()} | boolean().

cidr(Bin) when is_binary(Bin) ->
    try
        CIDR = bondy_cidr:parse(Bin),
        {ok, CIDR}
    catch
        error:badarg ->
            false
    end;

cidr(Term)  ->
    bondy_cidr:is_type(Term).


%% -----------------------------------------------------------------------------
%% @doc Allows reserved names like "all", "anonymous", etc
%% @end
%% -----------------------------------------------------------------------------
-spec username(Term :: binary()) -> {ok, term()} | boolean().

username(Term) when is_binary(Term) ->
    %% 3..254 is the range of an email.
    Size = byte_size(Term),

    case Size =< 254 of
        true ->
            Size >= 3 andalso rolename(Term);
        false ->
            {error, <<"Value is too big (max. is 254 bytes).">>}
    end;

username(_) ->
    false.


%% -----------------------------------------------------------------------------
%% @doc Allows reserved names like "all", "anonymous", etc
%% @end
%% -----------------------------------------------------------------------------
-spec usernames(Term :: [binary()] | binary()) -> {ok, [binary()]} | boolean().

usernames(all) ->
    true;

usernames(<<"all">>) ->
    {ok, all};

usernames(L) when is_list(L) ->
    try
        Valid = lists:foldl(
            fun(Term, Acc) ->
                case username(Term) of
                    {ok, Value} ->
                        [Value | Acc];
                    true ->
                        [Term | Acc];
                    false ->
                        throw(abort)
                end
            end,
            [],
            L
        ),
        {ok, lists:reverse(Valid)}
    catch
        throw:abort ->
            {error, <<"One or more values are not valid usernames.">>}
    end;

usernames(_) ->
    false.



%% -----------------------------------------------------------------------------
%% @doc Does not allow reserved namess
%% @end
%% -----------------------------------------------------------------------------
-spec strict_username(Term :: binary()) -> {ok, term()} | boolean().

strict_username(<<"all">>) -> false;
strict_username(<<"anonymous">>) -> false;
strict_username(<<"any">>) -> false;
strict_username(<<"from">>) -> false;
strict_username(<<"on">>) -> false;
strict_username(<<"to">>) -> false;
strict_username(Term) -> username(Term).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec groupname(Bin :: binary()) -> boolean().

groupname(Bin) ->
    rolename(Bin).


%% -----------------------------------------------------------------------------
%% @doc Allows reserved names like "all", "anonymous", etc
%% @end
%% -----------------------------------------------------------------------------
-spec groupnames(List :: [binary()]) -> {ok, [binary()]} | false.

groupnames(L) when is_list(L) ->
    try
        Valid = lists:foldl(
            fun
                (all, Acc) ->
                    Acc;
                (anonymous, Acc) ->
                    Acc;
                (<<"all">>, Acc) ->
                    Acc;
                (<<"anonymous">>, Acc) ->
                    Acc;
                (Term, Acc) ->
                    case groupname(Term) of
                        {ok, Value} ->
                            [Value | Acc];
                        true ->
                            [Term | Acc];
                        false ->
                            throw(abort)
                    end
            end,
            [],
            L
        ),
        {ok, lists:reverse(Valid)}
    catch
        throw:abort ->
            false
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec strict_groupname(Bin :: binary()) -> boolean().

strict_groupname(<<"all">>) -> false;
strict_groupname(<<"anonymous">>) -> false;
strict_groupname(<<"any">>) -> false;
strict_groupname(<<"from">>) -> false;
strict_groupname(<<"on">>) -> false;
strict_groupname(<<"to">>) -> false;
strict_groupname(Bin) -> groupname(Bin).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec rolename(Bin :: binary()) -> {ok, binary() | all | anonymous} | boolean().

rolename(all) ->
    true;

rolename(anonymous) ->
    true;

rolename(<<"all">>) ->
    {ok, all};

rolename(<<"anonymous">>) ->
    {ok, anonymous};

rolename(Bin0) when is_binary(Bin0) ->
    Bin = string:casefold(Bin0),
    Regex = persistent_term:get({?MODULE, illegal_rolename_regex}),
    nomatch =:= re:run(Bin, Regex) andalso {ok, Bin};

rolename(_) ->
    false.


%% -----------------------------------------------------------------------------
%% @doc Allows reserved names like "all", "anonymous", etc
%% @end
%% -----------------------------------------------------------------------------
-spec rolenames(Term :: [binary()] | binary()) -> {ok, [binary()]} | false.

rolenames(all) ->
    {ok, all};

rolenames(<<"all">>) ->
    {ok, all};

rolenames(L) when is_list(L) ->
    try
        Valid = lists:foldl(
            fun
                (Keyword, _)
                when Keyword == all orelse Keyword == <<"all">> ->
                    %% "all" is not a role so it cannot be mixed in a roles list
                    throw(abort);
                (Term, Acc) ->
                    case rolename(Term) of
                        {ok, Value} ->
                            [Value | Acc];
                        true ->
                            [Term | Acc];
                        false ->
                            throw(abort)
                    end
            end,
            [],
            L
        ),
        {ok, lists:reverse(Valid)}
    catch
        throw:abort ->
            false
    end;

rolenames(_) ->
    false.

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec password(Term :: binary() | fun(() -> binary()) | map()) ->
    {ok, bondy_password:future()} | boolean().

password(Bin) when is_binary(Bin) ->
    try
        {ok, bondy_password:future(Bin)}
    catch
        error:_ ->
            false
    end;

password(Term) when is_map(Term) ->
    bondy_password:is_type(Term);

password(Future) when is_function(Future, 1) ->
    Future;

password(_) ->
    false.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authorized_key(Term :: binary()) -> {ok, binary()} | boolean().

authorized_key(Term) when is_binary(Term) ->
    try
        {ok, hex_utils:hexstr_to_bin(Term)}
    catch
        error:_ ->
            %% Not in hex format
            true
    end;

authorized_key(_) ->
    false.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec existing_atom(Term :: binary() | atom()) -> {ok, term()} | boolean().

existing_atom(Term) when is_binary(Term) ->
    try
        {ok, binary_to_existing_atom(Term, utf8)}
    catch
        error:_ ->
            false
    end;

existing_atom(Term) when is_atom(Term) ->
    true;

existing_atom(_) ->
    false.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec realm_uri(Term :: binary()) -> boolean().

realm_uri(Term) ->
    case wamp_uri:is_valid(Term, wamp_config:get(uri_strictness)) of
        true ->
            {ok, string:casefold(Term)};
        false ->
            false
    end.

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec ip_address(inet:ip_address()) -> boolean().

ip_address(Term) ->
    case inet:ntoa(Term) of
        {error, einval} -> false;
        _ -> true
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec port_number(N :: 1024..65535) -> boolean().

port_number(N) ->
    N >= 1024 andalso N =< 65535.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec peer({inet:ip_address(), inet:port_number()}) -> boolean().

peer({A, B}) ->
    ip_address(A) andalso port_number(B);

peer(_) ->
    false.

%% =============================================================================
%% PRIVATE
%% =============================================================================



on_load() ->
    %% We persist the rolename regex
    %% -----------------------------
    %% Avoid whitespace, control characters, comma, semi-colon,
    %% non-standard Windows-only characters, other misc
    %% Illegal = lists:seq(0, 32) ++ [60, 62] ++ lists:seq(127, 191),
    %% [Bin] =/= string:tokens(Bin, Illegal).
    {ok, Regex} = re:compile(
        "^.*([\\o{000}-\\o{040}\\o{074}-\\o{076}\\o{0177}-\\o{277}])+.*$"
    ),
    ok = persistent_term:put({?MODULE, illegal_rolename_regex}, Regex),
    ok.