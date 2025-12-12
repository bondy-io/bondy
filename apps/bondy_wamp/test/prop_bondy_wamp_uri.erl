%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% @doc Property-based tests for bondy_wamp_uri (WAMP URI validation and matching).
%%
%% WAMP URIs follow specific rules for format and matching strategies.
%% @end
-module(prop_bondy_wamp_uri).

-include_lib("proper/include/proper.hrl").
-include("bondy_wamp.hrl").

%% Properties
-export([
    prop_valid_loose_uri_accepted/0,
    prop_valid_strict_uri_accepted/0,
    prop_empty_uri_only_loose_prefix/0,
    prop_exact_match_reflexive/0,
    prop_prefix_match_reflexive/0,
    prop_wildcard_match_reflexive/0,
    prop_prefix_match_empty_pattern/0,
    prop_wildcard_match_same_components/0,
    prop_components_valid_uri/0,
    prop_components_reconstructable/0
]).


%% =============================================================================
%% Generators
%% =============================================================================

%% Generate a valid loose URI component (no spaces, dots, or hashes)
loose_component() ->
    ?LET(Chars,
         non_empty(list(oneof([
             range($a, $z),
             range($A, $Z),
             range($0, $9),
             $_,
             $-
         ]))),
         list_to_binary(Chars)).


%% Generate a valid strict URI component (lowercase, digits, underscore only)
strict_component() ->
    ?LET(Chars,
         non_empty(list(oneof([
             range($a, $z),
             range($0, $9),
             $_
         ]))),
         list_to_binary(Chars)).


%% Generate a list of 2-5 components (avoids SUCHTHAT constraint issues)
components_list(ComponentGen) ->
    ?LET(N, range(2, 5),
         vector(N, ComponentGen)).


%% Generate a valid loose URI (at least 2 components separated by dots)
loose_uri() ->
    ?LET(Components, components_list(loose_component()),
         iolist_to_binary(lists:join(<<".">>, Components))).


%% Generate a valid strict URI
strict_uri() ->
    ?LET(Components, components_list(strict_component()),
         iolist_to_binary(lists:join(<<".">>, Components))).


%% Generate a URI suitable for wildcard matching (may have empty components)
wildcard_uri() ->
    ?LET(Components,
         ?SUCHTHAT(L, non_empty(list(oneof([loose_component(), <<>>]))),
                   length(L) >= 2 andalso
                   lists:any(fun(C) -> C =/= <<>> end, L)),
         iolist_to_binary(lists:join(<<".">>, Components))).


%% Generate a URI suitable for prefix matching (may have trailing dot)
prefix_uri() ->
    ?LET({Uri, TrailingDot},
         {loose_uri(), boolean()},
         case TrailingDot of
             true -> <<Uri/binary, ".">>;
             false -> Uri
         end).


%% Generate invalid URIs
invalid_uri() ->
    oneof([
        %% Contains spaces
        <<"com.example.my procedure">>,
        %% Contains hash (reserved)
        <<"com.example#topic">>,
        %% Single component
        <<"justoneword">>,
        %% Just dots
        <<"...">>,
        %% Empty
        <<>>
    ]).


%% =============================================================================
%% Properties: Validation
%% =============================================================================

%% Property: Valid loose URIs are accepted by is_valid/2 with loose rule
prop_valid_loose_uri_accepted() ->
    ?FORALL(Uri, loose_uri(),
            bondy_wamp_uri:is_valid(Uri, loose)).


%% Property: Valid strict URIs are accepted by is_valid/2 with strict rule
prop_valid_strict_uri_accepted() ->
    ?FORALL(Uri, strict_uri(),
            bondy_wamp_uri:is_valid(Uri, strict)).


%% Property: Empty URI is only valid with loose_prefix rule
prop_empty_uri_only_loose_prefix() ->
    ?FORALL(_, term(),
            begin
                %% Empty URI should be valid only with loose_prefix
                bondy_wamp_uri:is_valid(<<>>, loose_prefix) andalso
                not bondy_wamp_uri:is_valid(<<>>, loose) andalso
                not bondy_wamp_uri:is_valid(<<>>, strict)
            end).


%% =============================================================================
%% Properties: Matching
%% =============================================================================

%% Property: Exact match is reflexive - a URI matches itself
prop_exact_match_reflexive() ->
    ?FORALL(Uri, loose_uri(),
            bondy_wamp_uri:match(Uri, Uri, ?EXACT_MATCH)).


%% Property: Prefix match is reflexive - a URI matches itself
prop_prefix_match_reflexive() ->
    ?FORALL(Uri, loose_uri(),
            bondy_wamp_uri:match(Uri, Uri, ?PREFIX_MATCH)).


%% Property: Wildcard match is reflexive - a URI matches itself
prop_wildcard_match_reflexive() ->
    ?FORALL(Uri, loose_uri(),
            bondy_wamp_uri:match(Uri, Uri, ?WILDCARD_MATCH)).


%% Property: Empty pattern matches everything in prefix mode
prop_prefix_match_empty_pattern() ->
    ?FORALL(Uri, loose_uri(),
            bondy_wamp_uri:match(Uri, <<>>, ?PREFIX_MATCH)).


%% Property: Wildcard match requires same number of components
prop_wildcard_match_same_components() ->
    ?FORALL({Uri1, Uri2}, {loose_uri(), loose_uri()},
            begin
                Components1 = binary:split(Uri1, <<".">>, [global]),
                Components2 = binary:split(Uri2, <<".">>, [global]),
                case length(Components1) =:= length(Components2) of
                    true ->
                        %% When same number of components, wildcard might match
                        %% (depending on component values)
                        true;
                    false ->
                        %% Different number of components should not match
                        not bondy_wamp_uri:match(Uri1, Uri2, ?WILDCARD_MATCH)
                end
            end).


%% =============================================================================
%% Properties: Components
%% =============================================================================

%% Generate a list of exactly 3-5 components for components tests
components_list_3plus() ->
    ?LET(N, range(3, 5),
         vector(N, loose_component())).


%% Property: components/1 works on valid URIs with at least 3 components
prop_components_valid_uri() ->
    ?FORALL(Components, components_list_3plus(),
            begin
                Uri = iolist_to_binary(lists:join(<<".">>, Components)),
                ResultComponents = bondy_wamp_uri:components(Uri),
                is_list(ResultComponents) andalso length(ResultComponents) >= 2
            end).


%% Property: Domain component contains the first two parts
prop_components_reconstructable() ->
    ?FORALL(Components, components_list_3plus(),
            begin
                Uri = iolist_to_binary(lists:join(<<".">>, Components)),
                [Domain | Rest] = bondy_wamp_uri:components(Uri),
                %% Domain should be first.second
                ExpectedDomain = iolist_to_binary([
                    lists:nth(1, Components),
                    <<".">>,
                    lists:nth(2, Components)
                ]),
                %% Rest should be remaining components
                ExpectedRest = lists:nthtail(2, Components),
                Domain =:= ExpectedDomain andalso Rest =:= ExpectedRest
            end).
