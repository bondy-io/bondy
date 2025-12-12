%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% @doc Property-based tests for bondy_cidr (CIDR notation parsing and matching).
%%
%% Tests IPv4 and IPv6 CIDR notation parsing, mask operations, and matching.
%% @end
-module(prop_bondy_cidr).

-include_lib("proper/include/proper.hrl").

%% Properties
-export([
    prop_parse_valid_ipv4_cidr/0,
    prop_parse_valid_ipv6_cidr/0,
    prop_is_type_accepts_valid/0,
    prop_is_type_rejects_invalid/0,
    prop_mask_ipv4_bounds/0,
    prop_mask_ipv6_bounds/0,
    prop_anchor_mask_idempotent/0,
    prop_match_reflexive/0,
    prop_match_same_maskbits_required/0,
    prop_anchor_mask_preserves_maskbits/0
]).


%% =============================================================================
%% Generators
%% =============================================================================

%% Generate a valid IPv4 octet
ipv4_octet() ->
    range(0, 255).


%% Generate a valid IPv4 address tuple
ipv4_address() ->
    ?LET({A, B, C, D}, {ipv4_octet(), ipv4_octet(), ipv4_octet(), ipv4_octet()},
         {A, B, C, D}).


%% Generate a valid IPv4 maskbits (0-32)
ipv4_maskbits() ->
    range(0, 32).


%% Generate a valid IPv4 CIDR tuple
ipv4_cidr() ->
    ?LET({Addr, Maskbits}, {ipv4_address(), ipv4_maskbits()},
         {Addr, Maskbits}).


%% Generate a valid IPv4 CIDR as binary string
ipv4_cidr_binary() ->
    ?LET({{A, B, C, D}, Maskbits}, ipv4_cidr(),
         list_to_binary(
             io_lib:format("~B.~B.~B.~B/~B", [A, B, C, D, Maskbits])
         )).


%% Generate a valid IPv6 segment (16-bit)
ipv6_segment() ->
    range(0, 65535).


%% Generate a valid IPv6 address tuple
ipv6_address() ->
    ?LET({A, B, C, D, E, F, G, H},
         {ipv6_segment(), ipv6_segment(), ipv6_segment(), ipv6_segment(),
          ipv6_segment(), ipv6_segment(), ipv6_segment(), ipv6_segment()},
         {A, B, C, D, E, F, G, H}).


%% Generate a valid IPv6 maskbits (0-128)
ipv6_maskbits() ->
    range(0, 128).


%% Generate a valid IPv6 CIDR tuple
ipv6_cidr() ->
    ?LET({Addr, Maskbits}, {ipv6_address(), ipv6_maskbits()},
         {Addr, Maskbits}).


%% Generate a valid IPv6 CIDR as binary string
ipv6_cidr_binary() ->
    ?LET({{A, B, C, D, E, F, G, H}, Maskbits}, ipv6_cidr(),
         list_to_binary(
             io_lib:format("~.16B:~.16B:~.16B:~.16B:~.16B:~.16B:~.16B:~.16B/~B",
                           [A, B, C, D, E, F, G, H, Maskbits])
         )).


%% Generate any valid CIDR tuple
any_cidr() ->
    oneof([ipv4_cidr(), ipv6_cidr()]).


%% Generate invalid CIDR representations
invalid_cidr_term() ->
    oneof([
        %% Invalid maskbits for IPv4
        ?LET(Addr, ipv4_address(), {Addr, 33}),
        ?LET(Addr, ipv4_address(), {Addr, -1}),
        %% Invalid maskbits for IPv6
        ?LET(Addr, ipv6_address(), {Addr, 129}),
        ?LET(Addr, ipv6_address(), {Addr, -1}),
        %% Invalid address tuples
        {invalid, 16},
        {{256, 0, 0, 0}, 8}, %% Invalid octet
        {{-1, 0, 0, 0}, 8},  %% Negative octet
        %% Not a tuple
        <<"192.168.1.0/24">>,
        "192.168.1.0/24",
        42
    ]).


