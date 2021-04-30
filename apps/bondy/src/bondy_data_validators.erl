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


-export([validate_username/1]).
-export([validate_password/1]).
-export([validate_existing_atom/1]).




%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
validate_username(Term) when is_list(Term) ->
    validate_username(list_to_binary(Term));

validate_username(Term) when is_atom(Term) ->
    %% reserved
    validate_username(atom_to_binary(Term, utf8));

validate_username(<<"all">>) ->
    %% reserved
    false;

validate_username(Bin)
when is_binary(Bin) andalso byte_size(Bin) >= 3 andalso byte_size(Bin) =< 254 ->
    %% 3..254 is the range of an email.
    true;

validate_username(_) ->
    false.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
validate_password(Term) when
    is_binary(Term)
    andalso byte_size(Term) >= 6
    andalso byte_size(Term) =< 256 ->
    true;

validate_password(_) ->
    false.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
validate_existing_atom(Term) when is_binary(Term) ->
    try
        {ok, binary_to_existing_atom(Term, utf8)}
    catch
        error:_ ->
            false
    end;

validate_existing_atom(Term) when is_atom(Term) ->
    true;

validate_existing_atom(_) ->
    false.
