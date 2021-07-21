%% =============================================================================
%%  bondy_cidr.erl -
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

-module(bondy_cidr).



-define(LOCAL_CIDRS, [
    %% single class A network 10.0.0.0 – 10.255.255.255
    {{10, 0, 0, 0}, 8},
    %% 16 contiguous class B networks 172.16.0.0 – 172.31.255.255
    {{172, 16, 0, 0}, 12},
    %% 256 contiguous class C networks 192.168.0.0 – 192.168.255.255
    {{192, 168, 0, 0}, 16}
]).

-type t()   ::  {inet:ip_address(), non_neg_integer()}.

-export([parse/1]).
-export([is_type/1]).
-export([mask/1]).
-export([anchor_mask/1]).
-export([match/2]).



%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc Parses a binary string representation of a CIDR notation and returns its
%% erlang representation as a tuple `t()'.
%% Fails with a badarg exception if the binary `Bin' is not a valid input.
%% @end
%% -----------------------------------------------------------------------------
-spec parse(binary()) -> t() | no_return().

parse(Bin) when is_binary(Bin) ->
    case re:split(Bin, "/", [{return, list}, {parts, 2}]) of
        [Prefix, LenStr] ->
            {ok, Addr} = inet:parse_address(Prefix),
            {Maskbits, _} = string:to_integer(LenStr),
            {Addr, Maskbits};
        _ ->
            error(badarg)
    end;

parse(_) ->
    error(badarg).


%% -----------------------------------------------------------------------------
%% @doc Returns `true' if term `Term' is a valid CIDR notation representation in
%% erlang. Otherwise returns `false'.
%% @end
%% -----------------------------------------------------------------------------
-spec is_type(Term :: binary()) -> t() | no_return().

is_type({IP, Maskbits})
when tuple_size(IP) == 4 andalso Maskbits >= 0 andalso Maskbits =< 32 ->
    case inet:ntoa(IP) of
        {error, einval} -> false;
        _ -> true
    end;

is_type({IP, Maskbits})
when tuple_size(IP) == 8 andalso Maskbits >= 0 andalso Maskbits =< 128 ->
    case inet:ntoa(IP) of
        {error, einval} -> false;
        _ -> true
    end;

is_type(_) ->
    false.


%% -----------------------------------------------------------------------------
%% @doc Returns `true' if `Left' and `Right' are CIDR notation representations
%% in erlang and they match. Otherwise returns false.
%% @end
%% -----------------------------------------------------------------------------
-spec match(Left :: t(), Right :: t()) -> t() | no_return().

match({_, Maskbits} = Left, {_, Maskbits} = Right) ->
    mask(Left) == mask(Right);

match(_, _) ->
    false.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec mask(t()) -> Subnet :: binary().

mask({{_, _, _, _} = Addr, Maskbits})
when Maskbits >= 0 andalso Maskbits =< 32 ->
    B = list_to_binary(tuple_to_list(Addr)),
    <<Subnet:Maskbits, _Host/bitstring>> = B,
    Subnet;

mask({{A, B, C, D, E, F, G, H}, Maskbits})
when Maskbits >= 0 andalso Maskbits =< 128 ->
    <<Subnet:Maskbits, _Host/bitstring>> = <<
        A:16, B:16, C:16, D:16, E:16,F:16, G:16, H:16
    >>,
    Subnet.


%% -----------------------------------------------------------------------------
%% @doc returns the real bottom of a netmask. Eg if 192.168.1.1/16 is
%% provided, return 192.168.0.0/16
%% @end
%% -----------------------------------------------------------------------------
-spec anchor_mask(t()) -> t().


anchor_mask({Addr, Maskbits} = CIDR) when tuple_size(Addr) == 4 ->
    M = mask(CIDR),
    Rem = 32 - Maskbits,
    <<A:8, B:8, C:8, D:8>> = <<M:Maskbits, 0:Rem>>,
    {{A, B, C, D}, Maskbits};

anchor_mask({Addr, Maskbits} = CIDR) when tuple_size(Addr) == 8 ->
    M = mask(CIDR),
    Rem = 128 - Maskbits,
    <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>> = <<M:Maskbits, 0:Rem>>,
    {{A, B, C, D, E, F, G, H}, Maskbits};

anchor_mask(_) ->
    error(badarg).