%% =============================================================================
%% Properties: Parsing
%% =============================================================================

%% Property: parse accepts valid IPv4 CIDR strings
prop_parse_valid_ipv4_cidr() ->
    ?FORALL(CIDRBin, ipv4_cidr_binary(),
            begin
                Result = bondy_cidr:parse(CIDRBin),
                {Addr, Maskbits} = Result,
                tuple_size(Addr) =:= 4 andalso
                Maskbits >= 0 andalso Maskbits =< 32
            end).


%% Property: parse accepts valid IPv6 CIDR strings
prop_parse_valid_ipv6_cidr() ->
    ?FORALL(CIDRBin, ipv6_cidr_binary(),
            begin
                Result = bondy_cidr:parse(CIDRBin),
                {Addr, Maskbits} = Result,
                tuple_size(Addr) =:= 8 andalso
                Maskbits >= 0 andalso Maskbits =< 128
            end).


%% =============================================================================
%% Properties: Type Checking
%% =============================================================================

%% Property: is_type accepts valid CIDR tuples
prop_is_type_accepts_valid() ->
    ?FORALL(CIDR, any_cidr(),
            bondy_cidr:is_type(CIDR)).


%% Property: is_type rejects invalid terms
prop_is_type_rejects_invalid() ->
    ?FORALL(Invalid, invalid_cidr_term(),
            not bondy_cidr:is_type(Invalid)).


%% =============================================================================
%% Properties: Mask Operations
%% =============================================================================

%% Property: mask for IPv4 produces values within bounds
prop_mask_ipv4_bounds() ->
    ?FORALL(CIDR, ipv4_cidr(),
            begin
                {_Addr, Maskbits} = CIDR,
                Mask = bondy_cidr:mask(CIDR),
                %% Mask should fit in Maskbits bits
                Mask >= 0 andalso Mask < (1 bsl Maskbits)
            end).


%% Property: mask for IPv6 produces values within bounds
prop_mask_ipv6_bounds() ->
    ?FORALL(CIDR, ipv6_cidr(),
            begin
                {_Addr, Maskbits} = CIDR,
                Mask = bondy_cidr:mask(CIDR),
                %% Mask should fit in Maskbits bits
                Mask >= 0 andalso Mask < (1 bsl Maskbits)
            end).


%% Property: anchor_mask is idempotent
%% anchor_mask(anchor_mask(CIDR)) == anchor_mask(CIDR)
prop_anchor_mask_idempotent() ->
    ?FORALL(CIDR, any_cidr(),
            begin
                Anchored = bondy_cidr:anchor_mask(CIDR),
                DoubleAnchored = bondy_cidr:anchor_mask(Anchored),
                Anchored =:= DoubleAnchored
            end).


%% Property: anchor_mask preserves maskbits
prop_anchor_mask_preserves_maskbits() ->
    ?FORALL(CIDR, any_cidr(),
            begin
                {_Addr, Maskbits} = CIDR,
                {_AnchoredAddr, AnchoredMaskbits} = bondy_cidr:anchor_mask(CIDR),
                Maskbits =:= AnchoredMaskbits
            end).


%% =============================================================================
%% Properties: Matching
%% =============================================================================

%% Property: match is reflexive for anchored CIDRs
%% A CIDR matches itself when anchored
prop_match_reflexive() ->
    ?FORALL(CIDR, any_cidr(),
            begin
                Anchored = bondy_cidr:anchor_mask(CIDR),
                bondy_cidr:match(Anchored, Anchored)
            end).


%% Property: match requires same maskbits
prop_match_same_maskbits_required() ->
    ?FORALL({CIDR1, CIDR2}, {ipv4_cidr(), ipv4_cidr()},
            begin
                {_Addr1, Maskbits1} = CIDR1,
                {_Addr2, Maskbits2} = CIDR2,
                case Maskbits1 =:= Maskbits2 of
                    true ->
                        %% When maskbits are equal, match depends on the mask
                        true;
                    false ->
                        %% When maskbits differ, match should return false
                        not bondy_cidr:match(CIDR1, CIDR2)
                end
            end).
