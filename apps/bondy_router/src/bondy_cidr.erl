%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_cidr).
-moduledoc """
Parsing, validation and matching of CIDR notation address ranges, represented
in Erlang as `{inet:ip_address(), Maskbits}` tuples for both IPv4 and IPv6.

Examples:

* single class A network 10.0.0.0 – 10.255.255.255: `{{10, 0, 0, 0}, 8}`
* 16 contiguous class B networks 172.16.0.0 – 172.31.255.255 `{{172, 16, 0, 0}, 12}`
* 256 contiguous class C networks 192.168.0.0 – 192.168.255.255: `{{192, 168, 0, 0}, 16}`
""".

-type t() :: {inet:ip_address(), non_neg_integer()}.

-export_type([t/0]).

-export([parse/1]).
-export([is_type/1]).
-export([mask/1]).
-export([anchor_mask/1]).
-export([match/2]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Parses a binary string representation of a CIDR notation and returns its
erlang representation as a tuple `t()`.

`Bin` must be `Address/Maskbits`. `Address` is a full dotted-quad IPv4 or a
full IPv6 address, as `inet:parse_strict_address/1` accepts it, so a shorthand
such as `10/8` is refused rather than read as `0.0.0.10/8`. `Maskbits` is a
decimal integer within the family's range: 0 to 32 for IPv4, 0 to 128 for IPv6.

Fails with a badarg exception for any other input.
""".
-spec parse(binary()) -> t() | no_return().

parse(Bin) when is_binary(Bin) ->
    case binary:split(Bin, <<"/">>) of
        [Prefix, Len] ->
            Addr = parse_address(Prefix),
            Maskbits = parse_maskbits(Len),
            Maskbits =< max_maskbits(Addr) orelse error(badarg),
            {Addr, Maskbits};
        [_] ->
            error(badarg)
    end;
parse(_) ->
    error(badarg).

-doc """
Returns `true` if term `Term` is a valid CIDR notation representation in
erlang. Otherwise returns `false`.
""".
-spec is_type(Term :: binary()) -> t() | no_return().

is_type({IP, Maskbits}) when
    tuple_size(IP) == 4 andalso Maskbits >= 0 andalso Maskbits =< 32
->
    case inet:ntoa(IP) of
        {error, einval} -> false;
        _ -> true
    end;
is_type({IP, Maskbits}) when
    tuple_size(IP) == 8 andalso Maskbits >= 0 andalso Maskbits =< 128
->
    case inet:ntoa(IP) of
        {error, einval} -> false;
        _ -> true
    end;
is_type(_) ->
    false.

-doc """
Returns `true` if `Left` and `Right` are CIDR notation representations
in erlang and they match. Otherwise returns false.
""".
-spec match(Left :: t(), Right :: t()) -> t() | no_return().

match({_, Maskbits} = Left, {_, Maskbits} = Right) ->
    mask(Left) == mask(Right);
match(_, _) ->
    false.

-spec mask(t()) -> Subnet :: binary().

mask({{_, _, _, _} = Addr, Maskbits}) when
    Maskbits >= 0 andalso Maskbits =< 32
->
    B = list_to_binary(tuple_to_list(Addr)),
    <<Subnet:Maskbits, _Host/bitstring>> = B,
    Subnet;
mask({{A, B, C, D, E, F, G, H}, Maskbits}) when
    Maskbits >= 0 andalso Maskbits =< 128
->
    <<Subnet:Maskbits, _Host/bitstring>> = <<
        A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16
    >>,
    Subnet.

-doc """
Returns the real bottom of a netmask. Eg if 192.168.1.1/16 is
provided, return 192.168.0.0/16.
""".
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

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
parse_address(Prefix) ->
    case inet:parse_strict_address(binary_to_list(Prefix)) of
        {ok, Addr} ->
            Addr;
        {error, einval} ->
            error(badarg)
    end.

%% @private
%% Digits only: `binary_to_integer/1` would also accept a sign.
parse_maskbits(Len) ->
    case re:run(Len, "^[0-9]{1,3}$", [dollar_endonly, {capture, none}]) of
        match ->
            binary_to_integer(Len);
        nomatch ->
            error(badarg)
    end.

%% @private
max_maskbits(Addr) when tuple_size(Addr) =:= 4 ->
    32;
max_maskbits(Addr) when tuple_size(Addr) =:= 8 ->
    128.
