%% =============================================================================
%%  bondy_error.erl -
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


-module(bondy_error).
-include("http_api.hrl").
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").



%% -type error_map() :: #{
%%     code => binary(),
%%     message => binary(),
%%     description => binary(),
%%     errors => [#{
%%         code => binary(),
%%         message => binary(),
%%         description => binary(),
%%         key => any(),
%%         value => any()
%%     }]
%% }.

-export([map/1]).
-export([map/2]).
-export([code_to_uri/1]).



%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
code_to_uri(Reason) when is_atom(Reason) ->
    R = list_to_binary(atom_to_list(Reason)),
    <<"com.leapsight.bondy.error.", R/binary>>;

code_to_uri(<<"wamp.", _/binary>> = Reason) ->
    Reason;

code_to_uri(<<"bondy.", _/binary>> = Reason) ->
    Reason;

code_to_uri(<<"com.", _/binary>> = Reason) ->
    Reason;

code_to_uri(Reason) when is_binary(Reason) ->
    <<"com.leapsight.bondy.error.", Reason/binary>>.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
map(#error{} = Err) ->
    map(#{
        error_uri => Err#error.error_uri,
        details => Err#error.details,
        arguments => Err#error.arguments,
        arguments_kw => Err#error.arguments_kw
    });

map(#{error_uri := Uri} = M) ->
    Error = get_error(M),
    Error#{
        <<"code">> => Uri,
        <<"message">> => get_message(M)
    };

map(#{code := _} = M) ->
    bondy_utils:to_binary_keys(M);

map(#{<<"code">> := _} = M) ->
    M;

map(unsupported_token_type) ->
    #{
        <<"code">> => <<"unsupported_token_type">>,
        <<"status_code">> => ?HTTP_SERVICE_UNAVAILABLE,
        <<"message">> => <<"The authorization server does not support the revocation of the presented token type.  That is, the client tried to revoke an access token on a server not supporting this feature.">>,
        <<"description">> => <<"If the server responds with HTTP status code 503, the client must assume the token still exists and may retry after a reasonable delay. The server may include a 'Retry-After' header in the response to indicate how long the service is expected to be unavailable to the requesting client.">>
    };

map(oauth2_invalid_request) ->
    #{
        <<"code">> => <<"invalid_request">>,
        <<"status_code">> => ?HTTP_BAD_REQUEST,
        <<"message">> => <<"The request is malformed.">>,
        <<"description">> => <<"The request is missing a required parameter, includes an unsupported parameter value (other than grant type), repeats a parameter, includes multiple credentials, utilizes more than one mechanism for authenticating the client, or is otherwise malformed.">>
    };

map(oauth2_invalid_client) ->
    %% Client authentication failed (e.g., unknown client, no
    %% client authentication included, or unsupported
    %% authentication method).  The authorization server MAY
    %% return an HTTP 401 (Unauthorized) status code to indicate
    %% which HTTP authentication schemes are supported.  If the
    %% client attempted to authenticate via the "Authorization"
    %% request header field, the authorization server MUST
    %% respond with an HTTP 401 (Unauthorized) status code and
    %% include the "WWW-Authenticate" response header field
    %% matching the authentication scheme used by the client.
    #{
        <<"code">> => <<"invalid_client">>,
        <<"status_code">> => ?HTTP_UNAUTHORIZED,
        <<"message">> => <<"Unknown client or unsupported authentication method.">>,
        <<"description">> => <<"Client authentication failed (e.g., unknown client, no client authentication included, or unsupported authentication method).">>
    };

map(oauth2_invalid_grant) ->
    #{
        <<"code">> => <<"invalid_grant">>,
        <<"status_code">> => ?HTTP_BAD_REQUEST,
        <<"message">> => <<"The access or refresh token provided is expired, revoked, malformed, or invalid.">>,
        <<"description">> => <<"The provided authorization grant (e.g., authorization code, resource owner credentials) or refresh token is invalid, expired, revoked, does not match the redirection URI used in the authorization request, or was issued to another client. The client MAY request a new access token and retry the protected resource request.">>
    };

map(oauth2_unauthorized_client) ->
    #{
        <<"code">> => <<"unauthorized_client">>,
        <<"status_code">> => ?HTTP_BAD_REQUEST,
        <<"message">> => <<"The authenticated client is not authorized to use this authorization grant type.">>,
        <<"description">> => <<>>
    };

map(oauth2_unsupported_grant_type) ->
    #{
        <<"code">> => <<"unsupported_grant_type">>,
        <<"status_code">> => ?HTTP_BAD_REQUEST,
        <<"message">> => <<"The requested scope is invalid, unknown, malformed, or exceeds the scope granted by the resource owner.">>,
        <<"description">> => <<>>
    };

