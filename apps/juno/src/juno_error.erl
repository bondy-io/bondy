%% 
%%  juno_error.erl -
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

-module(juno_error).
-include("juno.hrl").
-include_lib("wamp/include/wamp.hrl").

-export([error_map/1]).
-export([error_uri/1]).




%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
error_uri(Reason) when is_atom(Reason) ->
    R = list_to_binary(atom_to_list(Reason)),
    <<"com.leapsight.error.", R/binary>>.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
error_map(#error{arguments = undefined, payload = undefined} = Err) ->
    #error{error_uri = Uri} = Err,
    #{
        <<"code">> => Uri,
        <<"message">> => <<>>,
        <<"description">> => <<>>
    };

error_map(#error{arguments = L, payload = undefined} = Err)
when is_list(L) ->
    #error{error_uri = Uri} = Err,
    Mssg = hd(L),
    #{
        <<"code">> => Uri,
        <<"message">> => Mssg,
        <<"description">> => Mssg
    };

error_map(#error{arguments = undefined, payload = M} = Err)
when is_map(M) ->
    #error{error_uri = Uri} = Err,
    Mssg = maps:get(<<"message">>, M),
    Desc = maps:get(<<"description">>, M, Mssg),
    #{
        <<"code">> => Uri,
        <<"message">> => Mssg,
        <<"description">> => Desc
    };

error_map(#error{arguments = L, payload = M} = Err) ->
    #error{error_uri = Uri} = Err,
    Mssg = hd(L),
    Desc = maps:get(<<"description">>, M, Mssg),
    #{
        <<"code">> => Uri,
        <<"message">> => Mssg,
        <<"description">> => Desc
    };

error_map({invalid_scheme, 401}) ->
    #{
        <<"code">> => <<"invalid_scheme">>,
        <<"status_code">> => 401,
        <<"message">> => <<"The authorization scheme is missing or the one provided is not the one required.">>,
        <<"description">> => <<>>
    };

error_map({invalid_request, 401}) ->
    #{
        <<"code">> => <<"invalid_request">>,
        <<"status_code">> => 401,
        <<"message">> => <<"The access token provided is expired, revoked, malformed, or invalid for other reasons.">>,
        <<"description">> => <<"The request is missing a required parameter, includes an unsupported parameter value (other than grant type), repeats a parameter, includes multiple credentials, utilizes more than one mechanism for authenticating the client, or is otherwise malformed.">>
    };

error_map({invalid_token, 401}) ->
    #{
        <<"code">> => <<"invalid_token">>,
        <<"status_code">> => 401,
        <<"message">> => <<"The access token provided is expired, revoked, malformed, or invalid for other reasons.">>,
        <<"description">> => <<"The client MAY request a new access token and retry the protected resource request.">>
    };
    
error_map({invalid_json, Data}) ->
    #{
        <<"code">> => invalid_data,
        <<"message">> => <<"The data provided is not a valid json.">>,
        value => Data,
        <<"description">> => <<"The data provided is not a valid json.">>
    };

error_map({invalid_msgpack, Data}) ->
    #{
        <<"code">> => invalid_data,
        <<"message">> => <<"The data provided is not a valid msgpack.">>,
        value => Data,
        <<"description">> => <<"The data provided is not a valid msgpack.">>
    };

error_map({Code, Mssg}) ->
    #{
        <<"code">> => Code,
        <<"message">> => Mssg,
        <<"description">> => Mssg
    };

error_map({Code, Mssg, Desc}) ->
    #{
        <<"code">> => Code,
        <<"message">> => Mssg,
        <<"description">> => Desc
    };

error_map(Code) ->
    #{
        <<"code">> => Code
    }.
