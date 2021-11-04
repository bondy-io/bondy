%% =============================================================================
%%  bondy_http_utils.erl -
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
-module(bondy_http_utils).


-export([client_ip/1]).
-export([real_ip/1]).
-export([forwarded_for/1]).
-export([set_meta_headers/1]).
-export([meta_headers/0]).
-export([parse_authorization/1]).

-on_load(on_load/0).



%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc Returns a binary representation of the IP or `<<"unknown">>'.
%% @end
%% -----------------------------------------------------------------------------
-spec client_ip(Req :: cowboy_req:req()) -> binary() | undefined.

client_ip(Req) ->
    case real_ip(Req) of
        undefined -> forwarded_for(Req);
        Value -> Value
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec real_ip(cowboy_req:req()) -> binary() | undefined.

real_ip(Req) ->
    cowboy_req:header(<<"x-real-ip">>, Req, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec forwarded_for(cowboy_req:req()) -> binary() | undefined.

forwarded_for(Req) ->
    case cowboy_req:parse_header(<<"x-forwarded-for">>, Req, undefined) of
        [H|_] -> H;
        Val -> Val
    end.

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec set_meta_headers(Req :: cowboy_req:req()) ->
    NewReq :: cowboy_req:req().

set_meta_headers(Req) ->
    cowboy_req:set_resp_headers(meta_headers(), Req).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec meta_headers() -> map().

meta_headers() ->
    persistent_term:get({?MODULE, meta_headers}).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec parse_authorization(Req :: cowboy_req:req()) ->
    {basic, binary(), binary()}
    | {bearer, binary()}
    | {digest, [{binary(), binary()}]}.

parse_authorization(Req) ->
    %% The authorization header has the based64 encoding of the
    %% string username ++ ":" ++ password.
    %% We allow Usernames with colons (as opposed to the HTTP Basic RFC
    %% standard) but we do not allow colons in passwords.
    %% cowboy_req:parse_header/2 follows the RFC standard, so we need
    %% to make sure to split the username and password correctly
    case cowboy_req:parse_header(<<"authorization">>, Req) of
        {basic, A, B} = Basic ->
            case binary:matches(B, <<$:>>) of
                [] ->
                    %% No additional colons
                    Basic;
                L ->
                    %% We found at least one colon, the last one is the
                    %% separator between username and password
                    {Pos, 1} = lists:last(L),
                    Rest = binary_part(B, 0, Pos),
                    Username = <<A/binary, Rest/binary>>,
                    Password = binary_part(B, Pos + 1, byte_size(B) - Pos - 1),
                    {basic, Username, Password}
            end;
        Other ->
            Other
    end.



%% =============================================================================
%% PRIVATE
%% =============================================================================


on_load() ->
    Meta = #{
        <<"server">> => "bondy/" ++ bondy_config:get(vsn, "undefined")
    },
    ok = persistent_term:put({?MODULE, meta_headers}, Meta),
    ok.