map(oauth2_invalid_scope) ->
    #{
        <<"code">> => <<"invalid_scope">>,
        <<"status_code">> => ?HTTP_BAD_REQUEST,
        <<"message">> => <<"The authorization grant type is not supported by the authorization server.">>,
        <<"description">> => <<"The authorization grant type is not supported by the authorization server.">>
    };

map(invalid_scheme) ->
    Msg = <<"The authorization scheme is missing or the one provided is not the one required.">>,
    maps:put(<<"message">>, Msg, map(oauth2_invalid_client));

map({no_such_realm, Uri}) ->

    #{
        <<"code">> => ?WAMP_NO_SUCH_REALM,
        <<"message">> => <<"There is no realm named ", $', Uri/binary, $'>>,
        <<"description">> => <<"The request cannot be executed because the realm provided does not exist.">>
    };

map({badarg, {decoding, json}}) ->
    #{
        <<"status_code">> => ?HTTP_BAD_REQUEST,
        <<"code">> => <<"invalid_data">>,
        <<"message">> => <<"The data provided is not a valid json.">>,
        <<"description">> => <<"Make sure the data type you are sending matches a supported mime type and that it matches the request content-type header.">>
    };

map({badarg, {decoding, msgpack}}) ->
    #{
        <<"status_code">> => ?HTTP_BAD_REQUEST,
        <<"code">> => <<"invalid_data">>,
        <<"message">> => <<"The data provided is not a valid msgpack.">>,
        <<"description">> => <<"Make sure the data type you are sending matches a supported mime type and that it matches the request content-type header.">>
    };

map({badarg, {body_max_bytes_exceeded, MaxLen}}) ->
    #{
        <<"status_code">> => ?HTTP_BAD_REQUEST,
        <<"code">> => <<"body_max_bytes_exceeded">>,
        <<"message">> => <<"The body content size exceeds the allowable limit of", $\s, (integer_to_binary(MaxLen))/binary, $\s, "bytes">>,
        <<"description">> => <<"The body cannot be larger that the defined maximum allowed.">>
    };

map({request_error, Key, Desc}) when is_atom(Key), is_atom(Desc) ->
    %% Cowboy error
    #{
        <<"code">> => <<"invalid_request">>,
        <<"status_code">> => ?HTTP_BAD_REQUEST,
        <<"message">> => <<"The request is malformed.">>,
        <<"description">> => <<>>
    };

map({request_error, {Key, _}, Desc}) when is_atom(Key), is_atom(Desc) ->
    %% Cowboy error
    #{
        <<"code">> => <<"invalid_request">>,
        <<"status_code">> => ?HTTP_BAD_REQUEST,
        <<"message">> => <<"The request is malformed.">>,
        <<"description">> => Desc
    };

map({badarg, Mssg}) when is_binary(Mssg); is_list(Mssg); is_atom(Mssg) ->
    #{
        <<"code">> => <<"badarg">>,
        <<"message">> => Mssg,
        <<"description">> => <<"">>
    };

map({badheader, Header, Desc})
when is_binary(Desc); is_list(Desc); is_atom(Desc) ->
    #{
        <<"code">> => <<"badarg">>,
        <<"message">> => <<"The header '", Header/binary, "' is malformed.">>,
        <<"description">> => Desc
    };

map({Code, Mssg}) when is_binary(Mssg); is_list(Mssg); is_atom(Mssg) ->
    #{
        <<"code">> => Code,
        <<"message">> => Mssg,
        <<"description">> => <<>>
    };

map({_, _} = Error) ->
    #{
        <<"code">> => unknown_error,
        <<"message">> => <<"An unknown error ocurred.">>,
        <<"description">> => iolist_to_binary(io_lib:format("~p", [Error]))
    };

map({Code, Mssg, Desc}) ->
    #{
        <<"code">> => Code,
        <<"message">> => Mssg,
        <<"description">> => Desc
    };

map(Code) ->
    #{
        <<"code">> => Code,
        <<"message">> => <<>>,
        <<"description">> => <<>>
    }.


map(Code, Term) when is_binary(Code) ->
    maps:put(<<"code">>, Code, map(Term)).





%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
get_error(#{arguments_kw := #{<<"error">> := Map}}) ->
    Map;

get_error(_) ->
    #{}.


%% @private
get_message(#{arguments := undefined}) ->
    <<>>;

get_message(#{arguments := []}) ->
    <<>>;

get_message(#{arguments := L}) when is_list(L) ->
    hd(L);

get_message(#{arguments_kw := undefined}) ->
    <<>>;

get_message(#{arguments_kw := #{}}) ->
    <<>>;

get_message(#{arguments_kw := #{<<"error">> := Map}}) when is_map(Map) ->
    case maps:find(<<"message">>, Map) of
        {ok, Val} -> Val;
        error -> <<>>
    end;

get_message(_) ->
    <<>>.





