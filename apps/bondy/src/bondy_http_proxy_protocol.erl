%% =============================================================================
%%  bondy_http_proxy_protocol.erl -
%%
%%  Copyright (c) 2016-2023 Leapsight. All rights reserved.
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
-module(bondy_http_proxy_protocol).
-include_lib("partisan/include/partisan_util.hrl").
-include("bondy.hrl").

-type t() :: #{
                enabled := boolean(),
                mode := strict | relaxed,
                proxy_info => #{
                    local_address := inet:ip_address(),
                    src_address := inet:ip_address() | undefined
                },
                error => any() | undefined
            }.


-export([init/1]).
-export([enabled/1]).
-export([error/1]).
-export([has_error/1]).
-export([mode/1]).
-export([proxy_info/1]).
-export([source_ip/1]).




%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec init(cowboy_req:req()) -> t().

init(#{ref := Ref} = Req) ->
    {LocalIP, _Port} = cowboy_req:peer(Req),
    Opts = maps:from_list(bondy_config:get([Ref, proxy_protocol], [])),

    case maps:get(enabled, Opts, false) of
        true ->
            case find_src_address(Req) of
                {ok, SourceIP} ->
                    Opts#{
                        proxy_info => #{
                            local_address => LocalIP,
                            src_address => SourceIP
                        }
                    };

                {error, Reason} ->
                    Opts#{
                        proxy_info => #{local_address => LocalIP},
                        error => Reason
                    }
            end;

        false ->
            Opts#{
                proxy_info => #{local_address => LocalIP}
            }
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
enabled(#{enabled := Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
mode(#{mode := Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
proxy_info(#{proxy_info := Val}) ->
    Val;

proxy_info(_) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
error(#{error := Val}) ->
    Val;

error(_) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
has_error(#{error := _}) -> true;
has_error(#{}) -> false.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
source_ip(#{enabled := true, mode := strict, error := Reason}) ->
    {error, {protocol_error, Reason}};

source_ip(#{enabled := true, mode := Mode, proxy_info := Info}) ->
    case Info of
        #{src_address := SourceIP} ->
            {ok, SourceIP};

        #{local_address := LocalIP} when Mode == relaxed ->
            {ok, LocalIP}
    end;

source_ip(#{enabled := false, proxy_info := #{local_address := LocalIP}}) ->
    {ok, LocalIP}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
find_src_address(Req) ->
    Funs = [
        fun forwarded/1,
        fun real_ip/1,
        fun forwarded_for/1
    ],
    find_src_address(Req, Funs, not_found, undefined).


%% @private
find_src_address(Req, [H | T], Acc, Fallback) ->
    case H(Req) of
        {ok, IP} ->
            case bondy_http_utils:is_public_ip(IP) of
                true ->
                    %% Stop iterating and return IP
                    {ok, IP};
                false ->
                    %% Keep as fallback and continue w/next header
                    find_src_address(Req, T, Acc, IP)
            end;

        {error, Reason} ->
            find_src_address(Req, T, Reason, Fallback)
    end;

find_src_address(_, [], Reason, undefined) ->
    {error, Reason};

find_src_address(_, [], _, Fallback) ->
    {ok, Fallback}.


%% @private
-spec real_ip(cowboy_req:req()) ->
    {ok, inet:ip_address()} | {error, any()}.

real_ip(Req) ->
    try

        case cowboy_req:header(<<"x-real-ip">>, Req, not_found) of
            not_found ->
                {error, not_found};

            Val ->
                case inet:parse_address(binary_to_list(Val)) of
                    {ok, Addr} ->
                        {ok, Addr};

                    {error, _} = Error ->
                        Error
                end
        end

    catch
        _ : {request_error, {header, _}, Reason} ->
            {error, Reason}
    end.


%% @private
-spec forwarded_for(cowboy_req:req()) ->
    {ok, inet:ip_address()} | {error, any()}.

forwarded_for(Req) ->
    try
        L = cowboy_req:parse_header(<<"x-forwarded-for">>, Req, []),
        first_valid_address(L, undefined)
    catch
        _ : {request_error, {header, _}, Reason} ->
            {error, Reason}
    end.


%% @private
-spec forwarded(cowboy_req:req()) ->
    {ok, inet:ip_address()} | {error, any()}.

forwarded(Req) ->
    try
        case cowboy_req:header(<<"forwarded">>, Req, not_found) of
            not_found ->
                {error, not_found};
            Bin ->
                L = parse_forwarded(Bin),
                first_valid_address(L, undefined)
        end
    catch
        _ : {request_error, {header, _}, Reason} ->
            {error, Reason}
    end.


%% @private
first_valid_address([H | T], Fallback) ->
    case inet:parse_address(binary_to_list(H)) of
        {ok, IPAddr} ->
            case bondy_http_utils:is_public_ip(IPAddr) of
                true ->
                    {ok, IPAddr};

                false when Fallback == undefined ->
                    first_valid_address(T, IPAddr);

                false ->
                    first_valid_address(T, Fallback)
            end;

        {error, _} ->
            first_valid_address(T, Fallback)
    end;

first_valid_address([], undefined) ->
    {error, not_found};

first_valid_address([], IPAddr) ->
    {ok, IPAddr}.


parse_forwarded(Bin) ->
    L = [
        parse_forwarded_element(string:trim(X))
        || X <- string:split(Bin, <<",">>, all)
    ],
    lists:flatten(L).


parse_forwarded_element(Bin) ->
    [
        parse_forwarded_pair(string:trim(X))
        || X <- string:split(Bin, <<";">>, all)
    ].


parse_forwarded_pair(<<"for", _/binary>> = Bin) ->
    [_, Value] = string:split(Bin, <<"=">>, all),
    parse_for(string:trim(Value, both, [$"]));

parse_forwarded_pair(_) ->
    %% We are only interested in the IP address
    [].


%% @private
parse_for(<<"[", Rest/binary>>) ->
    %% IPv6
    %% We remove "]" and any port number e.g. "]:9000"
    [IPAddr, _] = string:split(Rest, <<"]">>),
    IPAddr;

parse_for(Bin) ->
    %% IPv4
    [IPAddr | _] = string:split(Bin, <<":">>),
    IPAddr.



